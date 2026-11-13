//! Loopback lifecycle contracts for the Inspector transport.
//!
//! These tests exercise connection lifecycle, backpressure, allocation cleanup, and shutdown behavior against real HTTP and WebSocket peers.

const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");
const zev = @import("zev");
const test_client = @import("test_client");

const Stream = test_client.Stream;
const connectLoopback = test_client.connectLoopback;

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

fn isSwitchingProtocols(response: []const u8) bool {
    return std.mem.startsWith(u8, response, "HTTP/1.1 101");
}

fn handshake(stream: Stream, target: []const u8) !void {
    var request: [512]u8 = undefined;
    const bytes = try std.fmt.bufPrint(
        &request,
        "GET /{s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{target},
    );
    try stream.writeAll(bytes);
    const response = try readHttpStatus(testing.allocator, stream);
    defer testing.allocator.free(response);
    if (!isSwitchingProtocols(response)) return error.HandshakeRejected;
}

fn retryableHandshakeError(err: anyerror) bool {
    return switch (err) {
        error.HandshakeRejected, error.EndOfStream => true,
        else => false,
    };
}

/// Retry a reconnect until the handshake is 101 or `timeout_ms` elapses.
///
/// `session_closed` is fired before the last worker releases the session slot, so the first attempt after waitClosed can still receive HTTP 503.
fn handshakeUntilAccepted(port: u16, target: []const u8, timeout_ms: u64) !Stream {
    const deadline = zev.monotonicMilliseconds() + timeout_ms;
    while (true) {
        if (zev.monotonicMilliseconds() >= deadline) return error.HandshakeTimeout;
        const peer = try connectLoopback(port);
        if (handshake(peer, target)) |_| return peer else |err| {
            peer.close();
            if (!retryableHandshakeError(err)) return err;
        }
    }
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

const Opened = struct {
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    ids: [40]transport.SessionId = @splat(0),
    count: usize = 0,
    closed: usize = 0,

    fn handler(ctx: ?*anyopaque, event: transport.Event) void {
        const self: *Opened = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        switch (event.kind) {
            .session_opened => if (self.count < self.ids.len) {
                self.ids[self.count] = event.session_id;
                self.count += 1;
            },
            .session_closed => self.closed += 1,
            .message => {},
        }
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn wait(self: *Opened, want: usize) transport.SessionId {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count < want) self.changed.wait(&self.mutex);
        return self.ids[want - 1];
    }

    fn waitClosed(self: *Opened, want: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.closed < want) self.changed.wait(&self.mutex);
    }
};

/// Holds the session_closed callback so tests can observe reconnects before the worker releases the slot.
const SessionClosedHold = struct {
    opened: Opened = .{},
    hold_closed: bool = true,

    fn handler(ctx: ?*anyopaque, event: transport.Event) void {
        const self: *SessionClosedHold = @ptrCast(@alignCast(ctx.?));
        Opened.handler(&self.opened, event);
        if (event.kind != .session_closed) return;
        self.opened.mutex.lock();
        defer self.opened.mutex.unlock();
        while (self.hold_closed) self.opened.changed.wait(&self.opened.mutex);
    }

    fn release(self: *SessionClosedHold) void {
        self.opened.mutex.lock();
        self.hold_closed = false;
        self.opened.changed.broadcast();
        self.opened.mutex.unlock();
    }
};

const SendProbe = struct {
    transport_ptr: *transport.Transport,
    session: transport.SessionId,
    payload: []const u8,
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    finished: bool = false,
    result: bool = false,

    fn run(self: *SendProbe) void {
        self.result = self.transport_ptr.sendText(self.session, self.payload);
        self.mutex.lock();
        self.finished = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn wait(self: *SendProbe) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.finished) self.changed.wait(&self.mutex);
        return self.result;
    }
};

