//! Deterministic gradient reference catalog.
//!
//! This is deliberately a reference-renderer receipt, not a golden oracle:
//! the manifest names the renderer and records exact sample pixels, while
//! independent spec fixtures live in tests. Platform capture can render the
//! same catalog later and compare against both. Keeping those three facts
//! separate prevents a bug shared by the model and the reference renderer
//! from silently becoming the expected result.
//!
//! Run from the Native SDK root:
//!
//!   zig build gradient-reference -- /tmp/native-sdk-gradient-reference

const std = @import("std");
const native_sdk = @import("native_sdk");

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;
const platform = native_sdk.platform;

const view_label = "gradient-reference";
const width: usize = 128;
const height: usize = 64;
const sample_count = 5;

// Stay inside the panel's rounded edge antialiasing. The catalog still
// exercises the rounded clip visually, while semantic samples measure paint.
const sample_x = [sample_count]usize{ 8, 32, 64, 96, 119 };
const sample_y: usize = height / 2;

const opaque_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = canvas.Color.rgb8(255, 0, 0) },
    .{ .offset = 1, .color = canvas.Color.rgb8(0, 0, 255) },
};
const transparent_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = canvas.Color.rgba8(255, 0, 0, 0) },
    .{ .offset = 1, .color = canvas.Color.rgba8(0, 0, 255, 255) },
};
const sharp_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = canvas.Color.rgb8(245, 158, 11) },
    .{ .offset = 0.5, .color = canvas.Color.rgb8(245, 158, 11) },
    .{ .offset = 0.5, .color = canvas.Color.rgb8(37, 99, 235) },
    .{ .offset = 1, .color = canvas.Color.rgb8(37, 99, 235) },
};
const offset_stops = [_]canvas.GradientStop{
    .{ .offset = 0.2, .color = canvas.Color.rgb8(16, 185, 129) },
    .{ .offset = 0.75, .color = canvas.Color.rgb8(168, 85, 247) },
};
const single_stop = [_]canvas.GradientStop{
    .{ .offset = 0.4, .color = canvas.Color.rgba8(244, 63, 94, 192) },
};
const spectrum_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = canvas.Color.rgb8(239, 68, 68) },
    .{ .offset = 0.33, .color = canvas.Color.rgb8(250, 204, 21) },
    .{ .offset = 0.66, .color = canvas.Color.rgb8(34, 197, 94) },
    .{ .offset = 1, .color = canvas.Color.rgb8(59, 130, 246) },
};
const repeating_stops = [_]canvas.GradientStop{
    .{ .offset = 0, .color = canvas.Color.rgb8(15, 23, 42) },
    .{ .offset = 0.12, .color = canvas.Color.rgb8(15, 23, 42) },
    .{ .offset = 0.12, .color = canvas.Color.rgb8(56, 189, 248) },
    .{ .offset = 0.24, .color = canvas.Color.rgb8(56, 189, 248) },
};

const Scene = struct {
    name: []const u8,
    gradient: canvas.WidgetGradient,

    fn kind(self: Scene) []const u8 {
        return @tagName(self.gradient);
    }
};

const scenes = [_]Scene{
    .{ .name = "opaque-horizontal", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0.5), .end = geometry.PointF.init(1, 0.5), .stops = &opaque_stops } } },
    .{ .name = "transparent-horizontal", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0.5), .end = geometry.PointF.init(1, 0.5), .stops = &transparent_stops } } },
    .{ .name = "oklab-horizontal", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0.5), .end = geometry.PointF.init(1, 0.5), .stops = &opaque_stops, .interpolation = .oklab } } },
    .{ .name = "sharp-stop", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0.5), .end = geometry.PointF.init(1, 0.5), .stops = &sharp_stops } } },
    .{ .name = "arbitrary-angle", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(1, 1), .stops = &offset_stops } } },
    .{ .name = "repeating-linear", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0.5), .end = geometry.PointF.init(1, 0.5), .stops = &repeating_stops, .spread = .repeat, .interpolation = .srgb } } },
    .{ .name = "radial-ellipse", .gradient = .{ .radial = .{ .center = geometry.PointF.init(0.5, 0.5), .radii = geometry.SizeF.init(0.5, 0.5), .stops = &spectrum_stops, .interpolation = .oklab } } },
    .{ .name = "repeating-radial", .gradient = .{ .radial = .{ .center = geometry.PointF.init(0.5, 0.5), .radii = geometry.SizeF.init(0.5, 0.5), .stops = &repeating_stops, .spread = .repeat, .interpolation = .srgb } } },
    .{ .name = "conic", .gradient = .{ .conic = .{ .center = geometry.PointF.init(0.5, 0.5), .start_angle_radians = -@as(f32, std.math.pi) / 2, .stops = &spectrum_stops, .interpolation = .oklab } } },
    .{ .name = "repeating-conic", .gradient = .{ .conic = .{ .center = geometry.PointF.init(0.5, 0.5), .start_angle_radians = -@as(f32, std.math.pi) / 2, .stops = &repeating_stops, .spread = .repeat, .interpolation = .srgb } } },
    .{ .name = "degenerate-line", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0.5, 0.5), .end = geometry.PointF.init(0.5, 0.5), .stops = &opaque_stops } } },
    .{ .name = "single-stop", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(1, 1), .stops = &single_stop } } },
    .{ .name = "empty-stops", .gradient = .{ .linear = .{ .start = geometry.PointF.init(0, 0), .end = geometry.PointF.init(1, 1), .stops = &.{} } } },
};

