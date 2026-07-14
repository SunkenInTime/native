#pragma once

#include <windows.h>

// Private verification seam. Production code ignores it unless the runtime is
// launched with WEAVER_DPI_DIAGNOSTIC=1. The verifier changes the authoritative
// per-window DPI and drives the same relayout, resize, repaint, and visual-rebind
// path as WM_DPICHANGED without requiring five physical monitors.
static constexpr UINT kWeaverDpiDiagnosticSetDpiMessage = WM_APP + 0x3D1;
