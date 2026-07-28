const std = @import("std");
const native_sdk = @import("native_sdk");
const native_sdk_options = @import("native_sdk_options");

test "widget profile selects the bounded platform and runtime capacities" {
    if (!native_sdk_options.widget_profile) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 1), native_sdk.platform.max_windows);
    try std.testing.expectEqual(@as(usize, 1), native_sdk.platform.max_views);
    try std.testing.expectEqual(@as(usize, 1), native_sdk.platform.max_webviews);
    // The widget profile bounds the platform shape (one window/view/webview);
    // per-view budgets stay at the stock, measured capacities so widget UI
    // never budgets commands or nodes differently from desktop UI.
    try std.testing.expectEqual(@as(usize, 2048), native_sdk.runtime.max_canvas_commands_per_view);
    try std.testing.expectEqual(@as(usize, 2048), native_sdk.runtime.max_canvas_path_elements_per_view);
    try std.testing.expectEqual(@as(usize, 1024), native_sdk.runtime.max_canvas_widget_nodes_per_view);
    try std.testing.expectEqual(native_sdk.runtime.max_canvas_path_elements_per_view, native_sdk.canvas.max_chart_path_elements_per_frame);
}

test "stock profile remains the default capacity contract" {
    if (native_sdk_options.widget_profile) return error.SkipZigTest;

    try std.testing.expectEqual(@as(usize, 16), native_sdk.platform.max_windows);
    try std.testing.expectEqual(@as(usize, 32), native_sdk.platform.max_views);
    try std.testing.expectEqual(@as(usize, 16), native_sdk.platform.max_webviews);
    try std.testing.expectEqual(@as(usize, 2048), native_sdk.runtime.max_canvas_commands_per_view);
    try std.testing.expectEqual(@as(usize, 2048), native_sdk.runtime.max_canvas_path_elements_per_view);
    try std.testing.expectEqual(@as(usize, 1024), native_sdk.runtime.max_canvas_widget_nodes_per_view);
    try std.testing.expectEqual(native_sdk.runtime.max_canvas_path_elements_per_view, native_sdk.canvas.max_chart_path_elements_per_frame);
}
