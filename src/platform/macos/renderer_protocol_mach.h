#pragma once

#include <mach/mach.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The macOS shared-renderer channel, sibling of the Windows contract in
 * ../windows/renderer_protocol.h: fixed framing, one reply per request
 * (the reply is also the frame-completion signal the widget's scheduler
 * uses), and a handshake deliberately separate from frame framing so a
 * stale client and host reject one another before either side parses a
 * differently-sized frame structure.
 *
 * The channel is mach end-to-end — measured receipt in the weaver repo's
 * docs/macos-memory-handoff.md (2026-07-30): a non-launchd host claims a
 * dynamic per-user bootstrap name with bootstrap_check_in, widgets find
 * it with bootstrap_look_up, NSGP packet bytes travel as out-of-line
 * descriptors (vm-remapped, no copy for multi-megabyte packets), rendered
 * frames come back as IOSurface send rights in port descriptors
 * (IOSurfaceLookupFromMachPort — no deprecated global-surface lookup),
 * and client death is a no-senders notification on the per-client
 * session port. */

static const uint32_t kWeaverRendererMachMagic = 0x314d5257; /* WRM1 */
static const uint32_t kWeaverRendererMachVersion = 1;
/* Same packet ceiling as the Windows contract (kWeaverRendererMaxPacket):
 * a tripwire far past any measured widget packet, not a budget widgets
 * feel. */
static const uint32_t kWeaverRendererMachMaxPacket = 8 * 1024 * 1024;

/* The host's per-user bootstrap name. Overridable so tests and bakeoff
 * runs can isolate a private host instance. */
#define WEAVER_RENDER_HOST_NAME_ENV "WEAVER_RENDER_HOST_NAME"
#define WEAVER_RENDER_HOST_DEFAULT_NAME "com.weaver.render-host"

enum {
    kWeaverRendererMachMsgHello = 0x57520001,
    kWeaverRendererMachMsgFrame = 0x57520002,
    kWeaverRendererMachMsgImageUpload = 0x57520003,
};

/* Image pixels ride a side channel, exactly like the in-process binary
 * ABI (`uploadGpuSurfaceImage` runs BEFORE the packet referencing the
 * image is presented): packets carry only id + fingerprint references.
 * The ceiling mirrors canvas_limits.max_registered_canvas_image_pixel_bytes
 * for the stock profile (1 MiB; the widget profile's 256 KiB is enforced
 * client-side by the SDK before bytes ever reach this channel). */
static const uint32_t kWeaverRendererMachMaxImageBytes = 1024 * 1024;

enum {
    kWeaverRendererMachStatusFailed = 0,
    kWeaverRendererMachStatusOk = 1,
    kWeaverRendererMachStatusRefused = 2, /* packet refused; client resyncs with a full present */
    kWeaverRendererMachStatusVersionMismatch = 3,
};

/* Hello rides the service port; everything after rides the per-client
 * session port the reply carries. widget_pid is diagnostic (logs name the
 * client); trust derives from the bootstrap namespace, which is already
 * per-user. */
typedef struct {
    mach_msg_header_t header;
    uint32_t magic;
    uint32_t version;
    uint32_t struct_size;
    uint32_t widget_pid;
} WeaverRendererMachHello;

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    /* A send right to this client's session port (absent when status
     * is not Ok — the descriptor count says which). */
    mach_msg_port_descriptor_t session_port;
    uint32_t magic;
    uint32_t version;
    uint32_t status;
    uint32_t reserved;
} WeaverRendererMachHelloReply;

/* One frame present: the NSGP packet bytes are out-of-line (deallocated
 * by the receiver), the scalars mirror the in-process binary-packet ABI
 * exactly so both paths can never draw differently. */
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t packet;
    uint32_t magic;
    uint32_t version;
    uint32_t struct_size;
    uint32_t packet_len;
    double surface_width;
    double surface_height;
    double scale;
    uint8_t clear_r, clear_g, clear_b, clear_a;
    uint32_t requires_render;
    uint32_t command_count;
    uint32_t unsupported_command_count;
    uint32_t representable;
} WeaverRendererMachFrame;

/* The reply is the completion signal: it is sent only after the host's
 * GPU finished writing the surface, so the widget may flip the surface
 * into its layer contents the moment this arrives. The surface send
 * right is included on every Ok reply; clients that already hold the
 * surface_id deallocate the duplicate right — port-right bookkeeping
 * stays trivially correct at the cost of one descriptor per frame. */
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface_port;
    uint32_t magic;
    uint32_t version;
    int32_t status;
    uint32_t surface_id;
    uint32_t pixel_width;
    uint32_t pixel_height;
} WeaverRendererMachFrameReply;

/* One registered image, uploaded (or removed) ahead of the packets that
 * reference it. pixels_len == 0 (with a null descriptor size) is a
 * removal; the reply is the completion signal, mirroring frames. */
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_ool_descriptor_t pixels;
    uint32_t magic;
    uint32_t version;
    uint32_t struct_size;
    uint32_t pixels_len;
    uint64_t image_id;
    uint32_t width;
    uint32_t height;
} WeaverRendererMachImageUpload;

typedef struct {
    mach_msg_header_t header;
    uint32_t magic;
    uint32_t version;
    uint32_t status;
    uint32_t reserved;
} WeaverRendererMachImageUploadReply;

static inline bool weaverRendererMachImageUploadValid(const WeaverRendererMachImageUpload *upload) {
    if (upload->magic != kWeaverRendererMachMagic ||
        upload->version != kWeaverRendererMachVersion ||
        upload->struct_size != sizeof(WeaverRendererMachImageUpload) ||
        upload->image_id == 0) return false;
    if (upload->pixels_len == 0) {
        /* removal */
        return upload->width == 0 && upload->height == 0 && upload->pixels.size == 0;
    }
    return upload->width > 0 && upload->height > 0 &&
        upload->width <= 4096 && upload->height <= 4096 &&
        upload->pixels_len == upload->width * upload->height * 4 &&
        upload->pixels_len <= kWeaverRendererMachMaxImageBytes &&
        upload->pixels.size == upload->pixels_len;
}

static inline bool weaverRendererMachHelloValid(const WeaverRendererMachHello *hello) {
    return hello->magic == kWeaverRendererMachMagic &&
        hello->version == kWeaverRendererMachVersion &&
        hello->struct_size == sizeof(WeaverRendererMachHello) &&
        hello->widget_pid != 0;
}

static inline bool weaverRendererMachFrameValid(const WeaverRendererMachFrame *frame) {
    return frame->magic == kWeaverRendererMachMagic &&
        frame->version == kWeaverRendererMachVersion &&
        frame->struct_size == sizeof(WeaverRendererMachFrame) &&
        frame->packet_len > 0 &&
        frame->packet_len <= kWeaverRendererMachMaxPacket &&
        frame->packet.size == frame->packet_len &&
        frame->surface_width > 0 && frame->surface_height > 0 &&
        frame->scale > 0 && frame->scale <= 16.0 &&
        frame->surface_width * frame->scale <= 16384.0 &&
        frame->surface_height * frame->scale <= 16384.0;
}