const RepeatedSender = struct {
    transport_ptr: *transport.Transport,
    session: transport.SessionId,
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    started: bool = false,
    finished: bool = false,

    fn run(self: *RepeatedSender) void {
        self.mutex.lock();
        self.started = true;
        self.changed.broadcast();
        self.mutex.unlock();
        for (0..512) |_| _ = self.transport_ptr.sendText(self.session, "governance-racing-send");
        self.mutex.lock();
        self.finished = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn waitStarted(self: *RepeatedSender) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.started) self.changed.wait(&self.mutex);
    }

    fn waitFinished(self: *RepeatedSender) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.finished) self.changed.wait(&self.mutex);
    }
};

const ReentrantDeinitProbe = struct {
    transport_ptr: ?*transport.Transport = null,
    target_event: transport.EventKind,
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    entered: bool = false,
    returned: bool = false,

    fn handler(ctx: ?*anyopaque, event: transport.Event) void {
        const self: *ReentrantDeinitProbe = @ptrCast(@alignCast(ctx.?));
        if (event.kind != self.target_event) return;
        self.mutex.lock();
        self.entered = true;
        self.changed.broadcast();
        self.mutex.unlock();
        std.debug.print("TRANSPORT_REENTRANT_DEINIT_ENTERED\n", .{});
        self.transport_ptr.?.deinit();
        self.mutex.lock();
        self.returned = true;
        self.changed.broadcast();
        self.mutex.unlock();
        std.debug.print("TRANSPORT_REENTRANT_DEINIT_RETURNED\n", .{});
    }
};

/// Observes the transport's own allocation being released.  `Transport.init` allocates the Transport object first, and `destroyStorage` destroys it after every worker-owned allocation has been released.  Waiting for this free therefore makes the reentrant-close tests prove both callback return and eventual ownership cleanup without relying on a delay.
const TransportFreeObserver = struct {
    inner: std.mem.Allocator,
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    transport_memory: ?[*]u8 = null,
    transport_freed: bool = false,

    fn init(inner: std.mem.Allocator) TransportFreeObserver {
        return .{ .inner = inner };
    }

    fn deinit(self: *TransportFreeObserver) void {
        self.changed.deinit();
    }

    fn allocator(self: *TransportFreeObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TransportFreeObserver = @ptrCast(@alignCast(raw));
        const memory = self.inner.rawAlloc(len, alignment, ret_addr) orelse return null;
        if (len == @sizeOf(transport.Transport)) {
            self.mutex.lock();
            defer self.mutex.unlock();
            std.debug.assert(self.transport_memory == null);
            self.transport_memory = memory;
        }
        return memory;
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TransportFreeObserver = @ptrCast(@alignCast(raw));
        return self.inner.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TransportFreeObserver = @ptrCast(@alignCast(raw));
        return self.inner.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TransportFreeObserver = @ptrCast(@alignCast(raw));
        const is_transport = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.transport_memory != null and self.transport_memory.? == memory.ptr;
        };
        self.inner.rawFree(memory, alignment, ret_addr);
        if (!is_transport) return;
        self.mutex.lock();
        self.transport_freed = true;
        self.changed.broadcast();
        self.mutex.unlock();
    }

    fn waitForTransportFree(self: *TransportFreeObserver) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!self.transport_freed) self.changed.wait(&self.mutex);
    }
};

/// FailingAllocator counters are shared by detached socket workers.
const LockedFailingAllocator = struct {
    failing: testing.FailingAllocator,
    mutex: zev.Mutex = .{},

    fn init(inner: std.mem.Allocator, config: testing.FailingAllocator.Config) LockedFailingAllocator {
        return .{ .failing = testing.FailingAllocator.init(inner, config) };
    }

    fn deinit(self: *LockedFailingAllocator) void {
        self.mutex.deinit();
    }

    fn allocator(self: *LockedFailingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedFailingAllocator = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failing.allocator().rawAlloc(len, alignment, ret_addr);
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockedFailingAllocator = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failing.allocator().rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockedFailingAllocator = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.failing.allocator().rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedFailingAllocator = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failing.allocator().rawFree(memory, alignment, ret_addr);
    }

    fn failNextAllocation(self: *LockedFailingAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failing.fail_index = self.failing.alloc_index;
    }

    fn allowAllocations(self: *LockedFailingAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.failing.fail_index = std.math.maxInt(usize);
    }

    fn expectInducedFailure(self: *LockedFailingAllocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try testing.expect(self.failing.has_induced_failure);
    }

    fn expectFullyFreed(self: *LockedFailingAllocator) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try testing.expectEqual(self.failing.allocated_bytes, self.failing.freed_bytes);
    }
};

