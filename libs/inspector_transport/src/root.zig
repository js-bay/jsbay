//! Chrome DevTools Protocol inspector transport (MVP).
//!
//! Byte-level WebSocket + minimal HTTP discovery endpoints, built directly on raw POSIX socket syscalls (no std.net / std.Io.net — see the "Raw POSIX socket layer" note below for why).
//!
//! Responsibilities:
//!   - Bind a TCP port, accept connections on a background thread.
//!   - Serve /json, /json/list, /json/version, /json/protocol discovery.
//!   - Upgrade HTTP → WebSocket on GET /<target-id> with Sec-WebSocket-Key.
//! - Spawn a per-session reader thread that unmasks text frames and fires a caller-supplied handler. Handlers run on reader threads and MUST be thread-safe.
//!   - Send WS text frames from any thread (per-session write mutex).
//!
//! Explicitly NOT responsible for CDP protocol semantics; this is pure transport. Higher layers compose JSON-RPC on top.

const std = @import("std");
const inspector = @import("inspector");
const zev = @import("zev");

// A callback can request destruction of its transport. Its own socket worker must unwind before the transport can be released.
threadlocal var callback_transport: ?*Transport = null;

// -- Raw POSIX socket layer -------------------------------------------------
//
// This accept loop uses fcntl to poll a nonblocking listener so shutdown can be observed without closing a descriptor used by another thread. Use the matching libc calls directly because the std.Io network API treats EAGAIN from this configuration as a programmer error.
const RawSocket = struct {
    handle: std.posix.fd_t,

    fn close(s: RawSocket) void {
        _ = std.posix.system.close(s.handle);
    }

    fn setNonBlocking(s: RawSocket, nonblocking: bool) !void {
        const flags = std.posix.system.fcntl(s.handle, std.posix.F.GETFL, @as(c_int, 0));
        if (flags < 0) return error.FcntlFailed;
        const mask: c_int = @intCast(@as(u32, @bitCast(std.posix.O{ .NONBLOCK = true })));
        const new_flags: c_int = if (nonblocking) flags | mask else flags & ~mask;
        if (std.posix.system.fcntl(s.handle, std.posix.F.SETFL, new_flags) < 0) return error.FcntlFailed;
    }

    fn read(s: RawSocket, buf: []u8) !usize {
        return std.posix.read(s.handle, buf);
    }

    fn writeAll(s: RawSocket, bytes: []const u8) !void {
        try s.writeUntil(bytes, @as(i64, @intCast(zev.monotonicMilliseconds())) + write_deadline_ms, null);
    }

    fn writeUntil(s: RawSocket, bytes: []const u8, deadline: i64, sess: ?*Session) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            if (sess) |active| {
                if (active.closed.load(.acquire)) return error.Closed;
            }
            const n = std.c.send(s.handle, bytes.ptr + off, bytes.len - off, std.posix.MSG.NOSIGNAL);
            if (n < 0) {
                switch (std.posix.errno(n)) {
                    .INTR => continue,
                    .AGAIN => {
                        try waitSocket(s, std.posix.POLL.OUT, deadline, sess);
                        continue;
                    },
                    else => return error.WriteFailed,
                }
            }
            if (n == 0) return error.WriteFailed;
            off += @intCast(n);
        }
    }

    fn shutdownBoth(s: RawSocket) void {
        _ = std.posix.system.shutdown(s.handle, std.posix.SHUT.RDWR);
    }
};

const RawListener = struct {
    handle: std.posix.fd_t,
    port: u16,

    fn close(l: RawListener) void {
        _ = std.posix.system.close(l.handle);
    }

    /// Bind+listen on 127.0.0.1:want_port (0 = ephemeral). `port` on the returned value is the actually-bound port.
    fn openStreamSocket() !std.posix.fd_t {
        const raw = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (raw < 0) return error.SocketFailed;
        return @intCast(raw);
    }

    fn listenIp4Loopback(want_port: u16) !RawListener {
        const fd = openStreamSocket() catch return error.SocketFailed;
        errdefer _ = std.posix.system.close(fd);

        const reuse: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse));

        var addr: std.posix.sockaddr.in = .{
            .port = std.mem.nativeToBig(u16, want_port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        };
        if (std.posix.system.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.posix.system.listen(fd, 128) < 0) return error.ListenFailed;

        var actual: std.posix.sockaddr.in = undefined;
        var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        if (std.posix.system.getsockname(fd, @ptrCast(&actual), &actual_len) < 0) return error.GetSockNameFailed;
        return .{ .handle = fd, .port = std.mem.bigToNative(u16, actual.port) };
    }
};

// -- Public API -----------------------------------------------------------

pub const SessionId = inspector.SessionId;
pub const EventKind = inspector.EventKind;
pub const Event = inspector.Event;
pub const EventHandler = inspector.EventHandler;
pub const DiscoveryTarget = inspector.DiscoveryTarget;

