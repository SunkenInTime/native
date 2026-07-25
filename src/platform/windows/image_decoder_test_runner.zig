const std = @import("std");
const test_assets = @import("native_sdk_test_assets");

extern fn native_sdk_windows_decode_image(bytes: [*]const u8, bytes_len: usize, pixels: [*]u8, pixels_len: usize, out_width: *usize, out_height: *usize) c_int;

test "WIC decodes a real baseline JPEG at the stock image budget boundary" {
    // The deck fixture is a 512x512 baseline JPEG. Its decoded RGBA payload is
    // exactly the stock 1 MiB per-image budget, so an off-by-one or an encoded-
    // versus-decoded budget regression fails here.
    var pixels: [512 * 512 * 4]u8 = undefined;
    var width: usize = 0;
    var height: usize = 0;
    try std.testing.expectEqual(
        @as(c_int, 1),
        native_sdk_windows_decode_image(test_assets.baseline_jpeg.ptr, test_assets.baseline_jpeg.len, &pixels, pixels.len, &width, &height),
    );
    try std.testing.expectEqual(@as(usize, 512), width);
    try std.testing.expectEqual(@as(usize, 512), height);
    try std.testing.expectEqual(@as(usize, 512 * 512 * 4), pixels.len);
}
