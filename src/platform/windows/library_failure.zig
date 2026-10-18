const std = @import("std");

/// The host loads some system DLLs on first use (lazy_dll.h). When one
/// cannot load, the host calls this with a message naming the feature, the
/// DLL, the function and the Windows error; the feature's call then fails
/// the way it already fails. std.log so a host's logFn (the widget runtime
/// routes it to the per-widget log file) keeps the line.
///
/// A file of its own, which platform/root.zig always pulls in on Windows:
/// every binary that links the platform's C++ (webview2_host.cpp,
/// shared_renderer_client.cpp) needs this symbol, including ones whose Zig
/// never references the Windows platform (Weaver's ReleaseFast tests).
export fn native_sdk_windows_report_library_failure(message: [*]const u8, message_len: usize) void {
    std.log.err("{s}", .{message[0..message_len]});
}