// -- Internals ------------------------------------------------------------

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const max_queued_bytes: usize = 4 * 1024 * 1024;
const max_queued_frames: usize = 256;
const max_sessions: usize = 32;
const write_deadline_ms: i64 = 2_000;
const io_poll_ms: i32 = 100;

const OutboundKind = enum { text, pong, close };

const Outbound = struct {
    kind: OutboundKind,
    bytes: []u8,
};

const Session = struct {
    id: SessionId,
    stream: RawSocket,
    allocator: std.mem.Allocator,
    /// The registry owns one reference, each reader/writer owns one while it runs, and lookupSession retains a temporary send lease.  The fd is only closed by the final release, so a recycled fd cannot be used by a sender or worker that already held a lease.
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    /// Reserved before either worker is spawned.  A slot stays occupied until both detached workers exit, so rapid disconnects cannot bypass the connection cap while writers are still draining or timing out.
    workers_remaining: std.atomic.Value(u8) = std.atomic.Value(u8).init(2),
    queue_mu: zev.Mutex = .{},
    queue_changed: zev.Condition = .init,
    queue: std.ArrayListUnmanaged(Outbound) = .empty,
    queue_head: usize = 0,
    queued_bytes: usize = 0,
    accepting: bool = true,
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Threads are detached. Their references give the transport a durable lifetime boundary while avoiding an ever-growing list of joined handles.
    transport: *Transport,

    fn retain(self: *Session) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    fn release(self: *Session) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        self.queue_mu.lock();
        for (self.queue.items[self.queue_head..]) |frame| self.allocator.free(frame.bytes);
        self.queue.deinit(self.allocator);
        self.queue_head = 0;
        self.queue_mu.unlock();
        self.queue_changed.deinit();
        self.queue_mu.deinit();
        self.stream.close();
        self.allocator.destroy(self);
    }

    /// This transition is deliberately separate from close(2): shutdown wakes both workers, but the descriptor remains owned until their/session leases have drained.
    fn requestClose(self: *Session) void {
        if (self.closed.swap(true, .acq_rel)) return;
        self.queue_mu.lock();
        self.accepting = false;
        for (self.queue.items[self.queue_head..]) |frame| self.allocator.free(frame.bytes);
        self.queue.clearRetainingCapacity();
        self.queue_head = 0;
        self.queued_bytes = 0;
        self.queue_changed.broadcast();
        self.queue_mu.unlock();
        self.stream.shutdownBoth();
    }

    fn enqueue(self: *Session, kind: OutboundKind, bytes: []const u8, close_on_reject: bool) bool {
        self.queue_mu.lock();
        if (!self.accepting or self.closed.load(.acquire)) {
            self.queue_mu.unlock();
            return false;
        }
        const pending_frames = self.queue.items.len - self.queue_head;
        if (bytes.len > max_queued_bytes or pending_frames >= max_queued_frames or self.queued_bytes > max_queued_bytes - bytes.len) {
            self.queue_mu.unlock();
            if (close_on_reject) self.requestClose();
            return false;
        }
        const copy = self.allocator.dupe(u8, bytes) catch {
            self.queue_mu.unlock();
            return false;
        };
        self.queue.append(self.allocator, .{ .kind = kind, .bytes = copy }) catch {
            self.allocator.free(copy);
            self.queue_mu.unlock();
            return false;
        };
        self.queued_bytes += copy.len;
        self.queue_changed.signal();
        self.queue_mu.unlock();
        return true;
    }

    /// A peer close is serialized through the writer, preserving frame order. Once queued, new application messages are rejected.
    fn enqueueClose(self: *Session, code: u16) void {
        var body: [2]u8 = undefined;
        std.mem.writeInt(u16, &body, code, .big);
        self.queue_mu.lock();
        if (!self.accepting or self.closed.load(.acquire)) {
            self.queue_mu.unlock();
            self.requestClose();
            return;
        }
        self.accepting = false;
        const copy = self.allocator.dupe(u8, &body) catch {
            self.queue_mu.unlock();
            self.requestClose();
            return;
        };
        self.queue.append(self.allocator, .{ .kind = .close, .bytes = copy }) catch {
            self.allocator.free(copy);
            self.queue_mu.unlock();
            self.requestClose();
            return;
        };
        self.queued_bytes += copy.len;
        self.queue_changed.signal();
        self.queue_mu.unlock();
    }

    fn workerWasNotStarted(self: *Session) void {
        if (self.workers_remaining.fetchSub(1, .acq_rel) == 1) self.transport.sessionSlotGone();
    }

    fn workerFinished(self: *Session) bool {
        return self.workers_remaining.fetchSub(1, .acq_rel) == 1;
    }
};

/// Per-session entry stored in Transport.sessions. Heap-allocated so its address is stable while reader threads hold a pointer.
const SessionEntry = struct {
    session: *Session,
};

