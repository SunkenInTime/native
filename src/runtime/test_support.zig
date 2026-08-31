pub const std = @import("std");
pub const geometry = @import("geometry");
pub const trace = @import("trace");
pub const json = @import("json");
pub const canvas = @import("canvas");
pub const automation = @import("../automation/root.zig");
pub const bridge = @import("../bridge/root.zig");
pub const app_manifest = @import("app_manifest");
pub const platform = @import("../platform/root.zig");
pub const security = @import("../security/root.zig");
pub const extensions = @import("../extensions/root.zig");
pub const window_state = @import("../window_state/root.zig");
pub const runtime_module = @import("root.zig");
pub const bridge_payload = @import("bridge_payload.zig");
pub const canvas_frame = @import("canvas_frame.zig");

pub const App = runtime_module.App;
pub const Runtime = runtime_module.Runtime;
pub const Options = runtime_module.Options;
pub const Event = runtime_module.Event;
pub const LifecycleEvent = runtime_module.LifecycleEvent;
pub const CommandEvent = runtime_module.CommandEvent;
pub const Command = runtime_module.Command;
pub const CommandSource = runtime_module.CommandSource;
pub const FrameDiagnostics = runtime_module.FrameDiagnostics;
pub const ShortcutEvent = runtime_module.ShortcutEvent;
pub const Appearance = runtime_module.Appearance;
pub const GpuFrame = runtime_module.GpuFrame;
pub const GpuSurfaceFrameEvent = runtime_module.GpuSurfaceFrameEvent;
pub const GpuSurfaceResizeEvent = runtime_module.GpuSurfaceResizeEvent;
pub const GpuSurfaceInputEvent = runtime_module.GpuSurfaceInputEvent;
pub const CanvasWidgetPointerEvent = runtime_module.CanvasWidgetPointerEvent;
pub const CanvasWidgetKeyboardEvent = runtime_module.CanvasWidgetKeyboardEvent;
pub const CanvasWidgetDisplayListChrome = runtime_module.CanvasWidgetDisplayListChrome;
pub const CanvasPresentationMode = runtime_module.CanvasPresentationMode;
pub const CanvasPresentationResult = runtime_module.CanvasPresentationResult;
pub const CanvasWidgetAccessibilityActionKind = runtime_module.CanvasWidgetAccessibilityActionKind;
pub const CanvasWidgetAccessibilityAction = runtime_module.CanvasWidgetAccessibilityAction;
pub const CanvasWidgetFileDropEvent = runtime_module.CanvasWidgetFileDropEvent;
pub const CanvasWidgetDragEvent = runtime_module.CanvasWidgetDragEvent;
pub const InvalidationReason = runtime_module.InvalidationReason;
pub const TestHarness = runtime_module.TestHarness;
pub const max_canvas_commands_per_view = runtime_module.max_canvas_commands_per_view;
pub const max_canvas_gradient_stops_per_view = runtime_module.max_canvas_gradient_stops_per_view;
pub const max_canvas_mesh_patches_per_view = runtime_module.max_canvas_mesh_patches_per_view;
pub const max_canvas_widget_nodes_per_view = runtime_module.max_canvas_widget_nodes_per_view;

pub const jsonStringField = bridge_payload.jsonStringField;
pub const jsonNumberField = bridge_payload.jsonNumberField;
pub const jsonBoolField = bridge_payload.jsonBoolField;
pub const canvasRenderAnimationFinalOverrideNoop = canvas_frame.canvasRenderAnimationFinalOverrideNoop;
pub const copyInto = runtime_module.testing.copyInto;
pub const writeViewJson = runtime_module.testing.writeViewJson;
pub const canvasFrameScratchStorage = runtime_module.testing.canvasFrameScratchStorage;
pub const runtimeViewInfo = runtime_module.testing.runtimeViewInfo;
pub const runtimeViewCanvasFrameRenderOverrides = runtime_module.testing.runtimeViewCanvasFrameRenderOverrides;
pub const runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides = runtime_module.testing.runtimeViewCanvasRenderAnimationDirtyBoundsForOverrides;
pub const runtimeViewWidgetSemantics = runtime_module.testing.runtimeViewWidgetSemantics;
pub const runtimeViewSetCanvasWidgetSelected = runtime_module.testing.runtimeViewSetCanvasWidgetSelected;
pub const runtimeViewCanvasWidgetDirtyBounds = runtime_module.testing.runtimeViewCanvasWidgetDirtyBounds;
pub const dispatchAutomationWidgetAction = runtime_module.testing.dispatchAutomationWidgetAction;
pub const shellBoundsForWindow = runtime_module.testing.shellBoundsForWindow;
pub const reloadWindows = runtime_module.testing.reloadWindows;
pub const canvasWidgetSemanticsById = runtime_module.testing.canvasWidgetSemanticsById;
pub const platformWidgetAccessibilityNodeById = runtime_module.testing.platformWidgetAccessibilityNodeById;
pub const builtinBridgeErrorCode = runtime_module.testing.builtinBridgeErrorCode;
pub const builtinBridgeErrorMessage = runtime_module.testing.builtinBridgeErrorMessage;

pub fn testViewByLabel(views: []const platform.ViewInfo, label: []const u8) ?platform.ViewInfo {
    for (views) |view| {
        if (std.mem.eql(u8, view.label, label)) return view;
    }
    return null;
}

pub fn testCanvasWidgetPartId(id: canvas.ObjectId, slot: canvas.ObjectId) canvas.ObjectId {
    if (id == 0) return 0;
    const base = id *% 16;
    const part = base +% slot;
    return if (part == 0) id else part;
}
