#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>

// Windows DPI geometry has one deliberately small vocabulary. Runtime and
// protocol geometry is expressed in DIPs. OS rectangles and texture extents
// are physical pixels. Every physical rectangle is derived by rounding its
// logical edges once; widths and heights are always edge differences.

struct WeaverLogicalRectD {
    double x;
    double y;
    double width;
    double height;
};

struct WeaverPhysicalRectI {
    int32_t left;
    int32_t top;
    int32_t right;
    int32_t bottom;
};

struct WeaverPhysicalBoxU {
    uint32_t left;
    uint32_t top;
    uint32_t right;
    uint32_t bottom;
};

static constexpr uint32_t kWeaverMaximumSurfaceExtentPx = 16 * 1024;
static constexpr double kWeaverMinimumDeviceScale = 0.5;
static constexpr double kWeaverMaximumDeviceScale = 8.0;

inline bool weaverFinite(double value) {
    return std::isfinite(value);
}

inline bool weaverValidDeviceScale(double scale) {
    return weaverFinite(scale) && scale >= kWeaverMinimumDeviceScale &&
        scale <= kWeaverMaximumDeviceScale;
}

inline bool weaverValidLogicalRect(const WeaverLogicalRectD &rect,
    bool allow_negative_origin = true) {
    return weaverFinite(rect.x) && weaverFinite(rect.y) &&
        weaverFinite(rect.width) && weaverFinite(rect.height) &&
        rect.width > 0 && rect.height > 0 &&
        (allow_negative_origin || (rect.x >= 0 && rect.y >= 0));
}

inline int32_t weaverRoundPhysicalEdge(double logical_edge, double scale) {
    const double physical_edge = logical_edge * scale;
    if (!weaverFinite(physical_edge)) return 0;
    const double bounded = std::max<double>(std::numeric_limits<int32_t>::min(),
        std::min<double>(std::numeric_limits<int32_t>::max(), physical_edge));
    return static_cast<int32_t>(std::round(bounded));
}

inline WeaverPhysicalRectI weaverLogicalRectToPhysicalEdges(
    const WeaverLogicalRectD &rect, double scale) {
    return {
        weaverRoundPhysicalEdge(rect.x, scale),
        weaverRoundPhysicalEdge(rect.y, scale),
        weaverRoundPhysicalEdge(rect.x + rect.width, scale),
        weaverRoundPhysicalEdge(rect.y + rect.height, scale),
    };
}

inline int32_t weaverPhysicalWidth(const WeaverPhysicalRectI &rect) {
    return rect.right - rect.left;
}

inline int32_t weaverPhysicalHeight(const WeaverPhysicalRectI &rect) {
    return rect.bottom - rect.top;
}

inline bool weaverValidPhysicalRect(const WeaverPhysicalRectI &rect) {
    return rect.right > rect.left && rect.bottom > rect.top;
}

inline bool weaverValidSurfaceExtent(uint32_t width_px, uint32_t height_px) {
    return width_px > 0 && height_px > 0 &&
        width_px <= kWeaverMaximumSurfaceExtentPx &&
        height_px <= kWeaverMaximumSurfaceExtentPx;
}

inline bool weaverPhysicalRectsEqual(const WeaverPhysicalRectI &a,
    const WeaverPhysicalRectI &b) {
    return a.left == b.left && a.top == b.top && a.right == b.right &&
        a.bottom == b.bottom;
}

inline bool weaverLogicalRectsEqual(const WeaverLogicalRectD &a,
    const WeaverLogicalRectD &b) {
    return a.x == b.x && a.y == b.y && a.width == b.width &&
        a.height == b.height;
}

inline double weaverPhysicalToLogicalCoordinate(int32_t coordinate_px,
    double scale) {
    return weaverValidDeviceScale(scale) ? static_cast<double>(coordinate_px) / scale : 0;
}

// Dirty rectangles stay logical until upload. At that boundary their start
// edges floor, end edges ceil, and all four edges clamp to the texture.
inline WeaverPhysicalBoxU weaverLogicalDirtyRectToPhysicalBox(
    const WeaverLogicalRectD &dirty, double scale, uint32_t texture_width_px,
    uint32_t texture_height_px) {
    if (!weaverValidDeviceScale(scale) || !weaverValidLogicalRect(dirty) ||
        !weaverValidSurfaceExtent(texture_width_px, texture_height_px)) return {};
    const double left_value = std::floor(dirty.x * scale);
    const double top_value = std::floor(dirty.y * scale);
    const double right_value = std::ceil((dirty.x + dirty.width) * scale);
    const double bottom_value = std::ceil((dirty.y + dirty.height) * scale);
    const auto clamp_edge = [](double value, uint32_t extent) -> uint32_t {
        if (!weaverFinite(value) || value <= 0) return 0;
        if (value >= extent) return extent;
        return static_cast<uint32_t>(value);
    };
    WeaverPhysicalBoxU result = {
        clamp_edge(left_value, texture_width_px),
        clamp_edge(top_value, texture_height_px),
        clamp_edge(right_value, texture_width_px),
        clamp_edge(bottom_value, texture_height_px),
    };
    if (result.right < result.left) result.right = result.left;
    if (result.bottom < result.top) result.bottom = result.top;
    return result;
}

