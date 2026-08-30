#pragma once

#include <stdint.h>

/* The renderer is launched immediately before the first GPU widget. Give that
 * first handshake room for process startup; later crash-recovery probes must
 * stay short because they run on the widget UI thread. */
constexpr uint32_t kWeaverSharedRendererInitialConnectTimeoutMs = 2000;
constexpr uint32_t kWeaverSharedRendererReconnectTimeoutMs = 100;
constexpr uint32_t kWeaverSharedRendererRecoveryIntervalMs = 1000;

inline uint32_t weaverSharedRendererConnectTimeoutMs(bool attempted) {
    return attempted ? kWeaverSharedRendererReconnectTimeoutMs
                     : kWeaverSharedRendererInitialConnectTimeoutMs;
}

inline bool weaverSharedRendererRecoveryPumpNeeded(bool has_client,
    bool connected, bool presented) {
    return has_client && !connected && presented;
}
