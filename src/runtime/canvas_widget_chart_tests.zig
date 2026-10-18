//! Runtime-side chart widget tests: retained-tree copies own their
//! series bytes, budgets fail loudly, data changes repaint, and chart
//! semantics (role + series summary + latest value) reach the automation
//! snapshot.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const automation = support.automation;
const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;
const testViewByLabel = support.testViewByLabel;
const canvas_limits = @import("canvas_limits.zig");

test "the chart path scratch mirrors the per-view path element budget" {
    // widget_render's frame scratch cannot import the runtime's
    // canvas_limits, so its bound is a mirrored constant; if they drift,
    // chart emission either wastes address space or fails before the
    // per-view budget would.
    try std.testing.expectEqual(canvas_limits.max_canvas_path_elements_per_view, canvas.max_chart_path_elements_per_frame);
}

const ChartApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "gpu-widget-chart", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
    }
};

fn startChartHarness(app_state: *ChartApp) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 320, 240),
    });
    return harness;
}

test "retained chart series own their bytes and reach automation semantics" {
    const harness = try startChartHarness(&chart_app_state);
    defer harness.destroy(std.testing.allocator);

    var values = [_]f32{ 0.2, 0.4, 0.8 };
    var label_bytes = "cpu load".*;
    const series = [_]canvas.ChartSeries{.{
        .kind = .line,
        .values = &values,
        .color = .accent,
        .label = &label_bytes,
    }};
    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .chart,
        .frame = geometry.RectF.init(10, 10, 200, 60),
        .chart = .{ .series = &series, .y_min = 0, .y_max = 1 },
        .semantics = .{ .label = "cpu history" },
    }};
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Clobber the app-side buffers: the retained tree must not notice
    // (same ownership rule as text and context-menu labels).
    values = .{ 9, 9, 9 };
    label_bytes = "!!!!!!!!".*;

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const widget = retained.findById(2).?.widget;
    try std.testing.expectEqual(@as(usize, 1), widget.chart.series.len);
    try std.testing.expectEqualSlices(f32, &.{ 0.2, 0.4, 0.8 }, widget.chart.series[0].values);
    try std.testing.expectEqualStrings("cpu load", widget.chart.series[0].label);

    // Semantics: chart role, the app label, and the latest datapoint as
    // the value automation asserts on.
    const snapshot = harness.runtime.automationSnapshot("Charts");
    _ = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expectEqualStrings("chart", snapshot.widgets[0].role);
    try std.testing.expectEqualStrings("cpu history", snapshot.widgets[0].name);
    try std.testing.expectEqual(@as(?f32, 0.8), snapshot.widgets[0].value);
}

var chart_app_state: ChartApp = .{};

test "chart data changes mark the widget dirty and repaint" {
    const harness = try startChartHarness(&chart_app_state);
    defer harness.destroy(std.testing.allocator);

    var values = [_]f32{ 0.2, 0.4, 0.8 };
    const series = [_]canvas.ChartSeries{.{ .kind = .bar, .values = &values }};
    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .chart,
        .frame = geometry.RectF.init(10, 10, 200, 60),
        .chart = .{ .series = &series },
    }};
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // Same content again: no invalidation (chart equality is by value).
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    var nodes_again: [4]canvas.WidgetLayoutNode = undefined;
    const same = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes_again);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", same);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);

    // A new sample repaints.
    harness.runtime.invalidated = false;
    values[2] = 0.9;
    var nodes_changed: [4]canvas.WidgetLayoutNode = undefined;
    const changed = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes_changed);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", changed);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len > 0);
}

