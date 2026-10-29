const std = @import("std");

pub fn main(init: std.process.Init) !void {
    return @import("platform_test.zig").main(init);
}
