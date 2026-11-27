const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");
const zev = @import("zev");
const test_client = @import("test_client");

const Stream = test_client.Stream;

const Opened = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    session: transport.SessionId = 0,

    fn handler(ctx: ?*anyopaque, event: transport.Event) void {
        if (event.kind != .session_opened) return;
        const self: *Opened = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        self.session = event.session_id;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn wait(self: *Opened) transport.SessionId {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.session == 0) self.changed.wait(&self.mutex);
        return self.session;
    }
};

const DeinitProbe = struct {
    transport_ptr: *transport.Transport,
    fn run(self: *DeinitProbe) void {
        self.transport_ptr.deinit();
    }
};

fn connect(port: u16) !Stream {
    return test_client.connectLoopback(port);
}

fn handshake(stream: Stream) !void {
    try stream.writeAll("GET /drain-peer HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(testing.allocator);
    var suffix: [4]u8 = undefined;
    var used: usize = 0;
    while (true) {
        const byte = try stream.readByte();
        try response.append(testing.allocator, byte);
        if (used < suffix.len) {
            suffix[used] = byte;
            used += 1;
        } else {
            suffix[0] = suffix[1];
            suffix[1] = suffix[2];
            suffix[2] = suffix[3];
            suffix[3] = byte;
        }
        if (used == suffix.len and std.mem.eql(u8, &suffix, "\r\n\r\n")) break;
    }
    try testing.expect(std.mem.startsWith(u8, response.items, "HTTP/1.1 101"));
}

fn readTextFrame(alloc: std.mem.Allocator, stream: Stream) ![]u8 {
    var header: [2]u8 = undefined;
    try stream.readAll(&header);
    try testing.expectEqual(@as(u8, 0x1), header[0] & 0x0f);
    try testing.expectEqual(@as(u8, 0), header[1] & 0x80);
    var length: u64 = header[1] & 0x7f;
    if (length == 126) {
        var extended: [2]u8 = undefined;
        try stream.readAll(&extended);
        length = std.mem.readInt(u16, &extended, .big);
    } else if (length == 127) {
        var extended: [8]u8 = undefined;
        try stream.readAll(&extended);
        length = std.mem.readInt(u64, &extended, .big);
    }
    const payload = try alloc.alloc(u8, @intCast(length));
    errdefer alloc.free(payload);
    try stream.readAll(payload);
    return payload;
}

test "transport shutdown delivers accepted output before closing a paused writer" {
    const alloc = testing.allocator;
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    var barrier: transport.Transport.WriterTestBarrier = .{};
    defer barrier.deinit();
    const instance = try transport.Transport.init(alloc, 0);
    var deinit_thread: ?std.Thread = null;
    var deinit_complete = false;
    defer {
        barrier.releaseWriter();
        if (deinit_thread) |thread| {
            thread.join();
        } else if (!deinit_complete) {
            instance.deinit();
        }
    }
    instance.testing_writer_barrier = &barrier;
    instance.setDiscoveryTarget(.{ .title = "shutdown", .kind = "node", .url = "file:///shutdown.js", .id = "drain-peer" });
    try instance.start(&opened, Opened.handler);

    const peer = try connect(instance.boundPort());
    defer peer.close();
    try handshake(peer);
    const session = opened.wait();
    try testing.expect(barrier.waitUntilPaused(5_000));
    try testing.expect(instance.sendText(session, "accepted-before-shutdown"));

    var probe = DeinitProbe{ .transport_ptr = instance };
    deinit_thread = try std.Thread.spawn(.{}, DeinitProbe.run, .{&probe});
    const close_started = barrier.waitUntilCloseStarted(5_000);
    barrier.releaseWriter();
    deinit_thread.?.join();
    deinit_thread = null;
    deinit_complete = true;
    try testing.expect(close_started);

    const message = try readTextFrame(alloc, peer);
    defer alloc.free(message);
    try testing.expectEqualStrings("accepted-before-shutdown", message);
}
