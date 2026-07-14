#pragma once

#include <windows.h>
#include <stddef.h>
#include <stdint.h>

struct NativeSdkSharedRendererClient;

/// Creates only the device-less DirectComposition side of a shared surface.
/// Pipe connection is lazy so widgets launch safely while weaverd is still
/// bringing the renderer up, and reconnect after a renderer crash.
NativeSdkSharedRendererClient *nativeSdkSharedRendererClientCreate(HWND window);
void nativeSdkSharedRendererClientDestroy(NativeSdkSharedRendererClient *client);
bool nativeSdkSharedRendererClientPresent(
    NativeSdkSharedRendererClient *client,
    double logical_width,
    double logical_height,
    double scale,
    uint8_t clear_r,
    uint8_t clear_g,
    uint8_t clear_b,
    uint8_t clear_a,
    const uint8_t *packet,
    size_t packet_len,
    uint64_t retained_generation,
    size_t retained_width,
    size_t retained_height,
    const float *retained_dirty_rects,
    size_t retained_dirty_rect_count,
    const uint8_t *retained_rgba8,
    size_t retained_rgba8_len);
bool nativeSdkSharedRendererClientConnected(const NativeSdkSharedRendererClient *client);
