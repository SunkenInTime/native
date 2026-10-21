#pragma once

#include <stdint.h>

/* The renderer is launched immediately before the first GPU widget. Give that
 * first handshake room for process startup. Every later attempt runs on the
 * widget UI thread, on each frame presented while the renderer is down (every
 * resize step, the 1 s recovery pump), so it waits for nothing: one look for
 * the pipe. Receipt (2026-10-22, renderer exe missing): a 100 ms bounded
 * retry loop here froze a dragged widget ~110 ms every second and a resized
 * one ~230 ms per step. */
constexpr uint32_t kWeaverSharedRendererInitialConnectTimeoutMs = 2000;
constexpr uint32_t kWeaverSharedRendererReconnectTimeoutMs = 0;
constexpr uint32_t kWeaverSharedRendererRecoveryIntervalMs = 1000;

inline uint32_t weaverSharedRendererConnectTimeoutMs(bool attempted) {
    return attempted ? kWeaverSharedRendererReconnectTimeoutMs
                     : kWeaverSharedRendererInitialConnectTimeoutMs;
}

/* WaitNamedPipe's own wait per look. A missing pipe answers at once; this
 * bounds only a renderer whose pipe instances are all busy. 0 would mean the
 * server's default wait (NMPWAIT_USE_DEFAULT_WAIT), so a probe asks for 1 ms. */
inline uint32_t weaverSharedRendererPipeWaitMs(uint32_t timeout_ms) {
    return timeout_ms == 0 ? 1 : (timeout_ms < 100 ? timeout_ms : 100);
}

inline bool weaverSharedRendererRecoveryPumpNeeded(bool has_client,
    bool connected, bool presented) {
    return has_client && !connected && presented;
}
