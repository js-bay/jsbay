//! Loopback lifecycle contracts for the Inspector transport.
//!
//! These tests exercise connection lifecycle, backpressure, allocation cleanup, and shutdown behavior against real HTTP and WebSocket peers.

const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");
const zev = @import("zev");
const test_client = @import("test_client");

const socket = @import("portable_socket");

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

fn httpStatusCode(response: []const u8) ?u16 {
    const prefix = "HTTP/1.";
    if (!std.mem.startsWith(u8, response, prefix)) return null;
    var index = prefix.len;
    if (index >= response.len or response[index] < '0' or response[index] > '9') return null;
    while (index < response.len and response[index] >= '0' and response[index] <= '9') index += 1;
    if (index >= response.len or response[index] != ' ') return null;
    index += 1;
    if (response.len < index + 3) return null;
    const code = std.fmt.parseInt(u16, response[index..][0..3], 10) catch return null;
    if (response.len > index + 3) {
        const boundary = response[index + 3];
        if (boundary != ' ' and boundary != '\r' and boundary != '\n') return null;
    }
    return code;
}

fn handshakeErrorForStatus(status: u16) anyerror {
    return switch (status) {
        503 => error.SessionCapacity,
        else => error.HandshakeRejected,
    };
}

fn retryableHandshakeError(err: anyerror) bool {
    return err == error.SessionCapacity;
}

fn remainingPollTimeout(deadline_ms: u64) !i32 {
    const now = zev.monotonicMilliseconds();
    if (now >= deadline_ms) return error.HandshakeTimeout;
    return @intCast(@min(deadline_ms - now, @as(u64, std.math.maxInt(i32))));
}

fn ensureDeadline(deadline_ms: u64) !void {
    _ = try remainingPollTimeout(deadline_ms);
}

fn waitReady(stream: Stream, event: socket.PollEvent, deadline_ms: u64) !void {
    const sock = socket.Socket{ .handle = stream.handle };
    while (true) {
        const timeout = try remainingPollTimeout(deadline_ms);
        const result = try sock.poll(event, timeout);
        if (result.timed_out) continue;
        if (result.ready) {
            try ensureDeadline(deadline_ms);
            return;
        }
        if (result.closed) return error.EndOfStream;
    }
}

fn writeAllUntil(stream: Stream, bytes: []const u8, deadline_ms: u64) !void {
    const sock = socket.Socket{ .handle = stream.handle };
    var offset: usize = 0;
    while (offset < bytes.len) {
        try ensureDeadline(deadline_ms);
        const written = sock.write(bytes[offset..]) catch |err| switch (err) {
            error.Interrupted => continue,
            error.WouldBlock => {
                try waitReady(stream, .write, deadline_ms);
                continue;
            },
            else => return err,
        };
        if (written == 0) return error.WriteFailed;
        offset += written;
    }
    try ensureDeadline(deadline_ms);
}

