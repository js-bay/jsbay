const std = @import("std");
const overlay = @import("ios_stdlib_overlay.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next() orelse return error.Usage;
    const process = args.next() orelse return error.Usage;
    const output = args.next() orelse return error.Usage;
    if (args.next() != null) return error.Usage;
    return overlay.run(init, &.{ process, output });
}
