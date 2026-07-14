#include "d3d_presenter.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dcomp.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

template <typename T>
bool readScalar(const uint8_t *&cursor, const uint8_t *end, T *value) {
    if ((size_t)(end - cursor) < sizeof(T)) return false;
    memcpy(value, cursor, sizeof(T));
    cursor += sizeof(T);
    return true;
}

bool skipBytes(const uint8_t *&cursor, const uint8_t *end, size_t count) {
    if ((size_t)(end - cursor) < count) return false;
    cursor += count;
    return true;
}

struct F4 { float x, y, z, w; };

struct Instance {
    F4 rect;
    F4 color;
    F4 shape; // radius, kind (0 rounded rect / 1 line), x1, y1
    F4 extra; // x2, y2, thickness, unused
};

struct RetainedCommand {
    std::vector<Instance> instances;
};

struct PacketReader {
    const uint8_t *cursor;
    const uint8_t *end;

    bool u8(uint8_t *value) { return readScalar(cursor, end, value); }
    bool u32(uint32_t *value) { return readScalar(cursor, end, value); }
    bool u64(uint64_t *value) { return readScalar(cursor, end, value); }
    bool f32(float *value) { return readScalar(cursor, end, value) && std::isfinite(*value); }
    bool rect(F4 *value) { return f32(&value->x) && f32(&value->y) && f32(&value->z) && f32(&value->w); }
    bool skip(size_t count) { return skipBytes(cursor, end, count); }
};

bool readRadius(PacketReader &reader, float *radius) {
    float values[4];
    if (!reader.f32(&values[0]) || !reader.f32(&values[1]) ||
        !reader.f32(&values[2]) || !reader.f32(&values[3])) return false;
    *radius = std::max(0.0f, *std::max_element(values, values + 4));
    return true;
}

bool readColor(PacketReader &reader, F4 *color) {
    if (!reader.f32(&color->x) || !reader.f32(&color->y) ||
        !reader.f32(&color->z) || !reader.f32(&color->w)) return false;
    color->x *= color->w;
    color->y *= color->w;
    color->z *= color->w;
    return true;
}

bool readPaint(PacketReader &reader, F4 *color) {
    uint8_t tag = 0;
    if (!reader.u8(&tag)) return false;
    if (tag == 1) return readColor(reader, color);
    // Gradients stay on the pixel fallback until the shader receives a
    // second-stop instance channel; accepting them as a flat color would
    // be a silent rendering lie.
    return false;
}

