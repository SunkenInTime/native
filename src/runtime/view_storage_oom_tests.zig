//! A view's grown storage can fail to allocate. Each test here fails one
//! allocation at a time (`grown_array.testing_faults`), moving the failure
//! one allocation later per run until the step completes untouched, so every
//! allocation the step makes is hit. After each failure memory recovers and
//! the test checks that the view still agrees with itself and with the
//! platform: nothing is half published, and nothing is lost for good.
const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const App = support.App;
const TestHarness = support.TestHarness;
const Runtime = support.Runtime;
const grown_array = @import("grown_array.zig");
const canvas_limits = @import("canvas_limits.zig");

const faults = grown_array.testing_faults;

/// A tripwire for a step that never runs out of allocations to fail.
const max_failure_points = 64;

const TestApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "view-storage-oom", .source = platform.WebViewSource.html("<h1>OOM</h1>") };
    }
};

const Harness = TestHarness();

fn startCanvasHarness(app_state: *TestApp, size: geometry.SizeF) !*Harness {
    const harness = try Harness.create(std.testing.allocator, .{});
    errdefer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "canvas", .kind = .gpu_surface, .frame = geometry.RectF.init(0, 0, size.width, size.height) });
    return harness;
}

/// Run `step` with every allocation after the first `before_failure` failing.
/// OutOfMemory is the only error it may return; true when it completed, so
/// no later allocation is left to fail.
fn failAfter(before_failure: usize, step: anytype, args: anytype) !bool {
    faults.allocations_before_failure = before_failure;
    defer faults.allocations_before_failure = null;
    _ = @call(.auto, step, args) catch |err| switch (err) {
        error.OutOfMemory => return false,
        else => return err,
    };
    return true;
}

fn failurePoint(before_failure: usize) !void {
    if (before_failure >= max_failure_points) return error.FailurePointsNotExhausted;
}

/// Frames the platform received, by any path (the null platform counts a
/// binary packet in the packet count too).
fn platformPresents(harness: *Harness) usize {
    return harness.null_platform.gpu_surface_present_count + harness.null_platform.gpu_surface_packet_present_count;
}

test "a spinner whose animation bookkeeping fails to allocate leaves no loop running after it unmounts" {
    var completed = false;
    var before_failure: usize = 0;
    while (!completed) : (before_failure += 1) {
        try failurePoint(before_failure);
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 120));
        defer harness.destroy(std.testing.allocator);
        const spinner = canvas.Widget{ .id = 5, .kind = .spinner, .frame = geometry.RectF.init(20, 20, 20, 20) };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{spinner} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        completed = try failAfter(before_failure, Runtime.emitCanvasWidgetDisplayList, .{ &harness.runtime, 1, "canvas", canvas.DesignTokens{} });
        const view = harness.runtime.views[0];
        if (completed) try std.testing.expect(view.canvas_widget_loop_animation_ids.len > 0);

        var empty_nodes: [1]canvas.WidgetLayoutNode = undefined;
        const empty = try canvas.layoutWidgetTree(.{ .kind = .stack }, geometry.RectF.init(0, 0, 240, 120), &empty_nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", empty);
        _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
        std.testing.expectEqual(@as(usize, 0), view.canvas_render_animations.len) catch |err| {
            std.debug.print("allocation {d} failed: {d} animations survive the unmount, {d} tracked\n", .{ before_failure, view.canvas_render_animations.len, view.canvas_widget_loop_animation_ids.len });
            return err;
        };
    }
}

test "a caret blink whose bookkeeping fails to allocate leaves no animation after blur" {
    var completed = false;
    var before_failure: usize = 0;
    while (!completed) : (before_failure += 1) {
        try failurePoint(before_failure);
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 120));
        defer harness.destroy(std.testing.allocator);
        const text_field = canvas.Widget{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(12, 16, 160, 36), .placeholder = "Search" };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{text_field} }, geometry.RectF.init(0, 0, 240, 120), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
        completed = try failAfter(before_failure, Runtime.dispatchPlatformEvent, .{ &harness.runtime, app_state.app(), platform.Event{ .gpu_surface_input = .{
            .window_id = 1,
            .label = "canvas",
            .kind = .pointer_down,
            .timestamp_ns = 1_000_000_000,
            .x = 90,
            .y = 34,
        } } });
        const view = harness.runtime.views[0];
        if (completed) try std.testing.expect(view.canvas_widget_caret_blink_id != 0);

        view.focused = false;
        _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
        std.testing.expectEqual(@as(usize, 0), view.canvas_render_animations.len) catch |err| {
            std.debug.print("allocation {d} failed: {d} animations survive the blur\n", .{ before_failure, view.canvas_render_animations.len });
            return err;
        };
    }
}