pub const Transport = struct {
    /// Adapter used by Inspector. The HTTP/WebSocket server remains optional:
    /// callers may instead implement this same Inspector transport interface.
    interface: inspector.Transport = undefined,
    allocator: std.mem.Allocator,
    /// 0 = "bind ephemeral"; after start() this is the actual bound port.
    want_port: u16,
    bound_port: u16 = 0,

    server: ?RawListener = null,

    ctx: ?*anyopaque = null,
    handler: ?EventHandler = null,

    /// Signals the accept thread and reader threads to stop.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    accept_thread: ?std.Thread = null,

    sessions_mu: zev.Mutex = .{},
    sessions: std.ArrayList(*Session),
    session_slots: usize = 0,
    workers_mu: zev.Mutex = .{},
    workers_changed: zev.Condition = .init,
    /// Both detached workers are counted.  Detaching reclaims completed sessions continuously; deinit still waits for all owned socket workers before returning.
    workers_alive: usize = 0,
    accept_exited: bool = true,
    deferred_deinit: bool = false,
    deinit_started: std.atomic.Value(bool) = .init(false),

    /// Monotonic session id counter (starts at 1).
    next_session_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    /// Owned copies of DiscoveryTarget string fields (they may reference caller-owned memory that outlives a single call to setDiscoveryTarget, so we duplicate to be safe).
    target_title: []u8 = &.{},
    target_kind: []u8 = &.{},
    target_url: []u8 = &.{},
    target_id: []u8 = &.{},
    target_set: bool = false,
    /// Borrowed protocol document. It must outlive this transport.
    protocol_json: []const u8 = "{}",

    pub fn init(allocator: std.mem.Allocator, port: u16) !*Transport {
        const self = try allocator.create(Transport);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .want_port = port,
            .sessions = .empty,
        };
        self.interface = .{ .ctx = self, .vtable = &transport_vtable };
        return self;
    }

    /// Configures the JSON served from `/json/protocol`. This transport does not own the slice, so pass static or otherwise long-lived storage.
    pub fn setProtocolJson(self: *Transport, protocol_json: []const u8) void {
        self.protocol_json = protocol_json;
    }

    /// Returns the Inspector-owned view. Once supplied to an Inspector, that Inspector calls `deinit` during shutdown and consumes this allocation; callers must not then access or deinitialize `self` themselves.
    pub fn asTransport(self: *Transport) *inspector.Transport {
        return &self.interface;
    }

    /// Outside an event handler, waits for every owned thread and descriptor. In this transport's handler, requests shutdown and returns; the last worker releases the transport after all callbacks have unwound. The allocator and handler context must outlive that deferred release.
    pub fn deinit(self: *Transport) void {
        if (self.deinit_started.swap(true, .acq_rel)) return;
        if (callback_transport == self) {
            self.shutdown.store(true, .release);
            self.sessions_mu.lock();
            for (self.sessions.items) |sess| sess.requestClose();
            self.sessions_mu.unlock();
            // The accept loop participates in deferred ownership, including when session_opened is the callback requesting shutdown.
            if (self.accept_thread) |thread| thread.detach();
            self.accept_thread = null;
            self.workers_mu.lock();
            self.deferred_deinit = true;
            self.workers_mu.unlock();
            return;
        }
        // Signal shutdown. The accept loop polls the shutdown flag between short poll() calls and exits on its own — we MUST NOT close the listener here because a blocking accept() racing with close() on the same fd is still unsafe (see the RawSocket note above).
        self.shutdown.store(true, .seq_cst);

        // Join accept thread. Safe now because the accept loop exits on its next poll-timeout after it sees shutdown==true.
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }

        // Only now is it safe to close the listener (accept thread has joined so no concurrent accept() on this fd).
        if (self.server) |s| {
            s.close();
            self.server = null;
        }

        // Do not take an allocating snapshot: OOM must not leave a session asleep during shutdown.  requestClose does not acquire sessions_mu, and removals wait until this iteration releases it.
        self.sessions_mu.lock();
        for (self.sessions.items) |sess| sess.requestClose();
        self.sessions_mu.unlock();

        // Wait for detached workers so no reader, writer, or transport-owned fd remains once deinit returns.
        self.workers_mu.lock();
        while (self.workers_alive != 0) self.workers_changed.wait(&self.workers_mu);
        self.workers_mu.unlock();

        self.destroyStorage();
    }

    fn destroyStorage(self: *Transport) void {
        const alloc = self.allocator;
        if (self.server) |server| server.close();
        self.sessions.deinit(alloc);
        self.workers_changed.deinit();
        self.workers_mu.deinit();
        self.sessions_mu.deinit();
        alloc.free(self.target_title);
        alloc.free(self.target_kind);
        alloc.free(self.target_url);
        alloc.free(self.target_id);

        alloc.destroy(self);
    }

    pub fn setDiscoveryTarget(self: *Transport, target: DiscoveryTarget) void {
        // Best-effort: on OOM we leave the previous target in place. The caller has opted into a void-returning API so we can't surface the error; failure here just means discovery endpoints return the previous target (or a generic one) until re-called.
        const new_title = self.allocator.dupe(u8, target.title) catch return;
        const new_kind = self.allocator.dupe(u8, target.kind) catch {
            self.allocator.free(new_title);
            return;
        };
        const new_url = self.allocator.dupe(u8, target.url) catch {
            self.allocator.free(new_title);
            self.allocator.free(new_kind);
            return;
        };
        const new_id = self.allocator.dupe(u8, target.id) catch {
            self.allocator.free(new_title);
            self.allocator.free(new_kind);
            self.allocator.free(new_url);
            return;
        };
        self.allocator.free(self.target_title);
        self.allocator.free(self.target_kind);
        self.allocator.free(self.target_url);
        self.allocator.free(self.target_id);
        self.target_title = new_title;
        self.target_kind = new_kind;
        self.target_url = new_url;
        self.target_id = new_id;
        self.target_set = true;
    }

    pub fn start(self: *Transport, ctx: ?*anyopaque, handler: EventHandler) !void {
        if (self.server != null) return error.AlreadyStarted;
        self.ctx = ctx;
        self.handler = handler;

        self.server = try RawListener.listenIp4Loopback(self.want_port);
        self.bound_port = self.server.?.port;

        self.accept_exited = false;
        self.accept_thread = std.Thread.spawn(.{}, acceptLoop, .{self}) catch |err| {
            self.accept_exited = true;
            return err;
        };
    }

    pub fn sendText(self: *Transport, session: SessionId, message: []const u8) bool {
        const sess = self.lookupSession(session) orelse return false;
        defer sess.release();
        return sess.enqueue(.text, message, true);
    }

    pub fn broadcastText(self: *Transport, message: []const u8) void {
        // Snapshot retained leases; socket I/O happens only on session writers.
        var snapshot: std.ArrayList(*Session) = .empty;
        defer snapshot.deinit(self.allocator);
        // `append` can fail after earlier leases were retained.  Keep their release paired with the temporary snapshot on every return path.
        defer for (snapshot.items) |sess| sess.release();
        {
            self.sessions_mu.lock();
            defer self.sessions_mu.unlock();
            for (self.sessions.items) |sess| {
                sess.retain();
                snapshot.append(self.allocator, sess) catch {
                    sess.release();
                    return;
                };
            }
        }
        for (snapshot.items) |sess| {
            _ = sess.enqueue(.text, message, true);
        }
    }

    pub fn closeSession(self: *Transport, session: SessionId) void {
        const sess = self.lookupSession(session) orelse return;
        defer sess.release();
        sess.enqueueClose(1000);
    }

    pub fn boundPort(self: *Transport) u16 {
        return self.bound_port;
    }

    // -- Internal: session bookkeeping --

    fn lookupSession(self: *Transport, id: SessionId) ?*Session {
        self.sessions_mu.lock();
        defer self.sessions_mu.unlock();
        for (self.sessions.items) |s| {
            if (s.id == id and !s.closed.load(.acquire)) {
                s.retain();
                return s;
            }
        }
        return null;
    }

    fn registerSession(self: *Transport, sess: *Session) !void {
        self.sessions_mu.lock();
        defer self.sessions_mu.unlock();
        if (self.session_slots >= max_sessions) return error.SessionLimit;
        try self.sessions.append(self.allocator, sess);
        self.session_slots += 1;
    }

    fn removeSession(self: *Transport, id: SessionId) void {
        self.sessions_mu.lock();
        defer self.sessions_mu.unlock();
        var i: usize = 0;
        while (i < self.sessions.items.len) : (i += 1) {
            if (self.sessions.items[i].id == id) {
                const sess = self.sessions.items[i];
                _ = self.sessions.swapRemove(i);
                sess.release();
                return;
            }
        }
    }

    fn fire(self: *Transport, ev: Event) void {
        if (self.shutdown.load(.acquire)) return;
        const previous = callback_transport;
        callback_transport = self;
        defer callback_transport = previous;
        if (self.handler) |h| h(self.ctx, ev);
    }

    fn workerStarted(self: *Transport) void {
        self.workers_mu.lock();
        self.workers_alive += 1;
        self.workers_mu.unlock();
    }

    fn workerGone(self: *Transport) void {
        self.workers_mu.lock();
        std.debug.assert(self.workers_alive != 0);
        self.workers_alive -= 1;
        const finalize = self.deferred_deinit and self.accept_exited and self.workers_alive == 0;
        self.workers_changed.broadcast();
        self.workers_mu.unlock();
        if (finalize) self.destroyStorage();
    }

    fn acceptGone(self: *Transport) void {
        self.workers_mu.lock();
        self.accept_exited = true;
        const finalize = self.deferred_deinit and self.workers_alive == 0;
        self.workers_mu.unlock();
        if (finalize) self.destroyStorage();
    }

    fn sessionSlotGone(self: *Transport) void {
        self.sessions_mu.lock();
        std.debug.assert(self.session_slots != 0);
        self.session_slots -= 1;
        self.sessions_mu.unlock();
    }
};

