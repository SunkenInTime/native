#include <metal_stdlib>
#include "canvas_shader_types.h"
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
    radius = min(max(radius, 0.0), min(size.x, size.y) * 0.5);
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

struct NativeSdkGradientVertexOut {
    float4 position [[position]];
};

vertex NativeSdkGradientVertexOut native_sdk_gradient_vertex(
    uint vertex_id [[vertex_id]],
    constant NativeSdkGradientUniforms &uniforms [[buffer(0)]]) {
    float2 corner = float2(float(vertex_id & 1u), float(vertex_id >> 1u));
    float2 pixel = uniforms.draw_rect.xy + corner * uniforms.draw_rect.zw;
    return { float4(pixel.x / uniforms.viewport.x * 2.0 - 1.0,
                    1.0 - pixel.y / uniforms.viewport.y * 2.0,
                    0.0, 1.0) };
}

static float native_sdk_srgb_to_linear(float value) {
    value = saturate(value);
    return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4);
}

static float native_sdk_linear_to_srgb(float value) {
    value = saturate(value);
    return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1.0 / 2.4) - 0.055;
}

static float3 native_sdk_linear_srgb_to_oklab(float3 rgb) {
    float3 lms = float3(
        0.4122214708 * rgb.r + 0.5363325363 * rgb.g + 0.0514459929 * rgb.b,
        0.2119034982 * rgb.r + 0.6806995451 * rgb.g + 0.1073969566 * rgb.b,
        0.0883024619 * rgb.r + 0.2817188376 * rgb.g + 0.6299787005 * rgb.b);
    float3 roots = sign(lms) * pow(abs(lms), float3(1.0 / 3.0));
    return float3(
        0.2104542553 * roots.x + 0.7936177850 * roots.y - 0.0040720468 * roots.z,
        1.9779984951 * roots.x - 2.4285922050 * roots.y + 0.4505937099 * roots.z,
        0.0259040371 * roots.x + 0.7827717662 * roots.y - 0.8086757660 * roots.z);
}

static float3 native_sdk_oklab_to_linear_srgb(float3 lab) {
    float3 roots = float3(
        lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
        lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
        lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z);
    float3 lms = roots * roots * roots;
    return float3(
        4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z);
}

static float3 native_sdk_gradient_to_space(float3 color, float interpolation) {
    if (interpolation < 0.5) return color;
    float3 linear_rgb = float3(
        native_sdk_srgb_to_linear(color.r),
        native_sdk_srgb_to_linear(color.g),
        native_sdk_srgb_to_linear(color.b));
    return interpolation < 1.5 ? linear_rgb : native_sdk_linear_srgb_to_oklab(linear_rgb);
}

static float3 native_sdk_gradient_from_space(float3 color, float interpolation) {
    if (interpolation < 0.5) return saturate(color);
    float3 linear_rgb = interpolation < 1.5 ? color : native_sdk_oklab_to_linear_srgb(color);
    return saturate(float3(
        native_sdk_linear_to_srgb(linear_rgb.r),
        native_sdk_linear_to_srgb(linear_rgb.g),
        native_sdk_linear_to_srgb(linear_rgb.b)));
}

static float4 native_sdk_mix_gradient_colors(float4 a, float4 b, float amount, float interpolation) {
    float alpha = mix(a.a, b.a, amount);
    if (alpha <= 0.000001) return float4(0.0);
    float3 a_space = native_sdk_gradient_to_space(a.rgb, interpolation) * a.a;
    float3 b_space = native_sdk_gradient_to_space(b.rgb, interpolation) * b.a;
    float3 mixed = native_sdk_gradient_from_space(mix(a_space, b_space, amount) / alpha, interpolation);
    return float4(mixed * alpha, alpha);
}

static float native_sdk_gradient_parameter(float2 pixel, constant NativeSdkGradientUniforms &uniforms) {
    if (uniforms.paint.x < 1.5) {
        float2 start = uniforms.gradient.xy;
        float2 direction = uniforms.gradient.zw - start;
        float length_squared = dot(direction, direction);
        return length_squared <= 0.000001 ? 0.0 : dot(pixel - start, direction) / length_squared;
    }
    if (uniforms.paint.x < 2.5) {
        float2 delta = pixel - uniforms.gradient.xy;
        float2 basis_x = uniforms.gradient.zw;
        float2 basis_y = uniforms.gradient_options.zw;
        float determinant = basis_x.x * basis_y.y - basis_x.y * basis_y.x;
        if (abs(determinant) <= 0.000001)
            return dot(delta, delta) <= 0.000001 ? 0.0 : 1.0e20;
        float2 local = float2(
            (delta.x * basis_y.y - delta.y * basis_y.x) / determinant,
            (basis_x.x * delta.y - basis_x.y * delta.x) / determinant);
        return length(local);
    }
    float2 delta = pixel - uniforms.gradient.xy;
    float2 basis_x = uniforms.conic_basis.xy;
    float2 basis_y = uniforms.conic_basis.zw;
    float determinant = basis_x.x * basis_y.y - basis_x.y * basis_y.x;
    if (abs(determinant) <= 0.000001) return 0.0;
    float2 local = float2(
        (delta.x * basis_y.y - delta.y * basis_y.x) / determinant,
        (basis_x.x * delta.y - basis_x.y * delta.x) / determinant);
    float angle = dot(local, local) <= 0.000001 ? uniforms.gradient.z : atan2(local.y, local.x);
    float turn = (angle - uniforms.gradient.z) / (2.0 * M_PI_F);
    return turn - floor(turn);
}

