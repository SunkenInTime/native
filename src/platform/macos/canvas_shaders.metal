#include <metal_stdlib>
using namespace metal;

struct NativeSdkCanvasVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex NativeSdkCanvasVertexOut native_sdk_canvas_vertex(uint vertex_id [[vertex_id]]) {
    constexpr float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0, 1.0), float2(1.0, 1.0),
    };
    constexpr float2 uvs[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0),
    };
    return { float4(positions[vertex_id], 0.0, 1.0), uvs[vertex_id] };
}

fragment float4 native_sdk_canvas_fragment(
    NativeSdkCanvasVertexOut in [[stage_in]],
    texture2d<float> canvas_texture [[texture(0)]],
    sampler texture_sampler [[sampler(0)]]) {
    return canvas_texture.sample(texture_sampler, in.uv);
}

struct NativeSdkCompositeUniforms {
    float2 viewport;
    float2 rect_origin;
    float2 rect_size;
    float2 tex_origin;
    float2 shape_origin;
    float2 shape_size;
    float4 color;
    float4 corner_radius;
    uint primitive;
    uint3 pad;
};

struct NativeSdkCompositeVertexOut {
    float4 position [[position]];
};

vertex NativeSdkCompositeVertexOut native_sdk_composite_vertex(
    uint vertex_id [[vertex_id]],
    constant NativeSdkCompositeUniforms &uniforms [[buffer(0)]]) {
    float2 corner = float2(float(vertex_id & 1u), float(vertex_id >> 1u));
    float2 pixel = uniforms.rect_origin + corner * uniforms.rect_size;
    return { float4(pixel.x / uniforms.viewport.x * 2.0 - 1.0,
                    1.0 - pixel.y / uniforms.viewport.y * 2.0,
                    0.0, 1.0) };
}

fragment float4 native_sdk_composite_fragment(
    NativeSdkCompositeVertexOut in [[stage_in]],
    constant NativeSdkCompositeUniforms &uniforms [[buffer(0)]],
    texture2d<float, access::read> quad_texture [[texture(0)]]) {
    if (uniforms.primitive == 0u) return uniforms.color;
    if (uniforms.primitive == 2u) {
        float2 half_extent = uniforms.shape_size * 0.5;
        float2 local = in.position.xy - (uniforms.shape_origin + half_extent);
        float radius = local.x < 0.0
            ? (local.y < 0.0 ? uniforms.corner_radius.x : uniforms.corner_radius.w)
            : (local.y < 0.0 ? uniforms.corner_radius.y : uniforms.corner_radius.z);
        float2 q = abs(local) - half_extent + radius;
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float coverage = clamp(0.5 - distance, 0.0, 1.0);
        return uniforms.color * coverage;
    }
    int2 pixel = int2(in.position.xy);
    int2 texel = pixel - int2(uniforms.rect_origin) + int2(uniforms.tex_origin);
    texel = clamp(texel, int2(0),
                  int2(int(quad_texture.get_width()) - 1,
                       int(quad_texture.get_height()) - 1));
    return quad_texture.read(uint2(texel));
}
