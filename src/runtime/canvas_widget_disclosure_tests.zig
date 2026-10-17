//! Disclosure tween tests: the accordion open/close reveal, driven the
//! way a real app drives it — model-flipped rebuilds through
//! `setCanvasWidgetLayout` and presented-frame events through
//! `dispatchPlatformEvent` — pinning the whole contract: default-on
//! arming from a flip (state-compared or toggle-echoed), the previous
//! pose restored so the reveal EASES instead of snapping, content
//! clipped (never re-wrapped) mid-flight, interaction and semantics
//! concealed until settled, reduced-motion snap, replay determinism on
//! the recorded frame clock, and region-scoped mid-tween presents.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const App = support.App;
const Runtime = support.Runtime;
const Event = support.Event;
const TestHarness = support.TestHarness;
const max_canvas_commands_per_view = support.max_canvas_commands_per_view;
const canvasFrameScratchStorage = support.canvasFrameScratchStorage;
const CanvasPresentationMode = support.CanvasPresentationMode;

const TestMsg = union(enum) {
    toggled,
    pressed,
};

const TestUi = canvas.Ui(TestMsg);

const surface_width: f32 = 320;
const surface_height: f32 = 400;

/// A do-nothing app: these tests drive rebuilds by hand (the model
/// loop's `setCanvasWidgetLayout` calls, minus the loop).
const QuietApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "gpu-disclosure", .source = platform.WebViewSource.html("<h1>GPU</h1>"), .event_fn = event };
    }

    fn event(context: *anyopaque, runtime: *Runtime, event_value: Event) anyerror!void {
        _ = context;
        _ = runtime;
        _ = event_value;
    }
};

/// The scene: a few static rows (they must NOT move — the patch-present
/// pin leans on them), one accordion whose body holds a real button (the
/// concealed-interaction pin's target), and a trailing row that slides
/// with the reveal.
fn buildDisclosureTree(ui: *TestUi, open: bool) TestUi.Node {
    return ui.column(.{ .width = surface_width }, .{
        ui.text(.{}, "Static row one"),
        ui.text(.{}, "Static row two"),
        ui.text(.{}, "Static row three"),
        ui.el(.accordion, .{ .text = "Section", .selected = open, .on_toggle = .toggled }, .{
            ui.column(.{}, .{
                ui.text(.{ .wrap = true }, "Revealed body copy that lays out at full size and never re-wraps mid-flight."),
                ui.button(.{ .on_press = .pressed }, "Inside"),
            }),
        }),
        ui.text(.{}, "Below the section"),
    });
}

/// One model rebuild: a fresh builder (ids mint deterministically, so
/// every rebuild names the same widgets), laid out at the surface size
/// and landed through the real `setCanvasWidgetLayout` path.
fn setDisclosureLayout(harness: anytype, arena: std.mem.Allocator, open: bool) !void {
    var ui = TestUi.init(arena);
    const tree = try ui.finalize(buildDisclosureTree(&ui, open));
    const nodes = try arena.alloc(canvas.WidgetLayoutNode, 32);
    const layout = try canvas.layoutWidgetTree(tree.root, geometry.RectF.init(0, 0, surface_width, surface_height), nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
}

fn installDisclosureView(harness: anytype, app: App, arena: std.mem.Allocator, open: bool) !void {
    harness.null_platform.gpu_surfaces = true;
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface_width, surface_height),
    });
    try setDisclosureLayout(harness, arena, open);
    // Hand display-list ownership to the widget tree (what UiApp does
    // on its first present): from here on, every retained-tree change —
    // tween steps included — re-emits the display list itself.
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");
}

fn tweenFrame(harness: anytype, app: App, timestamp_ns: u64) !void {
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_frame = .{
        .window_id = 1,
        .label = "canvas",
        .size = geometry.SizeF.init(surface_width, surface_height),
        .timestamp_ns = timestamp_ns,
    } });
}

fn nodeByKind(layout: canvas.WidgetLayoutTree, kind: canvas.WidgetKind) ?canvas.WidgetLayoutNode {
    for (layout.nodes) |node| {
        if (node.widget.kind == kind) return node;
    }
    return null;
}

fn accordionNode(harness: anytype) !canvas.WidgetLayoutNode {
    const layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    return nodeByKind(layout, .accordion) orelse error.TestUnexpectedResult;
}

fn buttonNode(harness: anytype) !canvas.WidgetLayoutNode {
    const layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    return nodeByKind(layout, .button) orelse error.TestUnexpectedResult;
}

fn accordionHeight(harness: anytype) !f32 {
    return (try accordionNode(harness)).frame.height;
}

fn semanticsContainId(harness: anytype, id: canvas.ObjectId) !bool {
    const semantics = try harness.runtime.canvasWidgetSemantics(1, "canvas");
    for (semantics) |node| {
        if (node.id == id) return true;
    }
    return false;
}

