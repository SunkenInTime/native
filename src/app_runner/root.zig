const std = @import("std");
const build_options = @import("build_options");
const native_sdk = @import("native_sdk");
const app_manifest = @import("app_manifest_zon");
const manifest_shortcuts = if (@hasField(@TypeOf(app_manifest), "shortcuts")) app_manifest.shortcuts else .{};
const manifest_windows = if (@hasField(@TypeOf(app_manifest), "windows")) app_manifest.windows else .{};

pub const StdoutTraceSink = struct {
    pub fn sink(self: *StdoutTraceSink) native_sdk.trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: native_sdk.trace.Record) native_sdk.trace.WriteError!void {
        _ = context;
        // Never fail on an oversized record: a trace-formatting failure
        // inside dispatch must degrade (truncated output), not become an
        // error the platform callback treats as fatal.
        var buffer: [4096]u8 = undefined;
        std.debug.print("{s}\n", .{native_sdk.trace.formatTextBounded(record, &buffer)});
    }
};

pub const FilteredTraceSink = struct {
    child: native_sdk.trace.Sink,

    pub fn sink(self: *FilteredTraceSink) native_sdk.trace.Sink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, record: native_sdk.trace.Record) native_sdk.trace.WriteError!void {
        const self: *FilteredTraceSink = @ptrCast(@alignCast(context));
        if (!shouldTrace(record)) return;
        try self.child.write(record);
    }
};

pub const RunOptions = struct {
    app_name: []const u8,
    window_title: []const u8 = "",
    bundle_id: []const u8,
    // Dev-run Dock icon file. The scaffold's one-image contract puts a
    // square PNG here; a prebuilt .icns path works too. When no file
    // exists at this path, unbundled macOS runs render the toolkit's
    // embedded default icon — the same fallback `native package` ships —
    // so apps without a custom icon carry no committed copy to go stale.
    icon_path: []const u8 = "assets/icon.png",
    default_frame: native_sdk.geometry.RectF = native_sdk.geometry.RectF.init(0, 0, 1100, 760),
    restore_state: bool = true,
    /// When false, skip both restoring and recording the runner's
    /// bundle-scoped window state. Embedders that own a more specific
    /// placement store use this to keep one persistence authority.
    persist_window_state: bool = true,
    primary_display_anchor: ?native_sdk.PrimaryDisplayAnchor = null,
    bridge: ?native_sdk.BridgeDispatcher = null,
    builtin_bridge: native_sdk.BridgePolicy = .{},
    js_window_api: bool = false,
    security: native_sdk.SecurityPolicy = .{},
    menus: []const native_sdk.Menu = &.{},
    shortcuts: ?[]const native_sdk.Shortcut = null,

    fn appInfo(self: RunOptions, buffers: *StateBuffers) native_sdk.AppInfo {
        var info: native_sdk.AppInfo = .{
            .app_name = self.app_name,
            // The identity the OS shows (application menu, Dock, About
            // panel) reads straight from app.zon at comptime, so dev
            // runs carry the same display name and version a packaged
            // bundle gets from its Info.plist.
            .display_name = manifestStringField("display_name"),
            .version = manifestStringField("version"),
            .description = manifestStringField("description"),
            .has_web_content = manifestHasWebContent(),
            .window_title = self.window_title,
            .bundle_id = self.bundle_id,
            .icon_path = self.icon_path,
            .main_window = .{
                .id = 1,
                .label = "main",
                .title = self.window_title,
                .default_frame = self.default_frame,
                .restore_state = self.restore_state,
            },
        };
        const windows = manifestWindowOptions(buffers);
        if (windows.len > 0) {
            info.main_window = windows[0];
            info.windows = windows;
        } else {
            // Scene-first apps declare their one window under
            // `.shell.windows` — the startup window the host creates
            // adopts that declaration when the scene loads, but its
            // CHROME is fixed at create time, so the manifest's
            // titlebar style threads through here. Same for visibility:
            // a canvas-first startup window is created ordered-out and
            // shown after its first canvas frame presents, so launch
            // never flashes a blank window.
            info.main_window.titlebar = manifestShellStartupTitlebar();
            info.main_window.resizable = manifestShellStartupResizable();
            info.main_window.show = manifestShellStartupShowMode();
            info.main_window.transparent = manifestShellStartupBool("transparent", false);
            info.main_window.layer = manifestShellStartupLayer();
            info.main_window.click_through = manifestShellStartupBool("click_through", false);
            info.main_window.no_activate = manifestShellStartupBool("no_activate", false);
            // Min-size floors ride the create call like the titlebar:
            // the scene re-applies size/title later, but the window's
            // enforced floor is host state from the first frame on.
            info.main_window.min_width = manifestShellStartupMinSize("min_width");
            info.main_window.min_height = manifestShellStartupMinSize("min_height");
        }
        info.main_window.primary_display_anchor = self.primary_display_anchor;
        if (windows.len > 0) buffers.restored_windows[0].primary_display_anchor = self.primary_display_anchor;
        return info;
    }

    fn resolvedShortcuts(self: RunOptions, storage: *ShortcutStorage) []const native_sdk.Shortcut {
        return self.shortcuts orelse storage.fromManifest();
    }
};

const ShortcutStorage = struct {
    shortcuts: [native_sdk.platform.max_shortcuts]native_sdk.Shortcut = undefined,

    fn fromManifest(self: *ShortcutStorage) []const native_sdk.Shortcut {
        comptime {
            if (manifest_shortcuts.len > native_sdk.platform.max_shortcuts) {
                @compileError("app.zon defines too many shortcuts");
            }
        }

        inline for (manifest_shortcuts, 0..) |shortcut, index| {
            self.shortcuts[index] = .{
                .id = shortcut.id,
                .key = shortcut.key,
                .modifiers = shortcutModifiers(shortcut),
            };
        }
        return self.shortcuts[0..manifest_shortcuts.len];
    }
};

fn manifestWindowOptions(buffers: *StateBuffers) []const native_sdk.WindowOptions {
    comptime {
        if (manifest_windows.len > native_sdk.platform.max_windows) {
            @compileError("app.zon defines too many windows");
        }
    }

    inline for (manifest_windows, 0..) |window, index| {
        buffers.restored_windows[index] = manifestWindow(window, index);
    }
    return buffers.restored_windows[0..manifest_windows.len];
}

fn manifestWindow(comptime window: anytype, comptime index: usize) native_sdk.WindowOptions {
    return .{
        .id = index + 1,
        .label = windowLabel(window, index),
        .title = windowTitle(window),
        .default_frame = native_sdk.geometry.RectF.init(
            windowFloat(window, "x", 0),
            windowFloat(window, "y", 0),
            windowFloat(window, "width", 720),
            windowFloat(window, "height", 480),
        ),
        .resizable = windowBool(window, "resizable", true),
        .restore_state = windowBool(window, "restore_state", true),
        .restore_policy = windowRestorePolicy(window),
        .titlebar = windowTitlebarStyle(window),
        .min_width = windowMinSize(window, "min_width"),
        .min_height = windowMinSize(window, "min_height"),
    };
}

