const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");

comptime {
    _ = @import("transport_contract_tests.zig");
    _ = @import("governance_contract_tests.zig");
}

const Stream = struct {
    handle: std.posix.fd_t,

    fn read(self: Stream, buffer: []u8) !usize {
        return std.posix.read(self.handle, buffer);
    }

    fn writeAll(self: Stream, bytes: []const u8) !void {
        var written: usize = 0;
        while (written < bytes.len) {
            const result = std.posix.system.write(self.handle, bytes.ptr + written, bytes.len - written);
            if (result < 0) {
                if (std.posix.errno(result) == .INTR) continue;
                return error.WriteFailed;
            }
            written += @intCast(result);
        }
    }

    fn close(self: Stream) void {
        _ = std.posix.system.close(self.handle);
    }
};

fn connect(port: u16) !Stream {
    const raw = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw);
    errdefer _ = std.posix.system.close(fd);
    var address: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    if (std.posix.system.connect(fd, @ptrCast(&address), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
    return .{ .handle = fd };
}

fn readHeaders(allocator: std.mem.Allocator, stream: Stream) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var byte: [1]u8 = undefined;
    while (true) {
        if (try stream.read(&byte) == 0) return error.EndOfStream;
        try output.append(allocator, byte[0]);
        if (output.items.len >= 4 and std.mem.eql(u8, output.items[output.items.len - 4 ..], "\r\n\r\n")) break;
    }
    return output.toOwnedSlice(allocator);
}

fn readToEof(allocator: std.mem.Allocator, stream: Stream) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var buffer: [128]u8 = undefined;
    while (true) {
        const count = try stream.read(&buffer);
        if (count == 0) break;
        try output.appendSlice(allocator, buffer[0..count]);
    }
    return output.toOwnedSlice(allocator);
}

fn writeMaskedText(stream: Stream, text: []const u8) !void {
    const mask = [_]u8{ 0x12, 0x34, 0x56, 0x78 };
    var header: [6]u8 = .{ 0x81, 0x80 | @as(u8, @intCast(text.len)), mask[0], mask[1], mask[2], mask[3] };
    try stream.writeAll(&header);
    var payload: [128]u8 = undefined;
    for (text, 0..) |byte, index| payload[index] = byte ^ mask[index & 3];
    try stream.writeAll(payload[0..text.len]);
}

fn readFrame(stream: Stream, buffer: []u8) !struct { opcode: u8, payload: []u8 } {
    var header: [2]u8 = undefined;
    var used: usize = 0;
    while (used < header.len) used += try stream.read(header[used..]);
    const length: usize = header[1] & 0x7f;
    if (length > buffer.len) return error.FrameTooLong;
    used = 0;
    while (used < length) used += try stream.read(buffer[used..length]);
    return .{ .opcode = header[0] & 0x0f, .payload = buffer[0..length] };
}

const State = struct {
    transport: ?*transport.Transport = null,
    opened: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(u32) = .init(0),
};

fn handler(ctx: ?*anyopaque, event: transport.Event) void {
    const state: *State = @ptrCast(@alignCast(ctx.?));
    switch (event.kind) {
        .session_opened => _ = state.opened.fetchAdd(1, .seq_cst),
        .session_closed => _ = state.closed.fetchAdd(1, .seq_cst),
        .message => _ = state.transport.?.sendText(event.session_id, event.payload),
    }
}

test "loopback HTTP discovery, WebSocket text, and close" {
    const instance = try transport.Transport.init(testing.allocator, 0);
    defer instance.deinit();
    instance.setProtocolJson("{\"version\":\"test\"}");
    instance.setDiscoveryTarget(.{ .title = "test", .kind = "node", .url = "file:///test.js", .id = "transport-test" });
    var state = State{ .transport = instance };
    try instance.start(&state, handler);

    const http = try connect(instance.boundPort());
    defer http.close();
    try http.writeAll("GET /json/protocol HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const headers = try readHeaders(testing.allocator, http);
    defer testing.allocator.free(headers);
    try testing.expect(std.mem.startsWith(u8, headers, "HTTP/1.1 200 OK"));
    const protocol = try readToEof(testing.allocator, http);
    defer testing.allocator.free(protocol);
    try testing.expectEqualStrings("{\"version\":\"test\"}", protocol);

    const socket = try connect(instance.boundPort());
    defer socket.close();
    try socket.writeAll("GET /transport-test HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
    const handshake = try readHeaders(testing.allocator, socket);
    defer testing.allocator.free(handshake);
    try testing.expect(std.mem.startsWith(u8, handshake, "HTTP/1.1 101"));
    try writeMaskedText(socket, "ping");
    var frame_buffer: [16]u8 = undefined;
    const echo = try readFrame(socket, &frame_buffer);
    try testing.expectEqual(@as(u8, 1), echo.opcode);
    try testing.expectEqualStrings("ping", echo.payload);
    try socket.writeAll(&[_]u8{ 0x88, 0x80, 1, 2, 3, 4, 1, 2 });
    const close = try readFrame(socket, &frame_buffer);
    try testing.expectEqual(@as(u8, 8), close.opcode);
}
