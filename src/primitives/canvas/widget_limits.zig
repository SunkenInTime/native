// Widget-depth receipt (2026-07-29): executing every shipped Weaver example
// measured a maximum lowered depth of 8 (noro-shell). 32 leaves 4x headroom,
// including painted row/column lowering, and 4 MiB QuickJS recursion measured
// 70 trivial JS calls. Layout/routing/semantics/invalidation use at most four
// transient 32-entry usize/?usize stacks (256 bytes each); unused entries are
// undefined except the 256-byte semantics stack, so their combined maximum is
// 1 KiB of call-lifetime storage. Pinned by cli/src/index.ts
// nativeWidgetDepthLimit.
pub const max_widget_depth: usize = 32;
