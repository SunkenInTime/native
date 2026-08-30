#include "dpi_geometry.h"
#include "renderer_protocol.h"
#include "shared_renderer_policy.h"

#include <array>
#include <cmath>

namespace {

int failures = 0;

void expect(bool condition) {
    if (!condition) ++failures;
}

void expectRect(const WeaverPhysicalRectI &actual, int32_t left, int32_t top,
    int32_t right, int32_t bottom) {
    expect(actual.left == left && actual.top == top && actual.right == right &&
        actual.bottom == bottom);
}

WeaverRendererFrame validFrame() {
    WeaverRendererFrame frame = {};
    frame.magic = kWeaverRendererMagic;
    frame.version = kWeaverRendererVersion;
    frame.struct_size = sizeof(frame);
    frame.widget_pid = 42;
    frame.packet_len = 64;
    frame.logical_surface_width_dip = 240.5;
    frame.logical_surface_height_dip = 110.25;
    frame.device_scale = 1.5;
    frame.destination_x_dip = 10.25;
    frame.destination_y_dip = 20.5;
    frame.destination_width_dip = 240.5;
    frame.destination_height_dip = 110.25;
    const WeaverPhysicalRectI physical = weaverLogicalRectToPhysicalEdges({
        frame.destination_x_dip, frame.destination_y_dip,
        frame.destination_width_dip, frame.destination_height_dip,
    }, frame.device_scale);
    frame.destination_left_px = physical.left;
    frame.destination_top_px = physical.top;
    frame.destination_right_px = physical.right;
    frame.destination_bottom_px = physical.bottom;
    frame.source_texture_width_px = weaverPhysicalWidth(physical);
    frame.source_texture_height_px = weaverPhysicalHeight(physical);
    frame.geometry_generation = 7;
    return frame;
}

} // namespace

