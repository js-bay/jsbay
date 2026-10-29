const std = @import("std");
const cache = @import("bytecode_cache");

test "artifact identity separates version and fingerprint" {
    const allocator = std.testing.allocator;
    const source = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const name = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const first = cache.artifactPath(allocator, "cache", "v1", "build-a", source, name) orelse return error.OutOfMemory;
    defer allocator.free(first);
    const second = cache.artifactPath(allocator, "cache", "v1", "build-b", source, name) orelse return error.OutOfMemory;
    defer allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "unsafe artifact components have no path" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(cache.artifactPath(std.testing.allocator, "cache", "../outside", "build", key, key) == null);
}

test "artifact keys must be full lowercase SHA-256 hex" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    var malicious_source = key.*;
    malicious_source[20] = '/';
    var malicious_name = key.*;
    malicious_name[40] = '/';
    try expectNoArtifact(cache.artifactPath(std.testing.allocator, "cache", "v1", "build", &malicious_source, key));
    try expectNoArtifact(cache.artifactPath(std.testing.allocator, "cache", "v1", "build", key[0..63], key));
    try expectNoArtifact(cache.artifactPath(std.testing.allocator, "cache", "v1", "build", key, &malicious_name));
    try expectNoArtifact(cache.artifactPath(std.testing.allocator, "cache", "v1", "build", key, key[0..63]));
    var non_hex = key.*;
    non_hex[17] = 'G';
    try expectNoArtifact(cache.artifactPath(std.testing.allocator, "cache", "v1", "build", &non_hex, key));
    non_hex = key.*;
    non_hex[31] = 'A';
    try expectNoArtifact(cache.artifactPath(std.testing.allocator, "cache", "v1", "build", key, &non_hex));
}

fn expectNoArtifact(path: ?[]u8) !void {
    if (path) |owned| {
        std.testing.allocator.free(owned);
        return error.UnsafeArtifactPath;
    }
}

test "atomic write publishes bytes without a temporary artifact" {
    const allocator = std.testing.allocator;
    var name: [96]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    var random: [8]u8 = undefined;
    io.random(&random);
    const directory = try std.fmt.bufPrint(&name, ".zig-cache/bytecode-cache-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const path = try std.fmt.allocPrint(allocator, "{s}/artifact.bc", .{directory});
    defer allocator.free(path);
    cache.writeAtomically(io, allocator, path, "payload");
    const read = cache.read(io, allocator, path) orelse return error.ExpectedArtifact;
    defer allocator.free(read);
    try std.testing.expectEqualStrings("payload", read);
    var dir = try std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var files: usize = 0;
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp") == null);
        files += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), files);
}
