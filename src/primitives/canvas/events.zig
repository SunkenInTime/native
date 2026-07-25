const std = @import("std");
const geometry = @import("geometry");
const canvas = @import("root.zig");
const text_model = @import("text.zig");
const widget_model = @import("widgets.zig");

const ObjectId = canvas.ObjectId;
const TextInputEvent = text_model.TextInputEvent;
const TextRange = text_model.TextRange;
const Widget = widget_model.Widget;
const WidgetActions = widget_model.WidgetActions;
const WidgetKind = widget_model.WidgetKind;
const WidgetRole = widget_model.WidgetRole;
const WidgetState = widget_model.WidgetState;

pub const WidgetLayoutNode = struct {
    widget: Widget,
    frame: geometry.RectF,
    depth: usize,
    parent_index: ?usize = null,
};

pub const WidgetHit = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    depth: usize,
    index: usize,
    state: WidgetState,
    /// Semantic role of the hit widget (kind alone cannot distinguish a
    /// link hotspot from plain text, and links want a pointer cursor).
    role: WidgetRole = .none,
};

pub const WidgetPointerPhase = enum {
    hover,
    down,
    move,
    up,
    cancel,
    wheel,
};

pub const WidgetPointerEvent = struct {
    phase: WidgetPointerPhase,
    point: geometry.PointF,
    delta: geometry.OffsetF = .{},
    captured_id: ?ObjectId = null,
    /// How many rapid same-spot primary clicks this pointer event is
    /// part of: 1 = plain click, 2 = double (text inputs select the
    /// word under the pointer), 3 = triple (select all / the clicked
    /// line). The runtime derives it from recorded event timestamps —
    /// hosts do not forward a native click count — and clamps at 3, so
    /// a fourth rapid click repeats the triple behavior like platform
    /// text views. `.move` events during a drag carry the count of the
    /// press that started the gesture, which is how a double-click
    /// drag knows to extend by words.
    click_count: u8 = 1,
};

/// A press-family callback's geometry in node-local logical pixels. Width and
/// height are carried with the point so higher-level SDKs can derive stable
/// normalized coordinates without another layout lookup.
pub const WidgetPressEvent = struct {
    target_id: ObjectId,
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    click_count: u8 = 1,
};

pub const WidgetKeyboardPhase = enum {
    key_down,
    key_up,
    text_input,
};

pub const WidgetKeyboardModifiers = struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,

    pub fn hasCommandModifier(self: WidgetKeyboardModifiers) bool {
        return self.control or self.super;
    }

    pub fn hasNavigationModifier(self: WidgetKeyboardModifiers) bool {
        return self.control or self.alt or self.super;
    }
};

pub const WidgetKeyboardEvent = struct {
    phase: WidgetKeyboardPhase,
    focused_id: ?ObjectId = null,
    key: []const u8 = "",
    text: []const u8 = "",
    /// True when the runtime moved keyboard focus in response to this
    /// key BEFORE routing, so the event targets the newly focused
    /// widget (tree row navigation, group focus moves). Tree rows use
    /// it to tell "selection followed focus onto me" (dispatch select)
    /// from "an arrow landed on me in place" (collapse/expand intent).
    focus_moved: bool = false,
    edit: ?TextInputEvent = null,
    /// True when the runtime clamped a clipboard paste to fit capacity
    /// before building `edit`; apps that care about lost bytes must check
    /// this instead of assuming the whole clipboard landed.
    edit_truncated: bool = false,
    modifiers: WidgetKeyboardModifiers = .{},

    pub fn textEditEvent(self: WidgetKeyboardEvent) ?TextInputEvent {
        if (self.edit) |edit| return edit;
        return widgetKeyboardTextEditEvent(self);
    }
};

