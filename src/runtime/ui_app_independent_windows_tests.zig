//! Declared windows that render independent parts of one model (one
//! window per widget): `window_view_revision` rebuilds only the window
//! whose inputs moved, same-revision windows go through `project_update`,
//! and `window_sync` / `window_on_frame` reach the window they name. The
//! descriptor's surface flags reach the platform create call.

const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("canvas");
const app_manifest = @import("app_manifest");
const core = @import("core.zig");
const ui_app_model = @import("ui_app.zig");
const support = @import("test_support.zig");

const main_canvas = "desk-canvas";
const window_labels = [_][]const u8{ "a", "b" };
const canvas_labels = [_][]const u8{ "a-canvas", "b-canvas" };

const DeskModel = struct {
    /// View inputs of each window: its `window_view_revision`.
    counts: [2]u32 = .{ 0, 0 },
    /// Paint-only changes: never move a revision.
    paints: [2]u32 = .{ 0, 0 },
    syncs: [2]u32 = .{ 0, 0 },
    frames: [2]u32 = .{ 0, 0 },
};

const DeskMsg = union(enum) {
    bump: u8,
    paint: u8,
    frame: u8,
};

const DeskApp = ui_app_model.UiApp(DeskModel, DeskMsg);

/// Loop-thread observations the const view and projector hooks cannot
/// write into the model.
var view_builds: [2]u32 = .{ 0, 0 };
var projected: [2]u32 = .{ 0, 0 };

fn windowIndex(label: []const u8) usize {
    for (window_labels, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, label)) return index;
    }
    unreachable;
}

fn canvasIndex(label: []const u8) ?usize {
    for (canvas_labels, 0..) |candidate, index| {
        if (std.mem.eql(u8, candidate, label)) return index;
    }
    return null;
}

fn deskUpdate(model: *DeskModel, msg: DeskMsg) void {
    switch (msg) {
        .bump => |index| model.counts[index] += 1,
        .paint => |index| model.paints[index] += 1,
        .frame => |index| model.frames[index] += 1,
    }
}

fn deskViewRevision(_: *const DeskModel) u64 {
    return 0;
}

fn deskWindowViewRevision(model: *const DeskModel, window_label: []const u8) u64 {
    return model.counts[windowIndex(window_label)];
}

fn projectDesk(
    _: *core.Runtime,
    _: support.platform.WindowId,
    target_canvas_label: []const u8,
    _: *const DeskModel,
    msg: DeskMsg,
) anyerror!bool {
    const target = canvasIndex(target_canvas_label);
    if (target) |index| projected[index] += 1;
    // A bump moves its own window's view; every other canvas already
    // shows the update. Paint and frame Msgs are paint-only everywhere.
    return switch (msg) {
        .bump => |index| target != index,
        .paint, .frame => true,
    };
}

fn deskView(ui: *DeskApp.Ui, _: *const DeskModel) DeskApp.Ui.Node {
    return ui.column(.{ .padding = 8 }, .{ui.text(.{}, "desk")});
}

fn deskWindowView(ui: *DeskApp.Ui, model: *const DeskModel, window_label: []const u8) DeskApp.Ui.Node {
    const index = windowIndex(window_label);
    view_builds[index] += 1;
    return ui.column(.{ .padding = 8 }, .{ui.text(.{}, ui.fmt("count {d}", .{model.counts[index]}))});
}

fn deskWindowSync(model: *DeskModel, window_label: []const u8, _: canvas.WidgetLayoutTree) void {
    model.syncs[windowIndex(window_label)] += 1;
}

fn deskWindowOnFrame(_: *const DeskModel, window_label: []const u8, _: support.platform.GpuFrame) ?DeskMsg {
    return .{ .frame = @intCast(windowIndex(window_label)) };
}

fn deskWindows(_: *const DeskModel, scratch: *DeskApp.WindowsScratch) []const DeskApp.WindowDescriptor {
    for (window_labels, canvas_labels, 0..) |label, canvas_label, index| {
        scratch.windows[index] = .{
            .label = label,
            .canvas_label = canvas_label,
            .width = 240,
            .height = 110,
            .x = @floatFromInt(index * 240),
            .y = 0,
            .resizable = false,
            .titlebar = .chromeless,
            .transparent = index == 0,
            .layer = if (index == 0) .bottom else .topmost,
            .click_through = index == 0,
            .no_activate = true,
        };
    }
    return scratch.windows[0..window_labels.len];
}

const desk_views = [_]app_manifest.ShellView{
    .{ .label = main_canvas, .kind = .gpu_surface, .fill = true, .gpu_backend = .metal },
};
const desk_windows_scene = [_]app_manifest.ShellWindow{.{
    .label = "main",
    .title = "Desk",
    .width = 240,
    .height = 110,
    .views = &desk_views,
}};

