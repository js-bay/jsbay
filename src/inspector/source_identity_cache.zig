//! Source identity envelope only. Decode borrows input; encode returns owned bytes or null when persistence should be skipped. No file I/O or VM operations.
const std = @import("std");

const cache_envelope_magic = "JBSURL01";
const cache_envelope_header_len = cache_envelope_magic.len + @sizeOf(u32);

pub const Artifact = struct {
    bytecode: []const u8,
    effective_url: []const u8,
};

pub fn decode(bytes: []const u8) ?Artifact {
    if (bytes.len < cache_envelope_header_len + 1) return null;
    if (!std.mem.eql(u8, bytes[0..cache_envelope_magic.len], cache_envelope_magic)) return null;
    const url_len: usize = std.mem.readInt(u32, bytes[cache_envelope_magic.len..cache_envelope_header_len], .little);
    if (url_len == 0 or url_len > bytes.len - cache_envelope_header_len) return null;
    const url_end = cache_envelope_header_len + url_len;
    if (url_end == bytes.len) return null;
    const effective_url = bytes[cache_envelope_header_len..url_end];
    if (std.mem.indexOfScalar(u8, effective_url, 0) != null) return null;
    return .{ .effective_url = effective_url, .bytecode = bytes[url_end..] };
}

pub fn encode(allocator: std.mem.Allocator, effective_url: []const u8, bytecode: []const u8) ?[]u8 {
    if (effective_url.len == 0 or effective_url.len > std.math.maxInt(u32) or bytecode.len == 0) return null;
    if (std.mem.indexOfScalar(u8, effective_url, 0) != null) return null;
    const total = std.math.add(usize, cache_envelope_header_len, effective_url.len) catch return null;
    const size = std.math.add(usize, total, bytecode.len) catch return null;
    const artifact = allocator.alloc(u8, size) catch return null;
    @memcpy(artifact[0..cache_envelope_magic.len], cache_envelope_magic);
    std.mem.writeInt(u32, artifact[cache_envelope_magic.len..cache_envelope_header_len], @intCast(effective_url.len), .little);
    @memcpy(artifact[cache_envelope_header_len..total], effective_url);
    @memcpy(artifact[total..], bytecode);
    return artifact;
}

test "source identity: source URL cache envelope rejects malformed metadata" {
    const testing = std.testing;
    try testing.expect(decode("raw-bytecode") == null);
    try testing.expect(decode(cache_envelope_magic ++ "\x00\x00\x00\x00bytecode") == null);
    try testing.expect(decode(cache_envelope_magic ++ "\x05\x00\x00\x00url") == null);
    try testing.expect(decode(cache_envelope_magic ++ "\x03\x00\x00\x00a\x00bbytecode") == null);
    try testing.expect(decode(cache_envelope_magic ++ "\x03\x00\x00\x00url") == null);
    const valid = decode(cache_envelope_magic ++ "\x03\x00\x00\x00urlbytecode") orelse return error.ExpectedCacheArtifact;
    try testing.expectEqualStrings("url", valid.effective_url);
    try testing.expectEqualStrings("bytecode", valid.bytecode);
}

test "source identity: encoded format is stable and decode borrows the input" {
    const allocator = std.testing.allocator;
    const bytes = encode(allocator, "source.js", "\x00\xffbytecode") orelse return error.ExpectedCacheArtifact;
    defer allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "JBSURL01\x09\x00\x00\x00source.js\x00\xffbytecode", bytes);
    const artifact = decode(bytes) orelse return error.ExpectedCacheArtifact;
    try std.testing.expectEqual(@intFromPtr(bytes.ptr) + cache_envelope_header_len, @intFromPtr(artifact.effective_url.ptr));
    try std.testing.expectEqual(@intFromPtr(bytes.ptr) + cache_envelope_header_len + 9, @intFromPtr(artifact.bytecode.ptr));
}

test "source identity: invalid metadata and allocation failure only skip persistence" {
    const allocator = std.testing.allocator;
    try std.testing.expect(encode(allocator, "", "bytes") == null);
    try std.testing.expect(encode(allocator, "url", "") == null);
    try std.testing.expect(encode(allocator, "bad\x00url", "bytes") == null);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expect(encode(failing.allocator(), "source.js", "bytes") == null);
}