/// Enter in a multi-line editor EDITS instead of submitting: a textarea
/// maps a plain Enter keydown to a newline insert, and Shift+Enter stays
/// a newline too so single-line muscle memory never destroys text. The
/// primary-modifier chord (cmd/ctrl+Enter) is deliberately excluded —
/// that is the textarea's submit chord — as is alt+Enter, left free for
/// app shortcuts. Single-line kinds return null here and keep
/// enter-to-submit. Shared by the runtime edit path and the app `on_input`
/// dispatch so the retained text and the model always hear the same edit.
pub fn widgetKeyboardNewlineTextEditEvent(kind: WidgetKind, event: WidgetKeyboardEvent) ?TextInputEvent {
    if (kind != .textarea) return null;
    if (event.phase != .key_down or event.text.len != 0) return null;
    if (event.modifiers.control or event.modifiers.alt or event.modifiers.super) return null;
    if (!std.ascii.eqlIgnoreCase(event.key, "enter") and !std.ascii.eqlIgnoreCase(event.key, "return")) return null;
    return .{ .insert_text = "\n" };
}

/// The clipboard intent of a key event: cmd+C/X/V on macOS, ctrl+C/X/V
/// elsewhere (`hasCommandModifier` covers both). Shift/alt variants are
/// deliberately excluded so shift+ctrl+V-style paste-special chords stay
/// available to apps.
pub const WidgetClipboardAction = enum {
    copy,
    cut,
    paste,
};

pub fn widgetKeyboardClipboardAction(event: WidgetKeyboardEvent) ?WidgetClipboardAction {
    if (event.phase != .key_down) return null;
    if (!event.modifiers.hasCommandModifier() or event.modifiers.alt or event.modifiers.shift) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "c")) return .copy;
    if (std.ascii.eqlIgnoreCase(event.key, "x")) return .cut;
    if (std.ascii.eqlIgnoreCase(event.key, "v")) return .paste;
    return null;
}

pub const WidgetControlIntentKind = enum {
    press,
    toggle,
    select,
    set_value,
    scroll_by,
    scroll_to_start,
    scroll_to_end,
};

pub const WidgetControlIntent = struct {
    kind: WidgetControlIntentKind,
    actions: WidgetActions = .{},
    value: ?f32 = null,
    delta: f32 = 0,
};

pub const WidgetSemanticAction = enum {
    press,
    toggle,
    select,
    increment,
    decrement,
};

pub const WidgetFileDropEvent = struct {
    point: geometry.PointF,
    paths: []const []const u8 = &.{},
};

pub const WidgetDragEvent = struct {
    source_id: ObjectId = 0,
    point: geometry.PointF,
    delta: geometry.OffsetF = .{},
};

pub const WidgetEventPhase = enum {
    capture,
    target,
    bubble,
};

pub const WidgetEventRouteEntry = struct {
    phase: WidgetEventPhase,
    node_index: usize,
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
};

pub const WidgetEventRoute = struct {
    target: ?WidgetHit = null,
    /// Where a press on `target` actually lands: the deepest widget on the
    /// hit path that claims presses (`widgetClaimsPress`). Equal to
    /// `target` for interactive widgets; the nearest pressable ancestor
    /// when the raw hit is plain text/decoration; null when nothing on the
    /// path is pressable.
    press_target: ?WidgetHit = null,
    entries: []const WidgetEventRouteEntry = &.{},
};

pub const WidgetKeyboardRoute = struct {
    target: ?WidgetFocusTarget = null,
    entries: []const WidgetEventRouteEntry = &.{},
};

pub const WidgetFocusDirection = enum {
    forward,
    backward,
    left,
    right,
    up,
    down,
};

pub const WidgetFocusTarget = struct {
    id: ObjectId,
    kind: WidgetKind,
    bounds: geometry.RectF,
    index: usize,
    state: WidgetState,
};

pub const WidgetScrollMetrics = struct {
    present: bool = false,
    offset: f32 = 0,
    viewport_extent: f32 = 0,
    content_extent: f32 = 0,
};

pub const WidgetListMetrics = struct {
    present: bool = false,
    item_index: u32 = 0,
    item_count: u32 = 0,
};

pub const WidgetSemanticsNode = struct {
    id: ObjectId,
    role: WidgetRole,
    label: []const u8,
    value: ?f32 = null,
    text_value: []const u8 = "",
    placeholder: []const u8 = "",
    grid_row_index: ?usize = null,
    grid_column_index: ?usize = null,
    grid_row_count: ?usize = null,
    grid_column_count: ?usize = null,
    list: WidgetListMetrics = .{},
    scroll: WidgetScrollMetrics = .{},
    bounds: geometry.RectF,
    state: WidgetState,
    focusable: bool = false,
    actions: WidgetActions = .{},
    text_selection: ?TextRange = null,
    text_composition: ?TextRange = null,
    parent_index: ?usize = null,
};