fn readByteUntil(stream: Stream, deadline_ms: u64) !u8 {
    const sock = socket.Socket{ .handle = stream.handle };
    var byte: [1]u8 = undefined;
    while (true) {
        try ensureDeadline(deadline_ms);
        const n = sock.read(&byte) catch |err| switch (err) {
            error.WouldBlock => {
                try waitReady(stream, .read, deadline_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        try ensureDeadline(deadline_ms);
        return byte[0];
    }
}

fn readHttpStatusUntil(alloc: std.mem.Allocator, stream: Stream, deadline_ms: u64) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(alloc);
    var suffix: [4]u8 = undefined;
    var len: usize = 0;
    while (true) {
        try ensureDeadline(deadline_ms);
        const byte = try readByteUntil(stream, deadline_ms);
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
        if (len == suffix.len and std.mem.eql(u8, &suffix, "\r\n\r\n")) {
            try ensureDeadline(deadline_ms);
            return bytes.toOwnedSlice(alloc);
        }
    }
}

fn upgradeRequest(buffer: *[512]u8, target: []const u8) ![]u8 {
    return std.fmt.bufPrint(
        buffer,
        "GET /{s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{target},
    );
}

fn finishHandshake(response: []const u8) !void {
    const status = httpStatusCode(response) orelse return error.HandshakeRejected;
    if (status != 101) return handshakeErrorForStatus(status);
}

fn handshake(stream: Stream, target: []const u8) !void {
    var request: [512]u8 = undefined;
    try stream.writeAll(try upgradeRequest(&request, target));
    const response = try readHttpStatus(testing.allocator, stream);
    defer testing.allocator.free(response);
    try finishHandshake(response);
}

fn handshakeUntil(stream: Stream, target: []const u8, deadline_ms: u64) !void {
    var request: [512]u8 = undefined;
    try writeAllUntil(stream, try upgradeRequest(&request, target), deadline_ms);
    const response = try readHttpStatusUntil(testing.allocator, stream, deadline_ms);
    defer testing.allocator.free(response);
    try ensureDeadline(deadline_ms);
    try finishHandshake(response);
}

fn connectLoopbackUntil(port: u16, deadline_ms: u64) !Stream {
    try ensureDeadline(deadline_ms);
    const started = try socket.beginConnectLoopback(port);
    const stream = Stream{ .handle = started.socket.handle };
    errdefer stream.close();
    if (!started.done) try waitReady(stream, .write, deadline_ms);
    try started.socket.connectStatus();
    try ensureDeadline(deadline_ms);
    return stream;
}

/// Retry a reconnect until the handshake is 101 or the absolute `timeout_ms` deadline elapses.
///
/// `session_closed` is fired before the last worker releases the session slot, so the first attempt after waitClosed can still receive HTTP 503. Connect, write, and response read all share one deadline; only 503 is retried.
fn handshakeUntilAccepted(port: u16, target: []const u8, timeout_ms: u64) !Stream {
    const deadline = zev.monotonicMilliseconds() + timeout_ms;
    while (true) {
        const peer = connectLoopbackUntil(port, deadline) catch |err| {
            if (err == error.HandshakeTimeout) return err;
            return err;
        };
        if (handshakeUntil(peer, target, deadline)) |_| {
            try ensureDeadline(deadline);
            return peer;
        } else |err| {
            peer.close();
            if (err == error.HandshakeTimeout or !retryableHandshakeError(err)) return err;
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

/// Records only sockets that finished connect so deferred cleanup never closes an uninitialized handle.
const PeerList = struct {
    items: [32]Stream = undefined,
    len: usize = 0,
    closed: [32]bool = @splat(false),

    fn add(self: *PeerList, stream: Stream) void {
        self.items[self.len] = stream;
        self.len += 1;
    }

    fn closeIndex(self: *PeerList, index: usize) void {
        if (index >= self.len or self.closed[index]) return;
        self.items[index].close();
        self.closed[index] = true;
    }

    fn closeAll(self: *PeerList) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) self.closeIndex(i);
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

    var peers = PeerList{};
    defer peers.closeAll();
    for (0..9) |_| {
        const peer = try connectLoopback(t.boundPort());
        peers.add(peer);
        try handshake(peer, "oom-broadcast");
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
    peers.closeAll();
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

    var peers = PeerList{};
    defer peers.closeAll();
    for (0..32) |_| {
        const peer = try connectLoopback(t.boundPort());
        peers.add(peer);
        try handshake(peer, "session-cap");
    }
    _ = opened.wait(peers.len);

    const rejected = try connectLoopback(t.boundPort());
    defer rejected.close();
    try rejected.writeAll("GET /session-cap HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
    const rejection = try readHttpStatus(alloc, rejected);
    defer alloc.free(rejection);
    try testing.expect(httpStatusCode(rejection) != 101);
    std.debug.print("GOVERNANCE_SESSION_CAP_REJECTED\n", .{});

    peers.closeIndex(0);
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

    var peers = PeerList{};
    defer peers.closeAll();
    for (0..32) |_| {
        const peer = try connectLoopback(t.boundPort());
        peers.add(peer);
        try handshake(peer, "session-cap-hold");
    }
    _ = hold.opened.wait(peers.len);

    peers.closeIndex(0);
    hold.opened.waitClosed(1);

    const early = try connectLoopback(t.boundPort());
    defer early.close();
    try testing.expectError(error.SessionCapacity, handshake(early, "session-cap-hold"));

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

const fixture_poll_ms: i32 = 20;

fn waitMs(ms: u64) void {
    var mutex: zev.Mutex = .{};
    defer mutex.deinit();
    var cond: zev.Condition = .init;
    defer cond.deinit();
    mutex.lock();
    defer mutex.unlock();
    _ = cond.waitTimeout(&mutex, ms);
}

const ScriptedResponse = struct {
    delay_ms: u64 = 0,
    body: []const u8 = &.{},
};

/// Loopback fixture whose accept/read/delay loops poll with a bound so teardown can join without closing the listener to wake a blocking syscall.
const ScriptedServer = struct {
    listener: socket.Listener,
    scripts: []const ScriptedResponse,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(self: *ScriptedServer) !void {
        try self.listener.socket.setNonBlocking(true);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn stopped(self: *ScriptedServer) bool {
        return self.stop.load(.seq_cst);
    }

    fn requestStop(self: *ScriptedServer) void {
        self.stop.store(true, .seq_cst);
    }

    fn join(self: *ScriptedServer) void {
        self.requestStop();
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn run(self: *ScriptedServer) void {
        for (self.scripts) |step| {
            if (self.stopped()) return;
            const handle = self.acceptOne() catch return;
            const sock = socket.Socket{ .handle = handle };
            defer sock.close();
            self.readHeaders(sock) catch return;
            if (self.stopped()) return;
            if (step.delay_ms > 0) self.waitOrStop(step.delay_ms);
            if (self.stopped()) return;
            if (step.body.len > 0) _ = sock.write(step.body) catch {};
        }
    }

    fn acceptOne(self: *ScriptedServer) !socket.Handle {
        while (true) {
            if (self.stopped()) return error.Stopped;
            const result = self.listener.accept() catch |err| return err;
            switch (result) {
                .accepted => |h| return h,
                .retry => {
                    const polled = self.listener.socket.poll(.read, fixture_poll_ms) catch return error.PollFailed;
                    if (polled.closed and !polled.ready) return error.Stopped;
                },
            }
        }
    }

    fn readHeaders(self: *ScriptedServer, sock: socket.Socket) !void {
        try sock.setNonBlocking(true);
        var suffix: [4]u8 = undefined;
        var len: usize = 0;
        var byte: [1]u8 = undefined;
        while (true) {
            if (self.stopped()) return error.Stopped;
            const n = sock.read(&byte) catch |err| switch (err) {
                error.WouldBlock => {
                    const polled = sock.poll(.read, fixture_poll_ms) catch return error.PollFailed;
                    if (polled.closed and !polled.ready) return error.EndOfStream;
                    continue;
                },
                else => return err,
            };
            if (n == 0) return error.EndOfStream;
            if (len < suffix.len) {
                suffix[len] = byte[0];
                len += 1;
            } else {
                suffix[0] = suffix[1];
                suffix[1] = suffix[2];
                suffix[2] = suffix[3];
                suffix[3] = byte[0];
            }
            if (len == suffix.len and std.mem.eql(u8, &suffix, "\r\n\r\n")) return;
        }
    }

    fn waitOrStop(self: *ScriptedServer, ms: u64) void {
        const deadline = zev.monotonicMilliseconds() + ms;
        while (!self.stopped()) {
            const now = zev.monotonicMilliseconds();
            if (now >= deadline) return;
            waitMs(@min(deadline - now, @as(u64, @intCast(fixture_poll_ms))));
        }
    }
};

fn serveAndJoin(server: *ScriptedServer) void {
    server.join();
    server.listener.close();
}

test "transport: handshakeUntilAccepted rejects a 101 that arrives after the deadline" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{.{ .delay_ms = 250, .body = "HTTP/1.1 101 Switching Protocols\r\n\r\n" }},
    };
    try server.start();
    defer serveAndJoin(&server);
    const start = zev.monotonicMilliseconds();
    try testing.expectError(error.HandshakeTimeout, handshakeUntilAccepted(listener.port, "test", 10));
    try testing.expect(zev.monotonicMilliseconds() - start < 100);
}

test "transport: a silent handshake peer is bounded by the retry deadline" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{.{ .delay_ms = 250, .body = &.{} }},
    };
    try server.start();
    defer serveAndJoin(&server);
    const start = zev.monotonicMilliseconds();
    try testing.expectError(error.HandshakeTimeout, handshakeUntilAccepted(listener.port, "test", 10));
    try testing.expect(zev.monotonicMilliseconds() - start < 100);
}

test "transport: HTTP status 1010 is not treated as 101" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{.{ .body = "HTTP/1.1 1010 Invalid Status\r\n\r\n" }},
    };
    try server.start();
    defer serveAndJoin(&server);
    const peer = try connectLoopback(listener.port);
    defer peer.close();
    try testing.expectError(error.HandshakeRejected, handshake(peer, "test"));
}

test "transport: HTTP 404 is not retried as a handshake timeout" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{.{ .body = "HTTP/1.1 404 Not Found\r\n\r\n" }},
    };
    try server.start();
    defer serveAndJoin(&server);
    const start = zev.monotonicMilliseconds();
    try testing.expectError(error.HandshakeRejected, handshakeUntilAccepted(listener.port, "test", 200));
    try testing.expect(zev.monotonicMilliseconds() - start < 100);
}

test "transport: HTTP 503 is retried until a later 101 succeeds" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{
            .{ .body = "HTTP/1.1 503 Inspector session capacity reached\r\n\r\n" },
            .{ .body = "HTTP/1.1 101 Switching Protocols\r\n\r\n" },
        },
    };
    try server.start();
    defer serveAndJoin(&server);
    const peer = try handshakeUntilAccepted(listener.port, "test", 1_000);
    defer peer.close();
}

