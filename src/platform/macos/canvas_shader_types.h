#ifndef NATIVE_SDK_CANVAS_SHADER_TYPES_H
#define NATIVE_SDK_CANVAS_SHADER_TYPES_H

#if defined(__METAL_VERSION__)
#define NATIVE_SDK_FLOAT4 float4
#else
#include <simd/simd.h>
#define NATIVE_SDK_FLOAT4 vector_float4
#endif

/* These records mirror the existing canvas-wide limits: 64 stops and 16
 * mesh patches. They are shared by Objective-C and Metal so the fixed,
 * lazily allocated buffers cannot drift from the shader ABI. */
typedef struct {
    NATIVE_SDK_FLOAT4 color; /* straight-alpha sRGB */
    NATIVE_SDK_FLOAT4 data;  /* x = normalized stop offset */
} NativeSdkGradientStopGpu;

typedef struct {
    NATIVE_SDK_FLOAT4 points[8]; /* 16 row-major float2 control points */
    NATIVE_SDK_FLOAT4 colors[4]; /* TL, TR, BR, BL; straight alpha */
    NATIVE_SDK_FLOAT4 bounds;    /* min x/y, max x/y in device pixels */
    NATIVE_SDK_FLOAT4 options;   /* x = interpolation code */
} NativeSdkMeshPatchGpu;

typedef struct {
    NATIVE_SDK_FLOAT4 viewport;       /* x/y = physical surface size */
    NATIVE_SDK_FLOAT4 draw_rect;      /* conservative device-pixel quad */
    NATIVE_SDK_FLOAT4 shape_rect;     /* untransformed fill in device pixels */
    NATIVE_SDK_FLOAT4 corner_radius;  /* TL, TR, BR, BL in device pixels */
    NATIVE_SDK_FLOAT4 clip_rect;      /* negative width means no clip */
    NATIVE_SDK_FLOAT4 clip_radius;
    NATIVE_SDK_FLOAT4 gradient;       /* linear points; radial center/basis; conic center/angle */
    NATIVE_SDK_FLOAT4 gradient_options; /* spread, interpolation, radial Y basis */
    NATIVE_SDK_FLOAT4 conic_basis;    /* authored axes scaled into device pixels */
    NATIVE_SDK_FLOAT4 paint;          /* kind, first resource, resource count, opacity */
} NativeSdkGradientUniforms;

#undef NATIVE_SDK_FLOAT4

#endif
