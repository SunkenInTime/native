//! A view's grown storage can fail to allocate. Each test here injects that
//! failure (`grown_array.testing_faults`) at every allocation a step makes,
//! lets memory recover, and checks that the view's state still agrees with
//! itself and with the platform: nothing is half published.
const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;
const grown_array = @import("grown_array.zig");
const canvas_limits = @import("canvas_limits.zig");

const faults = grown_array.testing_faults;

/// More injection points than any step below allocates, so every one is hit.
const max_failure_points = 12;

const TestApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "view-storage-oom", .source = platform.WebViewSource.html("<h1>OOM</h1>") };
    }
};

fn startCanvasHarness(app_state: *TestApp, size: geometry.SizeF) !*TestHarness() {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, size.width, size.height) });
    return harness;
}

/// Run `step` with the allocation after `before_failure` successful ones
/// failing; OutOfMemory is the only error it may return.
fn failAfter(before_failure: usize, step: anytype, args: anytype) !void {
    faults.allocations_before_failure = before_failure;
    defer faults.allocations_before_failure = null;
    _ = @call(.auto, step, args) catch |err| switch (err) {
        error.OutOfMemory => {},
        else => return err,
    };
}

test "a spinner whose animation bookkeeping fails to allocate leaves no loop running after it unmounts" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 120));
        defer harness.destroy(std.testing.allocator);
        const spinner = canvas.Widget{ .id = 5, .kind = .spinner, .frame = geometry.RectF.init(20, 20, 20, 20) };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{spinner} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        try failAfter(before_failure, @TypeOf(harness.runtime).emitCanvasWidgetDisplayList, .{ &harness.runtime, 1, "canvas", canvas.DesignTokens{} });

        var empty_nodes: [1]canvas.WidgetLayoutNode = undefined;
        const empty = try canvas.layoutWidgetTree(.{ .kind = .stack }, geometry.RectF.init(0, 0, 240, 120), &empty_nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty);
        _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
        const view = harness.runtime.views[0];
        std.testing.expectEqual(@as(usize, 0), view.canvas_render_animations.len) catch |err| {
            std.debug.print("allocation {d} failed: {d} animations survive the unmount, {d} tracked\n", .{ before_failure, view.canvas_render_animations.len, view.canvas_widget_loop_animation_ids.len });
            return err;
        };
    }
}

test "a caret blink whose bookkeeping fails to allocate leaves no animation after blur" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 120));
        defer harness.destroy(std.testing.allocator);
        const text_field = canvas.Widget{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(12, 16, 160, 36), .placeholder = "Search" };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
        try failAfter(before_failure, @TypeOf(harness.runtime).dispatchPlatformEvent, .{ &harness.runtime, app_state.app(), platform.Event{ .gpu_surface_input = .{
            .window_id = 1,
            .label = "canvas",
            .kind = .pointer_down,
            .timestamp_ns = 1_000_000_000,
            .x = 90,
            .y = 34,
        } } });

        const view = harness.runtime.views[0];
        view.focused = false;
        _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
        std.testing.expectEqual(@as(usize, 0), view.canvas_render_animations.len) catch |err| {
            std.debug.print("allocation {d} failed: {d} animations survive the blur\n", .{ before_failure, view.canvas_render_animations.len });
            return err;
        };
    }
}

