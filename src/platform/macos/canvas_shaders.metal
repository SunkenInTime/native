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
    float2 clip_origin;
    float2 clip_size;
    float4 clip_corner_radius;
    float stroke_width;
    float image_scale;
    uint primitive;
    uint has_rounded_clip;
};

struct NativeSdkCompositeVertexOut {
    float4 position [[position]];
};

float native_sdk_rounded_rect_distance(
    float2 point,
    float2 origin,
    float2 size,
    float4 corner_radius) {
    float2 half_extent = size * 0.5;
    float2 local = point - (origin + half_extent);
    float radius = local.x < 0.0
        ? (local.y < 0.0 ? corner_radius.x : corner_radius.w)
        : (local.y < 0.0 ? corner_radius.y : corner_radius.z);
    float2 q = abs(local) - half_extent + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

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
    texture2d<float> quad_texture [[texture(0)]],
    sampler quad_sampler [[sampler(0)]]) {
    if (uniforms.primitive == 0u) return uniforms.color;
    if (uniforms.primitive == 2u || uniforms.primitive == 3u) {
        float distance = native_sdk_rounded_rect_distance(
            in.position.xy, uniforms.shape_origin, uniforms.shape_size, uniforms.corner_radius);
        float coverage = clamp(0.5 - distance, 0.0, 1.0);
        if (uniforms.primitive == 3u) {
            coverage = clamp(0.5 - abs(distance) + uniforms.stroke_width * 0.5, 0.0, 1.0);
        }
        if (uniforms.has_rounded_clip != 0u) {
            float clip_distance = native_sdk_rounded_rect_distance(
                in.position.xy, uniforms.clip_origin, uniforms.clip_size, uniforms.clip_corner_radius);
            coverage *= clamp(0.5 - clip_distance, 0.0, 1.0);
        }
        return uniforms.color * coverage;
    }
    if (uniforms.primitive == 4u) {
        float2 texture_size = float2(quad_texture.get_width(), quad_texture.get_height());
        float2 uv = (in.position.xy - uniforms.shape_origin) /
            max(uniforms.image_scale, 0.0001) / texture_size;
        float4 sampled = quad_texture.sample(quad_sampler, uv);
        float alpha = sampled.a * uniforms.color.a;
        float coverage = 1.0;
        if (uniforms.has_rounded_clip != 0u) {
            float clip_distance = native_sdk_rounded_rect_distance(
                in.position.xy, uniforms.clip_origin, uniforms.clip_size, uniforms.clip_corner_radius);
            coverage = clamp(0.5 - clip_distance, 0.0, 1.0);
        }
        return float4(sampled.rgb * alpha, alpha) * coverage;
    }
    int2 pixel = int2(in.position.xy);
    int2 texel = pixel - int2(uniforms.rect_origin) + int2(uniforms.tex_origin);
    texel = clamp(texel, int2(0),
                  int2(int(quad_texture.get_width()) - 1,
                       int(quad_texture.get_height()) - 1));
    return quad_texture.read(uint2(texel));
}