pub const WidgetInvalidationKind = enum {
    added,
    removed,
    changed,
};

pub const WidgetInvalidation = struct {
    kind: WidgetInvalidationKind,
    id: ObjectId,
    previous_index: ?usize = null,
    next_index: ?usize = null,
    dirty_bounds: ?geometry.RectF = null,
    layout_dirty: bool = false,
    paint_dirty: bool = false,
    semantics_dirty: bool = false,
};

fn widgetKeyboardTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    return switch (event.phase) {
        .text_input => if (event.text.len > 0 and !event.modifiers.hasCommandModifier()) .{ .insert_text = event.text } else null,
        .key_down => widgetKeyboardKeyDownTextEditEvent(event),
        .key_up => null,
    };
}

fn widgetKeyboardKeyDownTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (widgetKeyboardSelectAllTextEditEvent(event)) |edit| return edit;
    if (widgetKeyboardCommandTextNavigationEvent(event)) |edit| return edit;
    if (widgetKeyboardWordTextNavigationEvent(event)) |edit| return edit;
    if (widgetKeyboardWordDeleteTextEditEvent(event)) |edit| return edit;
    if (event.modifiers.hasNavigationModifier()) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_backward;
    if (std.ascii.eqlIgnoreCase(event.key, "delete")) return .delete_forward;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .previous, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .next, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "home")) return .{ .move_caret = .{ .direction = .start, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "end")) return .{ .move_caret = .{ .direction = .end, .extend = event.modifiers.shift } };
    return null;
}

fn widgetKeyboardCommandTextNavigationEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (!event.modifiers.super or event.modifiers.alt) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .start, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .end, .extend = event.modifiers.shift } };
    return null;
}

fn widgetKeyboardWordTextNavigationEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (event.modifiers.super) return null;
    if (event.modifiers.alt == event.modifiers.control) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "arrowleft")) return .{ .move_caret = .{ .direction = .previous_word, .extend = event.modifiers.shift } };
    if (std.ascii.eqlIgnoreCase(event.key, "arrowright")) return .{ .move_caret = .{ .direction = .next_word, .extend = event.modifiers.shift } };
    return null;
}

fn widgetKeyboardWordDeleteTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (event.modifiers.super or event.modifiers.shift) return null;
    if (event.modifiers.alt == event.modifiers.control) return null;
    if (std.ascii.eqlIgnoreCase(event.key, "backspace")) return .delete_word_backward;
    if (std.ascii.eqlIgnoreCase(event.key, "delete")) return .delete_word_forward;
    return null;
}

fn widgetKeyboardSelectAllTextEditEvent(event: WidgetKeyboardEvent) ?TextInputEvent {
    if (!event.modifiers.hasCommandModifier() or event.modifiers.alt or event.modifiers.shift) return null;
    if (!std.ascii.eqlIgnoreCase(event.key, "a")) return null;
    return .{ .set_selection = .{ .anchor = 0, .focus = std.math.maxInt(usize) } };
}

