#include "d3d_presenter.h"
#include "dpi_geometry.h"

#include <d3d11.h>
#include <d3dcompiler.h>
#include <dcomp.h>
#include <dxgi1_2.h>
#include <dxgi1_3.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <mutex>
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
    F4 gradient; // linear start/end; radial center/radii; conic center/start angle
    F4 gradient_options; // spread (pad/repeat/reflect), interpolation, unused
    F4 paint; // kind (0 color / 1 linear / 2 radial / 3 conic), stop offset/count, opacity
};

struct GradientStopInstance {
    F4 color; // straight-alpha sRGB; the pixel shader matches the reference mix
    F4 data; // offset, unused
};

struct MeshPatchInstance {
    F4 points[8]; // two row-major float2 control points per float4
    F4 colors[4]; // top-left, top-right, bottom-right, bottom-left
    F4 bounds; // min x/y, max x/y
    F4 options; // interpolation, unused
};

static_assert(sizeof(Instance) == 112);
static_assert(sizeof(GradientStopInstance) == 32);
static_assert(sizeof(MeshPatchInstance) == 224);

struct RetainedCommand {
    std::vector<Instance> instances;
    std::vector<GradientStopInstance> gradient_stops;
    std::vector<MeshPatchInstance> mesh_patches;
};

// Must match serialization.zig `binary_packet_version`; the build-time
// wire-format ratchet checks this independently of the macOS decoder.
static constexpr uint8_t kBinaryPacketVersion = 9;
// Matches canvas_limits.max_canvas_gradient_stops_per_view. Keep the decoder
// bound even though the runtime already applies the same aggregate budget.
static constexpr uint32_t kMaxGradientStopsPerSurface = 64;
static constexpr uint32_t kMaxMeshPatchesPerSurface = 16;

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