bool readCommand(PacketReader &reader, RetainedCommand *out) {
    uint8_t kind = 0, flags = 0, cap = 0;
    F4 bounds = {}, clip = {};
    float opacity = 1, stroke_width = 0;
    if (!reader.u8(&kind) || !reader.u8(&flags) || !reader.rect(&bounds) ||
        !reader.f32(&opacity) || !reader.f32(&stroke_width) || !reader.u8(&cap)) return false;
    if (flags & 0x01) { uint64_t id; if (!reader.u64(&id)) return false; }
    if (flags & 0x02) { if (!reader.rect(&clip)) return false; }
    if (flags & 0x04) {
        float transform[6];
        for (float &part : transform) if (!reader.f32(&part)) return false;
        // Weaver's immediate canvas currently emits identity transforms.
        // Refuse an unexpected transform rather than draw in the wrong place.
        if (transform[0] != 1 || transform[1] != 0 || transform[2] != 0 ||
            transform[3] != 1 || transform[4] != 0 || transform[5] != 0) return false;
    }
    if ((flags & 0x08) == 0 || (flags & 0x10) == 0) return false;
    if (flags & (0x20 | 0x40 | 0x80)) return false; // image, text, effects

    uint8_t shape_tag = 0;
    if (!reader.u8(&shape_tag)) return false;
    std::vector<Instance> instances;
    Instance base = {};
    base.rect = bounds;
    base.shape.y = 0;

    if (shape_tag == 1) {
        if (!reader.rect(&base.rect)) return false;
        base.shape.x = 0;
        instances.push_back(base);
    } else if (shape_tag == 2) {
        if (!reader.rect(&base.rect) || !readRadius(reader, &base.shape.x)) return false;
        instances.push_back(base);
    } else if (shape_tag == 3) {
        // Stroked rounded rectangles require a ring SDF, not a filled quad.
        return false;
    } else if (shape_tag == 4) {
        float x1, y1, x2, y2, width;
        if (!reader.f32(&x1) || !reader.f32(&y1) || !reader.f32(&x2) ||
            !reader.f32(&y2) || !reader.f32(&width)) return false;
        const float half = width * 0.5f;
        base.rect = { std::min(x1, x2) - half, std::min(y1, y2) - half,
            std::abs(x2 - x1) + width, std::abs(y2 - y1) + width };
        base.shape = { 0, 1, x1, y1 };
        base.extra = { x2, y2, width, cap == 1 ? 1.0f : 0.0f };
        instances.push_back(base);
    } else if (shape_tag == 5) {
        uint32_t count = 0;
        if (!reader.u32(&count) || count > 4096) return false;
        float start_x = 0, start_y = 0, previous_x = 0, previous_y = 0;
        bool has_previous = false;
        for (uint32_t i = 0; i < count; ++i) {
            uint8_t verb = 0;
            if (!reader.u8(&verb)) return false;
            const int points = verb <= 1 ? 1 : verb == 2 ? 2 : verb == 3 ? 3 : 0;
            float last_x = previous_x, last_y = previous_y;
            for (int point = 0; point < points; ++point) {
                if (!reader.f32(&last_x) || !reader.f32(&last_y)) return false;
            }
            if (verb == 0) {
                start_x = previous_x = last_x;
                start_y = previous_y = last_y;
                has_previous = true;
            } else if (verb == 1 && has_previous) {
                const float half = stroke_width * 0.5f;
                Instance line = base;
                line.rect = { std::min(previous_x, last_x) - half, std::min(previous_y, last_y) - half,
                    std::abs(last_x - previous_x) + stroke_width, std::abs(last_y - previous_y) + stroke_width };
                line.shape = { 0, 1, previous_x, previous_y };
                line.extra = { last_x, last_y, stroke_width, cap == 1 ? 1.0f : 0.0f };
                instances.push_back(line);
                previous_x = last_x;
                previous_y = last_y;
            } else if (verb == 4 && has_previous) {
                const float half = stroke_width * 0.5f;
                Instance line = base;
                line.rect = { std::min(previous_x, start_x) - half, std::min(previous_y, start_y) - half,
                    std::abs(start_x - previous_x) + stroke_width, std::abs(start_y - previous_y) + stroke_width };
                line.shape = { 0, 1, previous_x, previous_y };
                line.extra = { start_x, start_y, stroke_width, cap == 1 ? 1.0f : 0.0f };
                instances.push_back(line);
                previous_x = start_x;
                previous_y = start_y;
            } else if (verb > 1) {
                return false; // curves need tessellation
            }
        }
        if (instances.empty()) return false;
    } else {
        return false;
    }

    F4 color = {};
    if (!readPaint(reader, &color)) return false;
    color.x *= opacity; color.y *= opacity; color.z *= opacity; color.w *= opacity;
    for (Instance &instance : instances) instance.color = color;
    out->instances = std::move(instances);
    (void)kind;
    (void)clip;
    return true;
}

const char *shaderSource = R"(
struct Instance { float4 rect; float4 color; float4 shape; float4 extra; };
StructuredBuffer<Instance> instances : register(t0);
struct Out { float4 position:SV_POSITION; float2 pixel:TEXCOORD0; nointerpolation float4 rect:TEXCOORD1; nointerpolation float4 color:COLOR0; nointerpolation float4 shape:TEXCOORD2; nointerpolation float4 extra:TEXCOORD3; };
cbuffer Surface : register(b0) { float2 surface; float2 padding; };
Out vsMain(uint vertex:SV_VertexID, uint instance:SV_InstanceID) {
  const float2 corners[6] = { float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1) };
  Instance i=instances[instance]; float2 p=i.rect.xy+corners[vertex]*i.rect.zw;
  Out o; o.position=float4(p.x/surface.x*2-1,1-p.y/surface.y*2,0,1); o.pixel=p; o.rect=i.rect; o.color=i.color; o.shape=i.shape; o.extra=i.extra; return o;
}
float4 psMain(Out i):SV_TARGET {
  float distance;
  if (i.shape.y > 0.5) {
    float2 a=i.shape.zw, b=i.extra.xy, pa=i.pixel-a, ba=b-a;
    float h=saturate(dot(pa,ba)/max(dot(ba,ba),0.0001));
    distance=length(pa-ba*h)-i.extra.z*0.5;
  } else {
    float2 center=i.rect.xy+i.rect.zw*0.5, q=abs(i.pixel-center)-(i.rect.zw*0.5-i.shape.x);
    distance=length(max(q,0))+min(max(q.x,q.y),0)-i.shape.x;
  }
  float coverage=saturate(0.5-distance); return i.color*coverage;
})";