test "a toggle whose knob animation fails to allocate never arms it without its dirty bounds" {
    var completed = false;
    var before_failure: usize = 0;
    while (!completed) : (before_failure += 1) {
        try failurePoint(before_failure);
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(220, 100));
        defer harness.destroy(std.testing.allocator);
        const toggle = canvas.Widget{ .id = 4, .kind = .switch_control, .frame = geometry.RectF.init(10, 20, 112, 32), .text = "Live" };
        var nodes: [2]canvas.WidgetLayoutNode = undefined;
        const layout = try canvas.layoutWidgetTree(.{ .kind = .stack, .children = &.{toggle} }, geometry.RectF.init(0, 0, 220, 100), &nodes);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
        _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", .{});
        try harness.runtime.dispatchPlatformEvent(app_state.app(), .{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_down, .timestamp_ns = 100, .x = 66, .y = 36 } });
        completed = try failAfter(before_failure, Runtime.dispatchPlatformEvent, .{ &harness.runtime, app_state.app(), platform.Event{ .gpu_surface_input = .{ .window_id = 1, .label = "canvas", .kind = .pointer_up, .timestamp_ns = 110, .x = 66, .y = 36 } } });
        const view = harness.runtime.views[0];
        if (completed) try std.testing.expect(view.canvas_render_animations.len > 0);

        // An armed animation repaints through its dirty bounds; one armed
        // without them would leave stale knob pixels behind.
        for (view.canvas_render_animations.slice()) |animation| {
            var found = false;
            for (view.canvas_render_animation_dirty_bounds.slice()) |entry| {
                if (entry.id == animation.id) found = true;
            }
            if (!found) {
                std.debug.print("allocation {d} failed: animation {d} is armed without dirty bounds\n", .{ before_failure, animation.id });
                return error.TestUnexpectedResult;
            }
        }
        // After recovery the next frame still reaches the platform.
        var pixels: [220 * 100 * 4]u8 = undefined;
        var scratch: [220 * 100 * 4]u8 = undefined;
        const presents = platformPresents(harness);
        const frame = try harness.runtime.presentNextCanvasFramePixels(1, "canvas", .{ .frame_index = 1, .timestamp_ns = 120, .surface_size = geometry.SizeF.init(220, 100), .scale = 1 }, harness.runtime.canvasFrameScratchStorage(), &pixels, &scratch, canvas.Color.rgb8(0, 0, 0));
        try std.testing.expect(frame.requiresRender());
        try std.testing.expectEqual(presents + 1, platformPresents(harness));
    }
}

test "drag regions whose mirror fails to grow are never pushed, so a revert stays in step with the platform" {
    var completed = false;
    var before_failure: usize = 0;
    while (!completed) : (before_failure += 1) {
        try failurePoint(before_failure);
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
        completed = try failAfter(before_failure, Runtime.setCanvasWidgetLayout, .{ &harness.runtime, 1, "canvas", next });
        if (completed) try std.testing.expectEqual(@as(usize, 5), harness.null_platform.window_drag_region_count);

        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", old);
        const view = harness.runtime.views[0];
        std.testing.expectEqual(@as(usize, 1), harness.null_platform.window_drag_region_count) catch |err| {
            std.debug.print("allocation {d} failed: platform holds {d} regions after the revert, mirror {d}\n", .{ before_failure, harness.null_platform.window_drag_region_count, view.canvas_widget_drag_regions.len });
            return err;
        };
        try std.testing.expectEqual(@as(usize, 1), view.canvas_widget_drag_regions.len);
    }
}