bool readRadius(PacketReader &reader, F4 *radius) {
    if (!reader.f32(&radius->x) || !reader.f32(&radius->y) ||
        !reader.f32(&radius->z) || !reader.f32(&radius->w)) return false;
    radius->x = std::max(0.0f, radius->x);
    radius->y = std::max(0.0f, radius->y);
    radius->z = std::max(0.0f, radius->z);
    radius->w = std::max(0.0f, radius->w);
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

bool readStraightColor(PacketReader &reader, F4 *color) {
    return reader.f32(&color->x) && reader.f32(&color->y) &&
        reader.f32(&color->z) && reader.f32(&color->w);
}

bool readPaint(PacketReader &reader, Instance *instance,
    std::vector<GradientStopInstance> *gradient_stops,
    std::vector<MeshPatchInstance> *mesh_patches) {
    uint8_t tag = 0;
    if (!reader.u8(&tag)) return false;
    if (tag == 1) {
        instance->paint = {};
        return readColor(reader, &instance->color);
    }
    if (tag >= 2 && tag <= 4) {
        if (!reader.f32(&instance->gradient.x) ||
            !reader.f32(&instance->gradient.y)) return false;
        if (tag == 2 || tag == 3) {
            if (!reader.f32(&instance->gradient.z) ||
                !reader.f32(&instance->gradient.w)) return false;
        } else if (!reader.f32(&instance->gradient.z)) {
            return false;
        }
        uint8_t spread = 0, interpolation = 0;
        if (!reader.u8(&spread) || spread > 2 ||
            !reader.u8(&interpolation) || interpolation > 2) return false;
        uint32_t count = 0;
        if (!reader.u32(&count) || count > kMaxGradientStopsPerSurface) return false;
        gradient_stops->reserve(count);
        for (uint32_t index = 0; index < count; ++index) {
            GradientStopInstance stop = {};
            if (!reader.f32(&stop.data.x) ||
                !readStraightColor(reader, &stop.color)) return false;
            gradient_stops->push_back(stop);
        }
        instance->gradient_options = {
            static_cast<float>(spread), static_cast<float>(interpolation), 0, 0
        };
        instance->paint = {
            static_cast<float>(tag - 1), 0.0f, static_cast<float>(count), 1.0f
        };
        return true;
    }
    if (tag == 5) {
        uint8_t interpolation = 0;
        uint32_t count = 0;
        if (!reader.u8(&interpolation) || interpolation > 2 ||
            !reader.u32(&count) || count > kMaxMeshPatchesPerSurface) return false;
        mesh_patches->reserve(count);
        for (uint32_t patch_index = 0; patch_index < count; ++patch_index) {
            MeshPatchInstance patch = {};
            patch.bounds = { INFINITY, INFINITY, -INFINITY, -INFINITY };
            for (F4 &pair : patch.points) {
                if (!reader.rect(&pair)) return false;
                patch.bounds.x = std::min(patch.bounds.x, std::min(pair.x, pair.z));
                patch.bounds.y = std::min(patch.bounds.y, std::min(pair.y, pair.w));
                patch.bounds.z = std::max(patch.bounds.z, std::max(pair.x, pair.z));
                patch.bounds.w = std::max(patch.bounds.w, std::max(pair.y, pair.w));
            }
            for (F4 &color : patch.colors) {
                if (!readStraightColor(reader, &color)) return false;
            }
            patch.options.x = static_cast<float>(interpolation);
            mesh_patches->push_back(patch);
        }
        instance->paint = { 4.0f, 0.0f, static_cast<float>(count), 1.0f };
        return true;
    }
    return false;
}

bool readCommand(PacketReader &reader, RetainedCommand *out) {
    uint8_t kind = 0, flags = 0, cap = 0;
    F4 bounds = {}, clip = {};
    float opacity = 1, stroke_width = 0;
    if (!reader.u8(&kind) || !reader.u8(&flags) || !reader.rect(&bounds) ||
        !reader.f32(&opacity) || !reader.f32(&stroke_width) || !reader.u8(&cap)) return false;
    if (flags & 0x01) { uint64_t id; if (!reader.u64(&id)) return false; }
    if (flags & 0x02) {
        F4 clip_radius = {};
        if (!reader.rect(&clip) || !readRadius(reader, &clip_radius)) return false;
        // Per-command rounded clipping is not represented in the instance
        // pipeline yet. Reject it so the established CPU fallback paints it
        // correctly instead of silently drawing outside the clip.
        return false;
    }
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
    base.extra.w = 0;

    if (shape_tag == 1) {
        if (!reader.rect(&base.rect)) return false;
        base.shape = {};
        instances.push_back(base);
    } else if (shape_tag == 2) {
        if (!reader.rect(&base.rect) || !readRadius(reader, &base.shape)) return false;
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
        base.shape = { x1, y1, 0, 0 };
        base.extra = { x2, y2, width, 1.0f };
        instances.push_back(base);
    } else if (shape_tag == 5) {
        // The instance path is a sequence of stroked line quads. A fill_path
        // (wire kind 8) needs interior tessellation, which this presenter does
        // not implement. Refuse it so the caller uses the pixel fallback
        // instead of silently rendering only the outline.
        if (kind != 9) return false; // stroke_path
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
                line.shape = { previous_x, previous_y, 0, 0 };
                line.extra = { last_x, last_y, stroke_width, 1.0f };
                instances.push_back(line);
                previous_x = last_x;
                previous_y = last_y;
            } else if (verb == 4 && has_previous) {
                const float half = stroke_width * 0.5f;
                Instance line = base;
                line.rect = { std::min(previous_x, start_x) - half, std::min(previous_y, start_y) - half,
                    std::abs(start_x - previous_x) + stroke_width, std::abs(start_y - previous_y) + stroke_width };
                line.shape = { previous_x, previous_y, 0, 0 };
                line.extra = { start_x, start_y, stroke_width, 1.0f };
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

    std::vector<GradientStopInstance> gradient_stops;
    std::vector<MeshPatchInstance> mesh_patches;
    if (!readPaint(reader, &base, &gradient_stops, &mesh_patches)) return false;
    if (base.paint.x < 0.5f) {
        base.color.x *= opacity;
        base.color.y *= opacity;
        base.color.z *= opacity;
        base.color.w *= opacity;
    } else {
        base.paint.w = opacity;
    }
    for (Instance &instance : instances) {
        instance.color = base.color;
        instance.gradient = base.gradient;
        instance.gradient_options = base.gradient_options;
        instance.paint = base.paint;
    }
    out->instances = std::move(instances);
    out->gradient_stops = std::move(gradient_stops);
    out->mesh_patches = std::move(mesh_patches);
    (void)clip;
    return true;
}

const char *shaderSource = R"(
struct Instance { float4 rect; float4 color; float4 shape; float4 extra; float4 gradient; float4 gradientOptions; float4 paint; };
struct GradientStopInstance { float4 color; float4 data; };
struct MeshPatchInstance { float4 points[8]; float4 colors[4]; float4 bounds; float4 options; };
StructuredBuffer<Instance> instances : register(t0);
StructuredBuffer<GradientStopInstance> gradientStops : register(t1);
StructuredBuffer<MeshPatchInstance> meshPatches : register(t2);
struct Out { float4 position:SV_POSITION; float2 pixel:TEXCOORD0; nointerpolation float4 rect:TEXCOORD1; nointerpolation float4 color:COLOR0; nointerpolation float4 shape:TEXCOORD2; nointerpolation float4 extra:TEXCOORD3; nointerpolation float4 gradient:TEXCOORD4; nointerpolation float4 gradientOptions:TEXCOORD5; nointerpolation float4 paint:TEXCOORD6; };
cbuffer Surface : register(b0) { float2 surface; float2 padding; };
Out vsMain(uint vertex:SV_VertexID, uint instance:SV_InstanceID) {
  const float2 corners[6] = { float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1) };
  Instance i=instances[instance]; float2 p=i.rect.xy+corners[vertex]*i.rect.zw;
  Out o; o.position=float4(p.x/surface.x*2-1,1-p.y/surface.y*2,0,1); o.pixel=p; o.rect=i.rect; o.color=i.color; o.shape=i.shape; o.extra=i.extra; o.gradient=i.gradient; o.gradientOptions=i.gradientOptions; o.paint=i.paint; return o;
}
float srgbToLinear(float value) {
  value=saturate(value);
  return value <= 0.04045 ? value/12.92 : pow((value+0.055)/1.055,2.4);
}
float linearToSrgb(float value) {
  value=saturate(value);
  return value <= 0.0031308 ? value*12.92 : 1.055*pow(value,1.0/2.4)-0.055;
}
float4 premultiply(float4 color) {
  return float4(color.rgb*color.a,color.a);
}
float signedCubeRoot(float value) {
  return sign(value)*pow(abs(value),1.0/3.0);
}
float3 linearSrgbToOklab(float3 rgb) {
  float l=0.4122214708*rgb.r+0.5363325363*rgb.g+0.0514459929*rgb.b;
  float m=0.2119034982*rgb.r+0.6806995451*rgb.g+0.1073969566*rgb.b;
  float s=0.0883024619*rgb.r+0.2817188376*rgb.g+0.6299787005*rgb.b;
  float3 roots=float3(signedCubeRoot(l),signedCubeRoot(m),signedCubeRoot(s));
  return float3(
    0.2104542553*roots.x+0.7936177850*roots.y-0.0040720468*roots.z,
    1.9779984951*roots.x-2.4285922050*roots.y+0.4505937099*roots.z,
    0.0259040371*roots.x+0.7827717662*roots.y-0.8086757660*roots.z);
}
float3 oklabToLinearSrgb(float3 lab) {
  float3 roots=float3(
    lab.x+0.3963377774*lab.y+0.2158037573*lab.z,
    lab.x-0.1055613458*lab.y-0.0638541728*lab.z,
    lab.x-0.0894841775*lab.y-1.2914855480*lab.z);
  float3 lms=roots*roots*roots;
  return float3(
    4.0767416621*lms.x-3.3077115913*lms.y+0.2309699292*lms.z,
    -1.2684380046*lms.x+2.6097574011*lms.y-0.3413193965*lms.z,
    -0.0041960863*lms.x-0.7034186147*lms.y+1.7076147010*lms.z);
}
float3 gradientColorToSpace(float3 color,float interpolation) {
  if (interpolation<0.5) return color;
  float3 linearRgb=float3(srgbToLinear(color.r),srgbToLinear(color.g),srgbToLinear(color.b));
  return interpolation<1.5 ? linearRgb : linearSrgbToOklab(linearRgb);
}
float3 gradientColorFromSpace(float3 color,float interpolation) {
  if (interpolation<0.5) return saturate(color);
  float3 linearRgb=interpolation<1.5 ? color : oklabToLinearSrgb(color);
  return saturate(float3(linearToSrgb(linearRgb.r),linearToSrgb(linearRgb.g),linearToSrgb(linearRgb.b)));
}
float4 mixGradientColors(float4 a,float4 b,float amount,float interpolation) {
  float alpha=lerp(a.a,b.a,amount);
  if (alpha<=0.000001) return float4(0,0,0,0);
  float3 aSpace=gradientColorToSpace(a.rgb,interpolation)*a.a;
  float3 bSpace=gradientColorToSpace(b.rgb,interpolation)*b.a;
  float3 mixed=gradientColorFromSpace(lerp(aSpace,bSpace,amount)/alpha,interpolation);
  return float4(mixed*alpha,alpha);
}
float gradientParameter(Out i) {
  if (i.paint.x<1.5) {
    float2 start=i.gradient.xy, direction=i.gradient.zw-start;
    float lengthSquared=dot(direction,direction);
    return lengthSquared<=0.000001 ? 0 : dot(i.pixel-start,direction)/lengthSquared;
  }
  if (i.paint.x<2.5) {
    float2 delta=i.pixel-i.gradient.xy, radii=i.gradient.zw;
    if (abs(radii.x*radii.y)<=0.000001)
      return dot(delta,delta)<=0.000001 ? 0 : 1.0e20;
    float2 local=delta/radii;
    return length(local);
  }
  float2 delta=i.pixel-i.gradient.xy;
  float angle=dot(delta,delta)<=0.000001 ? i.gradient.z : atan2(delta.y,delta.x);
  float turn=(angle-i.gradient.z)/(2.0*3.14159265358979323846);
  return turn-floor(turn);
}
float applyGradientSpread(float t,float firstOffset,float lastOffset,float spread) {
  if (spread<0.5) return t;
  float interval=lastOffset-firstOffset;
  if (interval<=0.000001 || abs(t)>1.0e15) return firstOffset;
  float unit=(t-firstOffset)/interval;
  if (spread<1.5) return firstOffset+(unit-floor(unit))*interval;
  float doubled=unit-floor(unit/2.0)*2.0;
  float reflected=doubled<=1.0 ? doubled : 2.0-doubled;
  return firstOffset+reflected*interval;
}
float4 sampleGradient(Out i) {
  uint first=(uint)i.paint.y, count=(uint)i.paint.z;
  if (count==0) return float4(0,0,0,0);
  float interpolation=i.gradientOptions.y;
  GradientStopInstance previous=gradientStops[first];
  if (count==1) return premultiply(previous.color)*i.paint.w;
  float lastOffset=previous.data.x;
  [loop] for (uint lastIndex=1;lastIndex<count;++lastIndex)
    lastOffset=max(lastOffset,gradientStops[first+lastIndex].data.x);
  if (i.gradientOptions.x>0.5 && lastOffset-previous.data.x<=0.000001) {
    GradientStopInstance last=gradientStops[first+count-1];
    return mixGradientColors(previous.color,last.color,0.5,interpolation)*i.paint.w;
  }
  float t=applyGradientSpread(gradientParameter(i),previous.data.x,lastOffset,i.gradientOptions.x);
  float previousOffset=previous.data.x;
  if (t<previousOffset) return premultiply(previous.color)*i.paint.w;
  [loop] for (uint index=1;index<count;++index) {
    GradientStopInstance next=gradientStops[first+index];
    float nextOffset=max(previousOffset,next.data.x);
    if (t<nextOffset) {
      float span=nextOffset-previousOffset;
      float localAmount=abs(span)<=0.000001 ? 1 : saturate((t-previousOffset)/span);
      return mixGradientColors(previous.color,next.color,localAmount,interpolation)*i.paint.w;
    }
    previous=next;
    previousOffset=nextOffset;
  }
  return premultiply(previous.color)*i.paint.w;
}
float2 meshPoint(MeshPatchInstance patch,uint index) {
  float4 pair=patch.points[index/2];
  return (index&1)==0 ? pair.xy : pair.zw;
}
float4 cubicBasis(float value) {
  float inverse=1.0-value;
  return float4(
    inverse*inverse*inverse,
    3.0*inverse*inverse*value,
    3.0*inverse*value*value,
    value*value*value);
}
float4 cubicBasisDerivative(float value) {
  float inverse=1.0-value;
  return float4(
    -3.0*inverse*inverse,
    3.0*inverse*inverse-6.0*inverse*value,
    6.0*inverse*value-3.0*value*value,
    3.0*value*value);
}
void evaluateMeshPatch(MeshPatchInstance patch,float u,float v,
  out float2 position,out float2 derivativeU,out float2 derivativeV) {
  float4 basisU=cubicBasis(u), basisV=cubicBasis(v);
  float4 derivativeBasisU=cubicBasisDerivative(u), derivativeBasisV=cubicBasisDerivative(v);
  position=float2(0,0); derivativeU=float2(0,0); derivativeV=float2(0,0);
  [unroll] for (uint row=0;row<4;++row) {
    [unroll] for (uint column=0;column<4;++column) {
      float2 control=meshPoint(patch,row*4+column);
      position+=control*basisU[column]*basisV[row];
      derivativeU+=control*derivativeBasisU[column]*basisV[row];
      derivativeV+=control*basisU[column]*derivativeBasisV[row];
    }
  }
}
float4 mixMeshColors(MeshPatchInstance patch,float2 uv) {
  float4 weights=float4(
    (1.0-uv.x)*(1.0-uv.y),
    uv.x*(1.0-uv.y),
    uv.x*uv.y,
    (1.0-uv.x)*uv.y);
  float interpolation=patch.options.x;
  float alpha=0; float3 premultiplied=float3(0,0,0);
  [unroll] for (uint index=0;index<4;++index) {
    float weightedAlpha=patch.colors[index].a*weights[index];
    alpha+=weightedAlpha;
    premultiplied+=gradientColorToSpace(patch.colors[index].rgb,interpolation)*weightedAlpha;
  }
  if (alpha<=0.000001) return float4(0,0,0,0);
  float3 mixed=gradientColorFromSpace(premultiplied/alpha,interpolation);
  return float4(mixed*alpha,alpha);
}
float4 sampleMesh(Out i) {
  uint first=(uint)i.paint.y, count=(uint)i.paint.z;
  [loop] for (uint remaining=count;remaining>0;--remaining) {
    MeshPatchInstance patch=meshPatches[first+remaining-1];
    if (i.pixel.x<patch.bounds.x-0.01 || i.pixel.y<patch.bounds.y-0.01 ||
        i.pixel.x>patch.bounds.z+0.01 || i.pixel.y>patch.bounds.w+0.01) continue;
    float2 extent=patch.bounds.zw-patch.bounds.xy;
    float2 uv=float2(
      extent.x<=0.000001 ? 0.5 : saturate((i.pixel.x-patch.bounds.x)/extent.x),
      extent.y<=0.000001 ? 0.5 : saturate((i.pixel.y-patch.bounds.y)/extent.y));
    [loop] for (uint iteration=0;iteration<10;++iteration) {
      float2 position, derivativeU, derivativeV;
      evaluateMeshPatch(patch,uv.x,uv.y,position,derivativeU,derivativeV);
      float2 delta=position-i.pixel;
      float determinant=derivativeU.x*derivativeV.y-derivativeU.y*derivativeV.x;
      if (abs(determinant)<=0.000001) break;
      float2 step=float2(
        (delta.x*derivativeV.y-delta.y*derivativeV.x)/determinant,
        (derivativeU.x*delta.y-derivativeU.y*delta.x)/determinant);
      uv-=step;
      if (abs(step.x)+abs(step.y)<=0.00001) break;
    }
    if (uv.x < -0.001 || uv.x > 1.001 || uv.y < -0.001 || uv.y > 1.001) continue;
    uv=saturate(uv);
    float2 finalPosition, finalDerivativeU, finalDerivativeV;
    evaluateMeshPatch(patch,uv.x,uv.y,finalPosition,finalDerivativeU,finalDerivativeV);
    float2 residual=finalPosition-i.pixel;
    if (dot(residual,residual)>0.0001) continue;
    return mixMeshColors(patch,uv)*i.paint.w;
  }
  return float4(0,0,0,0);
}
float4 psMain(Out i):SV_TARGET {
  float distance;
  if (i.extra.w > 0.5) {
    float2 a=i.shape.xy, b=i.extra.xy, pa=i.pixel-a, ba=b-a;
    float h=saturate(dot(pa,ba)/max(dot(ba,ba),0.0001));
    distance=length(pa-ba*h)-i.extra.z*0.5;
  } else {
    float2 center=i.rect.xy+i.rect.zw*0.5;
    float radius = i.pixel.x < center.x
      ? (i.pixel.y < center.y ? i.shape.x : i.shape.w)
      : (i.pixel.y < center.y ? i.shape.y : i.shape.z);
    radius=min(radius,min(i.rect.z,i.rect.w)*0.5);
    float2 q=abs(i.pixel-center)-(i.rect.zw*0.5-radius);
    distance=length(max(q,0))+min(max(q.x,q.y),0)-radius;
  }
  float coverage=saturate(0.5-distance);
  float4 color=i.paint.x>3.5 ? sampleMesh(i) : (i.paint.x>0.5 ? sampleGradient(i) : i.color);
  return color*coverage;
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
    if (FAILED(result) && errors && errors->GetBufferPointer() && errors->GetBufferSize() > 0) {
        fprintf(stderr, "native-sdk-d3d: %s/%s compilation failed:\n%.*s\n",
            entry, target, static_cast<int>(errors->GetBufferSize()),
            static_cast<const char *>(errors->GetBufferPointer()));
    }
    return result;
}

} // namespace