inline bool weaverPhysicalBoxEmpty(const WeaverPhysicalBoxU &box) {
    return box.right <= box.left || box.bottom <= box.top;
}

inline bool weaverSurfaceExtentChanged(uint32_t current_width_px,
    uint32_t current_height_px, uint32_t next_width_px, uint32_t next_height_px) {
    return current_width_px != next_width_px || current_height_px != next_height_px;
}

inline uint64_t weaverNextGeometryGeneration(uint64_t current) {
    return current == std::numeric_limits<uint64_t>::max() ? 1 : current + 1;
}

// Anchor offsets and logical content extents are DIPs, while a monitor work
// area is a physical virtual-desktop rectangle. The physical origin is never
// scaled; only distances inward from its edges are.
enum class WeaverAnchorCorner : uint32_t {
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
};

inline WeaverPhysicalRectI weaverAnchoredPhysicalRect(
    const WeaverPhysicalRectI &work_area_px, double logical_width_dip,
    double logical_height_dip, double offset_x_dip, double offset_y_dip,
    double scale, WeaverAnchorCorner corner) {
    if (!weaverValidPhysicalRect(work_area_px) ||
        !weaverValidLogicalRect({ 0, 0, logical_width_dip, logical_height_dip }) ||
        !weaverFinite(offset_x_dip) || !weaverFinite(offset_y_dip) ||
        offset_x_dip < 0 || offset_y_dip < 0 || !weaverValidDeviceScale(scale)) return {};
    const int32_t width_px = weaverRoundPhysicalEdge(logical_width_dip, scale);
    const int32_t height_px = weaverRoundPhysicalEdge(logical_height_dip, scale);
    const int32_t offset_x_px = weaverRoundPhysicalEdge(offset_x_dip, scale);
    const int32_t offset_y_px = weaverRoundPhysicalEdge(offset_y_dip, scale);
    const bool right = corner == WeaverAnchorCorner::TopRight ||
        corner == WeaverAnchorCorner::BottomRight;
    const bool bottom = corner == WeaverAnchorCorner::BottomLeft ||
        corner == WeaverAnchorCorner::BottomRight;
    const int32_t left = right ? work_area_px.right - offset_x_px - width_px
                               : work_area_px.left + offset_x_px;
    const int32_t top = bottom ? work_area_px.bottom - offset_y_px - height_px
                               : work_area_px.top + offset_y_px;
    return { left, top, left + width_px, top + height_px };
}

// User resizing of a content-scaling window (ADR 0023): the content keeps
// its logical size and the window's physical size is that size times the
// device scale times one zoom. Edges use the WMSZ_* numbering, so the
// host passes its sizing codes straight through.
enum WeaverSizingEdge : int {
    kWeaverSizeLeft = 1,
    kWeaverSizeRight = 2,
    kWeaverSizeTop = 3,
    kWeaverSizeTopLeft = 4,
    kWeaverSizeTopRight = 5,
    kWeaverSizeBottom = 6,
    kWeaverSizeBottomLeft = 7,
    kWeaverSizeBottomRight = 8,
};

inline bool weaverSizingEdgeHasLeft(int edge) {
    return edge == kWeaverSizeLeft || edge == kWeaverSizeTopLeft || edge == kWeaverSizeBottomLeft;
}

inline bool weaverSizingEdgeHasRight(int edge) {
    return edge == kWeaverSizeRight || edge == kWeaverSizeTopRight || edge == kWeaverSizeBottomRight;
}

inline bool weaverSizingEdgeHasTop(int edge) {
    return edge == kWeaverSizeTop || edge == kWeaverSizeTopLeft || edge == kWeaverSizeTopRight;
}

inline bool weaverSizingEdgeHasBottom(int edge) {
    return edge == kWeaverSizeBottom || edge == kWeaverSizeBottomLeft || edge == kWeaverSizeBottomRight;
}

// The device scale for the content of a zoomed window. The scale crosses
// the runtime as an f32 and comes back with every frame, which must match
// it exactly (a frame drawn at another scale is dropped); DPI scales are
// exact in f32, an arbitrary zoom is not, so the product is one f32 carries.
inline double weaverContentScale(double dpi_scale, double zoom) {
    return static_cast<double>(static_cast<float>(dpi_scale * zoom));
}

struct WeaverContentZoomFrame {
    double logical_width;
    double logical_height;
    double dpi_scale;
    // The non-client frame around the client area (0 for a popup).
    int32_t chrome_width;
    int32_t chrome_height;
    double min_zoom;
    double max_zoom;
};