/// Window-enforced content min-size floor from app.zon. Validated at
/// comptime like the titlebar style: a negative floor is an authoring
/// error, not a silent clamp.
fn windowMinSize(comptime window: anytype, comptime field: []const u8) f32 {
    const value: f32 = comptime windowFloat(window, field, 0);
    comptime {
        if (!(value >= 0)) @compileError("app.zon window " ++ field ++ " must be non-negative");
    }
    return value;
}

fn windowTitlebarStyle(comptime window: anytype) native_sdk.WindowTitlebarStyle {
    if (comptime !@hasField(@TypeOf(window), "titlebar")) return .standard;
    const value = window.titlebar;
    if (comptime std.mem.eql(u8, value, "standard")) return .standard;
    if (comptime std.mem.eql(u8, value, "hidden_inset")) return .hidden_inset;
    if (comptime std.mem.eql(u8, value, "hidden_inset_tall")) return .hidden_inset_tall;
    if (comptime std.mem.eql(u8, value, "chromeless")) return .chromeless;
    @compileError("unknown app.zon window titlebar style");
}

/// The startup window's titlebar style for scene-first apps: app.zon's
/// `.shell.windows[0].titlebar`. Chrome cannot change after the host
/// creates the window, so it must ride the create call — unlike
/// size/title, which the loading scene re-applies.
fn manifestShellStartupTitlebar() native_sdk.WindowTitlebarStyle {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return .standard;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return .standard;
    if (comptime shell.windows.len == 0) return .standard;
    return windowTitlebarStyle(shell.windows[0]);
}

/// The startup window's resizability for scene-first apps: like the
/// titlebar style, resizable is window chrome fixed at create time.
fn manifestShellStartupResizable() bool {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return true;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return true;
    if (comptime shell.windows.len == 0) return true;
    return windowBool(shell.windows[0], "resizable", true);
}

fn manifestShellStartupBool(comptime field: []const u8, comptime fallback: bool) bool {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return fallback;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return fallback;
    if (comptime shell.windows.len == 0) return fallback;
    return windowBool(shell.windows[0], field, fallback);
}

fn manifestShellStartupLayer() native_sdk.WindowLayer {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return .normal;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return .normal;
    if (comptime shell.windows.len == 0) return .normal;
    const window = shell.windows[0];
    if (comptime !@hasField(@TypeOf(window), "layer")) return .normal;
    const value = window.layer;
    if (comptime std.mem.eql(u8, value, "normal")) return .normal;
    if (comptime std.mem.eql(u8, value, "bottom")) return .bottom;
    if (comptime std.mem.eql(u8, value, "topmost")) return .topmost;
    @compileError("unknown app.zon window layer");
}

/// The startup window's content min-size floor for scene-first apps:
/// app.zon's `.shell.windows[0].min_width`/`.min_height` (0 = none).
fn manifestShellStartupMinSize(comptime field: []const u8) f32 {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return 0;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return 0;
    if (comptime shell.windows.len == 0) return 0;
    return windowMinSize(shell.windows[0], field);
}

/// Present-before-show for the STARTUP window: when app.zon's first
/// shell window hosts a canvas (`gpu_surface` view), the host creates
/// it ordered-out and it becomes visible after the first canvas frame
/// presents. Webview-first startup windows keep immediate visibility.
fn manifestShellStartupShowMode() native_sdk.WindowShowMode {
    if (comptime !@hasField(@TypeOf(app_manifest), "shell")) return .immediate;
    const shell = app_manifest.shell;
    if (comptime !@hasField(@TypeOf(shell), "windows")) return .immediate;
    if (comptime shell.windows.len == 0) return .immediate;
    const window = shell.windows[0];
    if (comptime !@hasField(@TypeOf(window), "views")) return .immediate;
    inline for (window.views) |view| {
        if (comptime @hasField(@TypeOf(view), "kind")) {
            if (comptime std.mem.eql(u8, view.kind, "gpu_surface")) return .on_first_present;
        }
    }
    return .immediate;
}

/// A top-level app.zon string field (`display_name`, `version`,
/// `description`), or "" when the manifest omits it — optional identity
/// stays optional all the way into `AppInfo`.
fn manifestStringField(comptime field: []const u8) []const u8 {
    if (comptime !@hasField(@TypeOf(app_manifest), field)) return "";
    const value = @field(app_manifest, field);
    if (comptime @TypeOf(value) == @TypeOf(null)) return "";
    return value;
}

/// The theme pack app.zon selects (`theme = "geist"`), resolved at
/// comptime so an unknown name is a build error naming the field and
/// the valid packs — never a silent fallback. Absent means the house
/// register. Apps hand this to their `UiApp` options' `theme` field;
/// the pack then composes with the live system appearance, so packed
/// apps still re-theme on the OS light/dark flip.
pub fn manifestThemePack() native_sdk.canvas.ThemePack {
    if (comptime !@hasField(@TypeOf(app_manifest), "theme")) return .house;
    const name: []const u8 = app_manifest.theme;
    return comptime native_sdk.canvas.ThemePack.fromName(name) orelse
        @compileError("unknown app.zon theme \"" ++ name ++ "\" — expected one of: house, geist");
}

/// Whether app.zon declares web content — the shared declare-to-use
/// contract (`native_sdk.app_manifest.web_layer`) over the comptime
/// manifest import: a `.frontend` block, the `"webview"` capability, a
/// `.shell` webview view, or `.web_engine = "chromium"`. Hosts build
/// honest default menus from this — web items like Reload only exist
/// when a webview can answer them, so canvas-only apps never ship dead
/// menu items.
fn manifestHasWebContent() bool {
    return manifestWebDeclaration() != null;
}

/// The first web declaration visible in app.zon, evaluated at comptime.
/// The engine input here is the MANIFEST engine: the runner never sees
/// the `-Dweb-engine` flag, so an engine resolved to Chromium by flag
/// alone is out of this boundary's reach — the standard build graph
/// (build/app.zig), which does see the flag, owns that configure-time
/// error. See the contract's module doc for the full ownership split.
fn manifestWebDeclaration() ?native_sdk.app_manifest.web_layer.Declaration {
    const engine: native_sdk.app_manifest.WebEngine = comptime blk: {
        if (!@hasField(@TypeOf(app_manifest), "web_engine")) break :blk .system;
        break :blk native_sdk.app_manifest.web_layer.parseWebEngine(app_manifest.web_engine) orelse .system;
    };
    return comptime native_sdk.app_manifest.web_layer.webDeclaration(app_manifest, engine);
}

/// Whether this build ships the embedded web layer. The standard build
/// graph (build/app.zig) infers it from app.zon and passes it through
/// build options; an options module from an older hand-rolled build.zig
/// that predates the option keeps the layer — over-inclusion is safe.
fn webLayerEnabled() bool {
    if (comptime !@hasDecl(build_options, "web_layer")) return true;
    return build_options.web_layer;
}

