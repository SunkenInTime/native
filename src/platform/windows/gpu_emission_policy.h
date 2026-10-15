#pragma once

#include <stdint.h>

/* A GPU surface keeps at most one frame emission in flight. Producers that
 * re-arm it at a new delay (input, restore) supersede the pending one, but a
 * winmm deadline timer that has fired, or a direct post, cannot be recalled:
 * the superseded emission still arrives. If it emitted too, it would start a
 * second frame chain that re-arms itself forever.
 *
 * So every scheduled emission carries a generation, and only the emission
 * currently scheduled may emit. Generations come from one process-wide
 * counter, so they never repeat across surfaces or surface lifetimes the
 * way winmm timer ids (recycled after ~4K timers) or a per-surface counter
 * would. Nothing is cancelled by timer id: a stale deadline fires and is
 * dropped. */

enum WeaverGpuEmissionSource : int {
    kWeaverGpuEmissionNone = 0,
    kWeaverGpuEmissionPosted = 1,   /* posted now; it was already due */
    kWeaverGpuEmissionDeadline = 2, /* posted by a winmm deadline timer */
    kWeaverGpuEmissionUiTimer = 3,  /* WM_TIMER from SetTimer, which replaces itself */
};

struct WeaverGpuEmission {
    bool scheduled = false;
    int source = kWeaverGpuEmissionNone;
    uint32_t generation = 0;
};

/* Zero is never a live generation. Wraps after 2^32 schedules. */
inline uint32_t weaverNextGpuEmissionGeneration(uint32_t previous) {
    const uint32_t next = previous + 1;
    return next == 0 ? 1 : next;
}

/* The deadline timer's user value carries both the surface HWND and the
 * generation. Windows keeps HWND values within 32 bits so 32- and 64-bit
 * processes can share them. */
inline uint64_t weaverPackGpuDeadline(uint32_t hwnd32, uint32_t generation) {
    return ((uint64_t)generation << 32) | hwnd32;
}
inline uint32_t weaverGpuDeadlineHwnd(uint64_t user) { return (uint32_t)user; }
inline uint32_t weaverGpuDeadlineGeneration(uint64_t user) { return (uint32_t)(user >> 32); }

inline bool weaverGpuEmissionAccepts(const WeaverGpuEmission &current, int source,
    uint32_t generation) {
    return current.scheduled && current.source == source &&
        current.generation == generation;
}

/* Re-arming replaces the in-flight emission only if the replacement was
 * actually scheduled; otherwise the old one still arrives and still counts,
 * so the surface never loses its next frame. */
inline WeaverGpuEmission weaverGpuEmissionAfterRearm(const WeaverGpuEmission &previous,
    const WeaverGpuEmission &attempt) {
    return attempt.scheduled ? attempt : previous;
}