test "drag regions whose mirror fails to grow are never pushed, so a revert stays in step with the platform" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 240));
        defer harness.destroy(std.testing.allocator);
        var rows: [5]canvas.Widget = undefined;
        for (&rows, 0..) |*row, index| row.* = .{ .id = @intCast(index + 10), .kind = .row, .frame = geometry.RectF.init(0, @floatFromInt(index * 40), 240, 30), .window_drag = true };
        var old_nodes: [2]canvas.WidgetLayoutNode = undefined;
        const old = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = rows[0..1] }, geometry.RectF.init(0, 0, 240, 240), &old_nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", old);
        var new_nodes: [6]canvas.WidgetLayoutNode = undefined;
        const next = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &rows }, geometry.RectF.init(0, 0, 240, 240), &new_nodes);
        try failAfter(before_failure, @TypeOf(harness.runtime).setCanvasWidgetLayout, .{ &harness.runtime, 1, "canvas", next });

        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", old);
        const view = harness.runtime.views[0];
        std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_region_count) catch |err| {
            std.debug.print("allocation {d} failed: platform holds {d} regions after the revert, mirror {d}\n", .{ before_failure, harness.null_platform.window_drag_region_count, view.canvas_widget_drag_regions.len });
            return err;
        };
        try std.testing.expectEqual(@as(usize, 1), view.canvas_widget_drag_regions.len);
    }
}

test "a frame whose recording fails to allocate is not marked presented" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(40, 20));
        defer harness.destroy(std.testing.allocator);
        const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) } } }};
        _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
        const overrides = [_]canvas.CanvasRenderOverride{.{ .id = 1, .opacity = 0.5 }};
        var output: [8]canvas.CanvasGpuCommand = undefined;
        var packet_bytes: [4096]u8 = undefined;
        faults.allocations_before_failure = before_failure;
        const first = harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{ .frame_index = 1, .render_overrides = &overrides }, harness.runtime.canvasFrameScratchStorage(), canvas.Color.rgb8(0, 0, 0), &output, &packet_bytes);
        faults.allocations_before_failure = null;
        if (first) |_| continue else |err| try std.testing.expectEqual(error.OutOfMemory, err);

        // The failed frame never reached the platform, so the next one must.
        const retry = try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{ .frame_index = 2 }, harness.runtime.canvasFrameScratchStorage(), canvas.Color.rgb8(0, 0, 0), &output, &packet_bytes);
        std.testing.expect(retry.requiresRender()) catch |err| {
            std.debug.print("allocation {d} failed: the retry renders nothing, {d} presents\n", .{ before_failure, harness.null_platform.gpu_surface_packet_present_count });
            return err;
        };
        try std.testing.expectEqual(@as(usize, 1), harness.null_platform.gpu_surface_packet_present_count);
    }
}

/// Install `old`, fail somewhere in installing `next`, then reinstall `old`:
/// the retained widget `id` must read what `old` declares.
fn expectSourceRevertWins(old_layout: canvas.WidgetLayoutTree, next_layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, check: *const fn (canvas.Widget) bool) !void {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 240));
        defer harness.destroy(std.testing.allocator);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", old_layout);
        try failAfter(before_failure, @TypeOf(harness.runtime).setCanvasWidgetLayout, .{ &harness.runtime, 1, "canvas", next_layout });
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", old_layout);
        const retained = harness.runtime.views[0].widgetLayoutTree().findById(id).?.widget;
        if (!check(retained)) {
            std.debug.print("allocation {d} failed: retained widget {d} keeps value {d} text \"{s}\" after the revert\n", .{ before_failure, id, retained.value, retained.text });
            return error.TestUnexpectedResult;
        }
    }
}

test "a control's source mirror that fails to allocate does not let the failed value outlive a revert" {
    const old_slider = canvas.Widget{ .id = 10, .kind = .slider, .frame = geometry.RectF.init(0, 0, 240, 30), .value = 0.2 };
    var old_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const old = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{old_slider} }, geometry.RectF.init(0, 0, 240, 240), &old_nodes);
    var sliders: [5]canvas.Widget = undefined;
    for (&sliders, 0..) |*slider, index| slider.* = .{ .id = @intCast(index + 10), .kind = .slider, .frame = geometry.RectF.init(0, @floatFromInt(index * 40), 240, 30), .value = 0.8 };
    var new_nodes: [6]canvas.WidgetLayoutNode = undefined;
    const next = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &sliders }, geometry.RectF.init(0, 0, 240, 240), &new_nodes);
    try expectSourceRevertWins(old, next, 10, struct {
        fn check(widget: canvas.Widget) bool {
            return widget.value == 0.2;
        }
    }.check);
}

