#pragma once

/* System DLLs that only some apps use, loaded on first use instead of at
 * process start. A static import makes Windows map the DLL, and everything
 * it imports, into every process before main runs: SHELL32 alone brings
 * Windows.Storage and shcore, Media Foundation brings MFCORE and RTWorkQ.
 * Measured in a Weaver host running ten clock widgets (none of which play
 * audio, open URLs, show a tray icon or use the GPU presenter), loading
 * them at first use instead drops ten modules and 348 KiB of private image
 * pages, about 0.5 MiB of private working set. Each DLL below now loads
 * the first time a feature calls into it.
 *
 * Use NATIVE_SDK_LAZY_PROC(dll, Function, "what stops working") and keep the
 * result in a static: the pointer has exactly the type of the SDK header's
 * declaration, and resolution runs once per call site. A null result means
 * the feature cannot run; the loader has already reported why (DLL,
 * function, Windows error) through native_sdk_windows_report_library_failure,
 * which the platform layer logs. Callers fail the way the feature already
 * fails, never crash. */

#include <windows.h>

#include <atomic>
#include <mutex>
#include <stdio.h>
#include <string.h>

struct NativeSdkLazyDll {
    const wchar_t *file;
    const char *name;
    /* What a user can do when the DLL is missing, appended to the
     * report; null when there is nothing to suggest. */
    const char *remedy = nullptr;
    std::once_flag once;
    HMODULE module = nullptr;
    DWORD load_error = 0;
    /* The feature whose call last reported that this DLL would not load:
     * one feature resolving several functions reports the load failure
     * once, not once per function. */
    std::atomic<const char *> load_failure_reported_for{ nullptr };
};

inline constexpr const char *kNativeSdkMediaFeaturePackRemedy =
    "Windows N and KN editions ship without Media Foundation; install the Media Feature Pack (Settings > Apps > Optional features)";
inline NativeSdkLazyDll kNativeSdkMf{ L"mf.dll", "MF.dll", kNativeSdkMediaFeaturePackRemedy };
inline NativeSdkLazyDll kNativeSdkMfPlat{ L"mfplat.dll", "MFPlat.dll", kNativeSdkMediaFeaturePackRemedy };
inline NativeSdkLazyDll kNativeSdkWinHttp{ L"winhttp.dll", "WINHTTP.dll" };
inline NativeSdkLazyDll kNativeSdkShell32{ L"shell32.dll", "SHELL32.dll" };
inline NativeSdkLazyDll kNativeSdkDComp{ L"dcomp.dll", "dcomp.dll" };
inline NativeSdkLazyDll kNativeSdkDwmApi{ L"dwmapi.dll", "dwmapi.dll" };

/* Implemented by the Windows platform layer (root.zig), which logs it. */
extern "C" void native_sdk_windows_report_library_failure(const char *message, size_t message_len);

inline void nativeSdkReportLazyDllFailure(const NativeSdkLazyDll &dll, const char *proc, const char *feature, bool load_failed, DWORD error) {
    char reason[256] = "unknown error";
    DWORD reason_len = FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, nullptr, error, 0, reason, sizeof(reason), nullptr);
    while (reason_len > 0 && (reason[reason_len - 1] == '\r' || reason[reason_len - 1] == '\n' || reason[reason_len - 1] == ' ' || reason[reason_len - 1] == '.')) reason[--reason_len] = '\0';
    char message[768];
    const char *remedy_separator = load_failed && dll.remedy ? ". " : "";
    const char *remedy = load_failed && dll.remedy ? dll.remedy : "";
    int len = load_failed
        ? snprintf(message, sizeof(message), "%s unavailable: %s could not be loaded from System32 (needed for %s): %s (Windows error %lu)%s%s", feature, dll.name, proc, reason, (unsigned long)error, remedy_separator, remedy)
        : snprintf(message, sizeof(message), "%s unavailable: %s has no export %s: %s (Windows error %lu)", feature, dll.name, proc, reason, (unsigned long)error);
    if (len < 0) return;
    native_sdk_windows_report_library_failure(message, strnlen(message, sizeof(message)));
}

inline FARPROC nativeSdkLazyProcAddress(NativeSdkLazyDll &dll, const char *proc, const char *feature) {
    std::call_once(dll.once, [&dll] {
        /* System32 only: these are OS components, never something an app
         * directory or the working directory should be able to supply. */
        dll.module = LoadLibraryExW(dll.file, nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!dll.module) dll.load_error = GetLastError();
    });
    if (!dll.module) {
        if (dll.load_failure_reported_for.exchange(feature) != feature) nativeSdkReportLazyDllFailure(dll, proc, feature, true, dll.load_error);
        return nullptr;
    }
    FARPROC address = GetProcAddress(dll.module, proc);
    if (!address) nativeSdkReportLazyDllFailure(dll, proc, feature, false, GetLastError());
    return address;
}

#define NATIVE_SDK_LAZY_PROC(dll, proc, feature) \
    reinterpret_cast<decltype(&proc)>(nativeSdkLazyProcAddress((dll), #proc, (feature)))
