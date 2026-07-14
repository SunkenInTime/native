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
    size_t packet_len);
bool nativeSdkSharedRendererClientConnected(const NativeSdkSharedRendererClient *client);