// -- Accept loop ---------------------------------------------------------

fn acceptLoop(t: *Transport) void {
    defer t.acceptGone();
    const listener = t.server orelse return;
    const listener_fd = listener.handle;

    // Make the listener non-blocking so we can poll with a short timeout and observe the shutdown flag frequently. This avoids a BADF panic that happens when a blocking accept() races with close() in deinit().
    (RawSocket{ .handle = listener_fd }).setNonBlocking(true) catch return;

    while (!t.shutdown.load(.seq_cst)) {
        var pfds = [_]std.posix.pollfd{.{
            .fd = listener_fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const rc = std.posix.poll(&pfds, 100) catch return;
        if (rc == 0) continue; // timeout — loop and re-check shutdown
        if (pfds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL) != 0) return;
        if (pfds[0].revents & std.posix.POLL.IN == 0) continue;

        const accepted_fd = std.posix.system.accept(listener_fd, null, null);
        if (accepted_fd < 0) {
            switch (std.posix.errno(accepted_fd)) {
                .AGAIN, .INTR => continue,
                .CONNABORTED, .MFILE, .NFILE => continue,
                else => return,
            }
        }
        const conn = RawSocket{ .handle = @intCast(accepted_fd) };
        conn.setNonBlocking(true) catch {
            conn.close();
            continue;
        };

        handleConnection(t, conn) catch |e| {
            // Handshake failures close the stream but must not kill the accept loop.
            std.log.debug("inspector_transport: connection error: {s}", .{@errorName(e)});
        };
    }
}

/// Parse HTTP request line/headers. If the request upgrades to WebSocket, take over the stream and spawn a reader thread. Otherwise serve the appropriate discovery response and close.
fn handleConnection(t: *Transport, conn: RawSocket) !void {
    const stream = conn;
    errdefer stream.close();

    // Read until we see \r\n\r\n or fill the buffer. 8 KiB is ample for DevTools handshake requests.
    var buf: [8 * 1024]u8 = undefined;
    var used: usize = 0;
    const deadline = @as(i64, @intCast(zev.monotonicMilliseconds())) + write_deadline_ms;
    while (used < buf.len) {
        if (t.shutdown.load(.acquire)) return error.Closed;
        const n = stream.read(buf[used..]) catch |err| switch (err) {
            error.WouldBlock => {
                try waitSocket(stream, std.posix.POLL.IN, deadline, null);
                continue;
            },
            else => return err,
        };
        if (n == 0) return; // peer closed mid-request
        used += n;
        if (std.mem.indexOf(u8, buf[0..used], "\r\n\r\n") != null) break;
    }
    const req = buf[0..used];

    // Parse the request line.
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return writeBadRequest(stream);
    const req_line = req[0..line_end];
    // "GET /path HTTP/1.1"
    var it = std.mem.splitScalar(u8, req_line, ' ');
    const method = it.next() orelse return writeBadRequest(stream);
    const path = it.next() orelse return writeBadRequest(stream);
    if (!std.mem.eql(u8, method, "GET")) return writeNotFound(stream);

    // Scan headers.
    const headers_start = line_end + 2;
    const headers_end = std.mem.indexOf(u8, req, "\r\n\r\n") orelse return writeBadRequest(stream);
    const headers_slice = req[headers_start..headers_end];

    var ws_key: ?[]const u8 = null;
    var upgrade_ws = false;
    {
        var hit = std.mem.splitSequence(u8, headers_slice, "\r\n");
        while (hit.next()) |hline| {
            if (hline.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, hline, ':') orelse continue;
            const name = std.mem.trim(u8, hline[0..colon], " \t");
            const val = std.mem.trim(u8, hline[colon + 1 ..], " \t");
            if (std.ascii.eqlIgnoreCase(name, "Upgrade") and std.ascii.eqlIgnoreCase(val, "websocket")) {
                upgrade_ws = true;
            } else if (std.ascii.eqlIgnoreCase(name, "Sec-WebSocket-Key")) {
                ws_key = val;
            }
        }
    }

    if (upgrade_ws) {
        // Path must match configured target id (leading '/').
        if (path.len < 2 or path[0] != '/') return writeBadRequest(stream);
        const path_id = path[1..];
        if (!t.target_set or !std.mem.eql(u8, path_id, t.target_id)) {
            return writeBadRequest(stream);
        }
        const key = ws_key orelse return writeBadRequest(stream);
        // Capacity is reserved before 101 is visible to the peer.  The reservation and registry append share sessions_mu, so concurrent handshakes cannot all pass a racy preflight check.
        const sess = reserveSession(t, stream) catch |err| switch (err) {
            error.SessionLimit => return writeServiceUnavailable(stream),
            else => return err,
        };
        writeWsAccept(stream, key) catch |err| {
            discardReservedSession(t, sess);
            return err;
        };
        // 101 succeeded; session_opened is emitted by this path only after the reservation has become a real worker-backed session.
        try startReservedSession(t, sess);
        return;
    }

    // HTTP discovery routing.
    if (std.mem.eql(u8, path, "/json/version")) {
        try writeVersion(stream);
    } else if (std.mem.eql(u8, path, "/json") or std.mem.eql(u8, path, "/json/list")) {
        try writeTargetList(t, stream);
    } else if (std.mem.eql(u8, path, "/json/protocol")) {
        try writeProtocol(t, stream);
    } else {
        try writeNotFound(stream);
    }
    stream.close();
}

fn writeBadRequest(stream: RawSocket) !void {
    const body = "Bad Request";
    var buf: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    stream.writeAll(resp) catch {};
    stream.close();
}

fn writeNotFound(stream: RawSocket) !void {
    const body = "Not Found";
    var buf: [128]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    stream.writeAll(resp) catch {};
    stream.close();
}

fn writeServiceUnavailable(stream: RawSocket) !void {
    const body = "Inspector session capacity reached";
    var buf: [160]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    stream.writeAll(resp) catch {};
    stream.close();
}

fn writeJsonResponse(stream: RawSocket, body: []const u8) !void {
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(
        &hdr_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=UTF-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    );
    try stream.writeAll(hdr);
    try stream.writeAll(body);
}

fn writeVersion(stream: RawSocket) !void {
    const body =
        \\{"Browser":"js-bay/0.1","Protocol-Version":"1.3","V8-Version":"0","WebKit-Version":"0","User-Agent":"js-bay"}
    ;
    try writeJsonResponse(stream, body);
}

fn writeProtocol(t: *Transport, stream: RawSocket) !void {
    try writeJsonResponse(stream, t.protocol_json);
}

fn writeTargetList(t: *Transport, stream: RawSocket) !void {
    // Build JSON into a growable buffer so title/url may be arbitrary length.
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    const w = &aw.writer;

    if (!t.target_set) {
        // No target configured yet — return an empty array, still valid JSON.
        try w.writeAll("[]");
    } else {
        try w.writeByte('[');
        try w.writeAll("{\"description\":");
        try writeJsonString(w, t.target_title);
        try w.writeAll(",\"devtoolsFrontendUrl\":");
        try writeJsonFmt(w, "devtools://devtools/bundled/js_app.html?ws=localhost:{d}/{s}", .{ t.bound_port, t.target_id });
        try w.writeAll(",\"id\":");
        try writeJsonString(w, t.target_id);
        try w.writeAll(",\"title\":");
        try writeJsonString(w, t.target_title);
        try w.writeAll(",\"type\":");
        try writeJsonString(w, t.target_kind);
        try w.writeAll(",\"url\":");
        try writeJsonString(w, t.target_url);
        try w.writeAll(",\"webSocketDebuggerUrl\":");
        try writeJsonFmt(w, "ws://localhost:{d}/{s}", .{ t.bound_port, t.target_id });
        try w.writeByte('}');
        try w.writeByte(']');
    }

    try writeJsonResponse(stream, aw.written());
}

fn writeJsonFmt(writer: anytype, comptime fmt: []const u8, args: anytype) !void {
    // Build the string first so we can JSON-escape it.
    var tmp: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, fmt, args);
    try writeJsonString(writer, s);
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                var buf: [6]u8 = undefined;
                const esc = try std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c});
                try writer.writeAll(esc);
            },
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