HRESULT compileShader(const char *entry, const char *target, ID3DBlob **blob) {
    using CompileFn = HRESULT (WINAPI *)(LPCVOID, SIZE_T, LPCSTR,
        const D3D_SHADER_MACRO *, ID3DInclude *, LPCSTR, LPCSTR, UINT, UINT,
        ID3DBlob **, ID3DBlob **);
    static HMODULE compiler = LoadLibraryW(L"d3dcompiler_47.dll");
    static CompileFn compile = compiler ? reinterpret_cast<CompileFn>(GetProcAddress(compiler, "D3DCompile")) : nullptr;
    if (!compile) return E_NOINTERFACE;
    ComPtr<ID3DBlob> errors;
    const HRESULT result = compile(shaderSource, strlen(shaderSource), "native-sdk-d3d", nullptr,
        nullptr, entry, target, D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, blob, &errors);
    return result;
}

} // namespace

struct NativeSdkD3DPresenter {
    HWND window = nullptr;
    UINT width = 0, height = 0;
    uint64_t generation = 0;
    std::map<uint64_t, RetainedCommand> retained;
    std::vector<uint64_t> order;
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGISwapChain1> swapchain;
    ComPtr<IDCompositionDevice> composition;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<ID3D11VertexShader> vertex_shader;
    ComPtr<ID3D11PixelShader> pixel_shader;
    ComPtr<ID3D11Buffer> constant_buffer;
    ComPtr<ID3D11Buffer> instance_buffer;
    ComPtr<ID3D11ShaderResourceView> instance_srv;
    ComPtr<ID3D11BlendState> blend;
    size_t instance_capacity = 0;
};

bool nativeSdkD3DHardwareAvailable() {
    char forced[8] = {};
    if (GetEnvironmentVariableA("WEAVER_FORCE_SOFTWARE", forced, sizeof(forced)) > 0 && strcmp(forced, "1") == 0) return false;
    ComPtr<ID3D11Device> device;
    D3D_FEATURE_LEVEL level;
    return SUCCEEDED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        &device, &level, nullptr));
}

static bool createDeviceAndComposition(NativeSdkD3DPresenter *p) {
    D3D_FEATURE_LEVEL level;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        &p->device, &level, &p->context))) return false;
    ComPtr<IDXGIDevice> dxgi_device;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    if (FAILED(p->device.As(&dxgi_device)) || FAILED(dxgi_device->GetAdapter(&adapter)) ||
        FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return false;
    if (FAILED(DCompositionCreateDevice(dxgi_device.Get(), IID_PPV_ARGS(&p->composition)))) return false;
    if (FAILED(p->composition->CreateTargetForHwnd(p->window, TRUE, &p->target)) ||
        FAILED(p->composition->CreateVisual(&p->visual))) return false;

    ComPtr<ID3DBlob> vs, ps;
    if (FAILED(compileShader("vsMain", "vs_5_0", &vs)) ||
        FAILED(compileShader("psMain", "ps_5_0", &ps))) return false;
    if (FAILED(p->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &p->vertex_shader)) ||
        FAILED(p->device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &p->pixel_shader))) return false;
    D3D11_BUFFER_DESC cb = {};
    cb.ByteWidth = 16; cb.Usage = D3D11_USAGE_DYNAMIC; cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER; cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(p->device->CreateBuffer(&cb, nullptr, &p->constant_buffer))) return false;
    D3D11_BLEND_DESC blend = {};
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    return SUCCEEDED(p->device->CreateBlendState(&blend, &p->blend));
}