inline int32_t weaverContentZoomOuterWidth(const WeaverContentZoomFrame &frame, double zoom) {
    return weaverRoundPhysicalEdge(frame.logical_width, frame.dpi_scale * zoom) + frame.chrome_width;
}

inline int32_t weaverContentZoomOuterHeight(const WeaverContentZoomFrame &frame, double zoom) {
    return weaverRoundPhysicalEdge(frame.logical_height, frame.dpi_scale * zoom) + frame.chrome_height;
}

// The grabbed edges of the gesture's starting rect, moved by the cursor's
// travel since the press.
inline WeaverPhysicalRectI weaverDraggedSizingRect(WeaverPhysicalRectI start,
    int edge, int32_t dx, int32_t dy) {
    if (weaverSizingEdgeHasLeft(edge)) start.left += dx;
    if (weaverSizingEdgeHasRight(edge)) start.right += dx;
    if (weaverSizingEdgeHasTop(edge)) start.top += dy;
    if (weaverSizingEdgeHasBottom(edge)) start.bottom += dy;
    return start;
}

// The zoom a width and height ask for: the one axis an edge drags, or for a
// corner (edge 0: any other path) the size's projection onto the content's
// aspect diagonal - the zoom whose rect is nearest to it. The projection is
// continuous in the cursor, so a diagonal drag off the aspect grows smoothly;
// picking whichever axis moved further from the zoom of the previous step
// flipped between the axes on alternate steps and made the widget jitter.
// Clamped to the range.
inline double weaverAskedContentZoom(const WeaverContentZoomFrame &frame,
    int32_t outer_width, int32_t outer_height, int edge, double current_zoom) {
    const double unit_width = frame.logical_width * frame.dpi_scale;
    const double unit_height = frame.logical_height * frame.dpi_scale;
    if (!(unit_width > 0) || !(unit_height > 0)) return current_zoom;
    const double content_width = (double)(outer_width - frame.chrome_width);
    const double content_height = (double)(outer_height - frame.chrome_height);
    double zoom = content_width / unit_width;
    if (edge == kWeaverSizeTop || edge == kWeaverSizeBottom) {
        zoom = content_height / unit_height;
    } else if (edge != kWeaverSizeLeft && edge != kWeaverSizeRight) {
        zoom = (content_width * unit_width + content_height * unit_height) /
            (unit_width * unit_width + unit_height * unit_height);
    }
    if (!weaverFinite(zoom)) return current_zoom;
    return std::clamp(zoom, frame.min_zoom, frame.max_zoom);
}

// A sizing rect snapped to the zoom it asks for, aspect locked; the edges
// opposite the grabbed ones stay put.
inline WeaverPhysicalRectI weaverConstrainContentZoomSizing(
    const WeaverContentZoomFrame &frame, WeaverPhysicalRectI rect, int edge,
    double current_zoom) {
    const double zoom = weaverAskedContentZoom(frame, rect.right - rect.left,
        rect.bottom - rect.top, edge, current_zoom);
    const int32_t width = weaverContentZoomOuterWidth(frame, zoom);
    const int32_t height = weaverContentZoomOuterHeight(frame, zoom);
    if (weaverSizingEdgeHasLeft(edge)) {
        rect.left = rect.right - width;
    } else {
        rect.right = rect.left + width;
    }
    if (weaverSizingEdgeHasTop(edge)) {
        rect.top = rect.bottom - height;
    } else {
        rect.bottom = rect.top + height;
    }
    return rect;
}

// Any other path to a new size (Windows snapping, SetWindowPos from a
// tool): a size already within a pixel of the aspect and inside the range
// passes untouched, so a gesture's anchored edges never jitter; anything
// else becomes the nearest size that fits. Returns whether it changed.
inline bool weaverConstrainContentZoomSize(const WeaverContentZoomFrame &frame,
    double current_zoom, int32_t *width, int32_t *height) {
    const double unit_width = frame.logical_width * frame.dpi_scale;
    const double unit_height = frame.logical_height * frame.dpi_scale;
    if (!(unit_width > 0) || !(unit_height > 0)) return false;
    const double zoom_x = (double)(*width - frame.chrome_width) / unit_width;
    const double zoom_y = (double)(*height - frame.chrome_height) / unit_height;
    const double tolerance = 1e-3;
    const bool in_range = std::min(zoom_x, zoom_y) >= frame.min_zoom - tolerance &&
        std::max(zoom_x, zoom_y) <= frame.max_zoom + tolerance;
    const bool in_aspect = std::fabs((double)(*height - frame.chrome_height) - unit_height * zoom_x) <= 1.0;
    if (in_range && in_aspect) return false;
    const double zoom = weaverAskedContentZoom(frame, *width, *height, 0, current_zoom);
    *width = weaverContentZoomOuterWidth(frame, zoom);
    *height = weaverContentZoomOuterHeight(frame, zoom);
    return true;
}