/// Install `old`, fail somewhere in installing `next`, then reinstall `old`:
/// the retained widget `id` must read what `old` declares.
fn expectSourceRevertWins(old_layout: canvas.WidgetLayoutTree, next_layout: canvas.WidgetLayoutTree, id: canvas.ObjectId, check: *const fn (canvas.Widget) bool) !void {
    var completed = false;
    var before_failure: usize = 0;
    while (!completed) : (before_failure += 1) {
        try failurePoint(before_failure);
        var app_state: TestApp = .{};
        const harness = try startCanvasHarness(&app_state, geometry.SizeF.init(240, 240));
        defer harness.destroy(std.testing.allocator);
        _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", old_layout);
        completed = try failAfter(before_failure, Runtime.setCanvasWidgetLayout, .{ &harness.runtime, 1, "canvas", next_layout });
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

// ---- Presents: a frame that fails to allocate reaches nothing, and the
// next present after memory recovers reaches the platform.

const PresentPath = enum { packet, pixels, hybrid };

/// The arrays a scenario must have allocated by a clean present, so its
/// failure points provably include their allocations.
const Covered = enum { frame_caches, baseline, presented_summary };

const PresentScenario = struct {
    path: PresentPath,
    size: geometry.SizeF,
    commands: []const canvas.CanvasCommand,
    overrides: []const canvas.CanvasRenderOverride = &.{},
    covers: []const Covered,
};

const PresentBuffers = struct {
    gpu_commands: [32]canvas.CanvasGpuCommand = undefined,
    packet_bytes: [16 * 1024]u8 = undefined,
    pixels: []u8,
    scratch: []u8,
};

fn presentScenarioFrame(harness: *Harness, scenario: PresentScenario, buffers: *PresentBuffers, frame_index: u64, overrides: []const canvas.CanvasRenderOverride) anyerror!bool {
    const options: canvas.CanvasFrameOptions = .{ .frame_index = frame_index, .surface_size = scenario.size, .scale = 1, .render_overrides = overrides };
    const storage = harness.runtime.canvasFrameScratchStorage();
    const clear = canvas.Color.rgb8(0, 0, 0);
    return switch (scenario.path) {
        .packet => (try harness.runtime.presentNextCanvasGpuPacket(1, "canvas", options, storage, clear, &buffers.gpu_commands, &buffers.packet_bytes)).requiresRender(),
        .pixels => (try harness.runtime.presentNextCanvasFramePixels(1, "canvas", options, storage, buffers.pixels, buffers.scratch, clear)).requiresRender(),
        .hybrid => (try harness.runtime.presentNextCanvasHybridPacket(1, "canvas", options, storage, clear, &buffers.gpu_commands, &buffers.packet_bytes, buffers.pixels, buffers.scratch)) != null,
    };
}

fn startPresentScenario(app_state: *TestApp, scenario: PresentScenario) !*Harness {
    const harness = try startCanvasHarness(app_state, scenario.size);
    errdefer harness.destroy(std.testing.allocator);
    switch (scenario.path) {
        .packet => harness.null_platform.gpu_surface_packet_binary = true,
        .pixels => harness.runtime.options.pixel_present_retained_baseline = true,
        .hybrid => {
            harness.null_platform.gpu_surface_packet_binary = true;
            harness.null_platform.gpu_surface_hybrid_layers = true;
            harness.runtime.options.platform.services.gpu_surface_hybrid_layers = true;
        },
    }
    _ = try harness.runtime.setCanvasDisplayList(1, "canvas", .{ .commands = scenario.commands });
    return harness;
}

fn expectCovered(harness: *Harness, scenario: PresentScenario) !void {
    const view = harness.runtime.views[0];
    for (scenario.covers) |covered| switch (covered) {
        .frame_caches => {
            inline for (.{ "canvas_frame_path_geometry_cache", "canvas_frame_image_cache", "canvas_frame_layer_cache", "canvas_frame_resource_cache", "canvas_frame_visual_effect_cache", "canvas_frame_glyph_atlas_cache", "canvas_frame_text_layout_cache", "canvas_frame_render_overrides" }) |name| {
                if (@field(view, name).items.len == 0) {
                    std.debug.print("the scenario never allocates {s}\n", .{name});
                    return error.ScenarioMissesAnArray;
                }
            }
        },
        .baseline => if (view.canvas_packet_baseline_keys.items.len == 0) return error.ScenarioMissesAnArray,
        .presented_summary => if (view.presented_canvas_commands.items.len == 0) return error.ScenarioMissesAnArray,
    };
}

fn expectPresentSurvivesEveryFailure(scenario: PresentScenario) !void {
    const pixel_bytes: usize = @as(usize, @intFromFloat(scenario.size.width * scenario.size.height)) * 4;
    var buffers: PresentBuffers = .{
        .pixels = try std.testing.allocator.alloc(u8, pixel_bytes),
        .scratch = try std.testing.allocator.alloc(u8, pixel_bytes),
    };
    defer std.testing.allocator.free(buffers.pixels);
    defer std.testing.allocator.free(buffers.scratch);

    var completed = false;
    var before_failure: usize = 0;
    while (!completed) : (before_failure += 1) {
        try failurePoint(before_failure);
        var app_state: TestApp = .{};
        const harness = try startPresentScenario(&app_state, scenario);
        defer harness.destroy(std.testing.allocator);

        faults.allocations_before_failure = before_failure;
        const first = presentScenarioFrame(harness, scenario, &buffers, 1, scenario.overrides);
        faults.allocations_before_failure = null;
        if (first) |rendered| {
            completed = true;
            try std.testing.expect(rendered);
            try std.testing.expectEqual(@as(usize, 1), platformPresents(harness));
            try expectCovered(harness, scenario);
            continue;
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);

        std.testing.expectEqual(@as(usize, 0), platformPresents(harness)) catch |err| {
            std.debug.print("{t}: allocation {d} failed after the frame reached the platform\n", .{ scenario.path, before_failure });
            return err;
        };
        // Memory recovers. The frame never reached the platform, so the
        // next present must, even with nothing new to draw.
        const rendered = try presentScenarioFrame(harness, scenario, &buffers, 2, &.{});
        if (!rendered or platformPresents(harness) != 1) {
            std.debug.print("{t}: allocation {d} failed; the retry rendered={} and the platform has {d} presents\n", .{ scenario.path, before_failure, rendered, platformPresents(harness) });
            return error.FrameLostAfterRecovery;
        }
    }
}

const keyed_rect = [_]canvas.CanvasCommand{.{ .fill_rect = .{ .id = 1, .rect = geometry.RectF.init(0, 0, 10, 10), .fill = .{ .color = canvas.Color.rgb8(255, 0, 0) } } }};

const triangle = [_]canvas.PathElement{
    .{ .verb = .move_to, .points = .{ geometry.PointF.init(4, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
    .{ .verb = .line_to, .points = .{ geometry.PointF.init(24, 4), geometry.PointF.zero(), geometry.PointF.zero() } },
    .{ .verb = .line_to, .points = .{ geometry.PointF.init(14, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
    .{ .verb = .close },
};

/// A path, an image, a shadow and text, with an opacity override: a frame
/// that fills every per-view frame cache.
const every_cache = [_]canvas.CanvasCommand{
    .{ .fill_path = .{ .id = 1, .elements = &triangle, .fill = .{ .color = canvas.Color.rgb8(14, 165, 233) } } },
    .{ .draw_image = .{ .id = 2, .image_id = 42, .dst = geometry.RectF.init(32, 4, 18, 18) } },
    .{ .shadow = .{ .id = 3, .rect = geometry.RectF.init(58, 8, 20, 14), .radius = canvas.Radius.all(5), .blur = 8, .color = canvas.Color.rgba8(15, 23, 42, 80) } },
    .{ .draw_text = .{ .id = 4, .font_id = 5, .size = 14, .origin = geometry.PointF.init(4, 40), .color = canvas.Color.rgb8(15, 23, 42), .text = "A" } },
};
const every_cache_override = [_]canvas.CanvasRenderOverride{.{ .id = 1, .opacity = 0.5 }};

test "a packet present that fails to allocate reaches nothing, and the next one does" {
    try expectPresentSurvivesEveryFailure(.{ .path = .packet, .size = geometry.SizeF.init(40, 20), .commands = &keyed_rect, .covers = &.{ .baseline, .presented_summary } });
}

test "a pixel present that fails to allocate its retained baseline reaches nothing, and the next one does" {
    try expectPresentSurvivesEveryFailure(.{ .path = .pixels, .size = geometry.SizeF.init(40, 20), .commands = &keyed_rect, .covers = &.{ .baseline, .presented_summary } });
}

test "a hybrid present that fails to allocate reaches nothing, and the next one does" {
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
    try expectPresentSurvivesEveryFailure(.{ .path = .hybrid, .size = geometry.SizeF.init(96, 48), .commands = &commands, .covers = &.{.presented_summary} });
}

test "a packet frame that fills every cache survives a failure at each of their allocations" {
    try expectPresentSurvivesEveryFailure(.{ .path = .packet, .size = geometry.SizeF.init(96, 48), .commands = &every_cache, .overrides = &every_cache_override, .covers = &.{ .frame_caches, .presented_summary } });
}

test "a pixel frame that fills every cache survives a failure at each of their allocations" {
    try expectPresentSurvivesEveryFailure(.{ .path = .pixels, .size = geometry.SizeF.init(96, 48), .commands = &every_cache, .overrides = &every_cache_override, .covers = &.{ .frame_caches, .presented_summary } });
}
