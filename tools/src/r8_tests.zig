const std = @import("std");
const sdk = @import("sdk.zig");

test "R8 CLI accepts renamed or merged consumers and rejects unchanged or unrelated mappings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var fixture = std.testing.tmpDir(.{});
    defer fixture.cleanup();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = buffer[0..try fixture.dir.realPath(io, &buffer)];
    const tool = try sdk.toolPath(a, io);
    try fixture.dir.createDirPath(io, "io/jsbay/consumer");
    for ([_][]const u8{ "ConsumerMain", "JavaConsumer" }) |name| try fixture.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "io/jsbay/consumer/{s}.class", .{name}), .data = "class" });
    var zipped = try sdk.run(a, io, &.{ "zip", "-q", "-r", "consumer.jar", "io" }, path);
    defer zipped.deinit();
    try std.testing.expect(zipped.succeeded());
    const cases = [_]struct { mapping: []const u8, pass: bool }{
        .{ .mapping = "io.jsbay.consumer.ConsumerMain -> io.jsbay.consumer.ConsumerMain:\nio.jsbay.consumer.JavaConsumer -> a.b:\n", .pass = true },
        .{ .mapping = "io.jsbay.consumer.ConsumerMain -> io.jsbay.consumer.ConsumerMain:\n    1:1:void io.jsbay.consumer.JavaConsumer.run():0:0 -> main\n", .pass = true },
        .{ .mapping = "io.jsbay.consumer.ConsumerMain -> io.jsbay.consumer.ConsumerMain:\nio.jsbay.consumer.JavaConsumer -> io.jsbay.consumer.JavaConsumer:\n", .pass = false },
        .{ .mapping = "other.Main -> other.Main:\n", .pass = false },
    };
    for (cases) |case| {
        try fixture.dir.writeFile(io, .{ .sub_path = "mapping.txt", .data = case.mapping });
        var output = try sdk.run(a, io, &.{ tool, "check-r8", "mapping.txt", "consumer.jar" }, path);
        defer output.deinit();
        try std.testing.expectEqual(case.pass, output.succeeded());
    }
    // The JAR must contain both original inputs; a mapping alone is insufficient.
    try fixture.dir.writeFile(io, .{ .sub_path = "mapping.txt", .data = cases[0].mapping });
    var deleted = try sdk.run(a, io, &.{ "zip", "-q", "-d", "consumer.jar", "io/jsbay/consumer/JavaConsumer.class" }, path);
    defer deleted.deinit();
    try std.testing.expect(deleted.succeeded());
    var missing = try sdk.run(a, io, &.{ tool, "check-r8", "mapping.txt", "consumer.jar" }, path);
    defer missing.deinit();
    try std.testing.expect(!missing.succeeded());
}
