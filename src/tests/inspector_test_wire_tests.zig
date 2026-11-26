//! Regression tests for bounded HTTP handshake reads in the inspector test wire.

const std = @import("std");
const testing = std.testing;
const io = @import("../platform/io.zig");
const wire = @import("inspector_test_wire.zig");

const SocketPair = struct {
    client: wire.TestStream,
    server: wire.TestStream,
};

const BoundTestPort = struct {
    fd: std.posix.fd_t,
    port: u16,

    fn open() !BoundTestPort {
        const raw_fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (raw_fd < 0) return error.SocketFailed;
        const fd: std.posix.fd_t = @intCast(raw_fd);
        errdefer _ = std.posix.system.close(fd);
        var addr: std.posix.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7F000001) };
        if (std.posix.system.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.posix.system.listen(fd, 1) < 0) return error.ListenFailed;
        var actual: std.posix.sockaddr.in = undefined;
        var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        if (std.posix.system.getsockname(fd, @ptrCast(&actual), &actual_len) < 0) return error.GetSockNameFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, actual.port) };
    }

    fn close(self: BoundTestPort) void {
        _ = std.posix.system.close(self.fd);
    }
};

fn openSocketPair(with_receive_timeout: bool) !SocketPair {
    const listener = try BoundTestPort.open();
    defer listener.close();
    const client = if (with_receive_timeout) try wire.connect(listener.port) else try wire.connectLoopback(listener.port);
    errdefer client.close();
    const raw_server = std.posix.system.accept(listener.fd, null, null);
    if (raw_server < 0) return error.AcceptFailed;
    return .{ .client = client, .server = .{ .handle = @intCast(raw_server) } };
}

fn writeDelayedHeaders(stream: wire.TestStream) void {
    io.sleepMs(150);
    stream.writeAll("Upgrade: websocket\r\n\r\n") catch {};
}

fn writeLateHeaders(stream: wire.TestStream) void {
    io.sleepMs(300);
    stream.writeAll("HTTP/1.1 101 Switching Protocols\r\n\r\n") catch {};
}

fn writeHeadersInShortBursts(stream: wire.TestStream) void {
    const fragments = [_][]const u8{
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n",
        "\r\n",
    };
    for (fragments, 0..) |fragment, index| {
        if (index != 0) io.sleepMs(80);
        stream.writeAll(fragment) catch return;
    }
}

test "inspector HTTP header reader preserves a response split across socket timeouts" {
    const pair = try openSocketPair(true);
    defer pair.client.close();
    defer pair.server.close();
    try pair.server.writeAll("HTTP/1.1 101 Switching Protocols\r\n");
    const writer = try std.Thread.spawn(.{}, writeDelayedHeaders, .{pair.server});
    defer writer.join();

    const headers = try wire.readHttpHeaders(testing.allocator, pair.client);
    defer testing.allocator.free(headers);
    try testing.expectEqualStrings("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n", headers);
}

test "inspector HTTP header reader enforces a deadline without a receive timeout" {
    const pair = try openSocketPair(false);
    defer pair.client.close();
    defer pair.server.close();
    const writer = try std.Thread.spawn(.{}, writeLateHeaders, .{pair.server});
    defer writer.join();

    try testing.expectError(error.HttpHeadersTimeout, wire.readHttpHeadersWithTimeout(testing.allocator, pair.client, 100));
}

test "inspector HTTP header reader bounds total time while data keeps arriving" {
    const pair = try openSocketPair(true);
    defer pair.client.close();
    defer pair.server.close();
    const writer = try std.Thread.spawn(.{}, writeHeadersInShortBursts, .{pair.server});

    var headers: ?[]u8 = null;
    var read_error: ?anyerror = null;
    if (wire.readHttpHeadersWithTimeout(testing.allocator, pair.client, 300)) |value| {
        headers = value;
    } else |err| {
        read_error = err;
    }
    writer.join();
    if (headers) |value| testing.allocator.free(value);
    try testing.expect(read_error != null and read_error.? == error.HttpHeadersTimeout);
}