fn writeWsAccept(stream: RawSocket, key: []const u8) !void {
    // Sec-WebSocket-Accept = base64(sha1(key ++ WS_GUID))
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update(WS_GUID);
    var digest: [20]u8 = undefined;
    sha.final(&digest);

    var accept_buf: [28]u8 = undefined;
    const accept = std.base64.standard.Encoder.encode(&accept_buf, &digest);

    var resp_buf: [256]u8 = undefined;
    const resp = try std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n",
        .{accept},
    );
    try stream.writeAll(resp);
}

// -- Session lifecycle ---------------------------------------------------

fn reserveSession(t: *Transport, stream: RawSocket) !*Session {
    if (t.shutdown.load(.acquire)) return error.Closed;
    const sess = try t.allocator.create(Session);
    sess.* = .{
        .id = t.next_session_id.fetchAdd(1, .seq_cst),
        .stream = stream,
        .allocator = t.allocator,
        .transport = t,
    };
    errdefer {
        sess.queue_changed.deinit();
        sess.queue_mu.deinit();
        t.allocator.destroy(sess);
    }

    try t.registerSession(sess);
    return sess;
}

/// Drops a reservation which has no worker references yet (for example a failed 101 write).  Both future worker slots are returned before the registry reference is released.
fn discardReservedSession(t: *Transport, sess: *Session) void {
    sess.workerWasNotStarted();
    sess.workerWasNotStarted();
    t.removeSession(sess.id);
}