test "transport: peer cleanup only closes sockets that finished connect" {
    const listener = try socket.listenLoopback(0);
    const Held = struct {
        listener: socket.Listener,
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        accepted: [2]socket.Socket = undefined,
        accepted_len: usize = 0,
        listener_closed: bool = false,
        stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.listener.socket.setNonBlocking(true) catch return;
            while (!self.stop.load(.seq_cst)) {
                self.mutex.lock();
                const done = self.accepted_len == self.accepted.len;
                self.mutex.unlock();
                if (done) return;
                const result = self.listener.accept() catch return;
                switch (result) {
                    .accepted => |h| {
                        self.mutex.lock();
                        self.accepted[self.accepted_len] = .{ .handle = h };
                        self.accepted_len += 1;
                        self.changed.broadcast();
                        self.mutex.unlock();
                    },
                    .retry => {
                        const polled = self.listener.socket.poll(.read, fixture_poll_ms) catch return;
                        if (polled.closed and !polled.ready) return;
                    },
                }
            }
        }

        fn waitAccepted(self: *@This(), want: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.accepted_len < want) self.changed.wait(&self.mutex);
        }

        fn closeListener(self: *@This()) void {
            if (self.listener_closed) return;
            self.listener.close();
            self.listener_closed = true;
        }

        fn closeHeld(self: *@This()) void {
            self.mutex.lock();
            const len = self.accepted_len;
            var copies = self.accepted;
            self.mutex.unlock();
            var i: usize = 0;
            while (i < len) : (i += 1) copies[i].close();
        }
    };
    var held = Held{ .listener = listener };
    defer held.changed.deinit();
    defer held.mutex.deinit();
    const thread = try std.Thread.spawn(.{}, Held.run, .{&held});
    defer {
        held.stop.store(true, .seq_cst);
        thread.join();
        held.closeHeld();
        held.closeListener();
    }

    var peers = PeerList{};
    defer peers.closeAll();
    const first = try connectLoopback(listener.port);
    peers.add(first);
    const second = try connectLoopback(listener.port);
    peers.add(second);
    held.waitAccepted(2);
    held.closeListener();
    try testing.expectError(error.ConnectFailed, connectLoopback(listener.port));
    try testing.expectEqual(@as(usize, 2), peers.len);
}

