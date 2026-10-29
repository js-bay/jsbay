//! The build switch must turn persistent storage off while retaining normal source execution. This exercises the same engine-level entry point used by the C ABI after it has accepted cache options.

const std = @import("std");
const testing = std.testing;
const cache = @import("../script/cache.zig");
const build_options = @import("build_options");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");

test "cache disabled: source executes and no artifact is published" {
    comptime std.debug.assert(!build_options.bytecode_cache);
    var random: [8]u8 = undefined;
    testing.io.random(&random);
    var name: [96]u8 = undefined;
    const directory = try std.fmt.bufPrint(&name, ".zig-cache/cache-disabled-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer std.Io.Dir.cwd().deleteTree(testing.io, directory) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, directory);

    var source: [4 * 1024 + 64]u8 = undefined;
    @memset(&source, ' ');
    const program = "globalThis.__off__ = 42;";
    @memcpy(source[0..program.len], program);
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const result = cache.evalCached(id, &source, "disabled.js", directory, "v1");
    defer {
        if (result.result) |value| std.heap.c_allocator.free(@constCast(value));
        if (result.err_is_heap) if (result.err) |err| std.heap.c_allocator.free(@constCast(err));
    }
    try testing.expect(result.err == null);
    try testing.expect(!result.cache_hit);
    try helpers.expectEvalEquals(id, "String(globalThis.__off__)", "42");

    var dir = try std.Io.Dir.cwd().openDir(testing.io, directory, .{ .iterate = true });
    defer dir.close(testing.io);
    var iterator = dir.iterate();
    try testing.expect((try iterator.next(testing.io)) == null);
}