fn startReservedSession(t: *Transport, sess: *Session) !void {
    errdefer t.removeSession(sess.id);

    t.workerStarted();
    sess.retain();
    const writer = std.Thread.spawn(.{}, writerLoop, .{sess}) catch |err| {
        // Neither reserved worker exists, so release the session slot before the errdefer removes the registry reference.
        sess.workerWasNotStarted();
        sess.workerWasNotStarted();
        sess.release();
        t.workerGone();
        return err;
    };
    writer.detach();

    // The opened event precedes every reader message.  Reader liveness is counted before spawning so deinit cannot free Transport early.
    t.workerStarted();
    t.fire(.{ .kind = .session_opened, .session_id = sess.id, .payload = &.{} });
    sess.retain();
    const reader = std.Thread.spawn(.{}, sessionLoop, .{sess}) catch |err| {
        sess.workerWasNotStarted();
        sess.release();
        t.workerGone();
        sess.requestClose();
        t.fire(.{ .kind = .session_closed, .session_id = sess.id, .payload = &.{} });
        return err;
    };
    reader.detach();
}

fn writerLoop(sess: *Session) void {
    const t = sess.transport;
    defer {
        const final_worker = sess.workerFinished();
        sess.release();
        // deinit waits on this counter.  It is notified only after this worker has released its Session reference and, for the last worker, after the descriptor can no longer be retained by a worker.
        if (final_worker) t.sessionSlotGone();
        t.workerGone();
    }
    while (true) {
        sess.queue_mu.lock();
        while (sess.queue.items.len == sess.queue_head and !sess.closed.load(.acquire)) {
            sess.queue_changed.wait(&sess.queue_mu);
        }
        if (sess.queue.items.len == sess.queue_head) {
            sess.queue_mu.unlock();
            return;
        }
        const frame = sess.queue.items[sess.queue_head];
        sess.queue_head += 1;
        if (sess.queue_head == sess.queue.items.len) {
            sess.queue.clearRetainingCapacity();
            sess.queue_head = 0;
        } else if (sess.queue_head >= 32) {
            const remain = sess.queue.items[sess.queue_head..];
            var write: usize = 0;
            while (write < remain.len) : (write += 1) {
                sess.queue.items[write] = remain[write];
            }
            sess.queue.shrinkRetainingCapacity(remain.len);
            sess.queue_head = 0;
        }
        sess.queued_bytes -= frame.bytes.len;
        sess.queue_mu.unlock();

        const ok = writeFrame(sess, frame.kind, frame.bytes);
        const close_after = frame.kind == .close;
        sess.allocator.free(frame.bytes);
        if (!ok or close_after) {
            sess.requestClose();
            return;
        }
    }
}

