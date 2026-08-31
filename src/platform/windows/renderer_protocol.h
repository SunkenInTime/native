#pragma once

#include <stdint.h>
#include <stddef.h>
#include <cmath>

#include "dpi_geometry.h"

/// Fixed framing keeps the high-rate renderer pipe out of JSON parsing and
/// preserves the existing NSGP packet as the single rendering truth. Each
/// request receives exactly one reply, which is also the frame-completion
/// signal used by the widget's existing scheduler.
static constexpr uint32_t kWeaverRendererMagic = 0x31525257; // WRR1
static constexpr uint32_t kWeaverRendererVersion = 4;
static constexpr uint32_t kWeaverRendererMaxPacket = 8 * 1024 * 1024;
static constexpr uint32_t kWeaverRendererMaxDirtyRects = 8;
static constexpr uint32_t kWeaverRendererSectionNameChars = 96;

struct WeaverRendererRect { float x, y, width, height; };

enum WeaverRendererStatus : uint32_t {
    kWeaverRendererStatusFailed = 0,
    kWeaverRendererStatusOk = 1,
    kWeaverRendererStatusVersionMismatch = 2,
};

// The connection handshake is deliberately separate from frame framing. A
// stale client and renderer reject one another before either side sends or
// waits for a differently-sized frame structure or a multi-megabyte packet.
struct WeaverRendererHello {
    uint32_t magic;
    uint32_t version;
    uint32_t struct_size;
    uint32_t widget_pid;
};

struct WeaverRendererHelloReply {
    uint32_t magic;
    uint32_t version;
    uint32_t struct_size;
    uint32_t status;
};

struct WeaverRendererFrame {
    uint32_t magic;
    uint32_t version;
    uint32_t struct_size;
    uint32_t widget_pid;
    uint32_t packet_len;
    uint32_t source_texture_width_px;
    uint32_t source_texture_height_px;
    uint32_t reserved0;
    double logical_surface_width_dip;
    double logical_surface_height_dip;
    double device_scale;
    double destination_x_dip;
    double destination_y_dip;
    double destination_width_dip;
    double destination_height_dip;
    int32_t destination_left_px;
    int32_t destination_top_px;
    int32_t destination_right_px;
    int32_t destination_bottom_px;
    uint64_t geometry_generation;
    uint8_t clear_r;
    uint8_t clear_g;
    uint8_t clear_b;
    uint8_t clear_a;
    uint32_t retained_above_packet;
    uint64_t retained_generation;
    uint32_t retained_width;
    uint32_t retained_height;
    uint32_t retained_dirty_rect_count;
    uint32_t retained_section_name_len;
    WeaverRendererRect retained_dirty_rects[kWeaverRendererMaxDirtyRects];
    wchar_t retained_section_name[kWeaverRendererSectionNameChars];
};

struct WeaverRendererReply {
    uint32_t magic;
    uint32_t version;
    uint32_t status;
    uint32_t reserved;
    uint64_t surface_handle;
};

inline bool weaverRendererHelloValid(const WeaverRendererHello &hello) {
    return hello.magic == kWeaverRendererMagic &&
        hello.version == kWeaverRendererVersion &&
        hello.struct_size == sizeof(WeaverRendererHello) && hello.widget_pid != 0;
}

inline bool weaverRendererFrameValid(const WeaverRendererFrame &frame) {
    if (frame.magic != kWeaverRendererMagic ||
        frame.version != kWeaverRendererVersion ||
        frame.struct_size != sizeof(WeaverRendererFrame) ||
        frame.widget_pid == 0 || frame.packet_len == 0 ||
        frame.packet_len > kWeaverRendererMaxPacket ||
        frame.geometry_generation == 0 ||
        !weaverValidDeviceScale(frame.device_scale) ||
        !weaverValidLogicalRect({ 0, 0, frame.logical_surface_width_dip,
            frame.logical_surface_height_dip }) ||
        !weaverValidLogicalRect({ frame.destination_x_dip,
            frame.destination_y_dip, frame.destination_width_dip,
            frame.destination_height_dip }, false) ||
        !weaverValidSurfaceExtent(frame.source_texture_width_px,
            frame.source_texture_height_px) ||
        frame.retained_above_packet > 1 ||
        frame.retained_dirty_rect_count > kWeaverRendererMaxDirtyRects ||
        frame.retained_section_name_len >= kWeaverRendererSectionNameChars) return false;
    const WeaverPhysicalRectI destination = {
        frame.destination_left_px, frame.destination_top_px,
        frame.destination_right_px, frame.destination_bottom_px,
    };
    if (!weaverValidPhysicalRect(destination) ||
        static_cast<uint32_t>(weaverPhysicalWidth(destination)) !=
            frame.source_texture_width_px ||
        static_cast<uint32_t>(weaverPhysicalHeight(destination)) !=
            frame.source_texture_height_px) return false;
    if (frame.retained_generation != 0 &&
        (frame.retained_width != frame.source_texture_width_px ||
         frame.retained_height != frame.source_texture_height_px ||
         frame.retained_section_name_len == 0)) return false;
    for (uint32_t index = 0; index < frame.retained_dirty_rect_count; ++index) {
        const WeaverRendererRect &rect = frame.retained_dirty_rects[index];
        if (!weaverValidLogicalRect({ rect.x, rect.y, rect.width, rect.height }))
            return false;
    }
    return true;
}