test "a disclosure flip rebuild arms the default-on tween and eases the reveal on the frame clock" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: QuietApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try installDisclosureView(harness, app, arena.allocator(), false);

    const closed_height = try accordionHeight(harness);
    const below_closed_y = nodeByKind(try harness.runtime.canvasWidgetLayout(1, "canvas"), .accordion).?.frame.maxY();

    // The model opens the section. The rebuild's declared pose is the
    // open one, but the retained tree keeps painting the CLOSED pose —
    // the tween owns the walk between them. Arming requested the frame
    // that will drive the first step; no app declared anything.
    const requests_before = harness.null_platform.gpu_surface_frame_request_count;
    try setDisclosureLayout(harness, arena.allocator(), true);
    try std.testing.expect(harness.runtime.views[0].canvasWidgetDisclosureTweenActive());
    try std.testing.expectEqual(closed_height, try accordionHeight(harness));
    try std.testing.expect(harness.null_platform.gpu_surface_frame_request_count > requests_before);

    // First frame stamps the recorded clock: no motion yet.
    const t0: u64 = 1_000_000_000;
    try tweenFrame(harness, app, t0);
    try std.testing.expectEqual(closed_height, try accordionHeight(harness));

    // Mid-flight (the normal motion class is 180 ms): strictly between
    // the poses, and the row below rides the accordion's bottom edge —
    // the reflow moves as one band.
    try tweenFrame(harness, app, t0 + 90_000_000);
    const mid_height = try accordionHeight(harness);
    try std.testing.expect(mid_height > closed_height);
    const mid_node = try accordionNode(harness);
    const layout_mid = try harness.runtime.canvasWidgetLayout(1, "canvas");
    var below_mid_y: f32 = 0;
    for (layout_mid.nodes) |node| {
        if (node.widget.kind == .text and std.mem.eql(u8, node.widget.text, "Below the section")) below_mid_y = node.frame.y;
    }
    try std.testing.expect(below_mid_y > below_closed_y);
    try std.testing.expectApproxEqAbs(mid_node.frame.maxY(), below_mid_y, 0.001);

    // An idempotent rebuild mid-flight (the model re-declares the same
    // open state) must not pop the pose or restart the clock.
    try setDisclosureLayout(harness, arena.allocator(), true);
    try std.testing.expectEqual(mid_height, try accordionHeight(harness));
    try std.testing.expect(harness.runtime.views[0].canvasWidgetDisclosureTweenActive());

    // Past the duration: snapped to the exact declared pose, retired,
    // and the frame channel disarms itself.
    try tweenFrame(harness, app, t0 + 250_000_000);
    const open_height = try accordionHeight(harness);
    try std.testing.expect(open_height > mid_height);
    try std.testing.expect(!harness.runtime.views[0].canvasWidgetDisclosureTweenActive());
    const requests_settled = harness.null_platform.gpu_surface_frame_request_count;
    try tweenFrame(harness, app, t0 + 300_000_000);
    try std.testing.expectEqual(requests_settled, harness.null_platform.gpu_surface_frame_request_count);
    try std.testing.expectEqual(open_height, try accordionHeight(harness));
}

test "a mid-flight re-toggle reverses from the current pose without a jump" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: QuietApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try installDisclosureView(harness, app, arena.allocator(), false);
    const closed_height = try accordionHeight(harness);

    try setDisclosureLayout(harness, arena.allocator(), true);
    const t0: u64 = 1_000_000_000;
    try tweenFrame(harness, app, t0);
    try tweenFrame(harness, app, t0 + 90_000_000);
    const mid_height = try accordionHeight(harness);
    try std.testing.expect(mid_height > closed_height);

    // The model flips back mid-flight. The new tween's FROM pose is the
    // exact mid-flight pose the user is looking at — no jump to either
    // endpoint — and the walk reverses toward closed on a fresh clock.
    try setDisclosureLayout(harness, arena.allocator(), false);
    try std.testing.expectEqual(mid_height, try accordionHeight(harness));
    try std.testing.expect(harness.runtime.views[0].canvasWidgetDisclosureTweenActive());
    try tweenFrame(harness, app, t0 + 100_000_000);
    try std.testing.expectEqual(mid_height, try accordionHeight(harness));
    try tweenFrame(harness, app, t0 + 150_000_000);
    const reversing_height = try accordionHeight(harness);
    try std.testing.expect(reversing_height < mid_height);
    try std.testing.expect(reversing_height > closed_height);

    // Settle: exactly the closed pose, tween retired, and the content
    // emits nothing again (the conceal finished).
    try tweenFrame(harness, app, t0 + 400_000_000);
    try std.testing.expectEqual(closed_height, try accordionHeight(harness));
    try std.testing.expect(!harness.runtime.views[0].canvasWidgetDisclosureTweenActive());
    const accordion = try accordionNode(harness);
    const display_list = harness.runtime.views[0].canvasDisplayList();
    try std.testing.expect(display_list.findCommandById(canvas.widgetPartId(accordion.widget.id, 9)) == null);
}

