const std = @import("std");
const core = @import("core.zig");
const view = @import("view.zig");

/// Building a `RuntimeView` or `Runtime` writes its small fields, so the span
/// they cover becomes resident. Large storage carries `align(storage_align)`
/// to sit ahead of them (view.zig); a large field without it lands among the
/// small ones and stretches the span across megabytes.
const Span = struct { bytes: usize, largest_field: []const u8, largest_bytes: usize };

fn smallFieldSpan(comptime T: type) Span {
    var first: usize = std.math.maxInt(usize);
    var end: usize = 0;
    var span: Span = .{ .bytes = 0, .largest_field = "", .largest_bytes = 0 };
    inline for (@typeInfo(T).@"struct".fields) |field| {
        const alignment = field.alignment orelse @alignOf(field.type);
        if (alignment >= view.storage_align or @sizeOf(field.type) == 0) continue;
        first = @min(first, @offsetOf(T, field.name));
        end = @max(end, @offsetOf(T, field.name) + @sizeOf(field.type));
        if (@sizeOf(field.type) > span.largest_bytes) {
            span.largest_bytes = @sizeOf(field.type);
            span.largest_field = field.name;
        }
    }
    span.bytes = end - first;
    return span;
}

fn expectSmallFieldsWithin(comptime T: type, limit: usize) !void {
    const span = smallFieldSpan(T);
    if (span.bytes <= limit) return;
    std.debug.print(
        "{s}: small fields span {d} bytes, limit {d}; largest field without align(storage_align): {s} ({d} bytes)\n",
        .{ @typeName(T), span.bytes, limit, span.largest_field, span.largest_bytes },
    );
    return error.SmallFieldsScattered;
}

// Receipts (2026-10-15, Windows x64): RuntimeView 2,850 bytes, Runtime
// 10,142 bytes, against 32 and 22 scattered pages before. The limits are
// tripwires: small fields can grow several times over, while one stray
// fixed-capacity array lands at megabytes.
test "small fields stay packed behind aligned storage" {
    try expectSmallFieldsWithin(view.RuntimeView, 16 * 1024);
    try expectSmallFieldsWithin(core.Runtime, 64 * 1024);
}
