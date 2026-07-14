#pragma once

#include <stdint.h>

/// Fixed framing keeps the high-rate renderer pipe out of JSON parsing and
/// preserves the existing NSGP packet as the single rendering truth. Each
/// request receives exactly one reply, which is also the frame-completion
/// signal used by the widget's existing scheduler.
static constexpr uint32_t kWeaverRendererMagic = 0x31525257; // WRR1
static constexpr uint32_t kWeaverRendererVersion = 1;
static constexpr uint32_t kWeaverRendererMaxPacket = 8 * 1024 * 1024;

struct WeaverRendererFrame {
    uint32_t magic;
    uint32_t version;
    uint32_t widget_pid;
    uint32_t packet_len;
    double logical_width;
    double logical_height;
    double scale;
    uint8_t clear_r;
    uint8_t clear_g;
    uint8_t clear_b;
    uint8_t clear_a;
    uint32_t reserved;
};

struct WeaverRendererReply {
    uint32_t magic;
    uint32_t version;
    uint32_t status;
    uint32_t reserved;
    uint64_t surface_handle;
};