test "transport: a message handler can close its own transport without waiting for itself" {
    var observer = TransportFreeObserver.init(testing.allocator);
    defer observer.deinit();
    const t = try transport.Transport.init(observer.allocator(), 0);
    var probe = ReentrantDeinitProbe{ .transport_ptr = t, .target_event = .message };
    defer probe.changed.deinit();
    defer probe.mutex.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "reentrant-deinit" });
    try t.start(&probe, ReentrantDeinitProbe.handler);

    const peer = try connectLoopback(t.boundPort());
    defer peer.close();
    try handshake(peer, "reentrant-deinit");
    try writeMaskedText(peer, "close-from-handler");

    // The process watchdog detects a callback waiting on itself. Successful teardown reaches these assertions after the callback returns, without timed polling.
    probe.mutex.lock();
    while (!probe.returned) probe.changed.wait(&probe.mutex);
    try testing.expect(probe.entered);
    probe.mutex.unlock();
    observer.waitForTransportFree();
}

test "transport: a session-opened handler can close its own transport without joining itself" {
    var observer = TransportFreeObserver.init(testing.allocator);
    defer observer.deinit();
    const t = try transport.Transport.init(observer.allocator(), 0);
    var probe = ReentrantDeinitProbe{ .transport_ptr = t, .target_event = .session_opened };
    defer probe.changed.deinit();
    defer probe.mutex.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "reentrant-open" });
    try t.start(&probe, ReentrantDeinitProbe.handler);

    const peer = try connectLoopback(t.boundPort());
    defer peer.close();
    try handshake(peer, "reentrant-open");
    probe.mutex.lock();
    while (!probe.returned) probe.changed.wait(&probe.mutex);
    try testing.expect(probe.entered);
    probe.mutex.unlock();
    observer.waitForTransportFree();
}

test "transport: a session-closed handler can close its own transport without waiting for itself" {
    var observer = TransportFreeObserver.init(testing.allocator);
    defer observer.deinit();
    const t = try transport.Transport.init(observer.allocator(), 0);
    var probe = ReentrantDeinitProbe{ .transport_ptr = t, .target_event = .session_closed };
    defer probe.changed.deinit();
    defer probe.mutex.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "reentrant-closed" });
    try t.start(&probe, ReentrantDeinitProbe.handler);

    const peer = try connectLoopback(t.boundPort());
    try handshake(peer, "reentrant-closed");
    peer.close();
    probe.mutex.lock();
    while (!probe.returned) probe.changed.wait(&probe.mutex);
    try testing.expect(probe.entered);
    probe.mutex.unlock();
    observer.waitForTransportFree();
}

test "transport: a peer that stops reading cannot indefinitely retain a send" {
    const alloc = testing.allocator;
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    const t = try transport.Transport.init(alloc, 0);
    defer t.deinit();
    try t.start(&opened, Opened.handler);
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "slow-peer" });

    const stream = try connectLoopback(t.boundPort());
    defer stream.close();
    // Shrink the advertised receive window before the handshake.  The peer never reads a frame after this point, so a large response must exercise the server's slow-client policy rather than just an in-memory mock.
    const receive_bytes: c_int = 1024;
    try stream.setReceiveBuffer(receive_bytes);
    try handshake(stream, "slow-peer");
    const session = opened.wait(1);

    const payload = try alloc.alloc(u8, 64 * 1024 * 1024);
    defer alloc.free(payload);
    @memset(payload, 'x');
    var probe = SendProbe{ .transport_ptr = t, .session = session, .payload = payload };
    defer probe.changed.deinit();
    defer probe.mutex.deinit();
    const sender = try std.Thread.spawn(.{}, SendProbe.run, .{&probe});
    std.debug.print("GOVERNANCE_SLOW_SEND_ENTERED session={d}\n", .{session});
    _ = probe.wait();
    sender.join();
}