pub fn widgetKeyboardControlIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    if (widget.state.disabled) return null;
    // Tree rows are ROLE-driven (any pressable row becomes one by
    // carrying `role = .treeitem`), so their keymap resolves before the
    // kind switch.
    if (widget.semantics.role == .treeitem) {
        if (widgetTreeItemKeyboardControlIntent(widget, keyboard)) |intent| return intent;
    }
    return switch (widget.kind) {
        .button, .icon_button => if (isWidgetActivationKey(keyboard.key))
            .{ .kind = .press, .actions = .{ .press = true } }
        else
            null,
        // The closed-trigger open keys: Enter/Space press, and
        // ArrowDown/Up ALSO press so an arrow on a closed select opens
        // its model-owned picker. With the picker mounted the runtime's
        // focus step consumes the arrows first (they walk into the
        // anchored menu), and a trigger marked `expanded` never
        // re-presses from an arrow — pressing an open trigger would
        // toggle it closed.
        .select, .combobox => if (isWidgetActivationKey(keyboard.key) or
            (isWidgetMenuOpenArrowKey(keyboard.key) and !(widget.state.expanded orelse false)))
            .{ .kind = .press, .actions = .{ .press = true } }
        else
            null,
        .accordion, .checkbox, .switch_control, .toggle, .toggle_button => if (isWidgetActivationKey(keyboard.key))
            .{ .kind = .toggle, .actions = .{ .toggle = true } }
        else
            null,
        .radio, .list_item, .menu_item, .data_cell, .segmented_control => if (isWidgetActivationKey(keyboard.key))
            .{
                .kind = .select,
                .actions = .{
                    .select = true,
                    .press = widget.command.len > 0,
                },
            }
        else
            null,
        .slider => if (widgetSliderKeyboardValue(widget.value, keyboard)) |next_value|
            .{
                .kind = .set_value,
                .actions = .{
                    .increment = next_value > widget.value,
                    .decrement = next_value < widget.value,
                },
                .value = std.math.clamp(next_value, 0, 1),
            }
        else
            null,
        // The split divider is the ARIA separator: horizontal arrows
        // adjust the parent split's fraction, Home/End jump to the
        // clamp edges (the runtime clamps against the panes' min
        // widths when it applies the value).
        .split_divider => if (widgetSplitDividerKeyboardValue(widget.value, keyboard)) |next_value|
            .{
                .kind = .set_value,
                .actions = .{
                    .increment = next_value > widget.value,
                    .decrement = next_value < widget.value,
                },
                .value = std.math.clamp(next_value, 0, 1),
            }
        else
            null,
        .grid => if (widget.layout.virtualized) widgetScrollKeyboardIntent(widget, keyboard) else null,
        .scroll_view, .list, .data_grid, .table => widgetScrollKeyboardIntent(widget, keyboard),
        else => null,
    };
}

pub fn widgetSemanticControlIntent(widget: Widget, action: WidgetSemanticAction) ?WidgetControlIntent {
    return widgetSemanticControlIntentWithActions(widget, action, semanticActions(widget));
}

pub fn widgetSemanticControlIntentWithActions(widget: Widget, action: WidgetSemanticAction, actions: WidgetActions) ?WidgetControlIntent {
    if (widget.state.disabled or widget.semantics.hidden) return null;
    return switch (action) {
        .press => if (actions.press)
            widgetSemanticPressControlIntent(widget, actions)
        else
            null,
        .toggle => if (actions.toggle)
            .{ .kind = .toggle, .actions = .{ .toggle = true } }
        else
            null,
        .select => if (actions.select)
            .{
                .kind = .select,
                .actions = .{
                    .select = true,
                    .press = actions.press,
                },
            }
        else
            null,
        .increment => widgetSemanticStepControlIntent(widget, .increment, actions),
        .decrement => widgetSemanticStepControlIntent(widget, .decrement, actions),
    };
}

fn widgetSemanticPressControlIntent(widget: Widget, actions: WidgetActions) WidgetControlIntent {
    if (widget.semantics.role == .treeitem and actions.select) {
        return .{
            .kind = .select,
            .actions = .{
                .press = true,
                .select = true,
            },
        };
    }
    return switch (widget.kind) {
        .radio, .list_item, .menu_item, .data_cell, .segmented_control => if (actions.select)
            .{
                .kind = .select,
                .actions = .{
                    .press = true,
                    .select = true,
                },
            }
        else
            .{ .kind = .press, .actions = .{ .press = true } },
        else => .{ .kind = .press, .actions = .{ .press = true } },
    };
}

pub fn isWidgetActivationKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "space") or std.ascii.eqlIgnoreCase(key, "enter");
}

/// The editable text-entry widget kinds: a focused one of these owns
/// typing outright. Key routing treats the set STRUCTURALLY — a focused
/// text entry consumes character keys whether or not the app bound
/// `on_input`, so an app-level key fallback (a bare-space transport
/// toggle, single-letter accelerators) can never fire while the user is
/// typing. One definition serves the typed-dispatch path (`Ui.Tree`)
/// and the ui-app fallback gate.
pub fn isWidgetTextEntry(widget: Widget) bool {
    return switch (widget.kind) {
        .input, .text_field, .search_field, .combobox, .textarea => true,
        else => false,
    };
}