const CatalogApp = struct {
    fn app(self: *@This()) native_sdk.App {
        return .{
            .context = self,
            .name = "gradient-reference-catalog",
            .source = platform.WebViewSource.html("<h1>gradient reference</h1>"),
        };
    }
};

const Sample = struct {
    x: usize,
    y: usize,
    rgba8: [4]u8,
};

const RenderedScene = struct {
    samples: [sample_count]Sample,
};

fn renderScene(
    gpa: std.mem.Allocator,
    io: std.Io,
    scene: Scene,
    png_path: []const u8,
) !RenderedScene {
    const harness = try native_sdk.TestHarness().create(gpa, .{ .size = geometry.SizeF.init(width, height) });
    defer harness.destroy(gpa);
    harness.null_platform.gpu_surfaces = true;
    var app_state: CatalogApp = .{};
    const app = app_state.app();
    try harness.start(app);

    _ = try harness.runtime.createView(.{
        .window_id = 1,
        .label = view_label,
        .kind = .gpu_surface,
        .frame = geometry.RectF.init(0, 0, width, height),
    });

    const effects = [_]canvas.ImmediateCanvasCommand{.{ .background_gradient = scene.gradient }};
    const root = canvas.Widget{
        .id = 1,
        .kind = .panel,
        .immediate_commands = &effects,
    };
    var nodes: [1]canvas.WidgetLayoutNode = undefined;
    const layout = try canvas.layoutWidgetTree(root, geometry.RectF.init(0, 0, width, height), &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, view_label, layout);
    _ = try harness.runtime.emitCanvasWidgetDisplayList(1, view_label, .{});

    const pixel_size = try harness.runtime.canvasScreenshotPixelSize(1, view_label, 1);
    const pixels = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(pixels);
    const scratch = try gpa.alloc(u8, pixel_size.byte_len);
    defer gpa.free(scratch);
    const screenshot = try harness.runtime.renderCanvasScreenshot(1, view_label, 1, pixels, scratch);
    if (screenshot.width != width or screenshot.height != height) return error.UnexpectedScreenshotSize;

    const encoded = try gpa.alloc(u8, try canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height));
    defer gpa.free(encoded);
    var png_writer = std.Io.Writer.fixed(encoded);
    try canvas.png.writeRgba8(&png_writer, screenshot.width, screenshot.height, screenshot.rgba8);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = png_path, .data = png_writer.buffered() });

    var rendered: RenderedScene = undefined;
    for (sample_x, 0..) |x, index| {
        const pixel_offset = (sample_y * width + x) * 4;
        rendered.samples[index] = .{
            .x = x,
            .y = sample_y,
            .rgba8 = screenshot.rgba8[pixel_offset..][0..4].*,
        };
    }
    return rendered;
}

fn writeSampleJson(js: *std.json.Stringify, sample: Sample) !void {
    try js.beginObject();
    try js.objectField("x");
    try js.write(sample.x);
    try js.objectField("y");
    try js.write(sample.y);
    try js.objectField("rgba8");
    try js.beginArray();
    for (sample.rgba8) |channel| try js.write(channel);
    try js.endArray();
    try js.endObject();
}

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const out_dir = if (args.len > 1) args[1] else "/tmp/native-sdk-gradient-reference";

    try std.Io.Dir.cwd().createDirPath(init.io, out_dir);

    var manifest: std.Io.Writer.Allocating = .init(init.gpa);
    defer manifest.deinit();
    var js: std.json.Stringify = .{ .writer = &manifest.writer, .options = .{ .whitespace = .indent_2 } };
    try js.beginObject();
    try js.objectField("schemaVersion");
    try js.write(1);
    try js.objectField("renderer");
    try js.write("native-reference");
    try js.objectField("normative");
    try js.write(false);
    try js.objectField("note");
    try js.write("Reference output is a regression receipt, not the independent semantics oracle.");
    try js.objectField("scenes");
    try js.beginArray();

    for (scenes) |scene| {
        const png_path = try std.fmt.allocPrint(arena, "{s}/{s}.png", .{ out_dir, scene.name });
        const rendered = try renderScene(init.gpa, init.io, scene, png_path);
        try js.beginObject();
        try js.objectField("name");
        try js.write(scene.name);
        try js.objectField("kind");
        try js.write(scene.kind());
        try js.objectField("png");
        try js.write(try std.fmt.allocPrint(arena, "{s}.png", .{scene.name}));
        try js.objectField("width");
        try js.write(width);
        try js.objectField("height");
        try js.write(height);
        try js.objectField("samples");
        try js.beginArray();
        for (rendered.samples) |sample| try writeSampleJson(&js, sample);
        try js.endArray();
        try js.endObject();
    }

    try js.endArray();
    try js.endObject();
    const manifest_path = try std.fmt.allocPrint(arena, "{s}/manifest.json", .{out_dir});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = manifest_path, .data = manifest.written() });
    std.debug.print("gradient-reference: wrote {d} scenes and manifest to {s}\n", .{ scenes.len, out_dir });
}
