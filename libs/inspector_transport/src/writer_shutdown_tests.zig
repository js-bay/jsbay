const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");
const zev = @import("zev");
const test_client = @import("test_client");
const socket = @import("portable_socket");

const Stream = test_client.Stream;

const Opened = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    sessions: [2]transport.SessionId = @splat(0),
    count: usize = 0,

    fn handler(ctx: ?*anyopaque, event: transport.Event) void {
        if (event.kind != .session_opened) return;
        const self: *Opened = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        if (self.count < self.sessions.len) {
            self.sessions[self.count] = event.session_id;
            self.count += 1;
        }
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn wait(self: *Opened, want: usize) transport.SessionId {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count < want) self.changed.wait(&self.mutex);
        return self.sessions[want - 1];
    }
};

const DeinitProbe = struct {
    transport_ptr: *transport.Transport,
    completed: std.atomic.Value(bool) = .init(false),
    fn run(self: *DeinitProbe) void {
        self.transport_ptr.deinit();
        self.completed.store(true, .release);
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

fn waitForPeerClose(stream: Stream, barrier: ?*transport.Transport.WriterTestBarrier) !void {
    const peer = socket.Socket{ .handle = stream.handle };
    const deadline = zev.monotonicMilliseconds() + 5_000;
    var buffer: [16 * 1024]u8 = undefined;
    var bytes_read: usize = 0;
    var last_ready = false;
    var last_closed = false;
    while (zev.monotonicMilliseconds() < deadline) {
        const remaining = deadline - zev.monotonicMilliseconds();
        const result = try peer.poll(.read, @intCast(@min(remaining, 100)));
        last_ready = result.ready;
        last_closed = result.closed;
        if (result.closed) {
            return;
        }
        if (!result.ready) continue;
        const count = stream.read(&buffer) catch return;
        if (count == 0) return;
        bytes_read += count;
    }
    try peer.setNonBlocking(true);
    const probe_bytes = peer.read(&buffer) catch |err| {
        std.debug.print("PEER_CLOSE_TIMEOUT bytes_read={d} ready={any} closed={any} probe_error={s}\n", .{ bytes_read, last_ready, last_closed, @errorName(err) });
        if (barrier) |test_barrier| test_barrier.printSessionCloseDiagnostics();
        return error.PeerDidNotClose;
    };
    std.debug.print("PEER_CLOSE_TIMEOUT bytes_read={d} ready={any} closed={any} probe_bytes={d}\n", .{ bytes_read, last_ready, last_closed, probe_bytes });
    if (barrier) |test_barrier| test_barrier.printSessionCloseDiagnostics();
    if (probe_bytes == 0) return;
    return error.PeerDidNotClose;
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
    const session = opened.wait(1);
    try testing.expect(instance.sendText(session, "accepted-before-shutdown"));
    try testing.expect(barrier.waitUntilPaused(5_000));
    try testing.expect(instance.sendText(session, "queued-behind-inflight-frame"));

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
    const queued = try readTextFrame(alloc, peer);
    defer alloc.free(queued);
    try testing.expectEqualStrings("queued-behind-inflight-frame", queued);
}

test "transport shutdown shares its deadline across slow sessions" {
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

    const first_peer = try connect(instance.boundPort());
    defer first_peer.close();
    try first_peer.setReceiveBuffer(1024);
    try handshake(first_peer);
    const first_session = opened.wait(1);
    const second_peer = try connect(instance.boundPort());
    defer second_peer.close();
    try second_peer.setReceiveBuffer(1024);
    try handshake(second_peer);
    const second_session = opened.wait(2);

    const payload = try alloc.alloc(u8, 16 * 1024 * 1024);
    defer alloc.free(payload);
    @memset(payload, 's');
    try testing.expect(instance.sendText(first_session, payload));
    try testing.expect(barrier.waitUntilPaused(5_000));
    try testing.expect(instance.sendText(second_session, payload));

    var probe = DeinitProbe{ .transport_ptr = instance };
    const started = zev.monotonicMilliseconds();
    deinit_thread = try std.Thread.spawn(.{}, DeinitProbe.run, .{&probe});
    const close_started = barrier.waitUntilCloseStarted(5_000);
    barrier.releaseWriter();
    deinit_thread.?.join();
    deinit_thread = null;
    deinit_complete = true;
    const elapsed = zev.monotonicMilliseconds() - started;

    try testing.expect(close_started);
    try testing.expect(elapsed <= 4_000);
    try testing.expect(probe.completed.load(.acquire));
    try first_peer.setReceiveBuffer(4 * 1024 * 1024);
    try second_peer.setReceiveBuffer(4 * 1024 * 1024);
    const first_close = waitForPeerClose(first_peer, &barrier);
    const second_close = waitForPeerClose(second_peer, &barrier);
    try first_close;
    try second_close;
}
