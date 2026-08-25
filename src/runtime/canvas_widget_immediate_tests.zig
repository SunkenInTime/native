//! Paint-only retained widget update tests.

const support = @import("test_support.zig");
const std = support.std;
const geometry = support.geometry;
const canvas = support.canvas;
const platform = support.platform;
const runtime_module = support.runtime_module;
const App = support.App;
const TestHarness = support.TestHarness;

const ImmediateApp = struct {
    fn app(self: *@This()) App {
        return .{ .context = self, .name = "gpu-widget-immediate", .source = platform.WebViewSource.html("<h1>Hello</h1>") };
    }
};

test "immediate command batches repaint retained canvases without replacing layout" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: ImmediateApp = .{};
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 90),
    });

    const initial_commands = [_]canvas.ImmediateCanvasCommand{.{ .fill_rect = .{
        .rect = geometry.RectF.init(0, 0, 20, 10),
        .color = canvas.Color.rgba8(255, 0, 0, 255),
    } }};
    const children = [_]canvas.Widget{.{
        .id = 2,
        .kind = .stack,
        .frame = geometry.RectF.init(10, 10, 80, 40),
        .immediate_commands = &initial_commands,
    }};
    var nodes: [2]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(.{ .id = 1, .kind = .stack, .children = &children }, geometry.RectF.init(0, 0, 160, 90), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", canvas.DesignTokens.theme(.{}));

    const updated_commands = [_]canvas.ImmediateCanvasCommand{
        .{ .fill_rect = .{
            .rect = geometry.RectF.init(0, 0, 30, 10),
            .color = canvas.Color.rgba8(0, 255, 0, 255),
        } },
        .{ .fill_rect = .{
            .rect = geometry.RectF.init(0, 12, 30, 10),
            .color = canvas.Color.rgba8(0, 0, 255, 255),
        } },
    };
    const updates = [_]runtime_module.CanvasWidgetImmediateUpdate{.{
        .id = 2,
        .commands = &updated_commands,
    }};
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetImmediateCommands(1, "canvas", &updates);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqual(@as(usize, 2), retained.findById(2).?.widget.immediate_commands.len);
    try std.testing.expect(harness.runtime.invalidated);
    try std.testing.expect(harness.runtime.pendingDirtyRegions().len > 0);

    const bad = [_]runtime_module.CanvasWidgetImmediateUpdate{.{ .id = 99, .commands = &initial_commands }};
    try std.testing.expectError(error.InvalidCommand, harness.runtime.setCanvasWidgetImmediateCommands(1, "canvas", &bad));
    try std.testing.expectEqual(@as(usize, 2), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.immediate_commands.len);

    const duplicate = [_]runtime_module.CanvasWidgetImmediateUpdate{
        .{ .id = 2, .commands = &initial_commands },
        .{ .id = 2, .commands = &initial_commands },
    };
    try std.testing.expectError(error.InvalidCommand, harness.runtime.setCanvasWidgetImmediateCommands(1, "canvas", &duplicate));
    try std.testing.expectEqual(@as(usize, 2), (try harness.runtime.canvasWidgetLayout(1, "canvas")).findById(2).?.widget.immediate_commands.len);

    // Animation ownership is separate from paint diffing. The same command
    // batch can be the honest output of two successive animation callbacks;
    // its caller must be able to request the next surface tick explicitly.
    harness.null_platform.gpu_surface_frame_request_count = 0;
    _ = try harness.runtime.setCanvasWidgetImmediateCommands(1, "canvas", &updates);
    const requests_after_identical_batch = harness.null_platform.gpu_surface_frame_request_count;
    _ = try harness.runtime.requestCanvasFrame(1, "canvas");
    try std.testing.expectEqual(requests_after_identical_batch + 1, harness.null_platform.gpu_surface_frame_request_count);
}