test "transport: continuously readable headers still honor the handshake deadline" {
    const alloc = testing.allocator;
    const prefix = "HTTP/1.1 101 Switching Protocols\r\nX-Large: ";
    const suffix = "\r\n\r\n";
    const pad = 1024 * 1024;
    const body = try alloc.alloc(u8, prefix.len + pad + suffix.len);
    defer alloc.free(body);
    @memcpy(body[0..prefix.len], prefix);
    @memset(body[prefix.len..][0..pad], 'x');
    @memcpy(body[prefix.len + pad ..], suffix);

    const listener = try socket.listenLoopback(0);
    const scripts = [_]ScriptedResponse{.{ .body = body }};
    var server = ScriptedServer{ .listener = listener, .scripts = &scripts };
    try server.start();
    defer serveAndJoin(&server);
    const start = zev.monotonicMilliseconds();
    try testing.expectError(error.HandshakeTimeout, handshakeUntilAccepted(listener.port, "test", 10));
    try testing.expect(zev.monotonicMilliseconds() - start < 100);
}

test "transport: scripted server join does not wait for an unused scripted accept" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{
            .{ .body = "HTTP/1.1 503 Inspector session capacity reached\r\n\r\n" },
            .{ .body = "HTTP/1.1 101 Switching Protocols\r\n\r\n" },
        },
    };
    try server.start();
    const peer = try connectLoopback(listener.port);
    defer peer.close();
    try testing.expectError(error.SessionCapacity, handshake(peer, "test"));
    const start = zev.monotonicMilliseconds();
    serveAndJoin(&server);
    try testing.expect(zev.monotonicMilliseconds() - start < 300);
}

test "transport: scripted server join does not wait for unread request headers" {
    const listener = try socket.listenLoopback(0);
    var server = ScriptedServer{
        .listener = listener,
        .scripts = &.{.{ .body = "HTTP/1.1 101 Switching Protocols\r\n\r\n" }},
    };
    try server.start();
    const peer = try connectLoopback(listener.port);
    defer peer.close();
    const start = zev.monotonicMilliseconds();
    serveAndJoin(&server);
    try testing.expect(zev.monotonicMilliseconds() - start < 300);
}