struct NsgpSurfaceState {
    UINT width = 0, height = 0;
    uint64_t generation = 0;
    std::map<uint64_t, RetainedCommand> retained;
    std::vector<uint64_t> order;
    ComPtr<IDXGISwapChain1> swapchain;
    ComPtr<ID3D11Texture2D> retained_texture;
    uint64_t retained_generation = 0;
};

struct NsgpEngine {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<ID3D11VertexShader> vertex_shader;
    ComPtr<ID3D11PixelShader> pixel_shader;
    ComPtr<ID3D11Buffer> constant_buffer;
    ComPtr<ID3D11Buffer> instance_buffer;
    ComPtr<ID3D11ShaderResourceView> instance_srv;
    ComPtr<ID3D11Buffer> gradient_stop_buffer;
    ComPtr<ID3D11ShaderResourceView> gradient_stop_srv;
    ComPtr<ID3D11Buffer> mesh_patch_buffer;
    ComPtr<ID3D11ShaderResourceView> mesh_patch_srv;
    ComPtr<ID3D11BlendState> blend;
    size_t instance_capacity = 0;
    size_t gradient_stop_capacity = 0;
    size_t mesh_patch_capacity = 0;
};

struct NativeSdkD3DPresenter {
    HWND window = nullptr;
    NsgpEngine engine;
    NsgpSurfaceState surface;
    ComPtr<IDCompositionDevice> composition;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> visual;
};

struct NativeSdkD3DSharedRenderer {
    NsgpEngine engine;
    ComPtr<IDXGIFactoryMedia> factory_media;
    std::mutex mutex;
    std::condition_variable turn_changed;
    uint64_t next_ticket = 0;
    uint64_t serving_ticket = 0;
};

struct NativeSdkD3DSharedSurface {
    NativeSdkD3DSharedRenderer *renderer = nullptr;
    DWORD widget_pid = 0;
    HANDLE composition_handle = nullptr;
    NsgpSurfaceState state;
    uint64_t geometry_generation = 0;
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

static bool createEngine(NsgpEngine *engine) {
    D3D_FEATURE_LEVEL level;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        &engine->device, &level, &engine->context))) return false;

    ComPtr<ID3DBlob> vs, ps;
    if (FAILED(compileShader("vsMain", "vs_5_0", &vs)) ||
        FAILED(compileShader("psMain", "ps_5_0", &ps))) return false;
    if (FAILED(engine->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), nullptr, &engine->vertex_shader)) ||
        FAILED(engine->device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), nullptr, &engine->pixel_shader))) return false;
    D3D11_BUFFER_DESC cb = {};
    cb.ByteWidth = 16; cb.Usage = D3D11_USAGE_DYNAMIC; cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER; cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    if (FAILED(engine->device->CreateBuffer(&cb, nullptr, &engine->constant_buffer))) return false;
    D3D11_BLEND_DESC blend = {};
    blend.RenderTarget[0].BlendEnable = TRUE;
    blend.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blend.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blend.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blend.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    return SUCCEEDED(engine->device->CreateBlendState(&blend, &engine->blend));
}

