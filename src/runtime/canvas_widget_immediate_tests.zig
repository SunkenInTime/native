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

const OwnedPayloads = struct {
    placeholder: [16]u8 = "Search notes....".*,
    points: [3]geometry.PointF = .{ geometry.PointF.init(0, 0), geometry.PointF.init(10, 20), geometry.PointF.init(30, 5) },
    elements: [3]canvas.PathElement = .{
        .{ .verb = .move_to, .points = .{ geometry.PointF.init(2, 2), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(22, 2), geometry.PointF.zero(), geometry.PointF.zero() } },
        .{ .verb = .line_to, .points = .{ geometry.PointF.init(12, 20), geometry.PointF.zero(), geometry.PointF.zero() } },
    },
    stops: [2]canvas.GradientStop = .{
        .{ .offset = 0, .color = canvas.Color.rgba8(255, 0, 0, 255) },
        .{ .offset = 1, .color = canvas.Color.rgba8(0, 0, 255, 255) },
    },
    patches: [1]canvas.WidgetMeshPatch = .{.{
        .points = meshPoints(),
        .colors = .{ canvas.Color.rgba8(255, 0, 0, 255), canvas.Color.rgba8(0, 255, 0, 255), canvas.Color.rgba8(0, 0, 255, 255), canvas.Color.rgba8(255, 255, 0, 255) },
    }},
    canvas_commands: [2]canvas.ImmediateCanvasCommand = undefined,
    icon_commands: [1]canvas.ImmediateCanvasCommand = undefined,
    panel_commands: [2]canvas.ImmediateCanvasCommand = undefined,
    children: [4]canvas.Widget = undefined,

    fn meshPoints() [16]geometry.PointF {
        var points: [16]geometry.PointF = undefined;
        for (&points, 0..) |*point, index| {
            point.* = geometry.PointF.init(@as(f32, @floatFromInt(index % 4)) / 3, @as(f32, @floatFromInt(index / 4)) / 3);
        }
        return points;
    }

    /// Point every widget slice at this struct's own arrays, the way an
    /// app's tree points into the memory it built the tree in.
    fn root(self: *OwnedPayloads) canvas.Widget {
        self.canvas_commands = .{
            .{ .fill_rect = .{ .rect = geometry.RectF.init(0, 0, 20, 10), .color = canvas.Color.rgba8(255, 0, 0, 255) } },
            .{ .polyline = .{ .points = &self.points, .width = 2, .color = canvas.Color.rgba8(0, 255, 0, 255) } },
        };
        self.icon_commands = .{.{ .icon_path = .{ .elements = &self.elements, .stroke_width = 2 } }};
        self.panel_commands = .{
            .{ .background_gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(1, 0), .stops = &self.stops } } },
            .{ .background_mesh_gradient = .{ .patches = &self.patches } },
        };
        self.children = .{
            .{ .id = 2, .kind = .text_field, .frame = geometry.RectF.init(0, 0, 160, 24), .placeholder = &self.placeholder },
            .{ .id = 3, .kind = .stack, .frame = geometry.RectF.init(0, 30, 80, 40), .immediate_commands = &self.canvas_commands },
            .{ .id = 4, .kind = .icon, .frame = geometry.RectF.init(90, 30, 24, 24), .immediate_commands = &self.icon_commands },
            .{ .id = 5, .kind = .panel, .frame = geometry.RectF.init(0, 80, 160, 40), .immediate_commands = &self.panel_commands },
        };
        return .{ .id = 1, .kind = .stack, .children = &self.children };
    }
};

test "a retained layout owns its placeholders and immediate command payloads" {
    const harness = try TestHarness().create(std.testing.allocator, .{});
    defer harness.destroy(std.testing.allocator);
    harness.null_platform.gpu_surfaces = true;
    var app_state: ImmediateApp = .{};
    try harness.start(app_state.app());
    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = "canvas",
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, 160, 120),
    });
    const tokens = canvas.DesignTokens.theme(.{});

    var source: OwnedPayloads = .{};
    var nodes: [5]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(source.root(), geometry.RectF.init(0, 0, 160, 120), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", tokens);

    // The app reuses the memory it built the tree in. The runtime's
    // retained layout must not change with it.
    const expected: OwnedPayloads = .{};
    @memset(&source.placeholder, 'x');
    for (&source.points) |*point| point.* = geometry.PointF.init(-1, -1);
    for (&source.elements) |*element| element.verb = .close;
    for (&source.stops) |*stop| stop.offset = 0.5;
    source.patches[0].colors[0] = canvas.Color.rgba8(0, 0, 0, 0);
    @memset(std.mem.sliceAsBytes(&source.canvas_commands), 0xaa);
    @memset(std.mem.sliceAsBytes(&source.icon_commands), 0xaa);
    @memset(std.mem.sliceAsBytes(&source.panel_commands), 0xaa);

    const retained = try harness.runtime.canvasWidgetLayout(1, "canvas");
    try std.testing.expectEqualStrings(&expected.placeholder, retained.findById(2).?.widget.placeholder);
    const canvas_commands = retained.findById(3).?.widget.immediate_commands;
    try std.testing.expectEqual(@as(usize, 2), canvas_commands.len);
    try std.testing.expectEqual(@as(f32, 20), canvas_commands[0].fill_rect.rect.width);
    try std.testing.expectEqualSlices(geometry.PointF, &expected.points, canvas_commands[1].polyline.points);
    try std.testing.expectEqualSlices(canvas.PathElement, &expected.elements, retained.findById(4).?.widget.immediate_commands[0].icon_path.elements);
    const panel_commands = retained.findById(5).?.widget.immediate_commands;
    try std.testing.expectEqualSlices(canvas.GradientStop, &expected.stops, panel_commands[0].background_gradient.linear.stops);
    try std.testing.expectEqualSlices(canvas.WidgetMeshPatch, &expected.patches, panel_commands[1].background_mesh_gradient.patches);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, "canvas", tokens);

    // The same tree built again in other memory is not a change: the
    // payloads compare by content, so nothing repaints.
    var rebuilt: OwnedPayloads = .{};
    var rebuilt_nodes: [5]canvas.WidgetLayoutNode = undefined;
    const rebuilt_layout = try canvas.layoutWidgetTree(rebuilt.root(), geometry.RectF.init(0, 0, 160, 120), &rebuilt_nodes);
    harness.runtime.invalidated = false;
    harness.runtime.dirty_region_count = 0;
    _ = try harness.runtime.setCanvasWidgetLayout(1, "canvas", rebuilt_layout);
    try std.testing.expectEqual(@as(usize, 0), harness.runtime.pendingDirtyRegions().len);
}