extern "C" int native_sdk_dpi_geometry_tests() {
    failures = 0;
    const std::array<double, 5> scales = { 1.0, 1.25, 1.5, 1.75, 2.0 };

    // Width and height are derived from rounded edges. Fractional origins can
    // legitimately change an extent by one pixel, but adjacent edges remain
    // exactly shared and never drift across nesting levels.
    for (double scale : scales) {
        const WeaverPhysicalRectI first = weaverLogicalRectToPhysicalEdges(
            { 10.2, 20.4, 30.3, 40.6 }, scale);
        const WeaverPhysicalRectI second = weaverLogicalRectToPhysicalEdges(
            { 40.5, 20.4, 11.1, 40.6 }, scale);
        expect(first.right == second.left);
        expect(weaverPhysicalWidth(first) ==
            weaverRoundPhysicalEdge(40.5, scale) -
            weaverRoundPhysicalEdge(10.2, scale));
        expect(weaverPhysicalHeight(first) ==
            weaverRoundPhysicalEdge(61.0, scale) -
            weaverRoundPhysicalEdge(20.4, scale));
    }

    // Nested origins accumulate in DIPs before the one edge conversion.
    const double nested_x = 10.4 + 10.4;
    const WeaverPhysicalRectI nested = weaverLogicalRectToPhysicalEdges(
        { nested_x, 5.25 + 2.5, 10.2, 7.75 }, 1.5);
    expectRect(nested, 31, 12, 47, 23);
    expect(weaverRoundPhysicalEdge(10.4, 1.5) * 2 == 32);
    expect(nested.left == 31);

    // Negative virtual-desktop work areas retain their physical origin. Only
    // logical sizes and inward offsets scale.
    const WeaverPhysicalRectI left_monitor = { -1920, -120, 0, 960 };
    expectRect(weaverAnchoredPhysicalRect(left_monitor, 240, 110, 24, 24,
        1.25, WeaverAnchorCorner::TopLeft), -1890, -90, -1590, 48);
    expectRect(weaverAnchoredPhysicalRect(left_monitor, 240, 110, 24, 24,
        1.25, WeaverAnchorCorner::TopRight), -330, -90, -30, 48);
    expectRect(weaverAnchoredPhysicalRect(left_monitor, 240, 110, 24, 24,
        1.25, WeaverAnchorCorner::BottomLeft), -1890, 792, -1590, 930);
    expectRect(weaverAnchoredPhysicalRect(left_monitor, 240, 110, 24, 24,
        1.25, WeaverAnchorCorner::BottomRight), -330, 792, -30, 930);

    // Input converts client pixels back to DIPs exactly once at the current
    // window scale, including the clickable last physical pixel.
    for (double scale : scales) {
        expect(std::abs(weaverPhysicalToLogicalCoordinate(
            weaverRoundPhysicalEdge(100, scale), scale) - 100.0) < 0.000001);
        const int32_t rightmost = weaverRoundPhysicalEdge(240, scale) - 1;
        const double logical = weaverPhysicalToLogicalCoordinate(rightmost, scale);
        expect(logical >= 239.0 && logical < 240.0);
    }

    // Dirty rectangles floor their leading edges, ceil their trailing edges,
    // and clamp once to the exact destination texture.
    WeaverPhysicalBoxU dirty = weaverLogicalDirtyRectToPhysicalBox(
        { 0.25, 1.1, 10.2, 4.05 }, 1.5, 16, 8);
    expect(dirty.left == 0 && dirty.top == 1 && dirty.right == 16 && dirty.bottom == 8);
    dirty = weaverLogicalDirtyRectToPhysicalBox(
        { -3.0, -2.0, 4.0, 3.0 }, 1.25, 100, 100);
    expect(dirty.left == 0 && dirty.top == 0 && dirty.right == 2 && dirty.bottom == 2);

    // Geometry generations wrap away from zero; extent decisions do not
    // recreate for a pure move and do recreate for a changed edge extent.
    expect(weaverNextGeometryGeneration(0) == 1);
    expect(weaverNextGeometryGeneration(UINT64_MAX) == 1);
    expect(!weaverSurfaceExtentChanged(300, 138, 300, 138));
    expect(weaverSurfaceExtentChanged(300, 138, 301, 138));

    // Protocol v4 names and validates both geometries plus retained ordering.
    // Retained dimensions
    // must agree with the exact shared texture, and version skew is rejected
    // at the pre-frame handshake.
    WeaverRendererFrame frame = validFrame();
    expect(weaverRendererFrameValid(frame));
    frame.version = kWeaverRendererVersion - 1;
    expect(!weaverRendererFrameValid(frame));
    frame = validFrame();
    frame.source_texture_width_px += 1;
    expect(!weaverRendererFrameValid(frame));
    frame = validFrame();
    frame.retained_generation = 9;
    frame.retained_width = frame.source_texture_width_px;
    frame.retained_height = frame.source_texture_height_px;
    frame.retained_section_name_len = 4;
    expect(weaverRendererFrameValid(frame));
    frame.retained_above_packet = 2;
    expect(!weaverRendererFrameValid(frame));
    frame.retained_above_packet = 1;
    expect(weaverRendererFrameValid(frame));
    frame.retained_width -= 1;
    expect(!weaverRendererFrameValid(frame));

    WeaverRendererHello hello = {
        kWeaverRendererMagic, kWeaverRendererVersion,
        sizeof(WeaverRendererHello), 42,
    };
    expect(weaverRendererHelloValid(hello));
    hello.version -= 1;
    expect(!weaverRendererHelloValid(hello));

    // GPU bootstrap gets one process-start allowance. After a renderer crash,
    // probes stay short and a presented software fallback retains a slow
    // recovery pump until the shared pipe reconnects.
    expect(weaverSharedRendererConnectTimeoutMs(false) == 2000);
    expect(weaverSharedRendererConnectTimeoutMs(true) == 100);
    expect(!weaverSharedRendererRecoveryPumpNeeded(false, false, true));
    expect(!weaverSharedRendererRecoveryPumpNeeded(true, false, false));
    expect(!weaverSharedRendererRecoveryPumpNeeded(true, true, true));
    expect(weaverSharedRendererRecoveryPumpNeeded(true, false, true));

    // Software pixels, retained pixels, and shared GPU textures all consume
    // this same physical edge extent; no path re-derives it from width alone.
    const WeaverPhysicalRectI parity = weaverLogicalRectToPhysicalEdges(
        { 10.2, 4.4, 240.5, 110.25 }, 1.75);
    const uint32_t parity_width = weaverPhysicalWidth(parity);
    const uint32_t parity_height = weaverPhysicalHeight(parity);
    expect(weaverValidSurfaceExtent(parity_width, parity_height));
    frame = validFrame();
    frame.destination_x_dip = 10.2;
    frame.destination_y_dip = 4.4;
    frame.destination_width_dip = 240.5;
    frame.destination_height_dip = 110.25;
    frame.device_scale = 1.75;
    frame.destination_left_px = parity.left;
    frame.destination_top_px = parity.top;
    frame.destination_right_px = parity.right;
    frame.destination_bottom_px = parity.bottom;
    frame.source_texture_width_px = parity_width;
    frame.source_texture_height_px = parity_height;
    expect(weaverRendererFrameValid(frame));

    return failures;
}
