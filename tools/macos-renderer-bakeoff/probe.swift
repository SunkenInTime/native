import Foundation
import Metal

struct ProbeError: Error, CustomStringConvertible {
    let description: String
}

struct SurfaceResources {
    let canvas: MTLTexture
    let uploads: [MTLBuffer]
}

func elapsedMicroseconds(_ start: UInt64) -> UInt64 {
    (DispatchTime.now().uptimeNanoseconds - start) / 1_000
}

func makePipeline(_ device: MTLDevice, _ library: MTLLibrary,
                  _ vertex: String, _ fragment: String,
                  blending: Bool) throws -> MTLRenderPipelineState {
    guard let vertexFunction = library.makeFunction(name: vertex),
          let fragmentFunction = library.makeFunction(name: fragment) else {
        throw ProbeError(description: "metallib is missing a probe shader")
    }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = blending
    if blending {
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    return try device.makeRenderPipelineState(descriptor: descriptor)
}

func main() throws {
    guard CommandLine.arguments.count == 4,
          let count = Int(CommandLine.arguments[3]), [1, 3, 10].contains(count) else {
        throw ProbeError(description: "usage: renderer-probe <shaders.metal> <shaders.metallib> <1|3|10>")
    }
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw ProbeError(description: "Metal is unavailable")
    }
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let libraryURL = URL(fileURLWithPath: CommandLine.arguments[2])
    let source = try String(contentsOf: sourceURL, encoding: .utf8)

    var perViewRuntimeCompileUs: [UInt64] = []
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        let library = try device.makeLibrary(source: source, options: nil)
        _ = try makePipeline(device, library, "native_sdk_canvas_vertex",
                             "native_sdk_canvas_fragment", blending: false)
        perViewRuntimeCompileUs.append(elapsedMicroseconds(start))
    }

    let cacheStart = DispatchTime.now().uptimeNanoseconds
    let libraryLoadStart = DispatchTime.now().uptimeNanoseconds
    let library = try device.makeLibrary(URL: libraryURL)
    let libraryLoadUs = elapsedMicroseconds(libraryLoadStart)
    guard let queue = device.makeCommandQueue() else {
        throw ProbeError(description: "could not create shared command queue")
    }
    _ = queue
    _ = try makePipeline(device, library, "native_sdk_canvas_vertex",
                         "native_sdk_canvas_fragment", blending: false)
    _ = try makePipeline(device, library, "native_sdk_composite_vertex",
                         "native_sdk_composite_fragment", blending: true)
    let samplerDescriptor = MTLSamplerDescriptor()
    samplerDescriptor.minFilter = .nearest
    samplerDescriptor.magFilter = .nearest
    guard device.makeSamplerState(descriptor: samplerDescriptor) != nil else {
        throw ProbeError(description: "could not create shared sampler")
    }
    let processCacheUs = elapsedMicroseconds(cacheStart)

    let bytesPerSurface = 480 * 320 * 4
    var surfaces: [SurfaceResources] = []
    var perSurfaceCreateUs: [UInt64] = []
    for _ in 0..<count {
        let start = DispatchTime.now().uptimeNanoseconds
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 480, height: 320, mipmapped: false)
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.shaderRead, .renderTarget]
        guard let canvas = device.makeTexture(descriptor: textureDescriptor) else {
            throw ProbeError(description: "could not create canvas texture")
        }
        let uploads = try (0..<3).map { _ -> MTLBuffer in
            guard let buffer = device.makeBuffer(length: bytesPerSurface,
                                                  options: .storageModeShared) else {
                throw ProbeError(description: "could not create bounded upload ring")
            }
            return buffer
        }
        surfaces.append(SurfaceResources(canvas: canvas, uploads: uploads))
        perSurfaceCreateUs.append(elapsedMicroseconds(start))
    }

    let payload: [String: Any] = [
        "schema": 1,
        "surfaces": surfaces.count,
        "runtime_source_compile_us": perViewRuntimeCompileUs,
        "runtime_source_compile_total_us": perViewRuntimeCompileUs.reduce(0, +),
        "precompiled_metallib_load_us": libraryLoadUs,
        "process_cache_init_us": processCacheUs,
        "process_cache": ["devices": 1, "queues": 1, "libraries": 1,
                          "pipelines": 2, "samplers": 1],
        "per_surface_create_us": perSurfaceCreateUs,
        "bounded_upload_buffers_per_surface": 3,
        "declared_resource_bytes": bytesPerSurface * 4 * count,
    ]
    let data = try JSONSerialization.data(withJSONObject: payload,
                                          options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

do {
    try main()
} catch {
    FileHandle.standardError.write(Data("renderer-probe: \(error)\n".utf8))
    exit(1)
}
