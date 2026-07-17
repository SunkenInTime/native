//! Physical AppKit window-policy harness: three layers x two input modes.
//! Every window is transparent, chromeless, nonactivating, and backed by
//! a premultiplied Metal gpu_surface. Run with NATIVE_SDK_WINDOW_POLICY=1
//! to correlate the visible matrix with the host's resolved policy log.

const std = @import("std");
const runner = @import("runner");
const native_sdk = @import("native_sdk");

pub const panic = std.debug.FullPanic(native_sdk.debug.capturePanic);

const canvas = native_sdk.canvas;
const geometry = native_sdk.geometry;

const window_width: f32 = 280;
const window_height: f32 = 160;
const canvas_label = "canvas";

const shell_views = [_]native_sdk.ShellView{.{
    .label = canvas_label,
    .kind = .gpu_surface,
    .fill = true,
    .role = "macOS window policy card",
    .accessibility_label = "macOS widget window policy harness",
    .gpu_backend = .metal,
    .gpu_pixel_format = .bgra8_unorm,
    .gpu_present_mode = .timer,
    .gpu_alpha_mode = .premultiplied,
    .gpu_color_space = .srgb,
    .gpu_vsync = true,
}};

fn widgetWindow(comptime label: []const u8, comptime title: []const u8, x: f32, y: f32, layer: native_sdk.app_manifest.WindowLayer, click_through: bool) native_sdk.ShellWindow {
    return .{
        .label = label,
        .title = title,
        .x = x,
        .y = y,
        .width = window_width,
        .height = window_height,
        .resizable = false,
        .restore_state = true,
        .titlebar = .chromeless,
        .transparent = true,
        .layer = layer,
        .click_through = click_through,
        .no_activate = true,
        .views = &shell_views,
    };
}

const shell_windows = [_]native_sdk.ShellWindow{
    widgetWindow("bottom-input", "Bottom interactive", 40, 80, .bottom, false),
    widgetWindow("bottom-pass", "Bottom pass-through", 40, 300, .bottom, true),
    widgetWindow("normal-input", "Normal interactive", 370, 80, .normal, false),
    widgetWindow("normal-pass", "Normal pass-through", 370, 300, .normal, true),
    widgetWindow("topmost-input", "Topmost interactive", 700, 80, .topmost, false),
    widgetWindow("topmost-pass", "Topmost pass-through", 700, 300, .topmost, true),
};
const shell_scene: native_sdk.ShellConfig = .{ .windows = &shell_windows };

const Model = struct {};
const Msg = union(enum) { pressed };
const HarnessApp = native_sdk.UiApp(Model, Msg);
const Ui = canvas.Ui(Msg);

fn update(model: *Model, msg: Msg) void {
    _ = model;
    _ = msg;
}

fn view(ui: *Ui, model: *const Model) Ui.Node {
    _ = model;
    return ui.column(.{
        .grow = 1,
        .padding = 10,
        .style_tokens = .{ .background = .background },
    }, .{
        ui.panel(.{
            .grow = 1,
            .padding = 18,
            .style_tokens = .{ .background = .surface, .border_color = .border, .radius = .lg },
        }, .{
            ui.column(.{ .grow = 1, .gap = 8 }, .{
                ui.text(.{ .size = .lg }, "AppKit widget"),
                ui.text(.{ .style_tokens = .{ .foreground = .text_muted } }, "transparent • chromeless • no-activate"),
                ui.button(.{ .on_press = .pressed }, "Input probe"),
            }),
        }),
    });
}

fn transparentTokens() canvas.DesignTokens {
    var tokens = canvas.DesignTokens.theme(.{ .color_scheme = .dark });
    tokens.colors.background = canvas.Color.rgba8(0, 0, 0, 0);
    tokens.colors.surface = canvas.Color.rgba8(18, 24, 38, 224);
    tokens.colors.surface_subtle = canvas.Color.rgba8(255, 255, 255, 22);
    tokens.colors.border = canvas.Color.rgba8(255, 255, 255, 48);
    tokens.colors.text = canvas.Color.rgb8(248, 250, 252);
    tokens.colors.text_muted = canvas.Color.rgb8(148, 163, 184);
    return tokens;
}

pub fn main(init: std.process.Init) !void {
    const app_state = try std.heap.page_allocator.create(HarnessApp);
    defer std.heap.page_allocator.destroy(app_state);
    app_state.* = HarnessApp.init(std.heap.page_allocator, .{}, .{
        .name = "macos-widget-windowing",
        .scene = shell_scene,
        .canvas_label = canvas_label,
        .tokens = transparentTokens(),
        .update = update,
        .view = view,
    });
    defer app_state.deinit();

    try runner.runWithOptions(app_state.app(), .{
        .app_name = "macos-widget-windowing",
        .window_title = "macOS Widget Windowing",
        .bundle_id = "dev.native_sdk.macos_widget_windowing",
        .default_frame = geometry.RectF.init(40, 80, window_width, window_height),
        .restore_state = true,
        .js_window_api = false,
        .security = .{ .permissions = &.{native_sdk.security.permission_view} },
    }, init);
}

test "harness covers every layer and input combination" {
    try std.testing.expectEqual(@as(usize, 6), shell_windows.len);
    inline for (.{ native_sdk.app_manifest.WindowLayer.bottom, .normal, .topmost }) |layer| {
        var interactive = false;
        var pass_through = false;
        inline for (shell_windows) |window| {
            if (window.layer != layer) continue;
            interactive = interactive or !window.click_through;
            pass_through = pass_through or window.click_through;
            try std.testing.expect(window.transparent);
            try std.testing.expect(window.no_activate);
            try std.testing.expectEqual(native_sdk.app_manifest.WindowTitlebarStyle.chromeless, window.titlebar);
            try std.testing.expectEqual(native_sdk.app_manifest.GpuSurfaceAlphaMode.premultiplied, window.views[0].gpu_alpha_mode.?);
        }
        try std.testing.expect(interactive);
        try std.testing.expect(pass_through);
    }
}