test "a text field's source mirror that fails to allocate does not let the failed text outlive a revert" {
    const old_input = canvas.Widget{ .id = 10, .kind = .input, .frame = geometry.RectF.init(0, 0, 240, 30), .text = "before" };
    var old_nodes: [2]canvas.WidgetLayoutNode = undefined;
    const old = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{old_input} }, geometry.RectF.init(0, 0, 240, 240), &old_nodes);
    var inputs: [5]canvas.Widget = undefined;
    for (&inputs, 0..) |*input, index| input.* = .{ .id = @intCast(index + 10), .kind = .input, .frame = geometry.RectF.init(0, @floatFromInt(index * 40), 240, 30), .text = "failed" };
    var new_nodes: [6]canvas.WidgetLayoutNode = undefined;
    const next = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &inputs }, geometry.RectF.init(0, 0, 240, 240), &new_nodes);
    try expectSourceRevertWins(old, next, 10, struct {
        fn check(widget: canvas.Widget) bool {
            return std.mem.eql(u8, widget.text, "before");
        }
    }.check);
}

test "a scroll view's source mirror that fails to allocate does not let the failed offset outlive a revert" {
    const content = canvas.Widget{ .kind = .panel, .frame = geometry.RectF.init(0, 0, 200, 1000) };
    const old_scroll = canvas.Widget{ .id = 10, .kind = .scroll_view, .frame = geometry.RectF.init(0, 0, 240, 30), .children = &.{content}, .value = 20 };
    var old_nodes: [3]canvas.WidgetLayoutNode = undefined;
    const old = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{old_scroll} }, geometry.RectF.init(0, 0, 240, 240), &old_nodes);
    var scrolls: [5]canvas.Widget = undefined;
    for (&scrolls, 0..) |*scroll, index| scroll.* = .{ .id = @intCast(index + 10), .kind = .scroll_view, .frame = geometry.RectF.init(0, @floatFromInt(index * 40), 240, 30), .children = &.{content}, .value = 80 };
    var new_nodes: [11]canvas.WidgetLayoutNode = undefined;
    const next = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &scrolls }, geometry.RectF.init(0, 0, 240, 240), &new_nodes);
    try expectSourceRevertWins(old, next, 10, struct {
        fn check(widget: canvas.Widget) bool {
            return widget.value == 20;
        }
    }.check);
}

test "the source scroll and control mirrors truncate at the node budget, as their fixed arrays did" {
    var app_state: TestApp = .{};
    const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 240));
    defer harness.destroy(std.testing.allocator);
    const view = harness.runtime.views[0];
    const max_nodes = canvas_limits.max_canvas_widget_nodes_per_view;
    const nodes = try std.testing.allocator.alloc(canvas.WidgetLayoutNode, max_nodes + 1);
    defer std.testing.allocator.free(nodes);
    for (nodes, 0..) |*node, index| node.* = .{ .widget = .{ .id = @intCast(index + 1), .kind = .scroll_view }, .frame = geometry.RectF.init(0, 0, 10, 10), .depth = 0 };
    try view.copyCanvasWidgetSourceScroll(.{ .nodes = nodes });
    try std.testing.expectEqual(max_nodes, view.widgetSourceScrollEntries().len);
    for (nodes) |*node| node.widget.kind = .slider;
    try view.copyCanvasWidgetSourceControls(.{ .nodes = nodes });
    try std.testing.expectEqual(max_nodes, view.widgetSourceControlEntries().len);
}