// The runner-side half of the reject-conflicts contract: a build that
// excludes the web layer while app.zon declares web use must fail at
// compile time here too, so a hand-rolled build graph that bypasses the
// standard configure-time error still cannot ship an app whose declared
// webviews would fail at runtime. The guard covers every declaration
// visible in the manifest; only a Chromium engine resolved from the
// `-Dweb-engine` flag is invisible here, and that conflict is already a
// configure-time error in the graph that resolved the flag.
comptime {
    if (!webLayerEnabled()) {
        if (manifestWebDeclaration()) |declaration| {
            @compileError("this build excludes the web layer (-Dweb-layer=exclude or a custom build graph) but app.zon declares web use (" ++ declaration.text() ++ "); remove the exclude or drop the web declaration");
        }
    }
}

fn windowLabel(comptime window: anytype, comptime index: usize) []const u8 {
    if (comptime @hasField(@TypeOf(window), "label")) return window.label;
    return if (index == 0) "main" else "window";
}

fn windowTitle(comptime window: anytype) []const u8 {
    if (comptime !@hasField(@TypeOf(window), "title")) return "";
    const title = window.title;
    if (comptime @TypeOf(title) == @TypeOf(null)) return "";
    return title;
}

fn windowFloat(comptime window: anytype, comptime field: []const u8, comptime default_value: f32) f32 {
    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    return default_value;
}

fn windowBool(comptime window: anytype, comptime field: []const u8, comptime default_value: bool) bool {
    if (comptime @hasField(@TypeOf(window), field)) return @field(window, field);
    return default_value;
}

fn windowRestorePolicy(comptime window: anytype) native_sdk.WindowRestorePolicy {
    if (comptime !@hasField(@TypeOf(window), "restore_policy")) return .clamp_to_visible_screen;
    const value = window.restore_policy;
    if (comptime std.mem.eql(u8, value, "clamp_to_visible_screen")) return .clamp_to_visible_screen;
    if (comptime std.mem.eql(u8, value, "center_on_primary")) return .center_on_primary;
    @compileError("unknown app.zon window restore_policy");
}

fn shortcutModifiers(comptime shortcut: anytype) native_sdk.ShortcutModifiers {
    const values = if (@hasField(@TypeOf(shortcut), "modifiers")) shortcut.modifiers else .{};
    var modifiers: native_sdk.ShortcutModifiers = .{};
    inline for (values) |value| {
        const modifier: []const u8 = value;
        if (comptime std.mem.eql(u8, modifier, "primary")) {
            modifiers.primary = true;
        } else if (comptime std.mem.eql(u8, modifier, "command")) {
            modifiers.command = true;
        } else if (comptime std.mem.eql(u8, modifier, "control")) {
            modifiers.control = true;
        } else if (comptime std.mem.eql(u8, modifier, "option") or std.mem.eql(u8, modifier, "alt")) {
            modifiers.option = true;
        } else if (comptime std.mem.eql(u8, modifier, "shift")) {
            modifiers.shift = true;
        } else {
            @compileError("unknown app.zon shortcut modifier");
        }
    }
    return modifiers;
}

pub fn runWithOptions(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    if (build_options.debug_overlay) {
        std.debug.print("debug-overlay=true backend={s} web-engine={s} trace={s}\n", .{ build_options.platform, build_options.web_engine, build_options.trace });
    }
    // Capture and session replay never open a real platform. Capture owns
    // its output paths and short-lived null loop; replay treats its journal
    // as the whole world.
    if (init.environ_map.get("NATIVE_SDK_CAPTURE_IMAGE")) |image_path| {
        return runCapture(app, options, init, .{
            .image_path = image_path,
            .snapshot_path = init.environ_map.get("NATIVE_SDK_CAPTURE_SNAPSHOT") orelse return error.CaptureSnapshotPathMissing,
            .result_path = init.environ_map.get("NATIVE_SDK_CAPTURE_RESULT") orelse return error.CaptureResultPathMissing,
            .action_path = init.environ_map.get("NATIVE_SDK_CAPTURE_ACTION_FILE"),
            .session_journal_path = init.environ_map.get("NATIVE_SDK_CAPTURE_SESSION_JOURNAL"),
        });
    }
    // Session replay never opens a real platform: the journal is the
    // world, and it drives a headless runtime over the null platform.
    if (init.environ_map.get("NATIVE_SDK_SESSION_REPLAY")) |journal_path| {
        return runSessionReplay(app, options, init, journal_path);
    }
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        try runMacos(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "linux")) {
        try runLinux(app, options, init);
    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
        try runWindows(app, options, init);
    } else {
        try runNull(app, options, init);
    }
}

const CaptureRequest = struct {
    image_path: []const u8,
    snapshot_path: []const u8,
    result_path: []const u8,
    action_path: ?[]const u8 = null,
    session_journal_path: ?[]const u8 = null,
};

const CaptureActionTarget = struct {
    role: ?[]const u8 = null,
    name: ?[]const u8 = null,
    enabled: ?bool = null,
    selected: ?bool = null,
    value: ?f32 = null,
};

const CaptureAction = struct {
    action: []const u8,
    target: ?CaptureActionTarget = null,
    kind: ?[]const u8 = null,
    value: ?[]const u8 = null,
    key: ?[]const u8 = null,
    text: ?[]const u8 = null,
    from: ?f32 = null,
    to: ?f32 = null,
    delta: ?f32 = null,
    milliseconds: ?u64 = null,
    item: ?usize = null,
    width: ?f32 = null,
    height: ?f32 = null,
    scale: ?f32 = null,
};

const CaptureActionDocument = struct {
    schema: []const u8,
    actions: []const CaptureAction,
};

const CaptureTimingUs = struct {
    startup: u64 = 0,
    render: u64 = 0,
    encode: u64 = 0,
    write: u64 = 0,
    total: u64 = 0,
};

const CaptureOutput = struct {
    widthPx: usize,
    heightPx: usize,
    pngBytes: usize,
};

const CaptureRenderer = struct {
    pixels: []const u8 = "reference",
    textMeasurement: []const u8,
    eventsDriven: []const []const u8,
    framesDriven: usize,
    retainedRevision: u64,
    commands: usize,
    nodes: usize,
    images: usize,
    fonts: usize,
    pixelsDifferentFromClear: usize,
};

const CapturePending = struct {
    timers: usize,
    fetches: usize = 0,
    images: usize = 0,
    providers: []const []const u8 = &.{},
    frameRequests: usize,
};

const CaptureNativeResult = struct {
    schema: []const u8 = "native-sdk.capture.v1",
    status: []const u8 = "ok",
    output: CaptureOutput,
    renderer: CaptureRenderer,
    pending: CapturePending,
    timingUs: CaptureTimingUs,
    warnings: []const []const u8 = &.{},
};

const CaptureNativeError = struct {
    schema: []const u8 = "native-sdk.capture.v1",
    status: []const u8 = "error",
    @"error": struct {
        name: []const u8,
        ask: []const u8,
        remedy: []const u8,
        candidates: []const CaptureCandidate = &.{},
    },
};

const CaptureCandidate = struct {
    role: []const u8,
    name: []const u8,
    enabled: bool,
    selected: bool,
    value: ?f32,
};

const capture_events = [_][]const u8{
    "app_start",
    "appearance_changed",
    "surface_resized",
    "window_frame_changed",
    "gpu_surface_resized",
    "gpu_surface_frame",
    "app_shutdown",
};

const capture_replay_events = [_][]const u8{"session_journal"};

