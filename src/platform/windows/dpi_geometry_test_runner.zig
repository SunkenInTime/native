const std = @import("std");

extern fn native_sdk_dpi_geometry_tests() callconv(.c) c_int;

test "Windows DPI geometry and renderer protocol contract" {
    try std.testing.expectEqual(@as(c_int, 0), native_sdk_dpi_geometry_tests());
}