test "a packet present that fails to allocate never reaches the platform" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(40, 20));
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surface_packet_binary = true;
        const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) } } }};
        _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
        var output: [8]canvas.CanvasGpuCommand = undefined;
        var packet_bytes: [4096]u8 = undefined;
        faults.allocations_before_failure = before_failure;
        const presented = harness.runtime.presentNextCanvasGpuPacket(1, "canvas", .{ .frame_index = 1 }, harness.runtime.canvasFrameScratchStorage(), canvas.Color.rgb8(0, 0, 0), &output, &packet_bytes);
        faults.allocations_before_failure = null;
        if (presented) |_| continue else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_binary_count) catch |err| {
            std.debug.print("allocation {d} failed after the packet was presented\n", .{before_failure});
            return err;
        };
    }
}

test "a hybrid present that fails to allocate never reaches the platform" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(96, 48));
        defer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surface_packet_binary = true;
        harness.null_platform.gpu_surface_hybrid_layers = true;
        harness.runtime.options.platform.services.gpu_surface_hybrid_layers = true;
        const stops = [_]canvas.GradientStop{
            .{ .offset = 0, .color = canvas.Color.rgb8(14, 165, 233) },
            .{ .offset = 1, .color = canvas.Color.rgb8(168, 85, 247) },
        };
        const commands = [_]canvas.CanvasCommand{
            .{ .fill_rounded_rect = .{ .id = 4, .rect = geometry.RectF.init(0, 0, 96, 48), .radius = canvas.Radius.all(12), .fill = .{ .color = canvas.Color.rgb8(20, 24, 32) } } },
            .{ .push_clip = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 96, 48), .presentation_layer = .gpu_underlay } },
            .{ .fill_rounded_rect = .{ .id = 2, .rect = geometry.RectF.init(0, 0, 96, 48), .radius = canvas.Radius.all(12), .fill = .{ .linear_gradient = .{ .start = geometry.PointF.init(0, 24), .end = geometry.PointF.init(96, 24), .stops = &stops } } } },
            .pop_clip,
        };
        _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
        try std.testing.expect(harness.runtime.canvasViewHasHybridLayers(1, "canvas"));
        var gpu_commands: [16]canvas.CanvasGpuCommand = undefined;
        var packet_bytes: [16 * 1024]u8 = undefined;
        var pixels: [96 * 48 * 4]u8 = undefined;
        var scratch: [96 * 48 * 4]u8 = undefined;
        faults.allocations_before_failure = before_failure;
        const presented = harness.runtime.presentNextCanvasHybridPacket(1, "canvas", .{ .frame_index = 1, .surface_size = geometry.SizeF.init(96, 48), .scale = 1, .full_repaint = true }, harness.runtime.canvasFrameScratchStorage(), canvas.Color.rgba8(0, 0, 0, 0), &gpu_commands, &packet_bytes, &pixels, &scratch);
        faults.allocations_before_failure = null;
        if (presented) |_| continue else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_packet_present_binary_count) catch |err| {
            std.debug.print("allocation {d} failed after the hybrid packet was presented\n", .{before_failure});
            return err;
        };
    }
}

test "a pixel present that fails to allocate its retained baseline never reaches the platform" {
    for (0..max_failure_points) |before_failure| {
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(40, 20));
        defer harness.destroy(std.testing.allocator);
        harness.runtime.options.pixel_present_retained_baseline = true;
        const commands = [_]canvas.CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) } } }};
        _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = &commands });
        var pixels: [40 * 20 * 4]u8 = undefined;
        var scratch: [40 * 20 * 4]u8 = undefined;
        faults.allocations_before_failure = before_failure;
        const presented = harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{ .frame_index = 1, .surface_size = geometry.SizeF.init(40, 20), .scale = 1 }, harness.runtime.canvasFrameScratchStorage(), &pixels, &scratch, canvas.Color.rgb8(0, 0, 0));
        faults.allocations_before_failure = null;
        if (presented) |_| continue else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        std.testing.expectEqual(@as(usize, 0), harness.null_platform.gpu_surface_present_count) catch |err| {
            std.debug.print("allocation {d} failed after the pixels were presented\n", .{before_failure});
            return err;
        };
    }
}
