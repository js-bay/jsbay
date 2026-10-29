//! Tests for the CDP inspector transport layer. These don't need an engine instance — they exercise the transport in isolation.

const std = @import("std");
const testing = std.testing;
const transport = @import("inspector_transport");
const zev = @import("zev");

// -- Test harness helpers -------------------------------------------------

const TestStream = struct {
    handle: std.posix.fd_t,

    fn read(s: TestStream, buf: []u8) !usize {
        return std.posix.read(s.handle, buf);
    }

    fn writeAll(s: TestStream, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = std.posix.system.write(s.handle, bytes.ptr + off, bytes.len - off);
            if (n < 0) {
                if (std.posix.errno(n) == .INTR) continue;
                return error.WriteFailed;
            }
            off += @intCast(n);
        }
    }

    fn close(s: TestStream) void {
        _ = std.posix.system.close(s.handle);
    }
};

fn connectLoopback(port: u16) !TestStream {
    const raw_fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (raw_fd < 0) return error.SocketFailed;
    const fd: std.posix.fd_t = @intCast(raw_fd);
    errdefer _ = std.posix.system.close(fd);
    var addr: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    if (std.posix.system.connect(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.ConnectFailed;
    return .{ .handle = fd };
}

fn connect(port: u16) !TestStream {
    return connectLoopback(port);
}

fn readUntilEof(alloc: std.mem.Allocator, stream: TestStream, out: *std.ArrayList(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch 0;
        if (n == 0) return;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

fn readHttpResponse(alloc: std.mem.Allocator, stream: TestStream) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    try readUntilEof(alloc, stream, &list);
    return list.toOwnedSlice(alloc);
}

fn readAtLeast(stream: TestStream, buf: []u8, need: usize) !usize {
    var got: usize = 0;
    while (got < need) {
        const n = try stream.read(buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    return got;
}

/// Read just the HTTP response (until \r\n\r\n + Content-Length body). We rely on `Connection: close` semantics + short bodies, so reading till EOF is fine in tests.
fn readFullHttp(alloc: std.mem.Allocator, stream: TestStream) ![]u8 {
    return readHttpResponse(alloc, stream);
}

/// Read only up to and including `\r\n\r\n` (headers, not body). Used when we want to keep reading binary WS frames after.
fn readHttpHeaders(alloc: std.mem.Allocator, stream: TestStream) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [1]u8 = undefined;
    while (true) {
        const n = try stream.read(&buf);
        if (n == 0) return error.EndOfStream;
        try list.append(alloc, buf[0]);
        if (list.items.len >= 4) {
            const tail = list.items[list.items.len - 4 ..];
            if (std.mem.eql(u8, tail, "\r\n\r\n")) break;
        }
    }
    return list.toOwnedSlice(alloc);
}

/// Write a masked client-to-server text frame.
fn writeMaskedText(stream: TestStream, text: []const u8) !void {
    var header: [14]u8 = undefined;
    var hlen: usize = 0;
    header[0] = 0x80 | 0x1; // FIN + text
    if (text.len <= 125) {
        header[1] = 0x80 | @as(u8, @intCast(text.len));
        hlen = 2;
    } else if (text.len <= 0xFFFF) {
        header[1] = 0x80 | 126;
        std.mem.writeInt(u16, header[2..4], @as(u16, @intCast(text.len)), .big);
        hlen = 4;
    } else {
        header[1] = 0x80 | 127;
        std.mem.writeInt(u64, header[2..10], @as(u64, text.len), .big);
        hlen = 10;
    }
    const mask_key: [4]u8 = .{ 0x12, 0x34, 0x56, 0x78 };
    @memcpy(header[hlen..][0..4], &mask_key);
    hlen += 4;
    try stream.writeAll(header[0..hlen]);

    // Mask and write payload in chunks.
    var masked_buf: [1024]u8 = undefined;
    var off: usize = 0;
    while (off < text.len) {
        const chunk = @min(masked_buf.len, text.len - off);
        for (0..chunk) |i| {
            masked_buf[i] = text[off + i] ^ mask_key[(off + i) & 3];
        }
        try stream.writeAll(masked_buf[0..chunk]);
        off += chunk;
    }
}

/// Write a masked close frame.
fn writeMaskedClose(stream: TestStream, code: u16) !void {
    const mask_key: [4]u8 = .{ 0x01, 0x02, 0x03, 0x04 };
    var frame: [8]u8 = undefined;
    frame[0] = 0x88; // FIN + close
    frame[1] = 0x80 | 0x02; // masked, len=2
    @memcpy(frame[2..6], &mask_key);
    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, &payload, code, .big);
    frame[6] = payload[0] ^ mask_key[0];
    frame[7] = payload[1] ^ mask_key[1];
    try stream.writeAll(&frame);
}

/// Read a server→client (unmasked) frame's header + payload. Returns the opcode and payload. Allocates `payload` from `alloc`.
fn readFrame(alloc: std.mem.Allocator, stream: TestStream) !struct { opcode: u8, payload: []u8 } {
    var hdr: [2]u8 = undefined;
    _ = try readAtLeast(stream, &hdr, 2);
    const opcode: u8 = hdr[0] & 0x0F;
    const masked = (hdr[1] & 0x80) != 0;
    var plen: u64 = hdr[1] & 0x7F;
    if (plen == 126) {
        var ext: [2]u8 = undefined;
        _ = try readAtLeast(stream, &ext, 2);
        plen = std.mem.readInt(u16, &ext, .big);
    } else if (plen == 127) {
        var ext: [8]u8 = undefined;
        _ = try readAtLeast(stream, &ext, 8);
        plen = std.mem.readInt(u64, &ext, .big);
    }
    try testing.expect(!masked); // server → client must not be masked
    const payload = try alloc.alloc(u8, @as(usize, @intCast(plen)));
    if (plen > 0) _ = try readAtLeast(stream, payload, payload.len);
    return .{ .opcode = opcode, .payload = payload };
}

// -- Shared handler context ----------------------------------------------

const HandlerState = struct {
    opened_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    closed_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_session: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    echo: bool = false,
    transport: ?*transport.Transport = null,

    /// Recorded ordering for a single session lifecycle (open → msg → close).
    order_mu: zev.Mutex = .{},
    order: std.ArrayListUnmanaged(transport.EventKind) = .empty,
    order_alloc: ?std.mem.Allocator = null,
};

fn handler(ctx: ?*anyopaque, event: transport.Event) void {
    const st: *HandlerState = @ptrCast(@alignCast(ctx.?));
    switch (event.kind) {
        .session_opened => {
            _ = st.opened_count.fetchAdd(1, .seq_cst);
            st.last_session.store(event.session_id, .seq_cst);
        },
        .session_closed => {
            _ = st.closed_count.fetchAdd(1, .seq_cst);
        },
        .message => {
            if (st.echo) {
                if (st.transport) |t| {
                    _ = t.sendText(event.session_id, event.payload);
                }
            }
        },
    }
    if (st.order_alloc) |alloc| {
        st.order_mu.lock();
        defer st.order_mu.unlock();
        st.order.append(alloc, event.kind) catch {};
    }
}

// -- Tests ----------------------------------------------------------------

test "transport: HTTP /json/version returns expected JSON" {
    const alloc = testing.allocator;
    const t = try transport.Transport.init(alloc, 0);
    var state = HandlerState{};
    defer {
        t.deinit();
        state.order_mu.deinit();
    }
    try t.start(&state, handler);

    const stream = try connect(t.boundPort());
    try stream.writeAll("GET /json/version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const resp = try readFullHttp(alloc, stream);
    defer alloc.free(resp);
    stream.close();

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.indexOf(u8, resp, "Content-Type: application/json") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"Protocol-Version\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"Browser\"") != null);
}

test "transport: HTTP /json/list returns target array" {
    const alloc = testing.allocator;
    const t = try transport.Transport.init(alloc, 0);
    var state = HandlerState{};
    defer {
        t.deinit();
        state.order_mu.deinit();
    }
    t.setDiscoveryTarget(.{
        .title = "js-bay",
        .kind = "node",
        .url = "file:///tmp/bundle.js",
        .id = "deadbeef-1234",
    });
    try t.start(&state, handler);

    const stream = try connect(t.boundPort());
    try stream.writeAll("GET /json/list HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    const resp = try readFullHttp(alloc, stream);
    defer alloc.free(resp);
    stream.close();

    try testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.indexOf(u8, resp, "\"id\":\"deadbeef-1234\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"title\":\"js-bay\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"type\":\"node\"") != null);
    try testing.expect(std.mem.indexOf(u8, resp, "\"url\":\"file:///tmp/bundle.js\"") != null);

    // webSocketDebuggerUrl should contain the actual bound port.
    const port_buf = try std.fmt.allocPrint(alloc, "ws://localhost:{d}/deadbeef-1234", .{t.boundPort()});
    defer alloc.free(port_buf);
    try testing.expect(std.mem.indexOf(u8, resp, port_buf) != null);

    // Body is a one-element JSON array.
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return error.BadResponse;
    const body = resp[body_start + 4 ..];
    try testing.expect(body.len > 0 and body[0] == '[');
    try testing.expect(body[body.len - 1] == ']');
}

test "transport: WebSocket handshake accepted" {
    const alloc = testing.allocator;
    const t = try transport.Transport.init(alloc, 0);
    var state = HandlerState{};
    defer {
        t.deinit();
        state.order_mu.deinit();
    }
    t.setDiscoveryTarget(.{
        .title = "js-bay",
        .kind = "node",
        .url = "x",
        .id = "target-1",
    });
    try t.start(&state, handler);

    const stream = try connect(t.boundPort());
    defer stream.close();
    try stream.writeAll(
        "GET /target-1 HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
    );

    const hdrs = try readHttpHeaders(alloc, stream);
    defer alloc.free(hdrs);
    try testing.expect(std.mem.startsWith(u8, hdrs, "HTTP/1.1 101"));
    try testing.expect(std.mem.indexOf(u8, hdrs, "Upgrade: websocket") != null);
    try testing.expect(std.mem.indexOf(u8, hdrs, "Connection: Upgrade") != null);
    try testing.expect(std.mem.indexOf(u8, hdrs, "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);
}

test "transport: text frame roundtrip" {
    const alloc = testing.allocator;
    const t = try transport.Transport.init(alloc, 0);

    var state = HandlerState{
        .echo = true,
        .transport = null,
        .order_alloc = alloc,
    };
    state.transport = t;
    defer {
        t.deinit();
        state.order.deinit(alloc);
        state.order_mu.deinit();
    }

    t.setDiscoveryTarget(.{
        .title = "js-bay",
        .kind = "node",
        .url = "x",
        .id = "t-echo",
    });
    try t.start(&state, handler);

    const stream = try connect(t.boundPort());
    try stream.writeAll(
        "GET /t-echo HTTP/1.1\r\n" ++
            "Host: localhost\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n",
    );
    const hdrs = try readHttpHeaders(alloc, stream);
    defer alloc.free(hdrs);
    try testing.expect(std.mem.startsWith(u8, hdrs, "HTTP/1.1 101"));

    // Send a masked "hello".
    try writeMaskedText(stream, "hello");

    // Expect an unmasked text frame echo.
    const frame = try readFrame(alloc, stream);
    defer alloc.free(frame.payload);
    try testing.expectEqual(@as(u8, 0x1), frame.opcode);
    try testing.expectEqualStrings("hello", frame.payload);

    // Tell server we're closing.
    try writeMaskedClose(stream, 1000);

    // Expect echo'd close frame from the server.
    const close_frame = try readFrame(alloc, stream);
    defer alloc.free(close_frame.payload);
    try testing.expectEqual(@as(u8, 0x8), close_frame.opcode);

    stream.close();

    // Wait briefly (bounded) for session_closed to fire.
    var spins: usize = 0;
    while (state.closed_count.load(.seq_cst) == 0 and spins < 200) : (spins += 1) {
        zev.sleepMilliseconds(10);
    }
    try testing.expectEqual(@as(u32, 1), state.opened_count.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), state.closed_count.load(.seq_cst));

    // Ordering: opened → message → closed.
    state.order_mu.lock();
    defer state.order_mu.unlock();
    try testing.expect(state.order.items.len >= 3);
    try testing.expectEqual(transport.EventKind.session_opened, state.order.items[0]);
    // A message event appeared before closed.
    var saw_msg = false;
    var saw_closed = false;
    for (state.order.items) |k| {
        if (k == .message) saw_msg = true;
        if (k == .session_closed) {
            saw_closed = true;
            try testing.expect(saw_msg); // message arrived before close
        }
    }
    try testing.expect(saw_msg and saw_closed);
}

// Watchdog: if deinit hangs, the test should still fail promptly rather than hanging the whole test harness forever. We arm a thread that will abort the process after a generous timeout — but only if the test hasn't completed. Since std.Thread has no cancel, the simplest route is to run deinit and flip a "done" flag, and on watchdog wake-up check the flag.
const Watchdog = struct {
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deadline_ms: u64,

    fn run(self: *Watchdog) void {
        // Spin with short sleeps so the thread exits quickly once done.
        var elapsed: u64 = 0;
        while (!self.done.load(.seq_cst) and elapsed < self.deadline_ms) {
            zev.sleepMilliseconds(20);
            elapsed += 20;
        }
        if (!self.done.load(.seq_cst)) self.fired.store(true, .seq_cst);
    }
};

test "transport: deinit joins all threads" {
    const alloc = testing.allocator;

    // Part A: init + start + deinit with no connections.
    {
        const t = try transport.Transport.init(alloc, 0);
        var state = HandlerState{};
        defer state.order_mu.deinit();
        try t.start(&state, handler);

        var watch = Watchdog{ .deadline_ms = 2000 };
        const wth = try std.Thread.spawn(.{}, Watchdog.run, .{&watch});

        t.deinit();
        watch.done.store(true, .seq_cst);
        wth.join();
        try testing.expect(!watch.fired.load(.seq_cst));
    }

    // Part B: init + start + live connection + deinit forces close.
    {
        const t = try transport.Transport.init(alloc, 0);
        var state = HandlerState{};
        defer state.order_mu.deinit();
        t.setDiscoveryTarget(.{
            .title = "t",
            .kind = "node",
            .url = "x",
            .id = "target-b",
        });
        try t.start(&state, handler);

        // Open a session and leave it open.
        const stream = try connect(t.boundPort());
        try stream.writeAll(
            "GET /target-b HTTP/1.1\r\n" ++
                "Host: localhost\r\n" ++
                "Upgrade: websocket\r\n" ++
                "Connection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
                "Sec-WebSocket-Version: 13\r\n\r\n",
        );
        const hdrs = try readHttpHeaders(alloc, stream);
        defer alloc.free(hdrs);
        try testing.expect(std.mem.startsWith(u8, hdrs, "HTTP/1.1 101"));

        // Wait for session_opened so we know the reader thread is up.
        var spins: usize = 0;
        while (state.opened_count.load(.seq_cst) == 0 and spins < 200) : (spins += 1) {
            zev.sleepMilliseconds(10);
        }
        try testing.expectEqual(@as(u32, 1), state.opened_count.load(.seq_cst));

        var watch = Watchdog{ .deadline_ms = 3000 };
        const wth = try std.Thread.spawn(.{}, Watchdog.run, .{&watch});

        t.deinit(); // must force-close session + join reader thread
        watch.done.store(true, .seq_cst);
        wth.join();
        try testing.expect(!watch.fired.load(.seq_cst));

        // Client stream is now closed from the remote end. Drain.
        var drain: [64]u8 = undefined;
        _ = stream.read(&drain) catch {};
        stream.close();
    }
}