test "reduce motion snaps the disclosure flip to its declared pose" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: QuietApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try installDisclosureView(harness, app, arena.allocator(), false);
    const closed_height = try accordionHeight(harness);

    harness.runtime.appearance.reduce_motion = true;
    try setDisclosureLayout(harness, arena.allocator(), true);
    // No tween, no restored pose: the open pose stands in this rebuild's
    // frame, exactly the pre-disclosure behavior.
    try std.testing.expect(!harness.runtime.views[0].canvasWidgetDisclosureTweenActive());
    try std.testing.expect(try accordionHeight(harness) > closed_height);
}

test "identical recorded frame clocks replay a disclosure reveal to identical poses" {
    // The replay-determinism contract at disclosure scale: two runtimes
    // fed the SAME frame-event timestamps step the same reveal to
    // bitwise identical heights — no wall clock ever participates.
    const timestamps = [_]u64{ 5_000_000, 13_000_000, 29_000_000, 60_000_000, 120_000_000, 200_000_000 };
    var heights: [2][timestamps.len]f32 = undefined;
    for (0..2) |run| {
        const harness = try TestHarness().create(std.testing.allocator, .{});
        defer harness.destroy(std.testing.allocator);
        var app_state: QuietApp = .{};
        const app = app_state.app();
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        try installDisclosureView(harness, app, arena.allocator(), false);
        try setDisclosureLayout(harness, arena.allocator(), true);
        for (timestamps, 0..) |timestamp_ns, index| {
            try tweenFrame(harness, app, timestamp_ns);
            heights[run][index] = try accordionHeight(harness);
        }
    }
    for (heights[0], heights[1]) |first, second| {
        try std.testing.expectEqual(first, second);
    }
}

test "revealing content stays un-hittable, unfocusable, and out of semantics until settled" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: QuietApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try installDisclosureView(harness, app, arena.allocator(), false);

    // Closed: the button inside is laid out (full size, ready to
    // reveal) but concealed from every interaction surface.
    const concealed_button = try buttonNode(harness);
    try std.testing.expect(concealed_button.frame.height > 0);
    try std.testing.expect(!(try semanticsContainId(harness, concealed_button.widget.id)));

    try setDisclosureLayout(harness, arena.allocator(), true);
    const t0: u64 = 1_000_000_000;
    try tweenFrame(harness, app, t0);
    try tweenFrame(harness, app, t0 + 90_000_000);

    // Mid-reveal: the button's own frame may already be inside the
    // revealed band, but it must not hit-test, focus, or appear in
    // semantics until the reveal settles.
    const mid_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const mid_button = nodeByKind(mid_layout, .button) orelse return error.TestUnexpectedResult;
    const probe = geometry.PointF.init(mid_button.frame.x + 4, mid_button.frame.y + 4);
    if (mid_layout.hitTest(probe)) |hit| {
        try std.testing.expect(hit.id != mid_button.widget.id);
    }
    try std.testing.expect(mid_layout.focusTargetById(mid_button.widget.id) == null);
    try std.testing.expect(!(try semanticsContainId(harness, mid_button.widget.id)));

    // Settled open: the same probe reaches the button and semantics
    // expose it.
    try tweenFrame(harness, app, t0 + 250_000_000);
    const settled_layout = try harness.runtime.canvasWidgetLayout(1, "canvas");
    const settled_button = nodeByKind(settled_layout, .button) orelse return error.TestUnexpectedResult;
    const settled_probe = geometry.PointF.init(settled_button.frame.x + 4, settled_button.frame.y + 4);
    const settled_hit = settled_layout.hitTest(settled_probe) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(settled_button.widget.id, settled_hit.id);
    try std.testing.expect(settled_layout.focusTargetById(settled_button.widget.id) != null);
    try std.testing.expect(try semanticsContainId(harness, settled_button.widget.id));
}