test "transport: a slow session filling its budget does not block a second session or shutdown" {
    const alloc = testing.allocator;
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    const t = try transport.Transport.init(alloc, 0);
    defer t.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "queue-peer" });
    try t.start(&opened, Opened.handler);

    const slow = try connectLoopback(t.boundPort());
    defer slow.close();
    const receive_bytes: c_int = 1024;
    try slow.setReceiveBuffer(receive_bytes);
    try handshake(slow, "queue-peer");
    const slow_id = opened.wait(1);
    const fast = try connectLoopback(t.boundPort());
    defer fast.close();
    try handshake(fast, "queue-peer");
    const fast_id = opened.wait(2);

    const small = try alloc.alloc(u8, 32 * 1024);
    defer alloc.free(small);
    @memset(small, 'q');
    var rejected = false;
    var attempted: usize = 0;
    while (attempted < 512) : (attempted += 1) {
        if (!t.sendText(slow_id, small)) {
            rejected = true;
            break;
        }
    }
    std.debug.print("GOVERNANCE_QUEUE_BUDGET_REACHED frames={d}\n", .{attempted});
    try testing.expect(rejected);
    try testing.expect(t.sendText(fast_id, "governance-fast-session"));
    const received = try readTextFrame(alloc, fast);
    defer alloc.free(received);
    try testing.expectEqualStrings("governance-fast-session", received);
}

test "transport: a broadcast snapshot allocation failure releases every retained session" {
    var failing = LockedFailingAllocator.init(testing.allocator, .{});
    defer failing.deinit();
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    const t = try transport.Transport.init(failing.allocator(), 0);
    var deinitialized = false;
    defer if (!deinitialized) t.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "oom-broadcast" });
    try t.start(&opened, Opened.handler);

    var peers: [9]Stream = undefined;
    for (&peers) |*peer| {
        peer.* = try connectLoopback(t.boundPort());
        try handshake(peer.*, "oom-broadcast");
    }
    _ = opened.wait(peers.len);

    // broadcastText allocates the exact lease snapshot before retaining. Fail that allocation so OOM cannot observe any broadcast lease.
    failing.failNextAllocation();
    t.broadcastText("oom-broadcast-token");
    try failing.expectInducedFailure();
    // FailingAllocator keeps failing every alloc at fail_index; re-arm so deinit/close can free.
    failing.allowAllocations();
    std.debug.print("GOVERNANCE_BROADCAST_RESIZE_FAILED peers={d}\n", .{peers.len});
    t.deinit();
    deinitialized = true;
    for (peers) |peer| peer.close();
    try failing.expectFullyFreed();
}

test "transport: the session cap rejects the next handshake and recovers after disconnect" {
    const alloc = testing.allocator;
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    const t = try transport.Transport.init(alloc, 0);
    defer t.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "session-cap" });
    try t.start(&opened, Opened.handler);

    var peers: [32]Stream = undefined;
    defer for (peers) |peer| peer.close();
    for (&peers) |*peer| {
        peer.* = try connectLoopback(t.boundPort());
        try handshake(peer.*, "session-cap");
    }
    _ = opened.wait(peers.len);

    const rejected = try connectLoopback(t.boundPort());
    defer rejected.close();
    try rejected.writeAll("GET /session-cap HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
    const rejection = try readHttpStatus(alloc, rejected);
    defer alloc.free(rejection);
    try testing.expect(!std.mem.startsWith(u8, rejection, "HTTP/1.1 101"));
    std.debug.print("GOVERNANCE_SESSION_CAP_REJECTED\n", .{});

    peers[0].close();
    opened.waitClosed(1);
    // waitClosed only observes session_closed, which is not a session-slot release barrier.
    const recovered = try handshakeUntilAccepted(t.boundPort(), "session-cap", 5_000);
    defer recovered.close();
    _ = opened.wait(peers.len + 1);
}

