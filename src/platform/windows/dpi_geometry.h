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