const Fixture = struct {
    harness: *core.TestHarness(),
    app_state: *DeskApp,
    app: core.App,

    /// Start the app, install the main canvas (which declares both
    /// windows), then install each declared window's canvas.
    fn create() !Fixture {
        const harness = try core.TestHarness().create(std.testing.allocator, .{ .size = geometry.SizeF.init(240, 110) });
        errdefer harness.destroy(std.testing.allocator);
        harness.null_platform.gpu_surfaces = true;
        const app_state = try DeskApp.create(std.heap.page_allocator, .{
            .name = "ui-app-desk",
            .scene = .{ .windows = &desk_windows_scene },
            .canvas_label = main_canvas,
            .update = deskUpdate,
            .view = deskView,
            .view_revision = deskViewRevision,
            .window_view_revision = deskWindowViewRevision,
            .project_update = projectDesk,
            .windows_fn = deskWindows,
            .window_view = deskWindowView,
            .window_sync = deskWindowSync,
            .window_on_frame = deskWindowOnFrame,
        });
        const app = app_state.app();
        try harness.start(app);
        const fixture: Fixture = .{ .harness = harness, .app_state = app_state, .app = app };
        try fixture.frame(1, main_canvas, 1);
        for (canvas_labels, 0..) |canvas_label, index| {
            try fixture.frame(fixture.windowId(window_labels[index]), canvas_label, 1);
        }
        view_builds = .{ 0, 0 };
        projected = .{ 0, 0 };
        return fixture;
    }

    fn destroy(self: Fixture) void {
        self.app_state.destroy();
        self.harness.destroy(std.testing.allocator);
    }

    fn frame(self: Fixture, window_id: support.platform.WindowId, canvas_label: []const u8, frame_index: u64) !void {
        try self.harness.runtime.dispatchPlatformEvent(self.app, .{ .gpu_surface_frame = .{
            .window_id = window_id,
            .label = canvas_label,
            .size = geometry.SizeF.init(240, 110),
            .scale_factor = 1,
            .frame_index = frame_index,
            .timestamp_ns = frame_index * 16_000_000,
            .nonblank = true,
        } });
    }

    fn windowId(self: Fixture, label: []const u8) support.platform.WindowId {
        var buffer: [support.platform.max_windows]support.platform.WindowInfo = undefined;
        for (self.harness.runtime.listWindows(&buffer)) |info| {
            if (std.mem.eql(u8, info.label, label)) return info.id;
        }
        unreachable;
    }

    fn platformIndex(self: Fixture, label: []const u8) usize {
        const null_platform = self.harness.null_platform;
        for (null_platform.windows[0..null_platform.window_count], 0..) |info, index| {
            if (std.mem.eql(u8, info.label, label)) return index;
        }
        unreachable;
    }
};

test "declared windows carry the widget surface flags to the platform" {
    if (comptime support.platform.max_windows < 3) return error.SkipZigTest;
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const null_platform = fixture.harness.null_platform;

    const a = fixture.platformIndex("a");
    try std.testing.expect(null_platform.window_transparent[a]);
    try std.testing.expectEqual(support.platform.WindowLayer.bottom, null_platform.window_layer[a]);
    try std.testing.expect(null_platform.window_click_through[a]);
    try std.testing.expect(null_platform.window_no_activate[a]);

    const b = fixture.platformIndex("b");
    try std.testing.expect(!null_platform.window_transparent[b]);
    try std.testing.expectEqual(support.platform.WindowLayer.topmost, null_platform.window_layer[b]);
    try std.testing.expect(!null_platform.window_click_through[b]);
    try std.testing.expect(null_platform.window_no_activate[b]);
}

test "a Msg rebuilds only the declared window whose revision moved" {
    if (comptime support.platform.max_windows < 3) return error.SkipZigTest;
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.app_state.dispatch(&fixture.harness.runtime, 1, .{ .bump = 0 });
    try std.testing.expectEqual([2]u32{ 1, 0 }, view_builds);
    // The untouched window was offered the Msg as a projection instead.
    try std.testing.expectEqual([2]u32{ 0, 1 }, projected);

    const layout = try fixture.harness.runtime.canvasWidgetLayout(fixture.windowId("a"), "a-canvas");
    var found = false;
    for (layout.nodes) |node| found = found or std.mem.eql(u8, node.widget.text, "count 1");
    try std.testing.expect(found);
}

test "a same-revision Msg projects every declared window without rebuilding" {
    if (comptime support.platform.max_windows < 3) return error.SkipZigTest;
    const fixture = try Fixture.create();
    defer fixture.destroy();

    try fixture.app_state.dispatch(&fixture.harness.runtime, 1, .{ .paint = 1 });
    try std.testing.expectEqual(@as(u32, 1), fixture.app_state.model.paints[1]);
    try std.testing.expectEqual([2]u32{ 0, 0 }, view_builds);
    try std.testing.expectEqual([2]u32{ 1, 1 }, projected);
}

test "a declared window's frame maps through window_on_frame and syncs only that window" {
    if (comptime support.platform.max_windows < 3) return error.SkipZigTest;
    const fixture = try Fixture.create();
    defer fixture.destroy();
    const syncs_before = fixture.app_state.model.syncs;

    try fixture.frame(fixture.windowId("b"), "b-canvas", 2);
    try std.testing.expectEqual([2]u32{ 0, 1 }, fixture.app_state.model.frames);
    try std.testing.expectEqual(syncs_before[0], fixture.app_state.model.syncs[0]);
    try std.testing.expect(fixture.app_state.model.syncs[1] > syncs_before[1]);
    try std.testing.expectEqual([2]u32{ 0, 0 }, view_builds);
}