fn waitSocket(stream: RawSocket, events: i16, deadline: ?i64, sess: ?*Session) !void {
    while (true) {
        if (sess) |active| {
            // The close signal is Session-owned.  This path deliberately needs no transport lock while the writer is polling.
            if (active.closed.load(.acquire)) return error.Closed;
        }
        var timeout: i32 = io_poll_ms;
        if (deadline) |limit| {
            const remaining = limit - @as(i64, @intCast(zev.monotonicMilliseconds()));
            if (remaining <= 0) return error.TimedOut;
            timeout = @intCast(@min(remaining, @as(i64, io_poll_ms)));
        }
        var pfds = [_]std.posix.pollfd{.{ .fd = stream.handle, .events = events, .revents = 0 }};
        const ready = try std.posix.poll(&pfds, timeout);
        if (ready == 0) continue;
        if (pfds[0].revents & (std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL) != 0) return error.SocketClosed;
        if (pfds[0].revents & events != 0) return;
    }
}

fn writeFrame(sess: *Session, kind: OutboundKind, payload: []const u8) bool {
    var header: [10]u8 = undefined;
    header[0] = 0x80 | switch (kind) {
        .text => @as(u8, 0x1),
        .pong => @as(u8, 0xA),
        .close => @as(u8, 0x8),
    };
    var header_len: usize = 0;
    if (payload.len <= 125) {
        header[1] = @intCast(payload.len);
        header_len = 2;
    } else if (payload.len <= 0xffff) {
        header[1] = 126;
        std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header[1] = 127;
        std.mem.writeInt(u64, header[2..10], payload.len, .big);
        header_len = 10;
    }
    const deadline = @as(i64, @intCast(zev.monotonicMilliseconds())) + write_deadline_ms;
    sess.stream.writeUntil(header[0..header_len], deadline, sess) catch return false;
    sess.stream.writeUntil(payload, deadline, sess) catch return false;
    return true;
}