static bool resizeSwapchain(NativeSdkD3DPresenter *p, UINT width, UINT height) {
    if (width == 0 || height == 0) return false;
    p->engine.context->OMSetRenderTargets(0, nullptr, nullptr);
    if (p->surface.swapchain) {
        if (FAILED(p->surface.swapchain->ResizeBuffers(0, width, height, DXGI_FORMAT_UNKNOWN, 0))) return false;
    } else {
        ComPtr<IDXGIDevice> dxgi_device;
        ComPtr<IDXGIAdapter> adapter;
        ComPtr<IDXGIFactory2> factory;
        if (FAILED(p->engine.device.As(&dxgi_device)) || FAILED(dxgi_device->GetAdapter(&adapter)) ||
            FAILED(adapter->GetParent(IID_PPV_ARGS(&factory)))) return false;
        DXGI_SWAP_CHAIN_DESC1 desc = {};
        desc.Width = width; desc.Height = height; desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
        desc.BufferCount = 2; desc.Scaling = DXGI_SCALING_STRETCH;
        desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL; desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
        if (FAILED(factory->CreateSwapChainForComposition(p->engine.device.Get(), &desc, nullptr, &p->surface.swapchain))) return false;
        if (FAILED(p->visual->SetContent(p->surface.swapchain.Get())) || FAILED(p->target->SetRoot(p->visual.Get())) ||
            FAILED(p->composition->Commit())) return false;
    }
    p->surface.width = width; p->surface.height = height;
    return true;
}

NativeSdkD3DPresenter *nativeSdkD3DPresenterCreate(HWND window) {
    if (!window || !nativeSdkD3DHardwareAvailable()) return nullptr;
    NativeSdkD3DPresenter *p = new NativeSdkD3DPresenter();
    p->window = window;
    if (!createEngine(&p->engine)) { delete p; return nullptr; }
    ComPtr<IDXGIDevice> dxgi_device;
    if (FAILED(p->engine.device.As(&dxgi_device)) ||
        FAILED(DCompositionCreateDevice(dxgi_device.Get(), IID_PPV_ARGS(&p->composition))) ||
        FAILED(p->composition->CreateTargetForHwnd(p->window, TRUE, &p->target)) ||
        FAILED(p->composition->CreateVisual(&p->visual))) { delete p; return nullptr; }
    return p;
}

void nativeSdkD3DPresenterDestroy(NativeSdkD3DPresenter *presenter) { delete presenter; }

static bool ensureInstances(NsgpEngine *engine, size_t count) {
    if (count <= engine->instance_capacity) return true;
    engine->instance_capacity = std::max<size_t>(64, count * 2);
    D3D11_BUFFER_DESC desc = {};
    desc.ByteWidth = (UINT)(engine->instance_capacity * sizeof(Instance));
    desc.Usage = D3D11_USAGE_DYNAMIC; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE; desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    desc.StructureByteStride = sizeof(Instance);
    engine->instance_srv.Reset(); engine->instance_buffer.Reset();
    if (FAILED(engine->device->CreateBuffer(&desc, nullptr, &engine->instance_buffer))) return false;
    D3D11_SHADER_RESOURCE_VIEW_DESC srv = {};
    srv.Format = DXGI_FORMAT_UNKNOWN; srv.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
    srv.Buffer.NumElements = (UINT)engine->instance_capacity;
    return SUCCEEDED(engine->device->CreateShaderResourceView(engine->instance_buffer.Get(), &srv, &engine->instance_srv));
}

static bool ensureGradientStops(NsgpEngine *engine, size_t count) {
    if (count <= engine->gradient_stop_capacity) return true;
    engine->gradient_stop_capacity = std::max<size_t>(kMaxGradientStopsPerSurface, count);
    D3D11_BUFFER_DESC desc = {};
    desc.ByteWidth = (UINT)(engine->gradient_stop_capacity * sizeof(GradientStopInstance));
    desc.Usage = D3D11_USAGE_DYNAMIC;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    desc.StructureByteStride = sizeof(GradientStopInstance);
    engine->gradient_stop_srv.Reset();
    engine->gradient_stop_buffer.Reset();
    if (FAILED(engine->device->CreateBuffer(&desc, nullptr,
        &engine->gradient_stop_buffer))) return false;
    D3D11_SHADER_RESOURCE_VIEW_DESC srv = {};
    srv.Format = DXGI_FORMAT_UNKNOWN;
    srv.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
    srv.Buffer.NumElements = (UINT)engine->gradient_stop_capacity;
    return SUCCEEDED(engine->device->CreateShaderResourceView(
        engine->gradient_stop_buffer.Get(), &srv, &engine->gradient_stop_srv));
}

static bool ensureMeshPatches(NsgpEngine *engine, size_t count) {
    if (count <= engine->mesh_patch_capacity) return true;
    engine->mesh_patch_capacity = std::max<size_t>(kMaxMeshPatchesPerSurface, count);
    D3D11_BUFFER_DESC desc = {};
    desc.ByteWidth = (UINT)(engine->mesh_patch_capacity * sizeof(MeshPatchInstance));
    desc.Usage = D3D11_USAGE_DYNAMIC;
    desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
    desc.StructureByteStride = sizeof(MeshPatchInstance);
    engine->mesh_patch_srv.Reset();
    engine->mesh_patch_buffer.Reset();
    if (FAILED(engine->device->CreateBuffer(&desc, nullptr,
        &engine->mesh_patch_buffer))) return false;
    D3D11_SHADER_RESOURCE_VIEW_DESC srv = {};
    srv.Format = DXGI_FORMAT_UNKNOWN;
    srv.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
    srv.Buffer.NumElements = (UINT)engine->mesh_patch_capacity;
    return SUCCEEDED(engine->device->CreateShaderResourceView(
        engine->mesh_patch_buffer.Get(), &srv, &engine->mesh_patch_srv));
}