static bool resizeSwapchain(NativeSdkD3DPresenter *p, UINT width, UINT height) {
    if (width == 0 || height == 0) return false;
    p->context->OMSetRenderTargets(0, nullptr, nullptr);
    if (p->swapchain) {
        if (FAILED(p->swapchain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) return false;
    } else {
        ComPtr<IDXGIDevice> dxgi_device;
        ComPtr<IDXGIAdapter> adapter;
        ComPtr<IDXGIFactory2> factory;
        if (FAILED(p->device.As(&dxgi_device)) || FAILED(dxgi_device->GetAdapter(&adapter)) ||
            FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return false;
        DXGI_SWAP_CHAIN_DESC1 desc = {};
        desc.Width = width; desc.Height = height; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2; desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL; desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
        if (FAILED(factory->CreateSwapChainForComposition(p->device.Get(), &desc, nullptr, &p->swapchain))) return false;
        if (FAILED(p->visual->SetContent(p->swapchain.Get())) || FAILED(p->target->SetRoot(p->visual.Get())) ||
            FAILED(p->composition->Commit())) return false;
    }
    p->width = width; p->height = height;
    return true;
}

NativeSdkD3DPresenter *nativeSdkD3DPresenterCreate(HWND window) {
    if (!window || !nativeSdkD3DHardwareAvailable()) return nullptr;
    NativeSdkD3DPresenter *p = new NativeSdkD3DPresenter();
    p->window = window;
    if (!createDeviceAndComposition(p)) { delete p; return nullptr; }
    return p;
}

void nativeSdkD3DPresenterDestroy(NativeSdkD3DPresenter *presenter) { delete presenter; }

static bool ensureInstances(NativeSdkD3DPresenter *p, size_t count) {
    if (count <= p->instance_capacity) return true;
    p->instance_capacity = std::max<size_t>(64, count * 2);
    D3D11_BUFFER_DESC desc = {};
    desc.ByteWidth = (UINT)(p->instance_capacity * sizeof(Instance));
    desc.Usage = D3D11_USAGE_DYNAMIC; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE; desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    desc.StructureByteStride = sizeof(Instance);
    p->instance_srv.Reset(); p->instance_buffer.Reset();
    if (FAILED(p->device->CreateBuffer(&desc, nullptr, &p->instance_buffer))) return false;
    D3D11_SHADER_RESOURCE_VIEW_DESC srv = {};
    srv.Format = DXGI_FORMAT_UNKNOWN; srv.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
    srv.Buffer.NumElements = (UINT)p->instance_capacity;
    return SUCCEEDED(p->device->CreateShaderResourceView(p->instance_buffer.Get(), &srv, &p->instance_srv));
}

bool nativeSdkD3DPresenterPresent(NativeSdkD3DPresenter *p, double logical_width,
    double logical_height, double scale, uint8_t clear_r, uint8_t clear_g,
    uint8_t clear_b, uint8_t clear_a, const uint8_t *packet, size_t packet_len) {
    if (!p || !packet || packet_len < 16 || scale <= 0) return false;
    const UINT width = (UINT)std::max(1.0, std::round(logical_width * scale));
    const UINT height = (UINT)std::max(1.0, std::round(logical_height * scale));
    if ((width != p->width || height != p->height) && !resizeSwapchain(p, width, height)) return false;

    PacketReader r{ packet, packet + packet_len };
    if (!r.skip(4) || memcmp(packet, "NSGP", 4) != 0) return false;
    uint8_t version = 0, load = 0, flags = 0, reserved = 0;
    uint64_t generation = 0;
    if (!r.u8(&version) || version != 4 || !r.u8(&load) || !r.u8(&flags) ||
        !r.u8(&reserved) || !r.u64(&generation)) return false;
    if (flags & 0x01) { F4 scissor; if (!r.rect(&scissor)) return false; }
    if (flags & 0x02) { uint32_t count; if (!r.u32(&count) || count > 8 || !r.skip((size_t)count * 16)) return false; }
    uint32_t image_count = 0, action_count = 0;
    if (!r.u32(&image_count) || image_count != 0 || !r.u32(&action_count) || action_count != 0) return false;

    std::map<uint64_t, RetainedCommand> next_retained = p->retained;
    std::vector<uint64_t> next_order = p->order;
    if (load == 1 || load == 2) {
        uint32_t count = 0;
        if (!r.u32(&count) || count > 8192) return false;
        next_retained.clear(); next_order.clear();
        for (uint32_t i = 0; i < count; ++i) {
            uint64_t key = 0; RetainedCommand command;
            if (!r.u64(&key) || !readCommand(r, &command)) return false;
            next_retained[key] = std::move(command); next_order.push_back(key);
        }
    } else if (load == 3) {
        if (p->generation == 0 || p->generation != generation) return false;
        uint32_t evicts = 0, upserts = 0, order_count = 0;
        if (!r.u32(&evicts) || evicts > 8192) return false;
        for (uint32_t i = 0; i < evicts; ++i) { uint64_t key; if (!r.u64(&key)) return false; next_retained.erase(key); }
        if (!r.u32(&upserts) || upserts > 8192) return false;
        for (uint32_t i = 0; i < upserts; ++i) { uint64_t key; RetainedCommand command; if (!r.u64(&key) || !readCommand(r, &command)) return false; next_retained[key] = std::move(command); }
        if (!r.u32(&order_count) || order_count > 8192) return false;
        next_order.resize(order_count);
        for (uint64_t &key : next_order) if (!r.u64(&key) || next_retained.find(key) == next_retained.end()) return false;
    } else return false;
    if (r.cursor != r.end) return false;

    std::vector<Instance> instances;
    for (uint64_t key : next_order) {
        const auto found = next_retained.find(key);
        if (found == next_retained.end()) return false;
        instances.insert(instances.end(), found->second.instances.begin(), found->second.instances.end());
    }
    if (!ensureInstances(p, instances.size())) return false;
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (!instances.empty()) {
        if (FAILED(p->context->Map(p->instance_buffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
        memcpy(mapped.pData, instances.data(), instances.size() * sizeof(Instance));
        p->context->Unmap(p->instance_buffer.Get(), 0);
    }
    if (FAILED(p->context->Map(p->constant_buffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    float surface[4] = { (float)logical_width, (float)logical_height, 0, 0 };
    memcpy(mapped.pData, surface, sizeof(surface)); p->context->Unmap(p->constant_buffer.Get(), 0);

    ComPtr<ID3D11Texture2D> back;
    ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(p->swapchain->GetBuffer(0, IID_PPV_ARGS(&back))) ||
        FAILED(p->device->CreateRenderTargetView(back.Get(), nullptr, &rtv))) return false;
    const float alpha = clear_a / 255.0f;
    const float clear[4] = { clear_r / 255.0f * alpha, clear_g / 255.0f * alpha,
        clear_b / 255.0f * alpha, alpha };
    p->context->ClearRenderTargetView(rtv.Get(), clear);
    p->context->OMSetRenderTargets(1, rtv.GetAddressOf(), nullptr);
    p->context->OMSetBlendState(p->blend.Get(), nullptr, 0xffffffff);
    D3D11_VIEWPORT viewport = { 0, 0, (float)width, (float)height, 0, 1 };
    p->context->RSSetViewports(1, &viewport);
    p->context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    p->context->VSSetShader(p->vertex_shader.Get(), nullptr, 0);
    p->context->VSSetConstantBuffers(0, 1, p->constant_buffer.GetAddressOf());
    p->context->VSSetShaderResources(0, 1, p->instance_srv.GetAddressOf());
    p->context->PSSetShader(p->pixel_shader.Get(), nullptr, 0);
    if (!instances.empty()) p->context->DrawInstanced(6, (UINT)instances.size(), 0, 0);
    ID3D11ShaderResourceView *null_srv = nullptr;
    p->context->VSSetShaderResources(0, 1, &null_srv);
    if (FAILED(p->swapchain->Present(1, 0))) return false;
    p->retained = std::move(next_retained); p->order = std::move(next_order); p->generation = generation;
    return true;
}