const CaptureDriver = struct {
    io: std.Io,
    null_platform: *native_sdk.NullPlatform,
    runtime: *native_sdk.Runtime,
    app: native_sdk.App,
    request: CaptureRequest,
    title: []const u8,
    started_us: u64,
    frames_driven: usize = 0,
    next_frame_index: u64 = 1,
    next_timestamp_ns: u64 = 1_000_000,
    events_driven: []const []const u8 = &capture_events,
    failure_candidates: []CaptureCandidate = &.{},

    fn run(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque) anyerror!void {
        try self.null_platform.dispatchStartup(handler, handler_context);
        const startup_start_us = self.started_us;
        try self.driveInitialFrame(handler, handler_context);
        const startup_us = captureNowUs() -| startup_start_us;
        try self.applyActionFile(handler, handler_context);
        try self.writeArtifacts(startup_us);
        try self.null_platform.dispatchShutdown(handler, handler_context);
    }

    fn driveInitialFrame(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque) !void {
        const view = for (self.null_platform.views[0..self.null_platform.view_count]) |candidate| {
            if (candidate.kind == .gpu_surface) break candidate;
        } else return error.CaptureViewNotFound;
        try handler(handler_context, .{ .gpu_surface_resized = .{
            .window_id = view.window_id,
            .label = view.label,
            .frame = view.frame,
            .scale_factor = 1,
        } });
        // A real host schedules the completion only after resize invalidates
        // the surface. Consume that actual request instead of inventing a
        // frame count or waiting for an arbitrary duration.
        const requested = self.null_platform.takeGpuSurfaceFrameRequest() orelse return error.CaptureFrameNotRequested;
        if (requested.window_id != view.window_id or !std.mem.eql(u8, requested.label(), view.label)) return error.CaptureFrameTargetMismatch;
        try self.completeRequestedFrame(handler, handler_context, requested);
    }

    fn drivePendingFrame(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque) !bool {
        const requested = self.null_platform.takeGpuSurfaceFrameRequest() orelse return false;
        try self.completeRequestedFrame(handler, handler_context, requested);
        return true;
    }

    fn completeRequestedFrame(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque, requested: native_sdk.NullGpuSurfaceFrameRequest) !void {
        const requested_label = requested.label();
        const view = for (self.null_platform.views[0..self.null_platform.view_count]) |candidate| {
            if (candidate.window_id == requested.window_id and std.mem.eql(u8, candidate.label, requested_label)) break candidate;
        } else return error.CaptureViewNotFound;
        if (view.kind != .gpu_surface) return error.CaptureViewNotGpuSurface;
        try handler(handler_context, .{ .gpu_surface_frame = .{
            .window_id = requested.window_id,
            .label = requested_label,
            .size = view.frame.size(),
            .scale_factor = 1,
            .frame_index = self.next_frame_index,
            .timestamp_ns = self.next_timestamp_ns,
            .nonblank = false,
            .backend = .software,
            .pixel_format = .bgra8_unorm,
            .present_mode = .timer,
            .alpha_mode = .premultiplied,
            .color_space = .srgb,
            .vsync = false,
            .status = .ready,
        } });
        self.frames_driven += 1;
        self.next_frame_index += 1;
        self.next_timestamp_ns += native_sdk.platform.default_gpu_frame_interval_ns;
    }

    fn applyActionFile(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque) !void {
        const path = self.request.action_path orelse return;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(self.io, path, std.heap.page_allocator, .unlimited);
        defer std.heap.page_allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(CaptureActionDocument, std.heap.page_allocator, bytes, .{
            .ignore_unknown_fields = false,
        });
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.schema, "weaver.capture.actions.v1")) return error.CaptureActionSchemaUnsupported;
        for (parsed.value.actions) |action| {
            try self.applyAction(handler, handler_context, action);
            _ = try self.drivePendingFrame(handler, handler_context);
        }
    }

    fn applyAction(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque, action: CaptureAction) !void {
        if (std.mem.eql(u8, action.action, "advance-clock")) {
            try self.advanceClock(handler, handler_context, action.milliseconds orelse return error.CaptureActionMillisecondsMissing);
            return;
        }
        if (std.mem.eql(u8, action.action, "resize")) {
            const width = action.width orelse return error.CaptureActionWidthMissing;
            const height = action.height orelse return error.CaptureActionHeightMissing;
            const scale = action.scale orelse 1;
            try self.dispatchCommand("resize {d} {d} {d}", .{ width, height, scale });
            const view = for (self.null_platform.views[0..self.null_platform.view_count]) |candidate| {
                if (candidate.kind == .gpu_surface) break candidate;
            } else return error.CaptureViewNotFound;
            const frame = native_sdk.geometry.RectF.init(view.frame.x, view.frame.y, width, height);
            try self.null_platform.platform().services.setViewFrame(view.window_id, view.label, frame);
            try handler(handler_context, .{ .gpu_surface_resized = .{
                .window_id = view.window_id,
                .label = view.label,
                .frame = frame,
                .scale_factor = scale,
            } });
            return;
        }

        const target = try self.resolveTarget(action.target orelse return error.CaptureActionTargetMissing);
        if (std.mem.eql(u8, action.action, "click")) {
            return self.dispatchCommand("widget-click {s} {d}", .{ target.view_label, target.id });
        }
        if (std.mem.eql(u8, action.action, "drag")) {
            return self.dispatchCommand("widget-drag {s} {d} {d} {d}", .{
                target.view_label,
                target.id,
                action.from orelse return error.CaptureActionFromMissing,
                action.to orelse return error.CaptureActionToMissing,
            });
        }
        if (std.mem.eql(u8, action.action, "wheel")) {
            return self.dispatchCommand("widget-wheel {s} {d} {d}", .{
                target.view_label,
                target.id,
                action.delta orelse return error.CaptureActionDeltaMissing,
            });
        }
        if (std.mem.eql(u8, action.action, "text")) {
            const value = action.value orelse return error.CaptureActionValueMissing;
            try validateCaptureCommandValue(value);
            return self.dispatchCommand("widget-action {s} {d} set-text {s}", .{ target.view_label, target.id, value });
        }
        if (std.mem.eql(u8, action.action, "key")) {
            const key = action.key orelse return error.CaptureActionKeyMissing;
            const text = action.text orelse "";
            try validateCaptureCommandValue(key);
            try validateCaptureCommandValue(text);
            try self.dispatchCommand("widget-action {s} {d} focus", .{ target.view_label, target.id });
            return self.dispatchCommand("widget-key {s} {s} {s}", .{ target.view_label, key, text });
        }
        if (std.mem.eql(u8, action.action, "action")) {
            const kind = action.kind orelse return error.CaptureActionKindMissing;
            const value = action.value orelse "";
            try validateCaptureCommandValue(kind);
            try validateCaptureCommandValue(value);
            return self.dispatchCommand("widget-action {s} {d} {s} {s}", .{ target.view_label, target.id, kind, value });
        }
        if (std.mem.eql(u8, action.action, "context-menu")) {
            return self.dispatchCommand("widget-context-menu {s} {d} {d}", .{
                target.view_label,
                target.id,
                action.item orelse return error.CaptureActionItemMissing,
            });
        }
        return error.CaptureActionUnknown;
    }

    fn resolveTarget(self: *CaptureDriver, target: CaptureActionTarget) !native_sdk.automation.snapshot.Widget {
        if (target.role == null and target.name == null) return error.CaptureTargetSelectorEmpty;
        const snapshot = self.runtime.automationSnapshot(self.title);
        var match: ?native_sdk.automation.snapshot.Widget = null;
        var match_count: usize = 0;
        for (snapshot.widgets) |widget| {
            if (!captureTargetMatches(target, widget)) continue;
            match = widget;
            match_count += 1;
        }
        if (match_count == 1) return match.?;
        const candidate_count = if (match_count == 0) snapshot.widgets.len else match_count;
        self.failure_candidates = try std.heap.page_allocator.alloc(CaptureCandidate, candidate_count);
        var candidate_index: usize = 0;
        for (snapshot.widgets) |widget| {
            if (match_count != 0 and !captureTargetMatches(target, widget)) continue;
            self.failure_candidates[candidate_index] = .{
                .role = widget.role,
                .name = widget.name,
                .enabled = widget.enabled,
                .selected = widget.selected,
                .value = widget.value,
            };
            candidate_index += 1;
        }
        std.log.err("capture target role={s} name={s} matched {d} controls", .{
            target.role orelse "*",
            target.name orelse "*",
            match_count,
        });
        for (self.failure_candidates) |candidate| {
            std.log.err("- role={s} name=\"{s}\" enabled={} selected={}", .{
                candidate.role, candidate.name, candidate.enabled, candidate.selected,
            });
        }
        return if (match_count == 0) error.CaptureTargetNotFound else error.CaptureTargetAmbiguous;
    }

    fn dispatchCommand(self: *CaptureDriver, comptime format: []const u8, args: anytype) !void {
        const command = try std.fmt.allocPrint(std.heap.page_allocator, format, args);
        defer std.heap.page_allocator.free(command);
        try self.runtime.dispatchAutomationCommand(self.app, command);
    }

    fn advanceClock(self: *CaptureDriver, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque, milliseconds: u64) !void {
        if (milliseconds > std.math.maxInt(u64) / std.time.ns_per_ms) return error.CaptureClockAdvanceOverflow;
        try self.app.advanceCaptureClock(milliseconds);
        const target_ns = milliseconds * std.time.ns_per_ms;
        const Scheduled = struct { id: u64 = 0, due_ns: u64 = 0, interval_ns: u64 = 0, active: bool = false, eligible: bool = false };
        var scheduled = [_]Scheduled{.{}} ** native_sdk.max_null_timers;
        var scheduled_count: usize = 0;
        var elapsed_ns: u64 = 0;
        while (true) {
            for (scheduled[0..scheduled_count]) |*entry| entry.active = false;
            var timer_buffer: [native_sdk.max_null_timers]native_sdk.NullTimer = undefined;
            const active_timers = self.null_platform.listActiveTimers(&timer_buffer);
            for (active_timers) |timer| {
                if (timer.interval_ns == 0) return error.CaptureTimerIntervalZero;
                const existing = for (scheduled[0..scheduled_count], 0..) |entry, index| {
                    if (entry.id == timer.id) break index;
                } else null;
                if (existing) |index| {
                    scheduled[index].active = true;
                    if (scheduled[index].interval_ns != timer.interval_ns) {
                        scheduled[index].interval_ns = timer.interval_ns;
                        scheduled[index].eligible = timer.interval_ns <= target_ns - elapsed_ns;
                        if (scheduled[index].eligible) scheduled[index].due_ns = elapsed_ns + timer.interval_ns;
                    }
                } else {
                    const eligible = timer.interval_ns <= target_ns - elapsed_ns;
                    scheduled[scheduled_count] = .{
                        .id = timer.id,
                        .due_ns = if (eligible) elapsed_ns + timer.interval_ns else 0,
                        .interval_ns = timer.interval_ns,
                        .active = true,
                        .eligible = eligible,
                    };
                    scheduled_count += 1;
                }
            }
            const next_index = next: {
                var index: ?usize = null;
                for (scheduled[0..scheduled_count], 0..) |entry, candidate| {
                    if (!entry.active or !entry.eligible or entry.due_ns > target_ns) continue;
                    if (index == null or entry.due_ns < scheduled[index.?].due_ns) index = candidate;
                }
                break :next index;
            } orelse break;
            elapsed_ns = scheduled[next_index].due_ns;
            const id = scheduled[next_index].id;
            const event = self.null_platform.fireTimer(id, self.next_timestamp_ns + elapsed_ns) orelse {
                scheduled[next_index].active = false;
                continue;
            };
            try handler(handler_context, event);
            if (self.null_platform.startedTimer(id)) |timer| {
                if (timer.active) {
                    if (timer.interval_ns == 0) return error.CaptureTimerIntervalZero;
                    scheduled[next_index].interval_ns = timer.interval_ns;
                    scheduled[next_index].active = true;
                    scheduled[next_index].eligible = timer.interval_ns <= target_ns - elapsed_ns;
                    if (scheduled[next_index].eligible) scheduled[next_index].due_ns = elapsed_ns + timer.interval_ns;
                } else {
                    scheduled[next_index].active = false;
                    scheduled[next_index].eligible = false;
                }
            } else {
                scheduled[next_index].active = false;
                scheduled[next_index].eligible = false;
            }
        }
        self.next_timestamp_ns += target_ns;
    }

    fn writeArtifacts(self: *CaptureDriver, startup_us: u64) !void {
        var views_buffer: [native_sdk.platform.max_views]native_sdk.ViewInfo = undefined;
        const views = self.runtime.listViews(1, &views_buffer);
        const view = for (views) |candidate| {
            if (candidate.kind == .gpu_surface) break candidate;
        } else return error.CaptureViewNotFound;

        const render_start_us = captureNowUs();
        const pixel_size = try self.runtime.canvasScreenshotPixelSize(view.window_id, view.label, 1);
        const pixels = try std.heap.page_allocator.alloc(u8, pixel_size.byte_len);
        defer std.heap.page_allocator.free(pixels);
        const scratch = try std.heap.page_allocator.alloc(u8, pixel_size.byte_len);
        defer std.heap.page_allocator.free(scratch);
        const screenshot = try self.runtime.renderCanvasScreenshot(view.window_id, view.label, 1, pixels, scratch);
        const clear = try self.runtime.canvasClearColorRgba8(view.window_id, view.label);
        var pixels_different_from_clear: usize = 0;
        var pixel_index: usize = 0;
        while (pixel_index + 3 < screenshot.rgba8.len) : (pixel_index += 4) {
            if (!std.mem.eql(u8, screenshot.rgba8[pixel_index .. pixel_index + 4], &clear)) pixels_different_from_clear += 1;
        }
        const render_us = captureNowUs() -| render_start_us;

        const encode_start_us = captureNowUs();
        var png_writer = try std.Io.Writer.Allocating.initCapacity(
            std.heap.page_allocator,
            try native_sdk.canvas.png.encodedRgba8ByteLen(screenshot.width, screenshot.height),
        );
        defer png_writer.deinit();
        try native_sdk.canvas.png.writeRgba8(&png_writer.writer, screenshot.width, screenshot.height, screenshot.rgba8);
        const encode_us = captureNowUs() -| encode_start_us;

        var snapshot_writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 16 * 1024);
        defer snapshot_writer.deinit();
        try native_sdk.automation.snapshot.writeText(self.runtime.automationSnapshot(self.title), &snapshot_writer.writer);

        const write_start_us = captureNowUs();
        try writeCaptureFile(self.io, self.request.image_path, png_writer.written());
        try writeCaptureFile(self.io, self.request.snapshot_path, snapshot_writer.written());
        const write_us = captureNowUs() -| write_start_us;
        const total_us = captureNowUs() -| self.started_us;
        const refreshed_views = self.runtime.listViews(1, &views_buffer);
        const refreshed_view = for (refreshed_views) |candidate| {
            if (candidate.kind == .gpu_surface and std.mem.eql(u8, candidate.label, view.label)) break candidate;
        } else return error.CaptureViewNotFound;
        const app_pending = self.app.capturePendingWork();
        try writeCaptureJson(self.io, self.request.result_path, CaptureNativeResult{
            .output = .{
                .widthPx = screenshot.width,
                .heightPx = screenshot.height,
                .pngBytes = png_writer.written().len,
            },
            .renderer = .{
                .textMeasurement = if (comptime std.mem.eql(u8, build_options.platform, "macos")) "coretext" else "estimator",
                .eventsDriven = self.events_driven,
                .framesDriven = self.frames_driven,
                .retainedRevision = refreshed_view.canvas_revision,
                .commands = refreshed_view.canvas_command_count,
                .nodes = refreshed_view.widget_node_count,
                .images = self.runtime.registeredCanvasImageCount(),
                .fonts = self.runtime.registeredCanvasFontCount(),
                .pixelsDifferentFromClear = pixels_different_from_clear,
            },
            .pending = .{
                .timers = self.null_platform.activeTimerCount(),
                .fetches = app_pending.fetches,
                .images = app_pending.images,
                .providers = app_pending.providers,
                .frameRequests = self.null_platform.pendingGpuSurfaceFrameRequestCount(),
            },
            .timingUs = .{
                .startup = startup_us,
                .render = render_us,
                .encode = encode_us,
                .write = write_us,
                .total = total_us,
            },
        });
    }
};

