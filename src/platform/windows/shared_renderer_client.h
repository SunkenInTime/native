#pragma once

#include <windows.h>
#include <stddef.h>
#include <stdint.h>

struct NativeSdkSharedRendererClient;

struct NativeSdkSharedRendererGeometry {
    double destination_x_dip;
    double destination_y_dip;
    double destination_width_dip;
    double destination_height_dip;
    int32_t destination_left_px;
    int32_t destination_top_px;
    int32_t destination_right_px;
    int32_t destination_bottom_px;
    uint32_t source_texture_width_px;
    uint32_t source_texture_height_px;
    uint64_t generation;
};

/// Creates only the device-less DirectComposition side of a shared surface.
/// Pipe connection remains explicit so the Windows host can complete the
/// handshake before it advertises D3D11 to the runtime.
NativeSdkSharedRendererClient *nativeSdkSharedRendererClientCreate(HWND window);
void nativeSdkSharedRendererClientDestroy(NativeSdkSharedRendererClient *client);
bool nativeSdkSharedRendererClientEnsureConnected(NativeSdkSharedRendererClient *client);
bool nativeSdkSharedRendererClientPresent(
    NativeSdkSharedRendererClient *client,
    double logical_width,
    double logical_height,
    double scale,
    const NativeSdkSharedRendererGeometry *geometry,
    uint8_t clear_r,
    uint8_t clear_g,
    uint8_t clear_b,
    uint8_t clear_a,
    const uint8_t *packet,
    size_t packet_len,
    int retained_composite,
    uint64_t retained_generation,
    size_t retained_width,
    size_t retained_height,
    const float *retained_dirty_rects,
    size_t retained_dirty_rect_count,
    const uint8_t *retained_rgba8,
    size_t retained_rgba8_len);
bool nativeSdkSharedRendererClientConnected(const NativeSdkSharedRendererClient *client);