test "a mid-tween frame clips the revealing content and the settled frame does not" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: QuietApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try installDisclosureView(harness, app, arena.allocator(), false);
    const accordion = try accordionNode(harness);
    const clip_id = canvas.widgetPartId(accordion.widget.id, 9);

    // Settled closed: no clip, no content commands — the static display
    // list is byte-identical to the pre-disclosure one.
    try std.testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(clip_id) == null);

    try setDisclosureLayout(harness, arena.allocator(), true);
    const t0: u64 = 1_000_000_000;
    try tweenFrame(harness, app, t0);
    try tweenFrame(harness, app, t0 + 90_000_000);

    // Mid-reveal: the content paints inside a clip pinned to the
    // accordion's animated frame (slot 9, the house clip slot), and the
    // clip rect is exactly the mid-flight frame — full-size content,
    // revealed, never re-wrapped.
    const mid_display = harness.runtime.views[0].canvasDisplayList();
    const clip_ref = mid_display.findCommandById(clip_id) orelse return error.TestUnexpectedResult;
    const mid_accordion = try accordionNode(harness);
    switch (clip_ref.command) {
        .push_clip => |clip| try std.testing.expectApproxEqAbs(mid_accordion.frame.height, clip.rect.height, 0.51),
        else => return error.TestUnexpectedResult,
    }

    // Settled open: the clip dissolves and content paints unclipped —
    // byte-identical to a tree that was always open.
    try tweenFrame(harness, app, t0 + 250_000_000);
    try std.testing.expect(harness.runtime.views[0].canvasDisplayList().findCommandById(clip_id) == null);
}

test "a runtime toggle echo arms the tween when the model's rebuild lands" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    var app_state: QuietApp = .{};
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try installDisclosureView(harness, app, arena.allocator(), false);
    const accordion = try accordionNode(harness);
    const closed_height = accordion.frame.height;

    // The automation toggle rides the SAME dispatch path as pointer and
    // keyboard toggles: the optimistic echo flips the retained state
    // and notes the disclosure toggle for the next rebuild.
    _ = try harness.runtime.dispatchCanvasWidgetAccessibilityAction(app, 1, "canvas", .{
        .id = accordion.widget.id,
        .action = .toggle,
    });

    // The model heard on_toggle and rebuilds open. The retained state
    // already agreed (the echo), so only the noted toggle can arm the
    // tween — and it does.
    try setDisclosureLayout(harness, arena.allocator(), true);
    try std.testing.expect(harness.runtime.views[0].canvasWidgetDisclosureTweenActive());
    try std.testing.expectEqual(closed_height, try accordionHeight(harness));
}

test "mid-tween frames present as region-scoped patches, not full repaints" {
    var app_state: QuietApp = .{};
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    harness.null_platform.gpu_surface_packet_binary = true;
    const app = app_state.app();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try harness.start(app);
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, surface_width, surface_height),
    });
    try setDisclosureLayout(harness, arena.allocator(), false);
    _ = try harness.runtime.emitCanvasWidgetDisplayListWithStoredTokens(1, "canvas");

    const pixel_len: usize = @as(usize, surface_width) * @as(usize, surface_height) * 4;
    const gpu_commands = try std.testing.allocator.alloc(canvas.CanvasGpuCommand, max_canvas_commands_per_view);
    defer std.testing.allocator.free(gpu_commands);
    const packet_buffer = try std.testing.allocator.alloc(u8, platform.max_gpu_surface_packet_binary_bytes);
    defer std.testing.allocator.free(packet_buffer);
    const pixels = try std.testing.allocator.alloc(u8, pixel_len);
    defer std.testing.allocator.free(pixels);
    const scratch = try std.testing.allocator.alloc(u8, pixel_len);
    defer std.testing.allocator.free(scratch);

    const presentFrame = struct {
        fn present(h: anytype, gpu: []canvas.CanvasGpuCommand, packet: []u8, px: []u8, sc: []u8, frame_index: u64) !void {
            _ = try h.runtime.presentNextCanvasFrame(1, "canvas", .{
                .frame_index = frame_index,
                .timestamp_ns = frame_index * 16_000_000,
                .surface_size = geometry.SizeF.init(surface_width, surface_height),
                .scale = 1,
            }, canvasFrameScratchStorage(&h.runtime), gpu, packet, px, sc, canvas.Color.rgb8(15, 23, 42), null);
        }
    }.present;

    // Baseline present: the first packet is necessarily full.
    try presentFrame(harness, gpu_commands, packet_buffer, pixels, scratch, 1);
    try std.testing.expect(harness.runtime.views[0].canvas_packet_baseline_valid);

    // Flip open, step the tween mid-flight, and present: the moving
    // band re-encodes as PATCH upserts against the retained baseline —
    // the static rows above the accordion never ride the wire again.
    try setDisclosureLayout(harness, arena.allocator(), true);
    const t0: u64 = 1_000_000_000;
    try tweenFrame(harness, app, t0);
    try tweenFrame(harness, app, t0 + 90_000_000);
    try presentFrame(harness, gpu_commands, packet_buffer, pixels, scratch, 2);
    const view = harness.runtime.views[0];
    try std.testing.expectEqual(platform.GpuPresentPacketMode.patch, view.gpu_present_packet_mode);
    try std.testing.expect(view.gpu_present_patch_upsert_count > 0);
    try std.testing.expect(view.gpu_present_patch_upsert_count < harness.runtime.views[0].canvasDisplayList().commands.len);
}