static bool renderPacket(NsgpEngine *engine, NsgpSurfaceState *state,
    double logical_width,
    double logical_height, double scale, UINT physical_width_px,
    UINT physical_height_px, uint8_t clear_r, uint8_t clear_g,
    uint8_t clear_b, uint8_t clear_a, const uint8_t *packet, size_t packet_len,
    UINT present_interval) {
    if (!engine || !state || !state->swapchain || !packet || packet_len < 16 ||
        !weaverValidDeviceScale(scale) ||
        !weaverValidLogicalRect({ 0, 0, logical_width, logical_height }) ||
        !weaverValidSurfaceExtent(physical_width_px, physical_height_px)) return false;
    const UINT width = physical_width_px;
    const UINT height = physical_height_px;
    if (width != state->width || height != state->height) return false;

    PacketReader r{ packet, packet + packet_len };
    if (!r.skip(4) || memcmp(packet, "NSGP", 4) != 0) return false;
    uint8_t version = 0, load = 0, flags = 0, reserved = 0;
    uint64_t generation = 0;
    if (!r.u8(&version) || version != kBinaryPacketVersion || !r.u8(&load) || !r.u8(&flags) ||
        !r.u8(&reserved) || !r.u64(&generation)) return false;
    if (flags & 0x01) { F4 scissor; if (!r.rect(&scissor)) return false; }
    if (flags & 0x02) { uint32_t count; if (!r.u32(&count) || count > 8 || !r.skip((size_t)count * 16)) return false; }
    uint32_t image_count = 0, action_count = 0;
    if (!r.u32(&image_count) || image_count != 0 || !r.u32(&action_count) || action_count != 0) return false;

    std::map<uint64_t, RetainedCommand> next_retained = state->retained;
    std::vector<uint64_t> next_order = state->order;
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
        if (state->generation == 0 || state->generation != generation) return false;
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
    std::vector<GradientStopInstance> gradient_stops;
    std::vector<MeshPatchInstance> mesh_patches;
    for (uint64_t key : next_order) {
        const auto found = next_retained.find(key);
        if (found == next_retained.end()) return false;
        if (gradient_stops.size() + found->second.gradient_stops.size() >
            kMaxGradientStopsPerSurface) return false;
        if (mesh_patches.size() + found->second.mesh_patches.size() >
            kMaxMeshPatchesPerSurface) return false;
        const float stop_offset = static_cast<float>(gradient_stops.size());
        const float mesh_offset = static_cast<float>(mesh_patches.size());
        gradient_stops.insert(gradient_stops.end(),
            found->second.gradient_stops.begin(), found->second.gradient_stops.end());
        mesh_patches.insert(mesh_patches.end(),
            found->second.mesh_patches.begin(), found->second.mesh_patches.end());
        for (const Instance &retained_instance : found->second.instances) {
            Instance instance = retained_instance;
            if (instance.paint.x > 0.5f && instance.paint.x < 3.5f) {
                instance.paint.y = stop_offset;
                instance.paint.z = static_cast<float>(found->second.gradient_stops.size());
            } else if (instance.paint.x > 3.5f) {
                instance.paint.y = mesh_offset;
                instance.paint.z = static_cast<float>(found->second.mesh_patches.size());
            }
            instances.push_back(instance);
        }
    }
    if (!ensureInstances(engine, instances.size()) ||
        !ensureGradientStops(engine, gradient_stops.size()) ||
        !ensureMeshPatches(engine, mesh_patches.size())) return false;
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (!instances.empty()) {
        if (FAILED(engine->context->Map(engine->instance_buffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
        memcpy(mapped.pData, instances.data(), instances.size() * sizeof(Instance));
        engine->context->Unmap(engine->instance_buffer.Get(), 0);
    }
    if (!gradient_stops.empty()) {
        if (FAILED(engine->context->Map(engine->gradient_stop_buffer.Get(), 0,
            D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
        memcpy(mapped.pData, gradient_stops.data(),
            gradient_stops.size() * sizeof(GradientStopInstance));
        engine->context->Unmap(engine->gradient_stop_buffer.Get(), 0);
    }
    if (!mesh_patches.empty()) {
        if (FAILED(engine->context->Map(engine->mesh_patch_buffer.Get(), 0,
            D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
        memcpy(mapped.pData, mesh_patches.data(),
            mesh_patches.size() * sizeof(MeshPatchInstance));
        engine->context->Unmap(engine->mesh_patch_buffer.Get(), 0);
    }
    if (FAILED(engine->context->Map(engine->constant_buffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    float surface[4] = { (float)logical_width, (float)logical_height, 0, 0 };
    memcpy(mapped.pData, surface, sizeof(surface)); engine->context->Unmap(engine->constant_buffer.Get(), 0);

    ComPtr<ID3D11Texture2D> back;
    ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(state->swapchain->GetBuffer(0, IID_PPV_ARGS(&back))) ||
        FAILED(engine->device->CreateRenderTargetView(back.Get(), nullptr, &rtv))) return false;
    if (state->retained_texture) {
        engine->context->CopyResource(back.Get(), state->retained_texture.Get());
    } else {
        const float alpha = clear_a / 255.0f;
        const float clear[4] = { clear_r / 255.0f * alpha, clear_g / 255.0f * alpha,
            clear_b / 255.0f * alpha, alpha };
        engine->context->ClearRenderTargetView(rtv.Get(), clear);
    }
    engine->context->OMSetRenderTargets(1, rtv.GetAddressOf(), nullptr);
    engine->context->OMSetBlendState(engine->blend.Get(), nullptr, 0xffffffff);
    D3D11_VIEWPORT viewport = { 0, 0, (float)width, (float)height, 0, 1 };
    engine->context->RSSetViewports(1, &viewport);
    engine->context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    engine->context->VSSetShader(engine->vertex_shader.Get(), nullptr, 0);
    engine->context->VSSetConstantBuffers(0, 1, engine->constant_buffer.GetAddressOf());
    engine->context->VSSetShaderResources(0, 1, engine->instance_srv.GetAddressOf());
    engine->context->PSSetShader(engine->pixel_shader.Get(), nullptr, 0);
    engine->context->PSSetShaderResources(1, 1, engine->gradient_stop_srv.GetAddressOf());
    engine->context->PSSetShaderResources(2, 1, engine->mesh_patch_srv.GetAddressOf());
    if (!instances.empty()) engine->context->DrawInstanced(6, (UINT)instances.size(), 0, 0);
    ID3D11ShaderResourceView *null_srv = nullptr;
    engine->context->VSSetShaderResources(0, 1, &null_srv);
    engine->context->PSSetShaderResources(1, 1, &null_srv);
    engine->context->PSSetShaderResources(2, 1, &null_srv);
    if (FAILED(state->swapchain->Present(present_interval, 0))) return false;
    state->retained = std::move(next_retained); state->order = std::move(next_order); state->generation = generation;
    return true;
}

bool nativeSdkD3DPresenterPresent(NativeSdkD3DPresenter *p, double logical_width,
    double logical_height, double scale, uint8_t clear_r, uint8_t clear_g,
    uint8_t clear_b, uint8_t clear_a, const uint8_t *packet, size_t packet_len) {
    if (!p || !weaverValidDeviceScale(scale) ||
        !weaverValidLogicalRect({ 0, 0, logical_width, logical_height })) return false;
    const WeaverPhysicalRectI physical = weaverLogicalRectToPhysicalEdges(
        { 0, 0, logical_width, logical_height }, scale);
    const UINT width = static_cast<UINT>(weaverPhysicalWidth(physical));
    const UINT height = static_cast<UINT>(weaverPhysicalHeight(physical));
    if ((width != p->surface.width || height != p->surface.height) && !resizeSwapchain(p, width, height)) return false;
    return renderPacket(&p->engine, &p->surface, logical_width, logical_height,
        scale, width, height,
        clear_r, clear_g, clear_b, clear_a, packet, packet_len, 1);
}

NativeSdkD3DSharedRenderer *nativeSdkD3DSharedRendererCreate() {
    if (!nativeSdkD3DHardwareAvailable()) return nullptr;
    NativeSdkD3DSharedRenderer *renderer = new NativeSdkD3DSharedRenderer();
    if (!createEngine(&renderer->engine)) { delete renderer; return nullptr; }
    ComPtr<IDXGIDevice> dxgi_device;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIFactory2> factory;
    if (FAILED(renderer->engine.device.As(&dxgi_device)) ||
        FAILED(dxgi_device->GetAdapter(&adapter)) ||
        FAILED(adapter->GetParent(IID_PPV_ARGS(&factory))) ||
        FAILED(factory.As(&renderer->factory_media))) {
        delete renderer;
        return nullptr;
    }
    return renderer;
}

void nativeSdkD3DSharedRendererDestroy(NativeSdkD3DSharedRenderer *renderer) {
    delete renderer;
}

NativeSdkD3DSharedSurface *nativeSdkD3DSharedSurfaceCreate(
    NativeSdkD3DSharedRenderer *renderer, DWORD widget_pid,
    uint64_t *widget_surface_handle) {
    if (!renderer || widget_pid == 0) return nullptr;
    NativeSdkD3DSharedSurface *surface = new NativeSdkD3DSharedSurface();
    surface->renderer = renderer;
    surface->widget_pid = widget_pid;
    if (widget_surface_handle) *widget_surface_handle = 0;
    return surface;
}

void nativeSdkD3DSharedSurfaceDestroy(NativeSdkD3DSharedSurface *surface) {
    if (!surface) return;
    if (surface->composition_handle) CloseHandle(surface->composition_handle);
    delete surface;
}

static bool resizeSharedSurface(NativeSdkD3DSharedSurface *surface, UINT width,
    UINT height, uint64_t *widget_surface_handle) {
    NativeSdkD3DSharedRenderer *renderer = surface->renderer;
    if (!renderer || width == 0 || height == 0) return false;
    renderer->engine.context->OMSetRenderTargets(0, nullptr, nullptr);
    surface->state.swapchain.Reset();
    surface->state.retained_texture.Reset();
    surface->state.retained_generation = 0;
    if (surface->composition_handle) {
        CloseHandle(surface->composition_handle);
        surface->composition_handle = nullptr;
    }
    if (FAILED(DCompositionCreateSurfaceHandle(COMPOSITIONOBJECT_ALL_ACCESS,
        nullptr, &surface->composition_handle))) return false;
    DXGI_SWAP_CHAIN_DESC1 desc = {};
    desc.Width = width;
    desc.Height = height;
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    // Cross-process composition has one extra scheduling boundary between
    // the renderer's Present and the widget's visual. A third flip buffer
    // prevents one surface from monopolizing the shared renderer while DWM
    // consumes its previous frame; cadence still belongs to the widget.
    desc.BufferCount = 3;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    if (FAILED(renderer->factory_media->CreateSwapChainForCompositionSurfaceHandle(
        renderer->engine.device.Get(), surface->composition_handle, &desc,
        nullptr, &surface->state.swapchain))) return false;
    HANDLE widget_process = OpenProcess(PROCESS_DUP_HANDLE, FALSE, surface->widget_pid);
    if (!widget_process) return false;
    HANDLE duplicated = nullptr;
    const BOOL duplicate_ok = DuplicateHandle(GetCurrentProcess(),
        surface->composition_handle, widget_process, &duplicated, 0, FALSE,
        DUPLICATE_SAME_ACCESS);
    CloseHandle(widget_process);
    if (!duplicate_ok) return false;
    surface->state.width = width;
    surface->state.height = height;
    *widget_surface_handle = reinterpret_cast<uint64_t>(duplicated);
    return true;
}

bool nativeSdkD3DSharedSurfacePresent(NativeSdkD3DSharedSurface *surface,
    double logical_width, double logical_height, double scale,
    UINT source_texture_width_px, UINT source_texture_height_px,
    uint64_t geometry_generation,
    uint8_t clear_r, uint8_t clear_g, uint8_t clear_b, uint8_t clear_a,
    const uint8_t *packet, size_t packet_len, uint64_t retained_generation,
    UINT retained_width, UINT retained_height, const float *retained_dirty_rects,
    size_t retained_dirty_rect_count, const uint8_t *retained_bgra,
    uint64_t *replacement_widget_surface_handle) {
    if (!surface || !surface->renderer || !replacement_widget_surface_handle ||
        geometry_generation == 0 || !weaverValidDeviceScale(scale) ||
        !weaverValidLogicalRect({ 0, 0, logical_width, logical_height }) ||
        !weaverValidSurfaceExtent(source_texture_width_px,
            source_texture_height_px)) return false;
    NativeSdkD3DSharedRenderer *renderer = surface->renderer;
    std::unique_lock<std::mutex> lock(renderer->mutex);
    const uint64_t ticket = renderer->next_ticket++;
    renderer->turn_changed.wait(lock, [renderer, ticket] { return renderer->serving_ticket == ticket; });
    const auto finish_turn = [&] {
        renderer->serving_ticket += 1;
        lock.unlock();
        renderer->turn_changed.notify_all();
    };
    *replacement_widget_surface_handle = 0;
    const UINT width = source_texture_width_px;
    const UINT height = source_texture_height_px;
    if ((width != surface->state.width || height != surface->state.height) &&
        !resizeSharedSurface(surface, width, height, replacement_widget_surface_handle)) {
        finish_turn();
        return false;
    }
    if (surface->geometry_generation != geometry_generation) {
        // A geometry generation is a new presentation baseline even when a
        // pure move preserves the pixel extent. Retained pixels and packet
        // state must be republished once; subsequent frames reuse normally.
        surface->state.retained_texture.Reset();
        surface->state.retained_generation = 0;
        surface->state.retained.clear();
        surface->state.order.clear();
        surface->state.generation = 0;
        surface->geometry_generation = geometry_generation;
    }
    if (retained_generation != 0) {
        if (!retained_bgra || retained_width != width || retained_height != height ||
            retained_dirty_rect_count > 8) {
            finish_turn();
            return false;
        }
        if (!surface->state.retained_texture) {
            D3D11_TEXTURE2D_DESC desc = {};
            desc.Width = width; desc.Height = height;
            desc.MipLevels = 1; desc.ArraySize = 1;
            desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
            desc.SampleDesc.Count = 1; desc.Usage = D3D11_USAGE_DEFAULT;
            if (FAILED(renderer->engine.device->CreateTexture2D(&desc, nullptr,
                &surface->state.retained_texture))) {
                finish_turn();
                return false;
            }
            retained_dirty_rect_count = 0;
        }
        const size_t rect_count = retained_dirty_rect_count == 0 ? 1 : retained_dirty_rect_count;
        for (size_t index = 0; index < rect_count; ++index) {
            UINT left = 0, top = 0, right = width, bottom = height;
            if (retained_dirty_rect_count > 0) {
                const float *rect = retained_dirty_rects + index * 4;
                const WeaverPhysicalBoxU box = weaverLogicalDirtyRectToPhysicalBox(
                    { rect[0], rect[1], rect[2], rect[3] }, scale, width,
                    height);
                left = box.left;
                top = box.top;
                right = box.right;
                bottom = box.bottom;
            }
            if (right <= left || bottom <= top) continue;
            D3D11_BOX box = { left, top, 0, right, bottom, 1 };
            const uint8_t *source = retained_bgra + ((size_t)top * width + left) * 4;
            renderer->engine.context->UpdateSubresource(surface->state.retained_texture.Get(),
                0, &box, source, width * 4, width * height * 4);
        }
        surface->state.retained_generation = retained_generation;
    }
    const bool rendered = renderPacket(&renderer->engine, &surface->state,
        logical_width, logical_height, scale, width, height, clear_r, clear_g, clear_b,
        clear_a, packet, packet_len, 0);
    finish_turn();
    return rendered;
}

#if defined(WEAVER_D3D_PRESENTER_TESTS)
namespace {

template <typename T>
void appendTestScalar(std::vector<uint8_t> *bytes, const T &value) {
    const uint8_t *source = reinterpret_cast<const uint8_t *>(&value);
    bytes->insert(bytes->end(), source, source + sizeof(T));
}

void appendTestColor(std::vector<uint8_t> *bytes, float red, float green,
    float blue, float alpha) {
    appendTestScalar(bytes, red);
    appendTestScalar(bytes, green);
    appendTestScalar(bytes, blue);
    appendTestScalar(bytes, alpha);
}

void appendTestRect(std::vector<uint8_t> *bytes, float x, float y,
    float width, float height) {
    appendTestScalar(bytes, x);
    appendTestScalar(bytes, y);
    appendTestScalar(bytes, width);
    appendTestScalar(bytes, height);
}

void appendTestGradientPaint(std::vector<uint8_t> *bytes, uint8_t tag,
    uint8_t spread, uint8_t interpolation) {
    appendTestScalar(bytes, tag);
    appendTestScalar(bytes, 10.0f);
    appendTestScalar(bytes, 20.0f);
    if (tag == 2 || tag == 3) {
        appendTestScalar(bytes, 90.0f);
        appendTestScalar(bytes, 60.0f);
    } else {
        appendTestScalar(bytes, 0.75f);
    }
    appendTestScalar(bytes, spread);
    appendTestScalar(bytes, interpolation);
    appendTestScalar(bytes, static_cast<uint32_t>(3));
    appendTestScalar(bytes, 0.0f);
    appendTestColor(bytes, 1.0f, 0.0f, 0.0f, 0.5f);
    appendTestScalar(bytes, 0.4f);
    appendTestColor(bytes, 0.0f, 1.0f, 0.0f, 0.75f);
    appendTestScalar(bytes, 1.0f);
    appendTestColor(bytes, 0.0f, 0.0f, 1.0f, 1.0f);
}

void appendTestMeshPaint(std::vector<uint8_t> *bytes) {
    appendTestScalar(bytes, static_cast<uint8_t>(5));
    appendTestScalar(bytes, static_cast<uint8_t>(2)); // Oklab
    appendTestScalar(bytes, static_cast<uint32_t>(1));
    for (uint32_t row = 0; row < 4; ++row) {
        for (uint32_t column = 0; column < 4; ++column) {
            appendTestScalar(bytes, 10.0f + column * 20.0f);
            appendTestScalar(bytes, 20.0f + row * 10.0f);
        }
    }
    appendTestColor(bytes, 1.0f, 0.0f, 0.0f, 0.5f);
    appendTestColor(bytes, 0.0f, 1.0f, 0.0f, 0.75f);
    appendTestColor(bytes, 0.0f, 0.0f, 1.0f, 1.0f);
    appendTestColor(bytes, 1.0f, 1.0f, 1.0f, 1.0f);
}

bool closeEnough(float actual, float expected) {
    return std::abs(actual - expected) <= 0.000001f;
}

bool waitForQuery(ID3D11DeviceContext *context, ID3D11Query *query,
    void *data, UINT data_size) {
    const ULONGLONG deadline = GetTickCount64() + 5000;
    while (true) {
        const HRESULT result = context->GetData(query, data, data_size, 0);
        if (result == S_OK) return true;
        if (result != S_FALSE || GetTickCount64() >= deadline) return false;
        Sleep(0);
    }
}

/// Opt-in, hardware-only GPU receipt. CI still compiles and shader-compiles
/// this lane everywhere; a Windows machine with a real adapter runs it with
/// NATIVE_SDK_D3D_GRADIENT_BENCH=1. An optional
/// NATIVE_SDK_D3D_GRADIENT_BUDGET_US makes the measured per-draw timestamp a
/// hard gate without pretending dissimilar GPUs share one universal budget.
bool runMeshGpuTimestampBenchmark() {
    char enabled[8] = {};
    if (GetEnvironmentVariableA("NATIVE_SDK_D3D_GRADIENT_BENCH", enabled,
            sizeof(enabled)) == 0 || strcmp(enabled, "1") != 0) return true;

    NsgpEngine engine;
    if (!createEngine(&engine)) return false; // hardware only; never WARP
    ComPtr<IDXGIDevice> dxgi_device;
    ComPtr<IDXGIAdapter> adapter;
    ComPtr<IDXGIAdapter1> adapter1;
    DXGI_ADAPTER_DESC1 adapter_desc = {};
    if (FAILED(engine.device.As(&dxgi_device)) ||
        FAILED(dxgi_device->GetAdapter(&adapter)) ||
        FAILED(adapter.As(&adapter1)) ||
        FAILED(adapter1->GetDesc1(&adapter_desc)) ||
        (adapter_desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) != 0) return false;
    fprintf(stderr,
        "native-sdk-d3d: adapter vendor=0x%04x device=0x%04x dedicated=%lluMiB shared=%lluMiB\n",
        adapter_desc.VendorId, adapter_desc.DeviceId,
        static_cast<unsigned long long>(adapter_desc.DedicatedVideoMemory / (1024 * 1024)),
        static_cast<unsigned long long>(adapter_desc.SharedSystemMemory / (1024 * 1024)));
    constexpr UINT width = 512;
    constexpr UINT height = 512;
    constexpr UINT patch_columns = 4;
    constexpr UINT patch_rows = 4;
    constexpr UINT draw_count = 64;

    Instance instance = {};
    instance.rect = { 0, 0, static_cast<float>(width), static_cast<float>(height) };
    instance.paint = { 4, 0, static_cast<float>(patch_columns * patch_rows), 1 };
    std::vector<MeshPatchInstance> patches(patch_columns * patch_rows);
    for (UINT patch_row = 0; patch_row < patch_rows; ++patch_row) {
        for (UINT patch_column = 0; patch_column < patch_columns; ++patch_column) {
            MeshPatchInstance &patch = patches[patch_row * patch_columns + patch_column];
            const float left = static_cast<float>(patch_column * width / patch_columns);
            const float top = static_cast<float>(patch_row * height / patch_rows);
            const float right = static_cast<float>((patch_column + 1) * width / patch_columns);
            const float bottom = static_cast<float>((patch_row + 1) * height / patch_rows);
            for (UINT row = 0; row < 4; ++row) {
                for (UINT column = 0; column < 4; ++column) {
                    const UINT index = row * 4 + column;
                    const float x = left + (right - left) * column / 3.0f;
                    const float y = top + (bottom - top) * row / 3.0f;
                    F4 &pair = patch.points[index / 2];
                    if ((index & 1) == 0) {
                        pair.x = x; pair.y = y;
                    } else {
                        pair.z = x; pair.w = y;
                    }
                }
            }
            patch.colors[0] = { 0.96f, 0.25f, 0.37f, 1 };
            patch.colors[1] = { 0.05f, 0.65f, 0.91f, 1 };
            patch.colors[2] = { 0.66f, 0.33f, 0.97f, 1 };
            patch.colors[3] = { 0.98f, 0.80f, 0.08f, 1 };
            patch.bounds = { left, top, right, bottom };
            patch.options = { 2, 0, 0, 0 }; // Oklab, the expensive lane
        }
    }

    if (!ensureInstances(&engine, 1) ||
        !ensureMeshPatches(&engine, patches.size())) return false;
    D3D11_MAPPED_SUBRESOURCE mapped = {};
    if (FAILED(engine.context->Map(engine.instance_buffer.Get(), 0,
            D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    memcpy(mapped.pData, &instance, sizeof(instance));
    engine.context->Unmap(engine.instance_buffer.Get(), 0);
    if (FAILED(engine.context->Map(engine.mesh_patch_buffer.Get(), 0,
            D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    memcpy(mapped.pData, patches.data(), patches.size() * sizeof(MeshPatchInstance));
    engine.context->Unmap(engine.mesh_patch_buffer.Get(), 0);
    if (FAILED(engine.context->Map(engine.constant_buffer.Get(), 0,
            D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return false;
    const float surface[4] = { static_cast<float>(width), static_cast<float>(height), 0, 0 };
    memcpy(mapped.pData, surface, sizeof(surface));
    engine.context->Unmap(engine.constant_buffer.Get(), 0);

    D3D11_TEXTURE2D_DESC texture_desc = {};
    texture_desc.Width = width; texture_desc.Height = height;
    texture_desc.MipLevels = 1; texture_desc.ArraySize = 1;
    texture_desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    texture_desc.SampleDesc.Count = 1; texture_desc.Usage = D3D11_USAGE_DEFAULT;
    texture_desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ComPtr<ID3D11Texture2D> texture;
    ComPtr<ID3D11RenderTargetView> rtv;
    if (FAILED(engine.device->CreateTexture2D(&texture_desc, nullptr, &texture)) ||
        FAILED(engine.device->CreateRenderTargetView(texture.Get(), nullptr, &rtv))) return false;

    engine.context->OMSetRenderTargets(1, rtv.GetAddressOf(), nullptr);
    engine.context->OMSetBlendState(engine.blend.Get(), nullptr, 0xffffffff);
    D3D11_VIEWPORT viewport = { 0, 0, static_cast<float>(width), static_cast<float>(height), 0, 1 };
    engine.context->RSSetViewports(1, &viewport);
    engine.context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    engine.context->VSSetShader(engine.vertex_shader.Get(), nullptr, 0);
    engine.context->VSSetConstantBuffers(0, 1, engine.constant_buffer.GetAddressOf());
    engine.context->VSSetShaderResources(0, 1, engine.instance_srv.GetAddressOf());
    engine.context->PSSetShader(engine.pixel_shader.Get(), nullptr, 0);
    engine.context->PSSetShaderResources(2, 1, engine.mesh_patch_srv.GetAddressOf());
    for (UINT warmup = 0; warmup < 8; ++warmup) engine.context->DrawInstanced(6, 1, 0, 0);

    D3D11_QUERY_DESC query_desc = { D3D11_QUERY_TIMESTAMP_DISJOINT, 0 };
    ComPtr<ID3D11Query> disjoint;
    query_desc.Query = D3D11_QUERY_TIMESTAMP;
    ComPtr<ID3D11Query> start;
    ComPtr<ID3D11Query> end;
    if (FAILED(engine.device->CreateQuery(&query_desc, &start)) ||
        FAILED(engine.device->CreateQuery(&query_desc, &end))) return false;
    query_desc.Query = D3D11_QUERY_TIMESTAMP_DISJOINT;
    if (FAILED(engine.device->CreateQuery(&query_desc, &disjoint))) return false;

    engine.context->Begin(disjoint.Get());
    engine.context->End(start.Get());
    for (UINT draw = 0; draw < draw_count; ++draw) engine.context->DrawInstanced(6, 1, 0, 0);
    engine.context->End(end.Get());
    engine.context->End(disjoint.Get());
    engine.context->Flush();
    D3D11_QUERY_DATA_TIMESTAMP_DISJOINT timing = {};
    UINT64 start_ticks = 0, end_ticks = 0;
    if (!waitForQuery(engine.context.Get(), disjoint.Get(), &timing, sizeof(timing)) ||
        !waitForQuery(engine.context.Get(), start.Get(), &start_ticks, sizeof(start_ticks)) ||
        !waitForQuery(engine.context.Get(), end.Get(), &end_ticks, sizeof(end_ticks)) ||
        timing.Disjoint || timing.Frequency == 0 || end_ticks < start_ticks) return false;
    const double microseconds = static_cast<double>(end_ticks - start_ticks) *
        1'000'000.0 / static_cast<double>(timing.Frequency) / draw_count;
    fprintf(stderr, "native-sdk-d3d: mesh-gradient 512x512 16-patch Oklab GPU %.3fus/draw\n", microseconds);

    char budget_text[64] = {};
    const DWORD budget_length = GetEnvironmentVariableA(
        "NATIVE_SDK_D3D_GRADIENT_BUDGET_US", budget_text, sizeof(budget_text));
    if (budget_length > 0) {
        if (budget_length >= sizeof(budget_text)) return false;
        char *end_pointer = nullptr;
        const double budget = strtod(budget_text, &end_pointer);
        if (end_pointer == budget_text || *end_pointer != '\0' ||
            !std::isfinite(budget) || budget <= 0 ||
            microseconds > budget) return false;
    }
    return true;
}

} // namespace

extern "C" int native_sdk_d3d_presenter_tests() {
    int failures = 0;
    const auto expect = [&failures](bool condition) {
        if (!condition) ++failures;
    };

    std::vector<uint8_t> bytes;
    appendTestScalar(&bytes, static_cast<uint8_t>(1)); // fill_rect_gradient
    appendTestScalar(&bytes, static_cast<uint8_t>(0x18)); // shape + paint
    appendTestRect(&bytes, 10.0f, 20.0f, 80.0f, 40.0f); // bounds
    appendTestScalar(&bytes, 0.25f); // opacity
    appendTestScalar(&bytes, 0.0f); // stroke width
    appendTestScalar(&bytes, static_cast<uint8_t>(0)); // butt cap
    appendTestScalar(&bytes, static_cast<uint8_t>(1)); // rect
    appendTestRect(&bytes, 10.0f, 20.0f, 80.0f, 40.0f);
    appendTestGradientPaint(&bytes, 2, 2, 2);

    PacketReader reader{ bytes.data(), bytes.data() + bytes.size() };
    RetainedCommand command;
    expect(readCommand(reader, &command));
    expect(reader.cursor == reader.end);
    expect(command.instances.size() == 1);
    expect(command.gradient_stops.size() == 3);
    if (command.instances.size() == 1) {
        const Instance &instance = command.instances[0];
        expect(closeEnough(instance.paint.x, 1.0f));
        expect(closeEnough(instance.paint.w, 0.25f));
        expect(closeEnough(instance.gradient.x, 10.0f));
        expect(closeEnough(instance.gradient.y, 20.0f));
        expect(closeEnough(instance.gradient.z, 90.0f));
        expect(closeEnough(instance.gradient.w, 60.0f));
        expect(closeEnough(instance.gradient_options.x, 2.0f));
        expect(closeEnough(instance.gradient_options.y, 2.0f));
    }
    if (command.gradient_stops.size() == 3) {
        expect(closeEnough(command.gradient_stops[0].data.x, 0.0f));
        expect(closeEnough(command.gradient_stops[1].data.x, 0.4f));
        expect(closeEnough(command.gradient_stops[2].data.x, 1.0f));
        // Gradient colors remain straight-alpha until the shader finishes
        // interpolation. Premultiplying this first stop here would make red
        // 0.5 and diverge from the deterministic reference renderer.
        expect(closeEnough(command.gradient_stops[0].color.x, 1.0f));
        expect(closeEnough(command.gradient_stops[0].color.w, 0.5f));
    }

    const auto append_path_command = [&bytes](uint8_t kind) {
        bytes.clear();
        appendTestScalar(&bytes, kind);
        appendTestScalar(&bytes, static_cast<uint8_t>(0x18)); // shape + paint
        appendTestRect(&bytes, 10.0f, 20.0f, 80.0f, 40.0f);
        appendTestScalar(&bytes, 1.0f); // opacity
        appendTestScalar(&bytes, 2.0f); // stroke width
        appendTestScalar(&bytes, static_cast<uint8_t>(0)); // butt cap
        appendTestScalar(&bytes, static_cast<uint8_t>(5)); // path
        appendTestScalar(&bytes, static_cast<uint32_t>(3));
        appendTestScalar(&bytes, static_cast<uint8_t>(0)); // move_to
        appendTestScalar(&bytes, 10.0f);
        appendTestScalar(&bytes, 20.0f);
        appendTestScalar(&bytes, static_cast<uint8_t>(1)); // line_to
        appendTestScalar(&bytes, 90.0f);
        appendTestScalar(&bytes, 60.0f);
        appendTestScalar(&bytes, static_cast<uint8_t>(4)); // close
        appendTestGradientPaint(&bytes, 2, 0, 0);
    };

    append_path_command(8); // fill_path: CPU/pixel fallback owns interiors
    reader = { bytes.data(), bytes.data() + bytes.size() };
    expect(!readCommand(reader, &command));

    append_path_command(9); // stroke_path: line instances are exact
    reader = { bytes.data(), bytes.data() + bytes.size() };
    expect(readCommand(reader, &command));
    expect(reader.cursor == reader.end);
    expect(command.instances.size() == 2);
    expect(command.gradient_stops.size() == 3);

    std::vector<GradientStopInstance> stops;
    std::vector<MeshPatchInstance> mesh_patches;
    for (uint8_t tag = 3; tag <= 4; ++tag) {
        bytes.clear();
        appendTestGradientPaint(&bytes, tag, 1, 0);
        reader = { bytes.data(), bytes.data() + bytes.size() };
        Instance gradient_instance = {};
        stops.clear();
        mesh_patches.clear();
        expect(readPaint(reader, &gradient_instance, &stops, &mesh_patches));
        expect(reader.cursor == reader.end);
        expect(closeEnough(gradient_instance.paint.x, static_cast<float>(tag - 1)));
        expect(closeEnough(gradient_instance.gradient_options.x, 1.0f));
        expect(closeEnough(gradient_instance.gradient_options.y, 0.0f));
        expect(closeEnough(gradient_instance.gradient.x, 10.0f));
        expect(closeEnough(gradient_instance.gradient.y, 20.0f));
        expect(closeEnough(gradient_instance.gradient.z, tag == 3 ? 90.0f : 0.75f));
        if (tag == 3) expect(closeEnough(gradient_instance.gradient.w, 60.0f));
        expect(stops.size() == 3);
    }

    bytes.clear();
    appendTestScalar(&bytes, static_cast<uint8_t>(2));
    appendTestScalar(&bytes, 0.0f);
    appendTestScalar(&bytes, 0.0f);
    appendTestScalar(&bytes, 1.0f);
    appendTestScalar(&bytes, 1.0f);
    appendTestScalar(&bytes, static_cast<uint8_t>(0));
    appendTestScalar(&bytes, static_cast<uint8_t>(1));
    appendTestScalar(&bytes, kMaxGradientStopsPerSurface + 1);
    reader = { bytes.data(), bytes.data() + bytes.size() };
    Instance instance = {};
    stops.clear();
    mesh_patches.clear();
    expect(!readPaint(reader, &instance, &stops, &mesh_patches));

    bytes.clear();
    appendTestScalar(&bytes, static_cast<uint8_t>(4));
    appendTestScalar(&bytes, 0.0f);
    appendTestScalar(&bytes, 0.0f);
    appendTestScalar(&bytes, 0.0f);
    appendTestScalar(&bytes, static_cast<uint8_t>(3)); // invalid spread
    appendTestScalar(&bytes, static_cast<uint8_t>(1));
    appendTestScalar(&bytes, static_cast<uint32_t>(0));
    reader = { bytes.data(), bytes.data() + bytes.size() };
    stops.clear();
    mesh_patches.clear();
    expect(!readPaint(reader, &instance, &stops, &mesh_patches));

    bytes.clear();
    appendTestMeshPaint(&bytes);
    reader = { bytes.data(), bytes.data() + bytes.size() };
    stops.clear(); mesh_patches.clear();
    expect(readPaint(reader, &instance, &stops, &mesh_patches));
    expect(reader.cursor == reader.end);
    expect(closeEnough(instance.paint.x, 4.0f));
    expect(mesh_patches.size() == 1);
    if (mesh_patches.size() == 1) {
        expect(closeEnough(mesh_patches[0].bounds.x, 10.0f));
        expect(closeEnough(mesh_patches[0].bounds.y, 20.0f));
        expect(closeEnough(mesh_patches[0].bounds.z, 70.0f));
        expect(closeEnough(mesh_patches[0].bounds.w, 50.0f));
        expect(closeEnough(mesh_patches[0].options.x, 2.0f));
        expect(closeEnough(mesh_patches[0].colors[0].x, 1.0f));
        expect(closeEnough(mesh_patches[0].colors[0].w, 0.5f));
    }

    bytes.clear();
    appendTestScalar(&bytes, static_cast<uint8_t>(5));
    appendTestScalar(&bytes, static_cast<uint8_t>(1));
    appendTestScalar(&bytes, kMaxMeshPatchesPerSurface + 1);
    reader = { bytes.data(), bytes.data() + bytes.size() };
    mesh_patches.clear();
    expect(!readPaint(reader, &instance, &stops, &mesh_patches));

    ComPtr<ID3DBlob> vertex_shader;
    ComPtr<ID3DBlob> pixel_shader;
    expect(SUCCEEDED(compileShader("vsMain", "vs_5_0", &vertex_shader)));
    expect(SUCCEEDED(compileShader("psMain", "ps_5_0", &pixel_shader)));
    expect(runMeshGpuTimestampBenchmark());
    return failures;
}
#endif
