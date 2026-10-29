//! Loopback lifecycle contracts for the Inspector transport.
//!
//! These tests exercise connection lifecycle, backpressure, allocation cleanup, and shutdown behavior against real HTTP and WebSocket peers.

const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");
const zev = @import("zev");

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
    try std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&receive_bytes));
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
    try std.posix.setsockopt(slow.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, std.mem.asBytes(&receive_bytes));
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
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
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

    // The first snapshot append allocates its backing storage. The ninth append grows it. Let that first allocation succeed and fail the next allocation, which is the snapshot growth on this allocator.
    failing.fail_index = failing.alloc_index + 1;
    t.broadcastText("oom-broadcast-token");
    try testing.expect(failing.has_induced_failure);
    std.debug.print("GOVERNANCE_BROADCAST_RESIZE_FAILED peers={d}\n", .{peers.len});
    t.deinit();
    deinitialized = true;
    for (peers) |peer| peer.close();
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
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
    const recovered = try connectLoopback(t.boundPort());
    defer recovered.close();
    try handshake(recovered, "session-cap");
    _ = opened.wait(peers.len + 1);
}

test "transport: repeated concurrent sends and disconnects reclaim every worker allocation" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
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
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "transport: deinit returns only after live workers release sockets and allocations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
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
    try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);

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