test "transport: session_closed is not a session-slot release barrier" {
    const alloc = testing.allocator;
    var hold = SessionClosedHold{};
    defer hold.opened.changed.deinit();
    defer hold.opened.mutex.deinit();
    const t = try transport.Transport.init(alloc, 0);
    defer t.deinit();
    defer hold.release();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "session-cap-hold" });
    try t.start(&hold, SessionClosedHold.handler);

    var peers: [32]Stream = undefined;
    defer for (peers) |peer| peer.close();
    for (&peers) |*peer| {
        peer.* = try connectLoopback(t.boundPort());
        try handshake(peer.*, "session-cap-hold");
    }
    _ = hold.opened.wait(peers.len);

    peers[0].close();
    hold.opened.waitClosed(1);

    const early = try connectLoopback(t.boundPort());
    defer early.close();
    try testing.expectError(error.HandshakeRejected, handshake(early, "session-cap-hold"));

    hold.release();
    const recovered = try handshakeUntilAccepted(t.boundPort(), "session-cap-hold", 5_000);
    defer recovered.close();
    _ = hold.opened.wait(peers.len + 1);
}

test "transport: repeated concurrent sends and disconnects reclaim every worker allocation" {
    var failing = LockedFailingAllocator.init(testing.allocator, .{});
    defer failing.deinit();
    for (0..4) |round| {
        var opened = Opened{};
        defer opened.changed.deinit();
        defer opened.mutex.deinit();
        const t = try transport.Transport.init(failing.allocator(), 0);
        var deinitialized = false;
        defer if (!deinitialized) t.deinit();
        t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "concurrent-close" });
        try t.start(&opened, Opened.handler);

        const peer = try connectLoopback(t.boundPort());
        var peer_closed = false;
        defer if (!peer_closed) peer.close();
        try handshake(peer, "concurrent-close");
        const session = opened.wait(1);
        var sender = RepeatedSender{ .transport_ptr = t, .session = session };
        defer sender.changed.deinit();
        defer sender.mutex.deinit();
        const sender_thread = try std.Thread.spawn(.{}, RepeatedSender.run, .{&sender});
        sender.waitStarted();
        peer.close();
        peer_closed = true;
        sender.waitFinished();
        sender_thread.join();
        opened.waitClosed(1);
        t.deinit();
        deinitialized = true;
        std.debug.print("GOVERNANCE_CONCURRENT_CLOSE_RECLAIMED round={d}\n", .{round});
        try failing.expectFullyFreed();
    }
}

test "transport: deinit returns only after live workers release sockets and allocations" {
    var failing = LockedFailingAllocator.init(testing.allocator, .{});
    defer failing.deinit();
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    const t = try transport.Transport.init(failing.allocator(), 0);
    var deinitialized = false;
    defer if (!deinitialized) t.deinit();
    t.setDiscoveryTarget(.{ .title = "governance", .kind = "node", .url = "file:///governance.js", .id = "deinit-workers" });
    try t.start(&opened, Opened.handler);
    const bound_port = t.boundPort();

    const peer = try connectLoopback(bound_port);
    var peer_closed = false;
    defer if (!peer_closed) peer.close();
    try handshake(peer, "deinit-workers");
    const session = opened.wait(1);
    try testing.expect(t.sendText(session, "governance-queued-before-deinit"));
    t.deinit();
    deinitialized = true;
    peer.close();
    peer_closed = true;
    try failing.expectFullyFreed();

    const rebound = try transport.Transport.init(failing.allocator(), bound_port);
    defer rebound.deinit();
    try rebound.start(null, Opened.handler);
    try testing.expectEqual(bound_port, rebound.boundPort());
}

test "transport: shutdown completes when an HTTP peer leaves its headers unfinished" {
    const alloc = testing.allocator;
    var opened = Opened{};
    defer opened.changed.deinit();
    defer opened.mutex.deinit();
    const t = try transport.Transport.init(alloc, 0);
    try t.start(&opened, Opened.handler);
    const stream = try connectLoopback(t.boundPort());
    defer stream.close();
    try stream.writeAll("GET /json/version HTTP/1.1\r\nHost: localhost\r\n");
    std.debug.print("GOVERNANCE_PARTIAL_HTTP_SENT\n", .{});
    t.deinit();
}