test "chart hover details: pointer snaps to a sample, floats the card, and repaints only across samples" {
    const harness = try startChartHarness(&chart_app_state);
    defer harness.destroy(std.testing.allocator);
    const app = chart_app_state.app();

    const values = [_]f32{ 0.2, 0.4, 0.8, 0.6 };
    const labels = [_][]const u8{ "q1", "q2", "q3", "q4" };
    const series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &values, .label = "cpu" }};
    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .chart,
        .frame = geometry.RectF.init(10, 10, 200, 60),
        .chart = .{
            .series = &series,
            .y_min = 0,
            .y_max = 1,
            .x_labels = &labels,
            .hover_details = true,
        },
        .semantics = .{ .label = "cpu history" },
    }};
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    // The retained copy owns the label bytes too (same rule as series
    // labels): the runtime reads "q1".."q4" from its own storage.
    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings("q3", retained.findById(2).?.widget.chart.x_labels[2]);

    // Cold: no hover, no card (the card's shadow is the tell). The emit
    // call takes display-list ownership, so hover refreshes re-emit.
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
    var display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        try std.testing.expect(std.meta.activeTag(command) != .shadow);
    }

    // Hover mid-plot: a 4-sample lattice snaps x=110 (fraction 0.5) to
    // sample 2 — the chart reads as hovered in the snapshot (the
    // accessible summary stays untouched), and the display list gains
    // the cursor, the dot, and the card with title + series row.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 110, .y = 40 } });
    const snapshot = harness.runtime.automationSnapshot("ChartHover");
    _ = testViewByLabel(snapshot.views, "canvas").?;
    try std.testing.expectEqual(@as(usize, 1), snapshot.widgets.len);
    try std.testing.expect(snapshot.widgets[0].hovered);
    try std.testing.expectEqualStrings("cpu history", snapshot.widgets[0].name);
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    var title_count: usize = 0;
    var saw_row = false;
    var saw_shadow = false;
    for (display_list.commands) |command| {
        switch (command) {
            .draw_text => |text| {
                if (std.mem.eql(u8, text.text, "q3")) title_count += 1;
                if (std.mem.eql(u8, text.text, "cpu")) saw_row = true;
            },
            .shadow => saw_shadow = true,
            else => {},
        }
    }
    // "q3" draws once as an axis label and once as the card title.
    try std.testing.expectEqual(@as(usize, 2), title_count);
    try std.testing.expect(saw_row);
    try std.testing.expect(saw_shadow);

    // Gliding within the same sample repaints nothing; crossing into
    // the next sample invalidates.
    harness.runtime.invalidated = false;
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 112, .y = 42 } });
    try std.testing.expect(!harness.runtime.invalidated);
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 190, .y = 40 } });
    try std.testing.expect(harness.runtime.invalidated);

    // Leaving the chart clears the hover chrome.
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_move, .x = 300, .y = 220 } });
    display_list = try harness.runtime.canvasDisplayList(1, "canvas");
    for (display_list.commands) |command| {
        try std.testing.expect(std.meta.activeTag(command) != .shadow);
    }
    const cleared = harness.runtime.automationSnapshot("ChartHoverCleared");
    try std.testing.expect(!cleared.widgets[0].hovered);
}

test "chart budgets fail loudly by name" {
    const harness = try startChartHarness(&chart_app_state);
    defer harness.destroy(std.testing.allocator);

    // One series past the per-view series budget.
    const flat = [_]f32{ 0, 1 };
    var too_many_series: [canvas_limits.max_canvas_widget_chart_series_per_view + 1]canvas.ChartSeries = undefined;
    for (&too_many_series) |*entry| entry.* = .{ .kind = .line, .values = &flat };
    const series_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .chart,
        .frame = geometry.RectF.init(10, 10, 200, 60),
        .chart = .{ .series = &too_many_series },
    }};
    var series_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const series_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &series_children }, geometry.RectF.init(0, 0, 320, 240), &series_nodes);
    try std.testing.expectError(
        error.WidgetChartSeriesLimitReached,
        harness.runtime.setCanvasWidgetLayout(1, "canvas", series_layout),
    );

    // One point past the per-view points pool. `Ui.chart` downsampling
    // keeps sanctioned series at 256 points, so this needs 64 maximal
    // series plus one extra point.
    var big: [canvas_limits.max_canvas_widget_chart_points_per_view + 1]f32 = undefined;
    @memset(&big, 0.5);
    const big_series = [_]canvas.ChartSeries{.{ .kind = .line, .values = &big }};
    const point_children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .chart,
        .frame = geometry.RectF.init(10, 10, 200, 60),
        .chart = .{ .series = &big_series },
    }};
    var point_nodes: [4]canvas.WidgetLayoutNode = undefined;
    const point_layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &point_children }, geometry.RectF.init(0, 0, 320, 240), &point_nodes);
    try std.testing.expectError(
        error.WidgetChartPointsLimitReached,
        harness.runtime.setCanvasWidgetLayout(1, "canvas", point_layout),
    );
}

test "a display-list refresh nested inside another fails loudly instead of sharing its scratch" {
    // Every view's refresh shares one Runtime scratch. A refresh started
    // while another is mid-flight (say, from a text-measurement callback)
    // would overwrite the outer one's commands, so it must fail by name.
    const harness = try startChartHarness(&chart_app_state);
    defer harness.destroy(std.testing.allocator);
    var values = [_]f32{ 0.2, 0.4, 0.8 };
    const series = [_]canvas.ChartSeries{.{ .kind = .bar, .values = &values }};
    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .chart,
        .frame = geometry.RectF.init(10, 10, 200, 60),
        .chart = .{ .series = &series },
    }};
    var nodes: [4]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 320, 240), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);

    harness.runtime.display_list_refresh_active = true;
    try std.testing.expectError(error.DisplayListRefreshReentered, harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas"));
    harness.runtime.display_list_refresh_active = false;
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
    try std.testing.expect(!harness.runtime.display_list_refresh_active);
}