static float native_sdk_apply_gradient_spread(float value, float first_offset, float last_offset, float spread) {
    if (spread < 0.5) return value;
    float interval = last_offset - first_offset;
    if (interval <= 0.000001 || abs(value) > 1.0e15) return first_offset;
    float unit = (value - first_offset) / interval;
    if (spread < 1.5) return first_offset + fract(unit) * interval;
    float doubled = unit - floor(unit / 2.0) * 2.0;
    float reflected = doubled <= 1.0 ? doubled : 2.0 - doubled;
    return first_offset + reflected * interval;
}

static float4 native_sdk_sample_gradient(
    float2 pixel,
    constant NativeSdkGradientUniforms &uniforms,
    const device NativeSdkGradientStopGpu *stops) {
    uint first = uint(uniforms.paint.y);
    uint count = uint(uniforms.paint.z);
    if (count == 0) return float4(0.0);
    float interpolation = uniforms.gradient_options.y;
    NativeSdkGradientStopGpu previous = stops[first];
    if (count == 1) return float4(previous.color.rgb * previous.color.a, previous.color.a) * uniforms.paint.w;
    float last_offset = previous.data.x;
    for (uint last_index = 1; last_index < count; ++last_index)
        last_offset = max(last_offset, stops[first + last_index].data.x);
    if (uniforms.gradient_options.x > 0.5 && last_offset - previous.data.x <= 0.000001) {
        NativeSdkGradientStopGpu last = stops[first + count - 1];
        return native_sdk_mix_gradient_colors(previous.color, last.color, 0.5, interpolation) * uniforms.paint.w;
    }
    float value = native_sdk_apply_gradient_spread(
        native_sdk_gradient_parameter(pixel, uniforms), previous.data.x, last_offset, uniforms.gradient_options.x);
    float previous_offset = previous.data.x;
    if (value < previous_offset)
        return float4(previous.color.rgb * previous.color.a, previous.color.a) * uniforms.paint.w;
    for (uint index = 1; index < count; ++index) {
        NativeSdkGradientStopGpu next = stops[first + index];
        float next_offset = max(previous_offset, next.data.x);
        if (value < next_offset) {
            float span = next_offset - previous_offset;
            float amount = abs(span) <= 0.000001 ? 1.0 : saturate((value - previous_offset) / span);
            return native_sdk_mix_gradient_colors(previous.color, next.color, amount, interpolation) * uniforms.paint.w;
        }
        previous = next;
        previous_offset = next_offset;
    }
    return float4(previous.color.rgb * previous.color.a, previous.color.a) * uniforms.paint.w;
}

static float2 native_sdk_mesh_point(thread const NativeSdkMeshPatchGpu &patch, uint index) {
    float4 pair = patch.points[index / 2];
    return (index & 1u) == 0u ? pair.xy : pair.zw;
}

static float4 native_sdk_cubic_basis(float value) {
    float inverse = 1.0 - value;
    return float4(
        inverse * inverse * inverse,
        3.0 * inverse * inverse * value,
        3.0 * inverse * value * value,
        value * value * value);
}

static float4 native_sdk_cubic_basis_derivative(float value) {
    float inverse = 1.0 - value;
    return float4(
        -3.0 * inverse * inverse,
        3.0 * inverse * inverse - 6.0 * inverse * value,
        6.0 * inverse * value - 3.0 * value * value,
        3.0 * value * value);
}

static void native_sdk_evaluate_mesh_patch(
    thread const NativeSdkMeshPatchGpu &patch,
    float u,
    float v,
    thread float2 &position,
    thread float2 &derivative_u,
    thread float2 &derivative_v) {
    float4 basis_u = native_sdk_cubic_basis(u);
    float4 basis_v = native_sdk_cubic_basis(v);
    float4 derivative_basis_u = native_sdk_cubic_basis_derivative(u);
    float4 derivative_basis_v = native_sdk_cubic_basis_derivative(v);
    position = float2(0.0);
    derivative_u = float2(0.0);
    derivative_v = float2(0.0);
    for (uint row = 0; row < 4; ++row) {
        for (uint column = 0; column < 4; ++column) {
            float2 control = native_sdk_mesh_point(patch, row * 4 + column);
            position += control * basis_u[column] * basis_v[row];
            derivative_u += control * derivative_basis_u[column] * basis_v[row];
            derivative_v += control * basis_u[column] * derivative_basis_v[row];
        }
    }
}