/// The platform run loop and feature probes have different owners during a
/// capture. Keep both explicit instead of making every null-platform callback
/// reinterpret the capture driver as its own context.
const CapturePlatformContext = struct {
    null_platform: *native_sdk.NullPlatform,
    driver: *CaptureDriver,

    fn run(context: *anyopaque, handler: native_sdk.platform.EventHandler, handler_context: *anyopaque) anyerror!void {
        const self: *CapturePlatformContext = @ptrCast(@alignCast(context));
        try self.driver.run(handler, handler_context);
    }

    fn supportsFeature(context: *anyopaque, feature: native_sdk.platform.PlatformFeature) bool {
        const self: *CapturePlatformContext = @ptrCast(@alignCast(context));
        return self.null_platform.platform().supports(feature);
    }
};

fn captureTargetMatches(target: CaptureActionTarget, widget: native_sdk.automation.snapshot.Widget) bool {
    if (target.role) |role| if (!std.mem.eql(u8, role, widget.role)) return false;
    if (target.name) |name| if (!std.mem.eql(u8, name, widget.name)) return false;
    if (target.enabled) |enabled| if (enabled != widget.enabled) return false;
    if (target.selected) |selected| if (selected != widget.selected) return false;
    if (target.value) |value| if (widget.value == null or widget.value.? != value) return false;
    return true;
}