/// The arrow keys that open a closed select/combobox trigger's picker
/// (and, once it is mounted, walk into it).
pub fn isWidgetMenuOpenArrowKey(key: []const u8) bool {
    return std.ascii.eqlIgnoreCase(key, "arrowdown") or std.ascii.eqlIgnoreCase(key, "arrowup");
}

pub fn widgetSliderKeyboardValue(current: f32, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const step: f32 = if (keyboard.modifiers.shift) 0.1 else 0.05;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
        return current - step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
        return current + step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return 0;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return 1;
    return null;
}

/// Fraction steps for the split divider: the slider's step sizes, on the
/// horizontal axis only (the vertical arrows stay free for tree/list
/// focus travel around the divider).
pub fn widgetSplitDividerKeyboardValue(current: f32, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const step: f32 = if (keyboard.modifiers.shift) 0.1 else 0.05;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) return current - step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) return current + step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return 0;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return 1;
    return null;
}

/// The ARIA tree-row keymap, resolved on the routed keyboard target:
/// - Enter/Space activate (select, plus press when a command is bound).
/// - A key that MOVED focus onto this row (`focus_moved`) selects it —
///   selection follows focus, dispatched through the row's press
///   handler so the model owns it.
/// - Left on an expanded row collapses, Right on a collapsed row
///   expands (both as toggle intents — the model owns the state through
///   `on_toggle`; the runtime's focus pass already handled the
///   move-to-parent / move-to-first-child cases by moving focus, which
///   arrives here as `focus_moved`).
fn widgetTreeItemKeyboardControlIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (isWidgetActivationKey(keyboard.key)) {
        return .{
            .kind = .select,
            .actions = .{
                .select = true,
                .press = widget.command.len > 0,
            },
        };
    }
    const navigation_key = std.ascii.eqlIgnoreCase(keyboard.key, "arrowup") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or
        std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or
        std.ascii.eqlIgnoreCase(keyboard.key, "home") or
        std.ascii.eqlIgnoreCase(keyboard.key, "end");
    if (!navigation_key) return null;
    if (keyboard.focus_moved) {
        return .{
            .kind = .select,
            .actions = .{
                .select = true,
                .press = widget.command.len > 0,
            },
        };
    }
    const expanded = widget.state.expanded orelse return null;
    if (expanded and std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft")) {
        return .{ .kind = .toggle, .actions = .{ .toggle = true } };
    }
    if (!expanded and std.ascii.eqlIgnoreCase(keyboard.key, "arrowright")) {
        return .{ .kind = .toggle, .actions = .{ .toggle = true } };
    }
    return null;
}

pub fn widgetScrollKeyboardIntent(widget: Widget, keyboard: WidgetKeyboardEvent) ?WidgetControlIntent {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    if (widget.state.disabled) return null;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "home")) return .{ .kind = .scroll_to_start, .actions = .{ .decrement = true } };
    if (std.ascii.eqlIgnoreCase(keyboard.key, "end")) return .{ .kind = .scroll_to_end, .actions = .{ .increment = true } };
    const delta = widgetScrollKeyboardDelta(widget, keyboard) orelse return null;
    return .{
        .kind = .scroll_by,
        .actions = .{
            .increment = delta > 0,
            .decrement = delta < 0,
        },
        .delta = delta,
    };
}

pub fn widgetScrollKeyboardDelta(widget: Widget, keyboard: WidgetKeyboardEvent) ?f32 {
    if (keyboard.phase != .key_down or keyboard.modifiers.hasNavigationModifier()) return null;
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    const line_step = @max(24, viewport.height * 0.35);
    const page_step = @max(line_step, viewport.height * 0.85);
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowleft") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowup")) {
        return -line_step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "arrowright") or std.ascii.eqlIgnoreCase(keyboard.key, "arrowdown")) {
        return line_step;
    }
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pageup")) return -page_step;
    if (std.ascii.eqlIgnoreCase(keyboard.key, "pagedown")) return page_step;
    return null;
}

const WidgetSemanticStepDirection = enum {
    increment,
    decrement,
};

