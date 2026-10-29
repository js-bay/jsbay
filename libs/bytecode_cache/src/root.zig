//! Content-addressed storage for serialized bytecode.
//!
//! This package deliberately has no JavaScript-engine dependency. Callers own compile/run/error behavior; this module only names and publishes artifacts.

const std = @import("std");
const builtin = @import("builtin");

pub const name_key_bytes = 32;

pub fn sha256Hex(allocator: std.mem.Allocator, source: []const u8) ?[]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(source, &digest, .{});
    const out = allocator.alloc(u8, digest.len * 2) catch return null;
    const digits = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[index * 2] = digits[byte >> 4];
        out[index * 2 + 1] = digits[byte & 0xf];
    }
    return out;
}

/// Version and build fingerprint strings are inserted into a path component.
pub fn isSafeComponent(value: []const u8) bool {
    if (value.len == 0 or value.len > 64) return false;
    for (value) |byte| {
        const allowed = (byte >= 'a' and byte <= 'z') or
            (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or
            byte == '-' or byte == '_' or byte == '.';
        if (!allowed) return false;
    }
    return true;
}

/// Source and filename identities are SHA-256 digests, encoded as 64 lowercase hexadecimal bytes. They are not generic path components.
pub fn isSha256Hex(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

/// Build `<directory>/<version>-<fingerprint>-<source>-<name>.bc`.
pub fn artifactPath(allocator: std.mem.Allocator, directory: []const u8, version: []const u8, fingerprint: []const u8, source_key: []const u8, name_key: []const u8) ?[]u8 {
    if (!isSafeComponent(version) or !isSafeComponent(fingerprint) or !isSha256Hex(source_key) or !isSha256Hex(name_key)) return null;
    const total = directory.len + 1 + version.len + 1 + fingerprint.len + 1 + source_key.len + 1 + name_key_bytes + 3;
    const path = allocator.alloc(u8, total) catch return null;
    var index: usize = 0;
    inline for (.{ directory, "/", version, "-", fingerprint, "-", source_key, "-" }) |part| {
        @memcpy(path[index .. index + part.len], part);
        index += part.len;
    }
    @memcpy(path[index .. index + name_key_bytes], name_key[0..name_key_bytes]);
    index += name_key_bytes;
    @memcpy(path[index .. index + 3], ".bc");
    return path;
}

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch null;
}

/// Publish bytes through a unique temporary sibling. Storage failures are intentionally non-fatal for callers that can fall back to source parsing.
pub fn writeAtomically(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) void {
    const dir = std.Io.Dir.cwd();
    const separator = std.mem.lastIndexOfScalar(u8, path, '/') orelse return;
    if (builtin.abi.isAndroid()) {
        if (!createAndroidDirPath(path[0..separator])) return;
    } else dir.createDirPath(io, path[0..separator]) catch return;
    const suffix = temporarySuffix(io, allocator, path) orelse return;
    defer allocator.free(suffix);
    const temporary = allocator.alloc(u8, path.len + suffix.len) catch return;
    defer allocator.free(temporary);
    @memcpy(temporary[0..path.len], path);
    @memcpy(temporary[path.len..], suffix);
    dir.writeFile(io, .{ .sub_path = temporary, .data = bytes }) catch {
        dir.deleteFile(io, temporary) catch {};
        return;
    };
    dir.rename(temporary, dir, path, io) catch dir.deleteFile(io, temporary) catch {};
}

fn createAndroidDirPath(path: []const u8) bool {
    if (path.len == 0) return true;
    var owned = std.heap.c_allocator.dupeSentinel(u8, path, 0) catch return false;
    defer std.heap.c_allocator.free(owned);
    for (owned[1..], 1..) |*byte, index| {
        if (byte.* != '/') continue;
        byte.* = 0;
        const created = std.c.mkdir(owned[0..index :0], 0o777);
        byte.* = '/';
        if (created != 0 and std.c.errno(-1) != .EXIST) return false;
    }
    return std.c.mkdir(owned, 0o777) == 0 or std.c.errno(-1) == .EXIST;
}

pub fn delete(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn temporarySuffix(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const path_hash = sha256Hex(allocator, path) orelse return null;
    defer allocator.free(path_hash);
    const suffix = allocator.alloc(u8, 4 + 12 + 16) catch return null;
    @memcpy(suffix[0..4], ".tmp");
    @memcpy(suffix[4..16], path_hash[0..12]);
    var bytes: [8]u8 = undefined;
    io.random(&bytes);
    const digits = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        suffix[16 + index * 2] = digits[byte >> 4];
        suffix[16 + index * 2 + 1] = digits[byte & 0xf];
    }
    return suffix;
}

test "Android directory creation handles nested and root paths" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var name: [96]u8 = undefined;
    var random: [8]u8 = undefined;
    io.random(&random);
    const directory = try std.fmt.bufPrint(&name, ".zig-cache/bytecode-cache-android-{x}", .{std.mem.readInt(u64, &random, .little)});
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    try std.testing.expect(createAndroidDirPath(directory));
    try std.testing.expect(createAndroidDirPath(directory));
    try std.testing.expect(createAndroidDirPath(""));
}