fn validateCaptureCommandValue(value: []const u8) !void {
    if (std.mem.indexOfAny(u8, value, "\r\n") != null) return error.CaptureActionContainsLineBreak;
}

fn runCapture(app: native_sdk.App, options: RunOptions, init: std.process.Init, request: CaptureRequest) !void {
    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    const session_recorder = setupSessionRecorder(init, app_info);
    var null_platform = native_sdk.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    null_platform.gpu_surfaces = true;
    null_platform.image_decode = true;
    var capture_platform = null_platform.platform();
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        native_sdk.platform.macos.installHeadlessCaptureServices(&capture_platform.services);
        null_platform.gpu_surface_scroll_drivers = true;
    } else if (comptime std.mem.eql(u8, build_options.platform, "windows")) {
        native_sdk.platform.windows.installHeadlessCaptureServices(&capture_platform.services);
    }
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    var driver: CaptureDriver = .{
        .io = init.io,
        .null_platform = &null_platform,
        .runtime = runtime,
        .app = app,
        .request = request,
        .title = app_info.resolvedWindowTitle(),
        .started_us = captureNowUs(),
    };
    defer if (driver.failure_candidates.len > 0) std.heap.page_allocator.free(driver.failure_candidates);
    var capture_context: CapturePlatformContext = .{
        .null_platform = &null_platform,
        .driver = &driver,
    };
    if (request.session_journal_path == null) {
        capture_platform.context = &capture_context;
        capture_platform.run_fn = CapturePlatformContext.run;
        capture_platform.supports_fn = CapturePlatformContext.supportsFeature;
    }
    native_sdk.Runtime.initAt(runtime, .{
        .platform = capture_platform,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });
    const run_result: anyerror!void = if (request.session_journal_path) |journal_path|
        runCaptureJournal(&driver, runtime, app, init.io, journal_path)
    else
        runtime.run(app);
    run_result catch |err| {
        const detail = captureErrorDetail(err);
        writeCaptureJson(init.io, request.result_path, CaptureNativeError{
            .@"error" = .{
                .name = @errorName(err),
                .ask = detail.ask,
                .remedy = detail.remedy,
                .candidates = driver.failure_candidates,
            },
        }) catch {};
        return err;
    };
    finishSessionRecorder(session_recorder);
}

fn captureErrorDetail(err: anyerror) struct { ask: []const u8, remedy: []const u8 } {
    const name = @errorName(err);
    if (std.mem.startsWith(u8, name, "CaptureTarget")) return .{
        .ask = "select exactly one control by semantic role and accessible name",
        .remedy = "choose a unique role/name pair from error.candidates and rerun the same action file",
    };
    if (std.mem.startsWith(u8, name, "CaptureAction")) return .{
        .ask = "fix the named action field or action-file schema",
        .remedy = "use schema weaver.capture.actions.v1 and a documented semantic action, then rerun capture",
    };
    if (std.mem.startsWith(u8, name, "CaptureProvider")) return .{
        .ask = "provide valid recorded frames for every subscribed non-time provider",
        .remedy = "use schema weaver.provider-fixture.v1, declare only subscribed providers, and rerun capture",
    };
    if (std.mem.startsWith(u8, name, "SessionReplay")) return .{
        .ask = "provide a complete same-platform session journal whose verified replay matches",
        .remedy = "record the session again on this platform or fix the reported replay divergence",
    };
    return .{
        .ask = "inspect the named capture failure and widget diagnostic",
        .remedy = "fix the named runtime or widget failure, then rerun the same capture command",
    };
}