fn sessionLoop(sess: *Session) void {
    const t = sess.transport;
    const graceful = readLoop(sess) catch false;
    defer {
        if (!graceful) sess.requestClose();
        t.fire(.{ .kind = .session_closed, .session_id = sess.id, .payload = &.{} });
        t.removeSession(sess.id);
        const final_worker = sess.workerFinished();
        sess.release();
        if (final_worker) t.sessionSlotGone();
        t.workerGone();
    }
}

/// Read WebSocket frames until EOF, error, or a close frame. Errors here are terminal for the session; caller handles teardown.
fn readLoop(sess: *Session) !bool {
    const t = sess.transport;
    // Reused per-frame buffer for small frames; for large ones, allocate.
    var small: [4096]u8 = undefined;

    while (!t.shutdown.load(.seq_cst) and !sess.closed.load(.seq_cst)) {
        // Frame header: at minimum 2 bytes.
        var hdr: [2]u8 = undefined;
        try readExact(sess, &hdr);
        const b0 = hdr[0];
        const b1 = hdr[1];
        const fin = (b0 & 0x80) != 0;
        const opcode: u4 = @truncate(b0 & 0x0F);
        const masked = (b1 & 0x80) != 0;
        var payload_len: u64 = b1 & 0x7F;

        if (payload_len == 126) {
            var ext: [2]u8 = undefined;
            try readExact(sess, &ext);
            payload_len = std.mem.readInt(u16, &ext, .big);
        } else if (payload_len == 127) {
            var ext: [8]u8 = undefined;
            try readExact(sess, &ext);
            payload_len = std.mem.readInt(u64, &ext, .big);
        }

        // All client→server frames MUST be masked per RFC 6455.
        if (!masked) {
            sess.enqueueClose(1002);
            return true;
        }
        var mask_key: [4]u8 = undefined;
        try readExact(sess, &mask_key);

        // Read payload.
        var payload: []u8 = undefined;
        var payload_owned: bool = false;
        if (payload_len <= small.len) {
            payload = small[0..@as(usize, @intCast(payload_len))];
        } else {
            payload = try t.allocator.alloc(u8, @as(usize, @intCast(payload_len)));
            payload_owned = true;
        }
        defer if (payload_owned) t.allocator.free(payload);

        if (payload.len > 0) try readExact(sess, payload);
        for (payload, 0..) |*p, i| p.* ^= mask_key[i & 3];

        // Control frames must not be fragmented. We only handle complete frames for data opcodes (no fragmentation support — MVP).
        switch (opcode) {
            0x1 => { // text
                if (!fin) {
                    // Fragmented text — not supported in MVP.
                    sess.enqueueClose(1003);
                    return true;
                }
                t.fire(.{ .kind = .message, .session_id = sess.id, .payload = payload });
            },
            0x2 => { // binary — not supported
                sess.enqueueClose(1003);
                return true;
            },
            0x8 => { // close
                sess.enqueueClose(1000);
                return true;
            },
            0x9 => { // ping
                _ = sess.enqueue(.pong, payload, true);
            },
            0xA => { // pong — ignore
            },
            else => {
                sess.enqueueClose(1003);
                return true;
            },
        }
    }
    return false;
}

fn readExact(sess: *Session, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        if (sess.closed.load(.acquire) or sess.transport.shutdown.load(.acquire)) return error.Closed;
        const n = sess.stream.read(buf[got..]) catch |err| switch (err) {
            error.WouldBlock => {
                try waitSocket(sess.stream, std.posix.POLL.IN, null, sess);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        got += n;
    }
}

const transport_vtable: inspector.Transport.VTable = .{
    .start = interfaceStart,
    .deinit = interfaceDeinit,
    .send_text = interfaceSendText,
    .broadcast_text = interfaceBroadcastText,
    .close_session = interfaceCloseSession,
    .set_discovery_target = interfaceSetDiscoveryTarget,
    .bound_port = interfaceBoundPort,
};

fn interfaceSelf(ctx: *anyopaque) *Transport {
    return @ptrCast(@alignCast(ctx));
}

fn interfaceStart(ctx: *anyopaque, event_ctx: ?*anyopaque, handler: EventHandler) anyerror!void {
    return interfaceSelf(ctx).start(event_ctx, handler);
}

fn interfaceDeinit(ctx: *anyopaque) void {
    interfaceSelf(ctx).deinit();
}

fn interfaceSendText(ctx: *anyopaque, session: SessionId, message: []const u8) bool {
    return interfaceSelf(ctx).sendText(session, message);
}

fn interfaceBroadcastText(ctx: *anyopaque, message: []const u8) void {
    interfaceSelf(ctx).broadcastText(message);
}

fn interfaceCloseSession(ctx: *anyopaque, session: SessionId) void {
    interfaceSelf(ctx).closeSession(session);
}

fn interfaceSetDiscoveryTarget(ctx: *anyopaque, target: DiscoveryTarget) void {
    interfaceSelf(ctx).setDiscoveryTarget(target);
}

fn interfaceBoundPort(ctx: *anyopaque) u16 {
    return interfaceSelf(ctx).boundPort();
}