fn widgetSemanticStepControlIntent(widget: Widget, direction: WidgetSemanticStepDirection, actions: WidgetActions) ?WidgetControlIntent {
    const increment = direction == .increment;
    if (increment and !actions.increment) return null;
    if (!increment and !actions.decrement) return null;

    const intent_actions = WidgetActions{
        .increment = increment,
        .decrement = !increment,
    };
    return switch (widget.kind) {
        .slider => .{
            .kind = .set_value,
            .actions = intent_actions,
            .value = std.math.clamp(widget.value + if (increment) @as(f32, 0.05) else @as(f32, -0.05), 0, 1),
        },
        .grid, .scroll_view, .list, .data_grid, .table => .{
            .kind = .scroll_by,
            .actions = intent_actions,
            .delta = widgetSemanticScrollDelta(widget, direction),
        },
        else => null,
    };
}

fn widgetSemanticScrollDelta(widget: Widget, direction: WidgetSemanticStepDirection) f32 {
    const viewport = widget.frame.inset(widget.layout.padding).normalized();
    const line_step = @max(24, viewport.height * 0.35);
    const page_step = @max(line_step, viewport.height * 0.85);
    return if (direction == .increment) page_step else -page_step;
}

pub fn semanticActions(widget: Widget) WidgetActions {
    if (widget.state.disabled) return .{};
    var actions = defaultSemanticActions(widget);
    actions.focus = actions.focus or widget.semantics.actions.focus;
    actions.press = actions.press or widget.semantics.actions.press;
    actions.toggle = actions.toggle or widget.semantics.actions.toggle;
    actions.increment = actions.increment or widget.semantics.actions.increment;
    actions.decrement = actions.decrement or widget.semantics.actions.decrement;
    actions.set_text = actions.set_text or widget.semantics.actions.set_text;
    actions.set_selection = actions.set_selection or widget.semantics.actions.set_selection;
    actions.select = actions.select or widget.semantics.actions.select;
    actions.drag = actions.drag or widget.semantics.actions.drag;
    actions.drop_files = actions.drop_files or widget.semantics.actions.drop_files;
    actions.dismiss = actions.dismiss or widget.semantics.actions.dismiss;
    if (widget.state.read_only) {
        actions.set_text = false;
    }
    return actions;
}

pub fn defaultSemanticActions(widget: Widget) WidgetActions {
    if (widget.state.disabled) return .{};

    var actions = WidgetActions{
        .focus = widget.semantics.focusable or defaultFocusable(widget),
    };
    switch (widget.kind) {
        .button, .icon_button, .select => actions.press = true,
        .menu_item => {
            actions.press = true;
            actions.select = true;
        },
        .accordion, .checkbox, .switch_control, .toggle, .toggle_button => actions.toggle = true,
        .radio => {
            actions.select = true;
            if (widget.command.len > 0) actions.press = true;
        },
        .input, .text_field, .search_field, .combobox, .textarea => {
            if (widget.kind == .combobox) actions.press = true;
            actions.set_text = true;
            actions.set_selection = true;
        },
        .slider => {
            actions.increment = true;
            actions.decrement = true;
        },
        .resizable => actions.drag = true,
        .split_divider => {
            actions.drag = true;
            actions.increment = true;
            actions.decrement = true;
        },
        .dialog, .drawer, .sheet, .popover, .menu_surface, .dropdown_menu, .tooltip => actions.dismiss = true,
        .list_item, .segmented_control, .data_cell => {
            actions.select = true;
            if (widget.command.len > 0) actions.press = true;
        },
        else => {},
    }
    // Tree rows are role-driven: any row carrying `role = .treeitem` is
    // selectable through the tree keymap and assistive select actions.
    if (widget.semantics.role == .treeitem) {
        actions.select = true;
        if (widget.command.len > 0) actions.press = true;
    }
    return actions;
}

pub fn defaultFocusable(widget: Widget) bool {
    // Tree rows are role-driven: `role = .treeitem` on any row makes it
    // part of the tree's roving keyboard focus set.
    if (widget.semantics.role == .treeitem) return !widget.state.disabled;
    return switch (widget.kind) {
        .scroll_view, .accordion, .button, .toggle_button, .icon_button, .select, .input, .text_field, .search_field, .combobox, .textarea, .menu_item, .list_item, .data_cell, .segmented_control, .checkbox, .radio, .switch_control, .toggle, .slider, .split_divider => !widget.state.disabled,
        else => false,
    };
}
