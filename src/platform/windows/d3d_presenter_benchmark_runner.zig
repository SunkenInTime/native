const std = @import("std");

extern fn native_sdk_d3d_gradient_benchmark() callconv(.c) c_int;

pub fn main() !void {
    if (native_sdk_d3d_gradient_benchmark() != 0) {
        return error.D3DGradientBenchmarkFailed;
    }
}
