#pragma once

#include <windows.h>
#include <stddef.h>
#include <stdint.h>

/// Opaque DirectComposition presenter. The Win32 host owns one instance
/// per GPU surface and keeps its ordinary child HWND for input and pacing.
struct NativeSdkD3DPresenter;

/// Hardware-only probe. `WEAVER_FORCE_SOFTWARE=1` is checked here so the
/// exact production fallback can be exercised without an RDP session.
bool nativeSdkD3DHardwareAvailable();

/// Creates a flip-model, premultiplied-alpha composition target for the
/// top-level widget window. Never selects WARP.
NativeSdkD3DPresenter *nativeSdkD3DPresenterCreate(HWND window);
void nativeSdkD3DPresenterDestroy(NativeSdkD3DPresenter *presenter);

/// Decodes and applies one NSGP v4 full/patch packet, emits all supported
/// shape commands with one instanced draw, and performs one vsynced present.
/// False is a loud refusal: the SDK immediately uses its pixel fallback.
bool nativeSdkD3DPresenterPresent(
    NativeSdkD3DPresenter *presenter,
    double logical_width,
    double logical_height,
    double scale,
    uint8_t clear_r,
    uint8_t clear_g,
    uint8_t clear_b,
    uint8_t clear_a,
    const uint8_t *packet,
    size_t packet_len);

