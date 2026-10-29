//! CDP integration contracts for request validation and session registration.
//!
//! These tests use a real Inspector listener to verify that malformed CDP requests and a session-registration allocation failure preserve the protocol boundary expected by an engine host.

const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const inspector_faults = @import("inspector_test_faults.zig");
const helpers = @import("test_helpers.zig");

const Stream = struct {
    handle: std.posix.fd_t,

    fn writeAll(self: Stream, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const wrote = std.posix.system.write(self.handle, bytes.ptr + offset, bytes.len - offset);
            if (wrote < 0) {
                if (std.posix.errno(wrote) == .INTR) continue;
                return error.WriteFailed;
            }
            offset += @intCast(wrote);
        }
    }

    fn readByte(self: Stream) !u8 {
        var one: [1]u8 = undefined;
        if ((try std.posix.read(self.handle, &one)) == 0) return error.EndOfStream;
        return one[0];
    }

    fn close(self: Stream) void {
        _ = std.posix.system.close(self.handle);
    }
};

fn connectLoopback(port: u16) !Stream {
    const raw = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw);
    errdefer _ = std.posix.system.close(fd);
    var addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (std.posix.system.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
    return .{ .handle = fd };
}

fn readHttpHeaders(stream: Stream) !void {
    var suffix: [4]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const byte = try stream.readByte();
        if (len < suffix.len) {
            suffix[len] = byte;
            len += 1;
        } else {
            suffix[0] = suffix[1];
            suffix[1] = suffix[2];
            suffix[2] = suffix[3];
            suffix[3] = byte;
        }
        if (len == suffix.len and std.mem.eql(u8, &suffix, "\r\n\r\n")) return;
    }
}

fn readHttpStatus(alloc: std.mem.Allocator, stream: Stream) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    var suffix: [4]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const byte = try stream.readByte();
        try bytes.append(alloc, byte);
        if (len < suffix.len) {
            suffix[len] = byte;
            len += 1;
        } else {
            suffix[0] = suffix[1];
            suffix[1] = suffix[2];
            suffix[2] = suffix[3];
            suffix[3] = byte;
        }
        if (len == suffix.len and std.mem.eql(u8, &suffix, "\r\n\r\n")) return bytes.toOwnedSlice(alloc);
    }
}

fn handshake(stream: Stream, target: []const u8) !void {
    var request: [512]u8 = undefined;
    const bytes = try std.fmt.bufPrint(
        &request,
        "GET /{s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{target},
    );
    try stream.writeAll(bytes);
    try readHttpHeaders(stream);
}

/// Send one small masked client text frame. This intentionally exercises the public WebSocket callback path rather than calling a handler directly.
fn writeMaskedText(stream: Stream, text: []const u8) !void {
    try testing.expect(text.len <= 125);
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var header: [6]u8 = .{ 0x81, 0x80 | @as(u8, @intCast(text.len)), mask[0], mask[1], mask[2], mask[3] };
    try stream.writeAll(&header);
    var encoded: [125]u8 = undefined;
    for (text, 0..) |byte, index| encoded[index] = byte ^ mask[index & 3];
    try stream.writeAll(encoded[0..text.len]);
}

fn readTextFrame(alloc: std.mem.Allocator, stream: Stream) ![]u8 {
    var header: [2]u8 = undefined;
    header[0] = try stream.readByte();
    header[1] = try stream.readByte();
    try testing.expectEqual(@as(u8, 0x1), header[0] & 0x0f);
    try testing.expect((header[1] & 0x80) == 0);
    var len: u64 = header[1] & 0x7f;
    if (len == 126) {
        var extended: [2]u8 = undefined;
        for (&extended) |*byte| byte.* = try stream.readByte();
        len = std.mem.readInt(u16, &extended, .big);
    } else if (len == 127) {
        var extended: [8]u8 = undefined;
        for (&extended) |*byte| byte.* = try stream.readByte();
        len = std.mem.readInt(u64, &extended, .big);
    }
    const text = try alloc.alloc(u8, @intCast(len));
    errdefer alloc.free(text);
    for (text) |*byte| byte.* = try stream.readByte();
    return text;
}

const InspectorEnabledTests = if (@import("build_options").inspector) struct {
    test "cdp: an out-of-range floating request id cannot terminate the transport reader" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "invalid-float-id" });
        defer inspector.stop(handle);

        const peer = try connectLoopback(inspector.boundPort(handle));
        defer peer.close();
        try handshake(peer, "invalid-float-id");
        try writeMaskedText(peer, "{\"id\":1e300,\"method\":\"Runtime.getIsolateId\"}");
        try writeMaskedText(peer, "{\"id\":711,\"method\":\"Runtime.getIsolateId\"}");
        const response = try readTextFrame(testing.allocator, peer);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"id\":711") != null);
    }

    test "cdp: a notification without an id does not manufacture an id-zero response" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "missing-id" });
        defer inspector.stop(handle);

        const peer = try connectLoopback(inspector.boundPort(handle));
        defer peer.close();
        var timeout: std.posix.timeval = .{ .sec = 0, .usec = 100_000 };
        try std.posix.setsockopt(peer.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try handshake(peer, "missing-id");
        try writeMaskedText(peer, "{\"method\":\"Runtime.getIsolateId\"}");
        var byte: [1]u8 = undefined;
        try testing.expectError(error.WouldBlock, std.posix.read(peer.handle, &byte));
        try writeMaskedText(peer, "{\"id\":712,\"method\":\"Runtime.getIsolateId\"}");
        const response = try readTextFrame(testing.allocator, peer);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"id\":712") != null);
    }

    test "cdp: a non-numeric request id does not manufacture an id-zero response" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "string-id" });
        defer inspector.stop(handle);

        const peer = try connectLoopback(inspector.boundPort(handle));
        defer peer.close();
        var timeout: std.posix.timeval = .{ .sec = 0, .usec = 100_000 };
        try std.posix.setsockopt(peer.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeout));
        try handshake(peer, "string-id");
        try writeMaskedText(peer, "{\"id\":\"not-a-number\",\"method\":\"Runtime.getIsolateId\"}");
        var byte: [1]u8 = undefined;
        try testing.expectError(error.WouldBlock, std.posix.read(peer.handle, &byte));
        try writeMaskedText(peer, "{\"id\":713,\"method\":\"Runtime.getIsolateId\"}");
        const response = try readTextFrame(testing.allocator, peer);
        defer testing.allocator.free(response);
        try testing.expect(std.mem.indexOf(u8, response, "\"id\":713") != null);
    }

    test "cdp: a session registration allocation failure closes the WebSocket" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "session-registration-oom" });
        defer inspector.stop(handle);

        inspector_faults.arm(id, .session_registration);
        const peer = try connectLoopback(inspector.boundPort(handle));
        defer peer.close();
        try handshake(peer, "session-registration-oom");
        // The upgrade response precedes registration; the close frame proves the server has observed the injected registration failure.
        try testing.expectEqual(@as(u8, 0x88), try peer.readByte());
        try testing.expect(inspector_faults.wasConsumed(id, .session_registration));
        std.debug.print("SESSION_REGISTRATION_OOM_CONSUMED\n", .{});
    }
};

comptime {
    _ = InspectorEnabledTests;
}
