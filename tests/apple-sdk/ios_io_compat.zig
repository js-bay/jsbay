const std = @import("std");

pub export fn jsbay_ios_io_compat_probe(pathname: [*:0]const u8) c_int {
    probe(pathname) catch |err| return @intFromError(err);
    return 0;
}

fn probe(pathname: [*:0]const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = std.mem.span(pathname);
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);

    try file.writePositionalAll(io, "offset", 3);
    const header = "A";
    const pieces = [_][]const u8{ "", "BC", "D" };
    const expected_write = "ABCDD";
    const written = try io.vtable.fileWritePositional(io.userdata, file, header, &pieces, 2, 8);
    if (written == 0 or written > expected_write.len) return error.InvalidWritePrefix;
    var write_prefix: [expected_write.len]u8 = undefined;
    const prefix_read = try file.readPositionalAll(io, write_prefix[0..written], 8);
    if (prefix_read != written or !std.mem.eql(u8, write_prefix[0..written], expected_write[0..written])) return error.BadWritePrefix;
    try file.writePositionalAll(io, expected_write[written..], 8 + written);

    const expected_file = "\x00\x00\x00offseABCDD";
    var ignored_first: [0]u8 = .{};
    var first: [4]u8 = undefined;
    var ignored: [0]u8 = .{};
    var second: [16]u8 = undefined;
    const buffers = [_][]u8{ ignored_first[0..], first[0..], ignored[0..], second[0..] };
    const read = try io.vtable.fileReadPositional(io.userdata, file, &buffers, 0);
    if (read == 0 or read > expected_file.len) return error.InvalidReadPrefix;
    var combined: [expected_file.len]u8 = undefined;
    const first_read = @min(read, first.len);
    @memcpy(combined[0..first_read], first[0..first_read]);
    if (read > first_read) @memcpy(combined[first_read..read], second[0 .. read - first_read]);
    if (!std.mem.eql(u8, combined[0..read], expected_file[0..read])) return error.BadMultiBufferPrefix;
    const remaining = try file.readPositionalAll(io, combined[read..], read);
    if (read + remaining != expected_file.len or !std.mem.eql(u8, combined[0..], expected_file)) return error.BadMultiBufferRead;

    var eof: [4]u8 = undefined;
    if (try file.readPositional(io, &.{ eof[0..], ignored[0..] }, 4_096) != 0) return error.ExpectedEof;
    const read_only = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer read_only.close(io);
    var rejected = false;
    read_only.writePositionalAll(io, "x", 0) catch |err| switch (err) {
        error.NotOpenForWriting, error.AccessDenied, error.PermissionDenied => rejected = true,
        else => return err,
    };
    if (!rejected) return error.ReadOnlyWriteUnexpectedlySucceeded;
}