fn runCaptureJournal(
    driver: *CaptureDriver,
    runtime: *native_sdk.Runtime,
    app: native_sdk.App,
    io: std.Io,
    journal_path: []const u8,
) !void {
    driver.events_driven = &capture_replay_events;
    const journal_bytes = try readSessionJournal(io, journal_path);
    defer std.heap.page_allocator.free(journal_bytes);
    const replay_start_us = captureNowUs();
    const report = try native_sdk.runtime.replaySession(runtime, app, journal_bytes, .{ .verify = true });
    if (!report.ok()) return error.SessionReplayMismatch;
    driver.frames_driven = @intCast(runtime.frameDiagnostics().frame_index);
    try driver.writeArtifacts(captureNowUs() -| replay_start_us);
}

fn writeCaptureFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

fn writeCaptureJson(io: std.Io, path: []const u8, value: anytype) !void {
    var writer = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 2048);
    defer writer.deinit();
    try writer.writer.print("{f}\n", .{std.json.fmt(value, .{})});
    try writeCaptureFile(io, path, writer.written());
}

fn captureNowUs() u64 {
    const now_ns = native_sdk.runtime.nowNanoseconds();
    return @intCast(@max(0, @divTrunc(now_ns, 1000)));
}

fn runNull(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = if (options.persist_window_state) prepareStateStore(init.io, init.environ_map, &app_info, &buffers) else null;
    const session_recorder = setupSessionRecorder(init, app_info);
    var null_platform = native_sdk.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    native_sdk.Runtime.initAt(runtime, .{
        .platform = null_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

fn runMacos(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    // Launch-to-glass laps (NATIVE_SDK_WINDOW_TIMING): runner entry is the
    // first in-process stamp — spawn-to-here is exec + dyld + zig init.
    native_sdk.runtime.launch_timing.lap("runner_main");
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = if (options.persist_window_state) prepareStateStore(init.io, init.environ_map, &app_info, &buffers) else null;
    const session_recorder = setupSessionRecorder(init, app_info);
    var mac_platform = try native_sdk.platform.macos.MacPlatform.initWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer mac_platform.deinit();
    native_sdk.runtime.launch_timing.lap("host_ready");
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    native_sdk.Runtime.initAt(runtime, .{
        .platform = mac_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });
    native_sdk.runtime.launch_timing.lap("runtime_ready");

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

fn runLinux(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = if (options.persist_window_state) prepareStateStore(init.io, init.environ_map, &app_info, &buffers) else null;
    const session_recorder = setupSessionRecorder(init, app_info);
    var linux_platform = try native_sdk.platform.linux.LinuxPlatform.initWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer linux_platform.deinit();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    native_sdk.Runtime.initAt(runtime, .{
        .platform = linux_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

fn runWindows(app: native_sdk.App, options: RunOptions, init: std.process.Init) !void {
    var buffers: StateBuffers = undefined;
    var app_info = options.appInfo(&buffers);
    const store = if (options.persist_window_state) prepareStateStore(init.io, init.environ_map, &app_info, &buffers) else null;
    const session_recorder = setupSessionRecorder(init, app_info);
    var windows_platform = try native_sdk.platform.windows.WindowsPlatform.initWithOptions(native_sdk.geometry.SizeF.init(720, 480), webEngine(), app_info);
    defer windows_platform.deinit();
    var trace_sink = StdoutTraceSink{};
    var log_buffers: native_sdk.debug.LogPathBuffers = .{};
    const log_setup = native_sdk.debug.setupLogging(init.io, init.environ_map, app_info.bundle_id, &log_buffers) catch null;
    if (log_setup) |setup| native_sdk.debug.installPanicCapture(init.io, setup.paths);
    var file_trace_sink: native_sdk.debug.FileTraceSink = undefined;
    var fanout_sinks: [2]native_sdk.trace.Sink = undefined;
    var fanout_sink: native_sdk.debug.FanoutTraceSink = undefined;
    var runtime_trace_sink = trace_sink.sink();
    if (log_setup) |setup| {
        file_trace_sink = native_sdk.debug.FileTraceSink.init(init.io, setup.paths.log_dir, setup.paths.log_file, setup.format);
        fanout_sinks = .{ trace_sink.sink(), file_trace_sink.sink() };
        fanout_sink = .{ .sinks = &fanout_sinks };
        runtime_trace_sink = fanout_sink.sink();
    }
    var filtered_trace_sink: FilteredTraceSink = .{ .child = runtime_trace_sink };
    runtime_trace_sink = filtered_trace_sink.sink();
    var shortcut_storage: ShortcutStorage = .{};
    const shortcuts = options.resolvedShortcuts(&shortcut_storage);
    // The Runtime is multi-megabyte; Linux's default 8 MB main-thread
    // stack overflows on a stack instance, so construct it on the heap.
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    native_sdk.Runtime.initAt(runtime, .{
        .platform = windows_platform.platform(),
        .trace_sink = runtime_trace_sink,
        .log_path = if (log_setup) |setup| setup.paths.log_file else null,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .gpu_surface_frame_diagnostics = false,
        // The Windows pixel host preserves both its RGBA surface and its
        // layered DIB across presents. Its keyed mirror therefore describes
        // the pixels actually on glass, allowing rebuild damage to refine to
        // changed command bounds instead of conservatively repainting the
        // whole widget. Packet patches remain guarded from pixel baselines.
        .pixel_present_retained_baseline = true,
        .security = options.security,
        .menus = options.menus,
        .shortcuts = shortcuts,
        .automation = if (build_options.automation) native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", app_info.resolvedWindowTitle()) else null,
        .window_state_store = store,
        .environ = init.minimal.environ,
        .session_recorder = session_recorder,
    });

    try runtime.run(app);
    finishSessionRecorder(session_recorder);
}

// ------------------------------------------------- session record/replay

/// Positional file sink behind the session recorder. Process-lifetime:
/// allocated once at launch and never freed (the recorder outlives every
/// dispatch).
const SessionRecordContext = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,

    fn sink(self: *SessionRecordContext) native_sdk.runtime.SessionRecorderSink {
        return .{ .context = self, .write_fn = write };
    }

    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *SessionRecordContext = @ptrCast(@alignCast(context));
        try self.file.writePositionalAll(self.io, bytes, self.offset);
        self.offset += bytes.len;
    }
};

/// `NATIVE_SDK_SESSION_RECORD=<path>`: create the journal file and a
/// recorder that streams the session into it from the very first
/// dispatched event (init determinism needs init-time effect results).
/// Failures disable recording loudly and never block the app.
fn setupSessionRecorder(init: std.process.Init, app_info: native_sdk.AppInfo) ?*native_sdk.runtime.SessionRecorder {
    const path = init.environ_map.get("NATIVE_SDK_SESSION_RECORD") orelse return null;
    const file = std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true }) catch |err| {
        std.debug.print("session recording disabled: cannot create {s}: {s}\n", .{ path, @errorName(err) });
        return null;
    };
    const context = std.heap.page_allocator.create(SessionRecordContext) catch return null;
    context.* = .{ .io = init.io, .file = file };
    const recorder = std.heap.page_allocator.create(native_sdk.runtime.SessionRecorder) catch return null;
    recorder.* = native_sdk.runtime.SessionRecorder.init(context.sink());
    recorder.begin(native_sdk.runtime.sessionHeaderNow(
        native_sdk.runtime.sessionPlatformName(),
        app_info.app_name,
        app_info.main_window.default_frame.width,
        app_info.main_window.default_frame.height,
    ));
    std.debug.print("session recording to {s}\n", .{path});
    return recorder;
}

/// Seal the journal on clean exit. A crashed or killed app leaves no
/// end record, and replay refuses the file as truncated — honest by
/// construction.
fn finishSessionRecorder(recorder: ?*native_sdk.runtime.SessionRecorder) void {
    const active = recorder orelse return;
    active.finish();
    if (!active.failed) {
        std.debug.print("session journal sealed: {d} events, {d} effect results, {d} checkpoints, {d} screenshots, {d} bytes\n", .{
            active.event_count,
            active.effect_count,
            active.checkpoint_count,
            active.screenshot_count,
            active.bytes_written,
        });
    }
}

/// `NATIVE_SDK_SESSION_REPLAY=<path>`: replay the journal headlessly
/// (null platform — no windows, no timers, no effects; the journal is
/// the world), verify fingerprint and screenshot checkpoints unless
/// `NATIVE_SDK_SESSION_VERIFY=0`, print the report, and exit non-zero
/// on any mismatch.
fn runSessionReplay(app: native_sdk.App, options: RunOptions, init: std.process.Init, journal_path: []const u8) !void {
    const journal_bytes = readSessionJournal(init.io, journal_path) catch |err| {
        std.debug.print("session replay: cannot read {s}: {s}\n", .{ journal_path, @errorName(err) });
        return err;
    };

    var buffers: StateBuffers = undefined;
    const app_info = options.appInfo(&buffers);
    var null_platform = native_sdk.NullPlatform.initWithOptions(.{}, webEngine(), app_info);
    null_platform.gpu_surfaces = true;
    var replay_platform = null_platform.platform();
    // Same-platform replay must mirror the RECORDING host's rendering
    // capabilities, or pixel checkpoints catch the honest difference:
    // - text measures through the SAME host seam (macOS: CoreText + the
    //   bundled faces) — engine fallback metrics differ by fractions of
    //   a pixel;
    // - native scroll drivers exist (macOS overlay scrollers), so the
    //   engine's drawn scrollbar stands down exactly like it did live.
    if (comptime std.mem.eql(u8, build_options.platform, "macos")) {
        native_sdk.platform.macos.installHeadlessTextServices(&replay_platform.services);
        null_platform.gpu_surface_scroll_drivers = true;
    }
    const runtime = try std.heap.page_allocator.create(native_sdk.Runtime);
    defer std.heap.page_allocator.destroy(runtime);
    // Bridge policy and security must match what the recording ran
    // under (they gate replayed bridge_message dispatch); automation,
    // window-state restore, and tracing stay off — replay consumes only
    // the journal and restores nothing.
    native_sdk.Runtime.initAt(runtime, .{
        .platform = replay_platform,
        .bridge = options.bridge,
        .builtin_bridge = options.builtin_bridge,
        .js_window_api = options.js_window_api,
        .web_layer = webLayerEnabled(),
        .security = options.security,
        .menus = options.menus,
    });

    const verify = if (init.environ_map.get("NATIVE_SDK_SESSION_VERIFY")) |value|
        !std.mem.eql(u8, value, "0")
    else
        true;
    const report = native_sdk.runtime.replaySession(runtime, app, journal_bytes, .{ .verify = verify }) catch |err| {
        switch (err) {
            error.JournalBadMagic,
            error.JournalUnsupportedVersion,
            error.JournalTruncated,
            error.JournalCorrupt,
            error.JournalRecordOverBudget,
            error.JournalMissingHeader,
            error.JournalCountMismatch,
            => std.debug.print("session replay refused {s}: {s}\n", .{ journal_path, native_sdk.runtime.session_journal.describeError(@errorCast(err)) }),
            else => {},
        }
        return err;
    };
    std.debug.print("session replay: {d} events, {d} effect results fed ({d} regenerated), {d} fingerprint checkpoints, {d} screenshot marks\n", .{
        report.events_replayed,
        report.effects_fed,
        report.effects_skipped,
        report.checkpoints_verified,
        report.screenshots_verified,
    });
    if (!report.ok()) {
        const detail_count: usize = @intCast(@min(report.mismatch_count, report.mismatches.len));
        for (report.mismatches[0..detail_count]) |mismatch| {
            std.debug.print("session replay mismatch: {s} after event {d} (frame {d}): recorded {x} vs replayed {x}\n", .{
                @tagName(mismatch.kind),
                mismatch.event_ordinal,
                mismatch.frame_index,
                mismatch.expected,
                mismatch.actual,
            });
        }
        std.debug.print("session replay FAILED verification: {d} mismatching checkpoint(s)\n", .{report.mismatch_count});
        return error.SessionReplayMismatch;
    }
    std.debug.print("session replay verified: deterministic\n", .{});
}

fn readSessionJournal(io: std.Io, path: []const u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(
        std.heap.page_allocator,
        .limited(native_sdk.runtime.max_session_journal_bytes),
    );
}

fn shouldTrace(record: native_sdk.trace.Record) bool {
    if (comptime std.mem.eql(u8, build_options.trace, "off")) return false;
    if (comptime std.mem.eql(u8, build_options.trace, "all")) return true;
    if (comptime std.mem.eql(u8, build_options.trace, "events")) return std.mem.eql(u8, record.name, "runtime.event");
    return std.mem.indexOf(u8, record.name, build_options.trace) != null;
}

fn webEngine() native_sdk.WebEngine {
    if (comptime std.mem.eql(u8, build_options.web_engine, "chromium")) return .chromium;
    return .system;
}

const StateBuffers = struct {
    state_dir: [1024]u8 = undefined,
    file_path: [1200]u8 = undefined,
    read: [8192]u8 = undefined,
    restored_windows: [native_sdk.platform.max_windows]native_sdk.WindowOptions = undefined,
};

fn prepareStateStore(io: std.Io, env_map: *std.process.Environ.Map, app_info: *native_sdk.AppInfo, buffers: *StateBuffers) ?native_sdk.window_state.Store {
    const paths = native_sdk.window_state.defaultPaths(&buffers.state_dir, &buffers.file_path, app_info.bundle_id, native_sdk.debug.envFromMap(env_map)) catch return null;
    const store = native_sdk.window_state.Store.init(io, paths.state_dir, paths.file_path);
    if (app_info.windows.len > 0) {
        const restored_windows = buffers.restored_windows[0..app_info.windows.len];
        for (restored_windows, 0..) |*window, index| {
            if (!window.restore_state) continue;
            if (store.loadWindow(window.label, &buffers.read) catch null) |saved| {
                window.default_frame = saved.frame;
                if (index == 0) app_info.main_window.default_frame = saved.frame;
            }
        }
    } else if (app_info.main_window.restore_state) {
        if (store.loadWindow(app_info.main_window.label, &buffers.read) catch null) |saved| {
            app_info.main_window.default_frame = saved.frame;
        }
    }
    return store;
}