static float4 native_sdk_mix_mesh_colors(thread const NativeSdkMeshPatchGpu &patch, float2 uv) {
    float4 weights = float4(
        (1.0 - uv.x) * (1.0 - uv.y),
        uv.x * (1.0 - uv.y),
        uv.x * uv.y,
        (1.0 - uv.x) * uv.y);
    float interpolation = patch.options.x;
    float alpha = 0.0;
    float3 premultiplied = float3(0.0);
    for (uint index = 0; index < 4; ++index) {
        float weighted_alpha = patch.colors[index].a * weights[index];
        alpha += weighted_alpha;
        premultiplied += native_sdk_gradient_to_space(patch.colors[index].rgb, interpolation) * weighted_alpha;
    }
    if (alpha <= 0.000001) return float4(0.0);
    float3 mixed = native_sdk_gradient_from_space(premultiplied / alpha, interpolation);
    return float4(mixed * alpha, alpha);
}

static float4 native_sdk_sample_mesh(
    float2 pixel,
    constant NativeSdkGradientUniforms &uniforms,
    const device NativeSdkMeshPatchGpu *patches) {
    uint first = uint(uniforms.paint.y);
    uint count = uint(uniforms.paint.z);
    for (uint remaining = count; remaining > 0; --remaining) {
        NativeSdkMeshPatchGpu patch = patches[first + remaining - 1];
        if (pixel.x < patch.bounds.x - 0.01 || pixel.y < patch.bounds.y - 0.01 ||
            pixel.x > patch.bounds.z + 0.01 || pixel.y > patch.bounds.w + 0.01) continue;
        float2 extent = patch.bounds.zw - patch.bounds.xy;
        float2 uv = float2(
            extent.x <= 0.000001 ? 0.5 : saturate((pixel.x - patch.bounds.x) / extent.x),
            extent.y <= 0.000001 ? 0.5 : saturate((pixel.y - patch.bounds.y) / extent.y));
        /* Exact port of the shipped Windows evaluator's bounded Newton
         * solve and tolerances. This adds no macOS-only iteration budget. */
        for (uint iteration = 0; iteration < 10; ++iteration) {
            float2 position, derivative_u, derivative_v;
            native_sdk_evaluate_mesh_patch(patch, uv.x, uv.y, position, derivative_u, derivative_v);
            float2 delta = position - pixel;
            float determinant = derivative_u.x * derivative_v.y - derivative_u.y * derivative_v.x;
            if (abs(determinant) <= 0.000001) break;
            float2 step = float2(
                (delta.x * derivative_v.y - delta.y * derivative_v.x) / determinant,
                (derivative_u.x * delta.y - derivative_u.y * delta.x) / determinant);
            uv -= step;
            if (abs(step.x) + abs(step.y) <= 0.00001) break;
        }
        if (uv.x < -0.001 || uv.x > 1.001 || uv.y < -0.001 || uv.y > 1.001) continue;
        uv = saturate(uv);
        float2 final_position, final_derivative_u, final_derivative_v;
        native_sdk_evaluate_mesh_patch(patch, uv.x, uv.y, final_position, final_derivative_u, final_derivative_v);
        float2 residual = final_position - pixel;
        if (dot(residual, residual) > 0.0001) continue;
        return native_sdk_mix_mesh_colors(patch, uv) * uniforms.paint.w;
    }
    return float4(0.0);
}

fragment float4 native_sdk_gradient_fragment(
    NativeSdkGradientVertexOut in [[stage_in]],
    constant NativeSdkGradientUniforms &uniforms [[buffer(0)]],
    const device NativeSdkGradientStopGpu *stops [[buffer(1)]],
    const device NativeSdkMeshPatchGpu *patches [[buffer(2)]]) {
    float2 pixel = in.position.xy;
    if (uniforms.clip_rect.z >= 0.0 &&
        (pixel.x < uniforms.clip_rect.x || pixel.y < uniforms.clip_rect.y ||
         pixel.x >= uniforms.clip_rect.x + uniforms.clip_rect.z ||
         pixel.y >= uniforms.clip_rect.y + uniforms.clip_rect.w)) discard_fragment();
    float coverage = saturate(0.5 - native_sdk_rounded_rect_distance(
        pixel, uniforms.shape_rect.xy, uniforms.shape_rect.zw, uniforms.corner_radius));
    if (uniforms.clip_rect.z >= 0.0 && any(uniforms.clip_radius > 0.0)) {
        float clip_distance = native_sdk_rounded_rect_distance(
            pixel, uniforms.clip_rect.xy, uniforms.clip_rect.zw, uniforms.clip_radius);
        coverage *= saturate(0.5 - clip_distance);
    }
    float4 paint = uniforms.paint.x > 3.5
        ? native_sdk_sample_mesh(pixel, uniforms, patches)
        : native_sdk_sample_gradient(pixel, uniforms, stops);
    return paint * coverage;
}
