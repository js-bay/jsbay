//! End-to-end tests for the inspector: the inspector module starts a transport, accepts a test TCP/WebSocket client, and we exchange CDP messages over it.
//!
//! We drive `dispatch.tickInstance` from the test thread so the engine's single-threaded model is preserved — transport reader threads post `Runtime.evaluate` work via dispatch.postTask which gets drained here.

const std = @import("std");
const io = @import("../platform/io.zig");
const testing = std.testing;

const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const dispatch = @import("../runtime/dispatch.zig");
const instance_map = @import("../runtime/instance_map.zig");
const inspector = @import("../inspector/root.zig");
const inspector_state = @import("../inspector/root.zig").state;
const backend = @import("../backend.zig");
const host_value = @import("../abi/host_value.zig");
const weakcb = @import("../value/weakcb.zig");
const helpers = @import("test_helpers.zig");

const ConcurrentStartProbe = struct {
    id: i32,
    ready: *std.atomic.Value(u32),
    go: *std.atomic.Value(bool),
    started: bool = false,
    handle: ?*inspector.Handle = null,
    error_name: []const u8 = "",

    fn run(probe: *ConcurrentStartProbe) void {
        _ = probe.ready.fetchAdd(1, .seq_cst);
        while (!probe.go.load(.seq_cst)) std.Thread.yield() catch {};
        if (inspector.start(probe.id, .{ .port = 0, .target_id = "concurrent-inspector-start" })) |handle| {
            probe.started = true;
            probe.handle = handle;
        } else |err| {
            probe.error_name = @errorName(err);
        }
    }
};

// -- Minimal WebSocket client (copied from inspector_transport_tests style) ----

pub const TestStream = struct {
    handle: std.posix.fd_t,

    pub fn read(s: TestStream, buf: []u8) !usize {
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

    pub fn close(s: TestStream) void {
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

pub fn connect(port: u16) !TestStream {
    const stream = try connectLoopback(port);
    // Apply SO_RCVTIMEO so reads return EAGAIN after ~50ms instead of blocking. The tests poll read + tickInstance in a loop; without a timeout, evaluate responses that require a JS-thread tick can't arrive because the test is stuck in a blocking read.
    var tv: std.posix.timeval = .{ .sec = 0, .usec = 50_000 };
    std.posix.setsockopt(
        stream.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
    return stream;
}

fn readUntilEof(alloc: std.mem.Allocator, stream: TestStream, out: *std.ArrayList(u8)) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&buf) catch 0;
        if (n == 0) return;
        try out.appendSlice(alloc, buf[0..n]);
    }
}

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

fn readAtLeast(stream: TestStream, buf: []u8, need: usize) !usize {
    var got: usize = 0;
    while (got < need) {
        const n = try stream.read(buf[got..]);
        if (n == 0) return error.EndOfStream;
        got += n;
    }
    return got;
}

pub fn writeMaskedText(stream: TestStream, text: []const u8) !void {
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

const Frame = struct {
    opcode: u8,
    payload: []u8,
};

/// Owns partial server→client WebSocket frame state across socket timeouts.
pub const FrameReader = struct {
    stream: TestStream,
    header: [2]u8 = undefined,
    header_len: usize = 0,
    extended: [8]u8 = undefined,
    extended_len: usize = 0,
    extended_need: usize = 0,
    payload: ?[]u8 = null,
    payload_len: usize = 0,
    payload_read: usize = 0,

    pub fn init(stream: TestStream) FrameReader {
        return .{ .stream = stream };
    }

    pub fn deinit(self: *FrameReader, alloc: std.mem.Allocator) void {
        if (self.payload) |payload| alloc.free(payload);
        self.payload = null;
    }

    fn readPartial(self: *FrameReader, target: []u8, have: *usize) !bool {
        const n = self.stream.read(target[have.*..]) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        have.* += n;
        return true;
    }

    fn beginPayload(self: *FrameReader, alloc: std.mem.Allocator) !void {
        if ((self.header[1] & 0x80) != 0) return error.MaskedServerFrame;
        const encoded_len = self.header[1] & 0x7f;
        const plen: u64 = switch (encoded_len) {
            126 => std.mem.readInt(u16, self.extended[0..2], .big),
            127 => std.mem.readInt(u64, self.extended[0..8], .big),
            else => encoded_len,
        };
        if (plen > std.math.maxInt(usize)) return error.FrameTooLarge;
        self.payload_len = @intCast(plen);
        self.payload = try alloc.alloc(u8, self.payload_len);
        self.payload_read = 0;
    }

    /// Returns null after a socket timeout while preserving any consumed bytes.
    pub fn readTimed(self: *FrameReader, alloc: std.mem.Allocator, timeout_ms: u64) !?Frame {
        const deadline = io.milliTimestamp() + @as(i64, @intCast(timeout_ms));
        errdefer self.deinit(alloc);
        while (io.milliTimestamp() < deadline) {
            if (self.header_len < self.header.len) {
                if (!try self.readPartial(&self.header, &self.header_len)) return null;
                if (self.header_len < self.header.len) continue;
                const encoded_len = self.header[1] & 0x7f;
                self.extended_need = if (encoded_len == 126) 2 else if (encoded_len == 127) 8 else 0;
            }
            if (self.extended_len < self.extended_need) {
                if (!try self.readPartial(self.extended[0..self.extended_need], &self.extended_len)) return null;
                if (self.extended_len < self.extended_need) continue;
            }
            if (self.payload == null) try self.beginPayload(alloc);
            if (self.payload_read < self.payload_len) {
                if (!try self.readPartial(self.payload.?[0..self.payload_len], &self.payload_read)) return null;
                if (self.payload_read < self.payload_len) continue;
            }
            const frame = Frame{ .opcode = self.header[0] & 0x0f, .payload = self.payload.? };
            self.payload = null;
            self.header_len = 0;
            self.extended_len = 0;
            self.extended_need = 0;
            self.payload_len = 0;
            self.payload_read = 0;
            return frame;
        }
        return null;
    }
};

test "inspector frame reader preserves split frames across socket timeouts" {
    const alloc = testing.allocator;
    const listener = try BoundTestPort.open();
    defer listener.close();
    const client = try connect(listener.port);
    defer client.close();
    const raw_server = std.posix.system.accept(listener.fd, null, null);
    if (raw_server < 0) return error.AcceptFailed;
    const server = TestStream{ .handle = @intCast(raw_server) };
    var server_open = true;
    defer if (server_open) server.close();
    var reader = FrameReader.init(client);
    defer reader.deinit(alloc);

    try server.writeAll("\x81");
    try testing.expect((try reader.readTimed(alloc, 60)) == null);
    try server.writeAll("\x02ok");
    const first = (try reader.readTimed(alloc, 60)).?;
    defer alloc.free(first.payload);
    try testing.expectEqual(@as(u8, 1), first.opcode);
    try testing.expectEqualStrings("ok", first.payload);

    try server.writeAll("\x81\x7e\x00\x03abc");
    const extended = (try reader.readTimed(alloc, 60)).?;
    defer alloc.free(extended.payload);
    try testing.expectEqualStrings("abc", extended.payload);

    try server.writeAll("\x81\x02o");
    try testing.expect((try reader.readTimed(alloc, 60)) == null);
    server.close();
    server_open = false;
    try testing.expectError(error.EndOfStream, reader.readTimed(alloc, 60));
}

/// Drive tickInstance repeatedly while waiting for a matching frame. Returns the frame on success, null on timeout. Matcher sees payload text and returns true when the frame satisfies the caller's condition. Frames that don't match are freed.
fn waitForFrame(
    alloc: std.mem.Allocator,
    instance_id: i32,
    reader: *FrameReader,
    comptime matcher: fn (payload: []const u8) bool,
    timeout_ms: u64,
) !?Frame {
    const deadline = io.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (io.milliTimestamp() < deadline) {
        // Pump the engine thread work first — responses to evaluate come from here.
        _ = dispatch.tickInstance(instance_id);
        // Then try to read a frame within a short window.
        const frame_opt = try reader.readTimed(alloc, 50);
        if (frame_opt) |frame| {
            if (frame.opcode == 0x1 and matcher(frame.payload)) {
                return frame;
            }
            // Not the one we want — discard and keep polling.
            alloc.free(frame.payload);
        }
    }
    return null;
}

pub fn doWsHandshake(alloc: std.mem.Allocator, stream: TestStream, target_id: []const u8) !void {
    const req = try std.fmt.allocPrint(
        alloc,
        "GET /{s} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        .{target_id},
    );
    defer alloc.free(req);
    try stream.writeAll(req);

    const hdrs = try readHttpHeaders(alloc, stream);
    defer alloc.free(hdrs);
    try testing.expect(std.mem.startsWith(u8, hdrs, "HTTP/1.1 101"));
}

// -- Matchers used by waitForFrame --

fn containsIdOne(payload: []const u8) bool {
    return std.mem.indexOf(u8, payload, "\"id\":1") != null;
}
fn containsIdTwo(payload: []const u8) bool {
    return std.mem.indexOf(u8, payload, "\"id\":2") != null;
}
fn containsExecutionContextCreated(payload: []const u8) bool {
    return std.mem.indexOf(u8, payload, "Runtime.executionContextCreated") != null;
}
fn containsConsoleAPICalled(payload: []const u8) bool {
    return std.mem.indexOf(u8, payload, "Runtime.consoleAPICalled") != null;
}

pub fn readTextFrames(alloc: std.mem.Allocator, reader: *FrameReader, into: *std.ArrayList(u8), spins: usize) !void {
    var i: usize = 0;
    while (i < spins) : (i += 1) {
        const frame_opt = try reader.readTimed(alloc, 40);
        if (frame_opt) |frame| {
            defer alloc.free(frame.payload);
            if (frame.opcode == 0x1) {
                try into.appendSlice(alloc, frame.payload);
                try into.append(alloc, '\n');
            }
        }
    }
}

pub fn hasResponseIdSince(alloc: std.mem.Allocator, messages: []const u8, start: usize, id: i64) !bool {
    if (start > messages.len) return false;
    var cursor = start;
    while (cursor < messages.len) {
        const end = std.mem.indexOfScalarPos(u8, messages, cursor, '\n') orelse messages.len;
        const message = std.mem.trim(u8, messages[cursor..end], " \r\t");
        if (message.len != 0) {
            var parsed = std.json.parseFromSlice(std.json.Value, alloc, message, .{}) catch {
                cursor = @min(end + 1, messages.len);
                continue;
            };
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("id")) |value| {
                    if (value == .integer and value.integer == id) return true;
                }
            }
        }
        cursor = @min(end + 1, messages.len);
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const InspectorEnabledTests = if (@import("build_options").inspector) struct {
    test "inspector.start rejects intrinsic capture from a foreign thread after threadStart" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        try testing.expect(engine_thread.threadStart(id));
        defer engine_thread.threadStop(id);
        var spins: usize = 0;
        while (engine_thread.threadId(id) == 0 and spins < 10_000) : (spins += 1) std.Thread.yield() catch {};
        try testing.expect(engine_thread.threadId(id) != 0);

        const result = inspector.start(id, .{ .port = 0, .target_id = "foreign-start-owner" });
        if (result) |handle| {
            inspector.stop(handle);
            return error.ForeignInspectorStartWasAccepted;
        } else |err| {
            try testing.expectEqualStrings("EngineThreadViolation", @errorName(err));
        }
    }
};

comptime {
    _ = InspectorEnabledTests;
}

test "engine destroy cancels queued native tasks before an instance id can be reused" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var ran = std.atomic.Value(u32).init(0);
    try testing.expect(dispatch.postTask(id, .{ .ctx = &ran, .run = struct {
        fn run(ctx: ?*anyopaque) void {
            const count: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = count.fetchAdd(1, .seq_cst);
        }
    }.run }));
    engine.destroy(id);
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    _ = dispatch.tickInstance(id);
    try testing.expectEqual(@as(u32, 0), ran.load(.seq_cst));
}

test "dispatchTask rejects scripts after instance task admission closes" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(dispatch.closeInstanceTasks(id));
    try testing.expect(!engine.dispatchTask(id, "globalThis.__closed_dispatch_task__ = true"));
    const instance = instance_map.getInstance(id) orelse return error.InstanceMissing;
    instance.task_mutex.lock();
    const queued_scripts = instance.task_queue.items.items.len;
    instance.task_mutex.unlock();
    try testing.expectEqual(@as(usize, 0), queued_scripts);
    const result = engine.evalScript(id, "typeof globalThis.__closed_dispatch_task__", "<closed-dispatch>");
    defer helpers.freeEvalResult(result);
    try testing.expectEqualStrings("undefined", result.result orelse return error.MissingResult);
}

const DestroyTimerProbe = struct {
    calls: std.atomic.Value(u32) = .init(0),

    fn callback(_: c_int, data: ?*anyopaque, _: u32, _: ?[*]const host_value.HostValue, out: *host_value.HostValue) callconv(.c) c_int {
        const self: *DestroyTimerProbe = @ptrCast(@alignCast(data.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        host_value.clear(out);
        return 0;
    }
};

test "engine destroy drops ready timers without invoking callbacks" {
    const control_id = helpers.nextInstanceId();
    try testing.expect(engine.create(control_id, .{}));
    defer engine.destroy(control_id);
    var control_probe = DestroyTimerProbe{};
    try testing.expect(engine_thread.hostInstall(control_id, "recordDestroyTimer", DestroyTimerProbe.callback, &control_probe));
    const control_result = engine.evalScript(control_id, "setTimeout(() => recordDestroyTimer(), 100000)", "<timer-control>");
    defer helpers.freeEvalResult(control_result);
    _ = engine.testing.advance(control_id, 0);
    _ = engine.testing.advance(control_id, 100_000);
    try testing.expectEqual(@as(u32, 1), control_probe.calls.load(.seq_cst));

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var probe = DestroyTimerProbe{};
    try testing.expect(engine_thread.hostInstall(id, "recordDestroyTimer", DestroyTimerProbe.callback, &probe));
    const result = engine.evalScript(id, "setTimeout(() => recordDestroyTimer(), 100000)", "<destroy-timer>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
    _ = engine.testing.advance(id, 0);
    const instance = instance_map.getInstance(id) orelse return error.InstanceMissing;
    var timer_iter = instance.timers.entries.iterator();
    const timer_entry = timer_iter.next() orelse return error.TimerMissing;
    try timer_entry.value_ptr.*.timer.startAt(0);
    engine.destroy(id);
    try testing.expectEqual(@as(u32, 0), probe.calls.load(.seq_cst));
}

const DispatchPostRace = struct {
    id: i32,
    checked: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    posted: std.atomic.Value(bool) = .init(true),
    destroy_started: std.atomic.Value(bool) = .init(false),
    destroy_done: std.atomic.Value(bool) = .init(false),
    task_runs: std.atomic.Value(u32) = .init(0),

    fn hook(data: ?*anyopaque) void {
        const self: *DispatchPostRace = @ptrCast(@alignCast(data.?));
        self.checked.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) std.Thread.yield() catch {};
    }

    fn runTask(ctx: ?*anyopaque) void {
        const self: *DispatchPostRace = @ptrCast(@alignCast(ctx.?));
        _ = self.task_runs.fetchAdd(1, .seq_cst);
    }

    fn post(self: *DispatchPostRace) void {
        self.posted.store(dispatch.postTask(self.id, .{ .ctx = self, .run = runTask }), .seq_cst);
    }

    fn destroy(self: *DispatchPostRace) void {
        self.destroy_started.store(true, .seq_cst);
        engine.destroy(self.id);
        self.destroy_done.store(true, .seq_cst);
    }
};

test "dispatch admission serializes posting with instance teardown" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var race = DispatchPostRace{ .id = id };
    dispatch.setPostCheckedHookForTesting(DispatchPostRace.hook, &race);
    defer dispatch.setPostCheckedHookForTesting(null, null);
    const poster = try std.Thread.spawn(.{}, DispatchPostRace.post, .{&race});
    try testing.expect(spinUntil(&race.checked));
    const destroyer = try std.Thread.spawn(.{}, DispatchPostRace.destroy, .{&race});
    try testing.expect(spinUntil(&race.destroy_started));
    var spins: usize = 0;
    while (spins < 1000) : (spins += 1) std.Thread.yield() catch {};
    const destroy_finished_before_post = race.destroy_done.load(.seq_cst);
    race.release.store(true, .seq_cst);
    poster.join();
    destroyer.join();
    try testing.expect(!destroy_finished_before_post);
    try testing.expect(race.posted.load(.seq_cst));

    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    _ = dispatch.tickInstance(id);
    try testing.expectEqual(@as(u32, 0), race.task_runs.load(.seq_cst));
}

test "dispatch queue allocation failure releases admission locks once" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var runs = std.atomic.Value(u32).init(0);
    dispatch.failNextQueueAllocationForTesting();
    try testing.expect(!dispatch.postTask(id, .{ .ctx = &runs, .run = struct {
        fn run(ctx: ?*anyopaque) void {
            const value: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = value.fetchAdd(1, .seq_cst);
        }
    }.run }));
    try testing.expect(dispatch.postTask(id, .{ .ctx = &runs, .run = struct {
        fn run(ctx: ?*anyopaque) void {
            const value: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx.?));
            _ = value.fetchAdd(1, .seq_cst);
        }
    }.run }));
    _ = dispatch.tickInstance(id);
    try testing.expectEqual(@as(u32, 1), runs.load(.seq_cst));
}

const InspectorStartThreadRace = struct {
    id: i32,
    port: u16,
    capture_entered: std.atomic.Value(bool) = .init(false),
    release_capture: std.atomic.Value(bool) = .init(false),
    thread_start_done: std.atomic.Value(bool) = .init(false),
    thread_started: bool = false,
    thread_running_during_cleanup: bool = false,
    start_thread_id: u64 = 0,
    cleanup_thread_id: u64 = 0,
    engine_owner_during_cleanup: u64 = 0,
    start_error_name: []const u8 = "",

    fn afterCapture(ctx: ?*anyopaque) void {
        const self: *InspectorStartThreadRace = @ptrCast(@alignCast(ctx.?));
        self.capture_entered.store(true, .seq_cst);
        while (!self.release_capture.load(.seq_cst)) std.Thread.yield() catch {};
    }

    fn duringCleanup(ctx: ?*anyopaque) void {
        const self: *InspectorStartThreadRace = @ptrCast(@alignCast(ctx.?));
        self.cleanup_thread_id = @intCast(std.Thread.getCurrentId());
        self.engine_owner_during_cleanup = engine_thread.threadId(self.id);
        self.thread_running_during_cleanup = self.engine_owner_during_cleanup != 0;
    }

    fn startInspector(self: *InspectorStartThreadRace) void {
        self.start_thread_id = @intCast(std.Thread.getCurrentId());
        const handle = inspector.start(self.id, .{ .port = self.port, .target_id = "start-thread-race" }) catch |err| {
            self.start_error_name = @errorName(err);
            return;
        };
        inspector.stop(handle);
        self.start_error_name = "UnexpectedSuccess";
    }

    fn startEngineThread(self: *InspectorStartThreadRace) void {
        self.thread_started = engine_thread.threadStart(self.id);
        self.thread_start_done.store(true, .seq_cst);
    }
};

const BoundTestPort = struct {
    fd: std.posix.fd_t,
    port: u16,

    fn open() !BoundTestPort {
        const raw_fd = std.posix.system.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
        if (raw_fd < 0) return error.SocketFailed;
        const fd: std.posix.fd_t = @intCast(raw_fd);
        errdefer _ = std.posix.system.close(fd);
        const reuse: c_int = 1;
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, std.mem.asBytes(&reuse));
        var addr: std.posix.sockaddr.in = .{
            .port = 0,
            .addr = std.mem.nativeToBig(u32, 0x7F000001),
        };
        if (std.posix.system.bind(fd, @ptrCast(&addr), @sizeOf(std.posix.sockaddr.in)) < 0) return error.BindFailed;
        if (std.posix.system.listen(fd, 128) < 0) return error.ListenFailed;
        var actual: std.posix.sockaddr.in = undefined;
        var actual_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr.in);
        if (std.posix.system.getsockname(fd, @ptrCast(&actual), &actual_len) < 0) return error.GetSockNameFailed;
        return .{ .fd = fd, .port = std.mem.bigToNative(u16, actual.port) };
    }

    fn close(self: BoundTestPort) void {
        _ = std.posix.system.close(self.fd);
    }
};

fn spinUntil(flag: *const std.atomic.Value(bool)) bool {
    const deadline = io.monotonicMilliseconds() + 5_000;
    while (io.monotonicMilliseconds() < deadline) {
        if (flag.load(.seq_cst)) return true;
        io.sleepMs(1);
    }
    return flag.load(.seq_cst);
}

const DispatchSnapshotLeaseProbe = struct {
    id: i32,
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    destroy_started: std.atomic.Value(bool) = .init(false),
    destroy_done: std.atomic.Value(bool) = .init(false),

    fn runTask(ctx: ?*anyopaque) void {
        const self: *DispatchSnapshotLeaseProbe = @ptrCast(@alignCast(ctx.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) std.Thread.yield() catch {};
    }

    fn tick(self: *DispatchSnapshotLeaseProbe) void {
        _ = dispatch.tickInstance(self.id);
    }

    fn destroy(self: *DispatchSnapshotLeaseProbe) void {
        self.destroy_started.store(true, .seq_cst);
        engine.destroy(self.id);
        self.destroy_done.store(true, .seq_cst);
    }
};

const ReentrantDestroyFinalizer = struct {
    instance_id: i32,
    calls: std.atomic.Value(u32) = .init(0),

    fn run(user_data: ?*anyopaque, _: bool) callconv(.c) void {
        const self: *ReentrantDestroyFinalizer = @ptrCast(@alignCast(user_data.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        engine.destroy(self.instance_id);
    }
};

const InspectorEnabledTests2 = if (@import("build_options").inspector) struct {
    test "inspector start holds its context lease through transport failure cleanup" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const occupied = try BoundTestPort.open();
        defer occupied.close();
        var probe = InspectorStartThreadRace{ .id = id, .port = occupied.port };
        inspector.setStartHooksForTesting(
            InspectorStartThreadRace.afterCapture,
            InspectorStartThreadRace.duringCleanup,
            &probe,
        );
        defer inspector.setStartHooksForTesting(null, null, null);
        const start_thread = try std.Thread.spawn(.{}, InspectorStartThreadRace.startInspector, .{&probe});
        try testing.expect(spinUntil(&probe.capture_entered));
        const engine_thread_start = try std.Thread.spawn(.{}, InspectorStartThreadRace.startEngineThread, .{&probe});
        var spins: usize = 0;
        while (spins < 100_000 and !probe.thread_start_done.load(.seq_cst)) : (spins += 1) std.Thread.yield() catch {};
        const thread_start_escaped_capture_lease = probe.thread_start_done.load(.seq_cst);
        probe.release_capture.store(true, .seq_cst);
        start_thread.join();
        engine_thread_start.join();
        if (probe.thread_started) engine_thread.threadStop(id);
        try testing.expect(!thread_start_escaped_capture_lease);
        try testing.expect(!probe.thread_running_during_cleanup);
        try testing.expectEqual(probe.start_thread_id, probe.cleanup_thread_id);
        try testing.expectEqual(@as(u64, 0), probe.engine_owner_during_cleanup);
        try testing.expectEqualStrings("TransportStartFailed", probe.start_error_name);
    }
};

comptime {
    _ = InspectorEnabledTests2;
}

test "engine destroy waits for an in-flight native task snapshot" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var probe = DispatchSnapshotLeaseProbe{ .id = id };
    try testing.expect(dispatch.postTask(id, .{ .ctx = &probe, .run = DispatchSnapshotLeaseProbe.runTask }));
    const ticker = try std.Thread.spawn(.{}, DispatchSnapshotLeaseProbe.tick, .{&probe});
    try testing.expect(spinUntil(&probe.entered));
    const destroyer = try std.Thread.spawn(.{}, DispatchSnapshotLeaseProbe.destroy, .{&probe});
    try testing.expect(spinUntil(&probe.destroy_started));
    var spins: usize = 0;
    while (spins < 100_000 and !probe.destroy_done.load(.seq_cst)) : (spins += 1) std.Thread.yield() catch {};
    const destroyed_while_task_active = probe.destroy_done.load(.seq_cst);
    probe.release.store(true, .seq_cst);
    ticker.join();
    destroyer.join();
    try testing.expect(!destroyed_while_task_active);
    try testing.expect(engine.getContext(id) == null);
}

const InspectorEnabledTests3 = if (@import("build_options").inspector) struct {
    test "concurrent inspector starts reserve the instance id exactly once" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var ready = std.atomic.Value(u32).init(0);
        var go = std.atomic.Value(bool).init(false);
        var a = ConcurrentStartProbe{ .id = id, .ready = &ready, .go = &go };
        var b = ConcurrentStartProbe{ .id = id, .ready = &ready, .go = &go };
        const ta = try std.Thread.spawn(.{}, ConcurrentStartProbe.run, .{&a});
        const tb = try std.Thread.spawn(.{}, ConcurrentStartProbe.run, .{&b});
        var spins: usize = 0;
        while (ready.load(.seq_cst) != 2 and spins < 100_000) : (spins += 1) std.Thread.yield() catch {};
        try testing.expectEqual(@as(u32, 2), ready.load(.seq_cst));
        go.store(true, .seq_cst);
        ta.join();
        tb.join();
        if (a.handle) |handle| inspector.stop(handle);
        if (b.handle) |handle| inspector.stop(handle);
        try testing.expect(a.started != b.started);
        try testing.expectEqualStrings("AlreadyStarted", if (a.started) b.error_name else a.error_name);
    }

    const InspectorYieldStopProbe = struct {
        id: i32,
        handle: *inspector.Handle,
        owner_yielded: std.atomic.Value(bool) = .init(false),
        foreign_entered: std.atomic.Value(bool) = .init(false),
        release_foreign: std.atomic.Value(bool) = .init(false),
        owner_stop_started: std.atomic.Value(bool) = .init(false),
        owner_stop_done: std.atomic.Value(bool) = .init(false),
        foreign_eval_done: std.atomic.Value(bool) = .init(false),
        owner_done: std.atomic.Value(bool) = .init(false),
    };

    fn holdInspectorForeignEval(
        _: c_int,
        data: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const probe: *InspectorYieldStopProbe = @ptrCast(@alignCast(data orelse return 1));
        probe.foreign_entered.store(true, .seq_cst);
        while (!probe.release_foreign.load(.seq_cst)) io.sleepMs(1);
        host_value.clear(out);
        return 0;
    }

    fn stopInspectorWhileYielded(data: ?*anyopaque) void {
        const probe: *InspectorYieldStopProbe = @ptrCast(@alignCast(data orelse return));
        if (!engine_thread.releaseForExternalEval(probe.id)) return;
        probe.owner_yielded.store(true, .seq_cst);
        const deadline = io.monotonicMilliseconds() + 3000;
        while (!probe.foreign_entered.load(.seq_cst)) {
            if (io.monotonicMilliseconds() >= deadline) {
                _ = engine_thread.reacquire(probe.id);
                probe.owner_done.store(true, .seq_cst);
                return;
            }
            io.sleepMs(1);
        }
        probe.owner_stop_started.store(true, .seq_cst);
        inspector.stop(probe.handle);
        probe.owner_stop_done.store(true, .seq_cst);
        _ = engine_thread.reacquire(probe.id);
        probe.owner_done.store(true, .seq_cst);
    }

    fn runHeldInspectorForeignEval(probe: *InspectorYieldStopProbe) void {
        const result = engine.evalScript(probe.id, "holdInspectorStop()", "<held-inspector-eval>");
        helpers.freeEvalResult(result);
        probe.foreign_eval_done.store(true, .seq_cst);
    }

    test "JSC inspector stop on yielded owner waits for foreign eval before freeing JS values" {
        if (!backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "jsc-yield-stop" });
        var probe = InspectorYieldStopProbe{ .id = id, .handle = handle };
        try testing.expect(engine_thread.hostInstall(id, "holdInspectorStop", holdInspectorForeignEval, @ptrCast(@constCast(&probe))));
        try testing.expect(engine_thread.threadStart(id));
        defer engine_thread.threadStop(id);
        try testing.expect(engine_thread.postToEngineThread(id, stopInspectorWhileYielded, @ptrCast(@constCast(&probe))));

        try testing.expect(spinUntil(&probe.owner_yielded));
        const eval_thread = try std.Thread.spawn(.{}, runHeldInspectorForeignEval, .{@constCast(&probe)});
        const owner_stop_started = spinUntil(&probe.owner_stop_started);
        // Brief probe only: stop must remain blocked while the foreign eval holds the JSC gate. A long spinUntil would just burn time without proving more.
        const stop_probe_deadline = io.monotonicMilliseconds() + 50;
        var stop_finished_while_eval_held = false;
        while (io.monotonicMilliseconds() < stop_probe_deadline) {
            if (probe.owner_stop_done.load(.seq_cst)) {
                stop_finished_while_eval_held = true;
                break;
            }
            io.sleepMs(1);
        }
        probe.release_foreign.store(true, .seq_cst);
        eval_thread.join();
        const owner_finished = spinUntil(&probe.owner_done);
        try testing.expect(owner_stop_started);
        try testing.expect(!stop_finished_while_eval_held);
        try testing.expect(owner_finished);
        try testing.expect(probe.foreign_eval_done.load(.seq_cst));
        try testing.expect(probe.owner_stop_done.load(.seq_cst));
        try testing.expect(inspector_state.stateByInstance(id) == null);
    }

    test "threadStop lets the next legal eval take over retired inspector values" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "thread-stop-retired-owner" });
        const state = inspector_state.stateByInstance(id) orelse return error.InspectorStateMissing;
        try testing.expect(engine_thread.threadStart(id));
        try testing.expect(inspector_state.postInspectorTask(state, .{
            .ctx = null,
            .run = markStopScopeRun,
        }));
        var spins: usize = 0;
        while (state.engine_thread_id.load(.seq_cst) == @as(u64, @intCast(std.Thread.getCurrentId())) and spins < 10_000) : (spins += 1) std.Thread.yield() catch {};
        const worker_id = state.engine_thread_id.load(.seq_cst);
        try testing.expect(worker_id != 0);
        try testing.expect(worker_id != @as(u64, @intCast(std.Thread.getCurrentId())));
        engine_thread.threadStop(id);

        inspector.stop(handle);
        try testing.expectEqual(@as(usize, 1), inspector_state.retiredStateCount(id));
        const result = engine.evalScript(id, "6 * 7", "thread-stop-retired.js");
        defer if (result.result) |text| std.heap.c_allocator.free(text);
        try testing.expect(result.err == null);
        try testing.expectEqual(@as(usize, 0), inspector_state.retiredStateCount(id));
    }
};

comptime {
    _ = InspectorEnabledTests3;
}

test "engine destroy ignores recursive requests from its runtime finalizer" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var finalizer = ReentrantDestroyFinalizer{ .instance_id = id };
    try helpers.evalOk(id, "globalThis.__recursive_destroy_target = {};");
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = backend.ActiveEngine.getGlobalObject(ctx);
    const target = backend.ActiveEngine.getPropertyVal(ctx, global, "__recursive_destroy_target") orelse {
        backend.ActiveEngine.freeValue(ctx, global);
        return error.NoTarget;
    };
    try testing.expect(weakcb.attachDestroyingFinalizer(id, target, @ptrCast(&finalizer), ReentrantDestroyFinalizer.run));
    backend.ActiveEngine.freeValue(ctx, target);
    backend.ActiveEngine.freeValue(ctx, global);

    engine.destroy(id);
    try testing.expectEqual(@as(u32, 1), finalizer.calls.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

const InspectorEnabledTests4 = if (@import("build_options").inspector) struct {
    test "inspector: /json/list returns configured target" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .title = "inspector-test",
            .url = "file:///inspector-test.js",
            .target_id = "target-abcdef",
        });
        defer inspector.stop(handle);

        const port = inspector.boundPort(handle);
        const stream = try connect(port);
        try stream.writeAll("GET /json/list HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        var resp: std.ArrayList(u8) = .empty;
        defer resp.deinit(alloc);
        try readUntilEof(alloc, stream, &resp);
        stream.close();

        try testing.expect(std.mem.startsWith(u8, resp.items, "HTTP/1.1 200 OK"));
        try testing.expect(std.mem.indexOf(u8, resp.items, "\"id\":\"target-abcdef\"") != null);
        try testing.expect(std.mem.indexOf(u8, resp.items, "\"title\":\"inspector-test\"") != null);

        const ws_url = try std.fmt.allocPrint(alloc, "ws://localhost:{d}/target-abcdef", .{port});
        defer alloc.free(ws_url);
        try testing.expect(std.mem.indexOf(u8, resp.items, ws_url) != null);
    }

    test "inspector: WebSocket Runtime.enable roundtrip" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "runtime-enable-t",
        });
        defer inspector.stop(handle);

        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "runtime-enable-t");

        try writeMaskedText(stream, "{\"id\":1,\"method\":\"Runtime.enable\"}");

        // We expect two frames; order not strictly guaranteed. Collect both.
        var got_response = false;
        var got_event = false;
        var spins: usize = 0;
        while ((!got_response or !got_event) and spins < 100) : (spins += 1) {
            _ = dispatch.tickInstance(id);
            const frame_opt = try reader.readTimed(alloc, 50);
            if (frame_opt) |frame| {
                defer alloc.free(frame.payload);
                if (frame.opcode != 0x1) continue;
                // Check event first — events also contain the substring "id":1 (context.id=1), so a plain id match would misclassify them.
                if (containsExecutionContextCreated(frame.payload)) {
                    got_event = true;
                } else if (containsIdOne(frame.payload)) {
                    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"result\":{}") != null);
                    got_response = true;
                }
            }
        }
        try testing.expect(got_response);
        try testing.expect(got_event);
    }

    test "inspector: Runtime.evaluate returns primitive result" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "eval-primitive",
        });
        defer inspector.stop(handle);

        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "eval-primitive");

        // Skip Runtime.enable — evaluate works without it. (DevTools sends enable first in practice; we just want to test evaluate here.)
        try writeMaskedText(stream, "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1 + 2\"}}");

        const frame_opt = try waitForFrame(alloc, id, &reader, containsIdTwo, 3000);
        try testing.expect(frame_opt != null);
        const frame = frame_opt.?;
        defer alloc.free(frame.payload);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "\"type\":\"number\"") != null);
        try testing.expect(
            std.mem.indexOf(u8, frame.payload, "\"value\":3") != null or
                std.mem.indexOf(u8, frame.payload, "\"description\":\"3\"") != null,
        );
    }

    test "inspector: Runtime.evaluate captures exception" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "eval-exception",
        });
        defer inspector.stop(handle);

        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "eval-exception");

        try writeMaskedText(stream, "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"throw new Error('boom')\"}}");

        const frame_opt = try waitForFrame(alloc, id, &reader, containsIdTwo, 3000);
        try testing.expect(frame_opt != null);
        const frame = frame_opt.?;
        defer alloc.free(frame.payload);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "exceptionDetails") != null);
        try testing.expect(std.mem.indexOf(u8, frame.payload, "boom") != null);
    }

    test "inspector: console.log triggers Runtime.consoleAPICalled event" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "console-tap",
        });
        defer inspector.stop(handle);

        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "console-tap");

        // Enable Runtime so consoleAPICalled events get emitted to this session.
        try writeMaskedText(stream, "{\"id\":1,\"method\":\"Runtime.enable\"}");

        // Wait for the enable reply so we know the session is marked enabled before the evaluate below emits a console.log.
        const enable_frame = try waitForFrame(alloc, id, &reader, containsIdOne, 2000);
        try testing.expect(enable_frame != null);
        alloc.free(enable_frame.?.payload);

        // Also drain the executionContextCreated event out of the pipe so it doesn't confuse later matchers.
        var ctx_seen = false;
        var spins: usize = 0;
        while (!ctx_seen and spins < 40) : (spins += 1) {
            _ = dispatch.tickInstance(id);
            const f = try reader.readTimed(alloc, 25);
            if (f) |ff| {
                defer alloc.free(ff.payload);
                if (containsExecutionContextCreated(ff.payload)) ctx_seen = true;
            }
        }

        try writeMaskedText(stream, "{\"id\":2,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"console.log('hello from js')\"}}");

        const ev = try waitForFrame(alloc, id, &reader, containsConsoleAPICalled, 3000);
        try testing.expect(ev != null);
        const ef = ev.?;
        defer alloc.free(ef.payload);
        try testing.expect(std.mem.indexOf(u8, ef.payload, "hello from js") != null);
        try testing.expect(std.mem.indexOf(u8, ef.payload, "\"type\":\"log\"") != null);
    }

    test "inspector: stop closes sessions and joins" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "stop-closes",
        });

        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "stop-closes");

        // Give the reader thread a moment to register the session; not strictly needed for the below assertion, but keeps behaviour deterministic.
        io.sleepMs(20);

        inspector.stop(handle);

        // Now the client read should return EOF (or closed frame) within a bounded wait.
        var buf: [64]u8 = undefined;
        var polls: usize = 0;
        var closed = false;
        while (polls < 100 and !closed) : (polls += 1) {
            const n = stream.read(&buf) catch 0;
            if (n == 0) {
                closed = true;
                break;
            }
            // If we got data (e.g. a close frame), that still counts — the next read should return 0.
            io.sleepMs(10);
        }
        try testing.expect(closed);
    }
};

comptime {
    _ = InspectorEnabledTests4;
}

test "CDP response wait matches only a complete message with the requested top-level id" {
    const messages = "{\"id\":1,\"result\":{}}\n{\"method\":\"Debugger.scriptParsed\",\"params\":{\"id\":2}}\n{\"id\":3,\"result\":{}}\n";
    const after_first = (std.mem.indexOfScalar(u8, messages, '\n') orelse unreachable) + 1;
    try testing.expect(try hasResponseIdSince(testing.allocator, messages, 0, 1));
    try testing.expect(!try hasResponseIdSince(testing.allocator, messages, after_first, 1));
    try testing.expect(!try hasResponseIdSince(testing.allocator, messages, after_first, 2));
    try testing.expect(try hasResponseIdSince(testing.allocator, messages, after_first, 3));
}

var stop_scope_runs: std.atomic.Value(u32) = .init(0);
var stop_scope_cancels: std.atomic.Value(u32) = .init(0);
var stop_scope_owned_cancels: std.atomic.Value(u32) = .init(0);

fn markStopScopeRun(_: ?*anyopaque) void {
    _ = stop_scope_runs.fetchAdd(1, .seq_cst);
}

fn markStopScopeCancel(_: ?*anyopaque) void {
    _ = stop_scope_cancels.fetchAdd(1, .seq_cst);
}

fn markStopScopeOwnedCancel(_: ?*anyopaque) void {
    _ = stop_scope_owned_cancels.fetchAdd(1, .seq_cst);
}

const InspectorEnabledTests5 = if (@import("build_options").inspector) struct {
    test "inspector.stop cancels only its own queued dispatch tasks" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "stop-owned-tasks" });
        const state = inspector_state.stateByInstance(id) orelse return error.InspectorStateMissing;
        stop_scope_runs.store(0, .seq_cst);
        stop_scope_cancels.store(0, .seq_cst);
        stop_scope_owned_cancels.store(0, .seq_cst);

        try testing.expect(dispatch.postTask(id, .{
            .ctx = null,
            .run = markStopScopeRun,
            .cancel = markStopScopeCancel,
        }));
        try testing.expect(inspector_state.postInspectorTask(state, .{
            .ctx = null,
            .run = markStopScopeRun,
            .cancel = markStopScopeOwnedCancel,
        }));

        inspector.stop(handle);
        try testing.expectEqual(@as(u32, 0), stop_scope_cancels.load(.seq_cst));
        try testing.expectEqual(@as(u32, 1), stop_scope_owned_cancels.load(.seq_cst));
        try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
        try testing.expectEqual(@as(u32, 1), stop_scope_runs.load(.seq_cst));
    }

    const NestedOwnerProbe = struct {
        instance_id: i32,
        owner: *anyopaque,
        nested_owner_visible: std.atomic.Value(bool) = .init(false),
        queued_ran: bool = false,
        reentrant_runs: usize = 0,

        fn inner(ctx: ?*anyopaque) void {
            const probe: *NestedOwnerProbe = @ptrCast(@alignCast(ctx.?));
            probe.nested_owner_visible.store(dispatch.isRunningTaskForOwner(probe.owner), .seq_cst);
        }

        fn outer(ctx: ?*anyopaque) void {
            const probe: *NestedOwnerProbe = @ptrCast(@alignCast(ctx.?));
            // Synchronous nested work retains the parent owner. Queued application work waits until that synchronous stack returns.
            var frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&frame, probe.instance_id, null);
            inner(ctx);
            dispatch.leaveTaskOwnerFrame(&frame);
            std.debug.assert(dispatch.postTask(probe.instance_id, .{ .ctx = ctx, .run = queued }));
            probe.reentrant_runs = dispatch.tickInstance(probe.instance_id);
        }

        fn queued(ctx: ?*anyopaque) void {
            const probe: *NestedOwnerProbe = @ptrCast(@alignCast(ctx.?));
            probe.queued_ran = true;
        }
    };

    test "dispatch preserves the parent inspector owner through a nested unowned task" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "nested-owner-task" });
        defer inspector.stop(handle);
        const state = inspector_state.stateByInstance(id) orelse return error.InspectorStateMissing;
        var probe = NestedOwnerProbe{ .instance_id = id, .owner = state };
        try testing.expect(dispatch.postTask(id, .{
            .ctx = &probe,
            .run = NestedOwnerProbe.outer,
            .owner = state,
        }));
        _ = dispatch.tickInstance(id);
        try testing.expect(probe.nested_owner_visible.load(.seq_cst));
        try testing.expectEqual(@as(usize, 0), probe.reentrant_runs);
        try testing.expect(!probe.queued_ran);
        try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
        try testing.expect(probe.queued_ran);
    }

    const StopLeaseProbe = struct {
        instance_id: i32,
        handle: *inspector.Handle,
        task_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        stop_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        stop_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        stop_waited_for_task: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        duplicate_start_rejected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        destroy_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        destroy_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        destroy_waited_for_task: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        coordination_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        stop_thread: ?std.Thread = null,
        destroy_thread: ?std.Thread = null,

        fn task(ctx: ?*anyopaque) void {
            const probe: *StopLeaseProbe = @ptrCast(@alignCast(ctx.?));
            probe.task_started.store(true, .seq_cst);
            probe.stop_thread = std.Thread.spawn(.{}, StopLeaseProbe.stop, .{probe}) catch return;
            if (!spinUntil(&probe.stop_started)) {
                probe.coordination_ok.store(false, .seq_cst);
                return;
            }
            const state = inspector_state.stateByInstance(probe.instance_id) orelse {
                probe.coordination_ok.store(false, .seq_cst);
                return;
            };
            if (!spinUntilInspectorClosing(state)) {
                probe.coordination_ok.store(false, .seq_cst);
                return;
            }
            if (probe.stop_done.load(.seq_cst)) {
                probe.coordination_ok.store(false, .seq_cst);
                return;
            }
            probe.stop_waited_for_task.store(true, .seq_cst);

            if (inspector.start(probe.instance_id, .{ .port = 0, .target_id = "stop-start-overlap" })) |new_handle| {
                inspector.stop(new_handle);
            } else |err| {
                probe.duplicate_start_rejected.store(err == error.AlreadyStarted, .seq_cst);
            }

            probe.destroy_thread = std.Thread.spawn(.{}, StopLeaseProbe.destroy, .{probe}) catch return;
            if (!spinUntil(&probe.destroy_started) or !spinUntilTeardownPending(probe.instance_id)) {
                probe.coordination_ok.store(false, .seq_cst);
                return;
            }
            if (probe.destroy_done.load(.seq_cst)) {
                probe.coordination_ok.store(false, .seq_cst);
                return;
            }
            probe.destroy_waited_for_task.store(true, .seq_cst);
        }

        fn stop(ctx: *StopLeaseProbe) void {
            ctx.stop_started.store(true, .seq_cst);
            inspector.stop(ctx.handle);
            ctx.stop_done.store(true, .seq_cst);
        }

        fn destroy(ctx: *StopLeaseProbe) void {
            ctx.destroy_started.store(true, .seq_cst);
            engine.destroy(ctx.instance_id);
            ctx.destroy_done.store(true, .seq_cst);
        }
    };

    test "inspector.stop waits for a dispatch snapshot task to finish" {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "inspector-stop-lease" });
        var probe = StopLeaseProbe{ .instance_id = id, .handle = handle };
        defer {
            if (probe.stop_thread) |thread| thread.join();
            if (probe.destroy_thread) |thread| thread.join();
            if (!probe.destroy_done.load(.seq_cst)) engine.destroy(id);
        }

        const state = inspector_state.stateByInstance(id) orelse return error.InspectorStateMissing;
        try testing.expect(inspector_state.postInspectorTask(state, .{
            .ctx = &probe,
            .run = StopLeaseProbe.task,
        }));

        try testing.expectEqual(@as(usize, 1), dispatch.tickInstance(id));
        if (probe.stop_thread) |thread| {
            thread.join();
            probe.stop_thread = null;
        }
        if (probe.destroy_thread) |thread| {
            thread.join();
            probe.destroy_thread = null;
        }
        try testing.expect(probe.task_started.load(.seq_cst));
        try testing.expect(probe.coordination_ok.load(.seq_cst));
        try testing.expect(probe.stop_waited_for_task.load(.seq_cst));
        try testing.expect(probe.duplicate_start_rejected.load(.seq_cst));
        try testing.expect(probe.destroy_waited_for_task.load(.seq_cst));
        try testing.expect(probe.stop_done.load(.seq_cst));
        try testing.expect(probe.destroy_done.load(.seq_cst));
        try testing.expect(inspector_state.stateByInstance(id) == null);
    }

    fn spinUntilInspectorClosing(state: *inspector_state.InspectorState) bool {
        const deadline = io.monotonicMilliseconds() + 5_000;
        while (io.monotonicMilliseconds() < deadline) {
            if (inspector_state.isClosing(state)) return true;
            io.sleepMs(1);
        }
        return inspector_state.isClosing(state);
    }

    fn spinUntilTeardownPending(instance_id: i32) bool {
        const deadline = io.monotonicMilliseconds() + 5_000;
        while (io.monotonicMilliseconds() < deadline) {
            if (instance_map.isTeardownPending(instance_id)) return true;
            io.sleepMs(1);
        }
        return instance_map.isTeardownPending(instance_id);
    }

    test "inspector: Debugger.enable replays parsed scripts" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{ .port = 0, .target_id = "dbg-replay" });
        defer inspector.stop(handle);
        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "dbg-replay");
        try writeMaskedText(stream, "{\"id\":1,\"method\":\"Debugger.enable\"}");

        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        var enable_spins: usize = 0;
        while (std.mem.indexOf(u8, got.items, "\"id\":1") == null and enable_spins < 40) : (enable_spins += 1) {
            _ = dispatch.tickInstance(id);
            try readTextFrames(alloc, &reader, &got, 1);
        }
        try testing.expect(std.mem.indexOf(u8, got.items, "\"id\":1") != null);

        const source = "var a = 1;\nvar b = 2;\n//# sourceMappingURL=logic.js.map\n";
        const loaded = engine.evalScript(id, source, "logic.js");
        defer if (loaded.result) |text| std.heap.c_allocator.free(text);
        defer if (loaded.err) |text| {
            if (loaded.err_is_heap) std.heap.c_allocator.free(text);
        };
        try testing.expect(loaded.err == null);
        got.clearRetainingCapacity();
        var script_spins: usize = 0;
        while (std.mem.indexOf(u8, got.items, "Debugger.scriptParsed") == null and script_spins < 40) : (script_spins += 1) {
            _ = dispatch.tickInstance(id);
            try readTextFrames(alloc, &reader, &got, 1);
        }
        try testing.expect(std.mem.indexOf(u8, got.items, "Debugger.scriptParsed") != null);
        try testing.expect(std.mem.indexOf(u8, got.items, "\"endLine\":0") == null);
        try testing.expect(std.mem.indexOf(u8, got.items, "logic.js.map") != null);

        try writeMaskedText(stream, "{\"id\":2,\"method\":\"Debugger.getScriptSource\",\"params\":{\"scriptId\":\"1\"}}");
        got.clearRetainingCapacity();
        var source_spins: usize = 0;
        while (std.mem.indexOf(u8, got.items, "\"id\":2") == null and source_spins < 20) : (source_spins += 1) {
            _ = dispatch.tickInstance(id);
            try readTextFrames(alloc, &reader, &got, 1);
        }
        try testing.expect(std.mem.indexOf(u8, got.items, "var a = 1;") != null);
    }

    test "inspector: paused call frame can evaluate a local" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "dbg-pause" });
        defer inspector.stop(handle);
        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "dbg-pause");
        try writeMaskedText(stream, "{\"id\":1,\"method\":\"Debugger.enable\"}");
        var ready: std.ArrayList(u8) = .empty;
        defer ready.deinit(alloc);
        var enabled = false;
        var enable_spins: usize = 0;
        while (!enabled and enable_spins < 40) : (enable_spins += 1) {
            _ = dispatch.tickInstance(id);
            try readTextFrames(alloc, &reader, &ready, 1);
            if (std.mem.indexOf(u8, ready.items, "\"id\":1") != null) enabled = true;
        }
        try testing.expect(enabled);
        ready.clearRetainingCapacity();
        try writeMaskedText(stream, "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"add.js\",\"lineNumber\":2}}");
        var breakpoint_ready = false;
        var ready_spins: usize = 0;
        while (!breakpoint_ready and ready_spins < 40) : (ready_spins += 1) {
            _ = dispatch.tickInstance(id);
            try readTextFrames(alloc, &reader, &ready, 1);
            if (std.mem.indexOf(u8, ready.items, "\"id\":3") != null) breakpoint_ready = true;
        }
        try testing.expect(breakpoint_ready);

        const Eval = struct {
            fn run(instance_id: i32) void {
                const script = "function add(a, b) {\n  var n = a + b;\n  return n;\n}\nadd(20, 22)\n";
                const res = engine.evalScript(instance_id, script, "add.js");
                if (res.result) |text| std.heap.c_allocator.free(text);
                if (res.err) |text| {
                    if (res.err_is_heap) std.heap.c_allocator.free(text);
                }
            }
        };
        const thread = try std.Thread.spawn(.{}, Eval.run, .{id});
        var joined = false;
        defer if (!joined) {
            const debugger_mod = @import("../inspector/debugger.zig");
            debugger_mod.resumeExecution(id);
            thread.join();
        };

        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        var seen_pause = false;
        var spins: usize = 0;
        while (!seen_pause and spins < 80) : (spins += 1) {
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items, "Debugger.paused") != null) seen_pause = true;
        }
        if (!seen_pause) {
            std.debug.print("debugger bytes:\n{s}\n", .{got.items});
            return error.TestUnexpectedResult;
        }
        try testing.expect(std.mem.indexOf(u8, got.items, "\"functionName\":\"add\"") != null);
        try testing.expect(std.mem.indexOf(u8, got.items, "\"callFrames\":[]") == null);
        try testing.expect(std.mem.indexOf(u8, got.items, "Debugger.breakpointResolved") != null);

        try writeMaskedText(stream, "{\"id\":4,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":\"0\",\"expression\":\"n\"}}");
        var saw_value = false;
        spins = 0;
        while (!saw_value and spins < 40) : (spins += 1) {
            const before = got.items.len;
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items[before..], "\"id\":4") != null and
                std.mem.indexOf(u8, got.items[before..], "42") != null) saw_value = true;
        }
        try testing.expect(saw_value);

        try writeMaskedText(stream, "{\"id\":5,\"method\":\"Debugger.resume\"}");
        var saw_resumed = false;
        spins = 0;
        while (!saw_resumed and spins < 40) : (spins += 1) {
            const before = got.items.len;
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items[before..], "Debugger.resumed") != null) saw_resumed = true;
        }
        try testing.expect(saw_resumed);
        thread.join();
        joined = true;
    }

    test "inspector: Runtime.evaluate pause exposes the eval script" {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return;
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        const handle = try inspector.start(id, .{ .port = 0, .target_id = "dbg-input" });
        defer inspector.stop(handle);
        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "dbg-input");

        var stop = std.atomic.Value(bool).init(false);
        const ticker = try std.Thread.spawn(.{}, struct {
            fn run(instance_id: i32, flag: *std.atomic.Value(bool)) void {
                while (!flag.load(.seq_cst)) {
                    _ = dispatch.tickInstance(instance_id);
                    io.sleepMs(1);
                }
            }
        }.run, .{ id, &stop });
        defer {
            const debugger_mod = @import("../inspector/debugger.zig");
            debugger_mod.resumeExecution(id);
            stop.store(true, .seq_cst);
            ticker.join();
        }

        try writeMaskedText(stream, "{\"id\":1,\"method\":\"Debugger.enable\"}");
        var got: std.ArrayList(u8) = .empty;
        defer got.deinit(alloc);
        var enabled = false;
        var spins: usize = 0;
        while (!enabled and spins < 40) : (spins += 1) {
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items, "\"id\":1") != null) enabled = true;
        }
        try testing.expect(enabled);
        try writeMaskedText(stream, "{\"id\":3,\"method\":\"Debugger.setBreakpointByUrl\",\"params\":{\"url\":\"<input>\",\"lineNumber\":2}}");
        var breakpoint_ready = false;
        spins = 0;
        while (!breakpoint_ready and spins < 40) : (spins += 1) {
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items, "\"id\":3") != null) breakpoint_ready = true;
        }
        try testing.expect(breakpoint_ready);
        try writeMaskedText(stream, "{\"id\":10,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"function add(a, b) {\\n  var n = a + b;\\n  return n;\\n}\\nadd(20, 22)\"}}");

        var seen_pause = false;
        spins = 0;
        while (!seen_pause and spins < 80) : (spins += 1) {
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items, "Debugger.paused") != null) seen_pause = true;
        }
        try testing.expect(seen_pause);
        try testing.expect(std.mem.indexOf(u8, got.items, "\"url\":\"<input>\"") != null);
        try testing.expect(std.mem.indexOf(u8, got.items, "\"functionName\":\"add\"") != null);
        try testing.expect(std.mem.indexOf(u8, got.items, "Debugger.breakpointResolved") != null);

        const name_at = std.mem.indexOf(u8, got.items, "\"functionName\":\"add\"") orelse return error.TestUnexpectedResult;
        const marker = "\"scriptId\":\"";
        const at = std.mem.indexOf(u8, got.items[name_at..], marker) orelse return error.TestUnexpectedResult;
        const at_abs = name_at + at;
        const id_start = at_abs + marker.len;
        const id_end = std.mem.indexOfScalarPos(u8, got.items, id_start, '"') orelse return error.TestUnexpectedResult;
        try testing.expect(!std.mem.eql(u8, got.items[id_start..id_end], "0"));
        const script_id = got.items[id_start..id_end];
        const source_cmd = try std.fmt.allocPrint(alloc, "{{\"id\":11,\"method\":\"Debugger.getScriptSource\",\"params\":{{\"scriptId\":\"{s}\"}}}}", .{script_id});
        defer alloc.free(source_cmd);
        try writeMaskedText(stream, source_cmd);
        var saw_source = false;
        spins = 0;
        while (!saw_source and spins < 40) : (spins += 1) {
            const before = got.items.len;
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items[before..], "\"id\":11") != null and
                std.mem.indexOf(u8, got.items[before..], "return n") != null) saw_source = true;
        }
        try testing.expect(saw_source);

        try writeMaskedText(stream, "{\"id\":12,\"method\":\"Debugger.evaluateOnCallFrame\",\"params\":{\"callFrameId\":\"0\",\"expression\":\"n\"}}");
        var saw_value = false;
        spins = 0;
        while (!saw_value and spins < 40) : (spins += 1) {
            const before = got.items.len;
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items[before..], "\"id\":12") != null and
                std.mem.indexOf(u8, got.items[before..], "42") != null) saw_value = true;
        }
        try testing.expect(saw_value);

        try writeMaskedText(stream, "{\"id\":13,\"method\":\"Debugger.resume\"}");
        var saw_resumed = false;
        spins = 0;
        while (!saw_resumed and spins < 40) : (spins += 1) {
            const before = got.items.len;
            try readTextFrames(alloc, &reader, &got, 1);
            if (std.mem.indexOf(u8, got.items[before..], "Debugger.resumed") != null) saw_resumed = true;
        }
        try testing.expect(saw_resumed);
    }

    test "inspector: DevTools startup methods reply empty" {
        const alloc = testing.allocator;
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);

        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "startup-stubs",
        });
        defer inspector.stop(handle);

        const stream = try connect(inspector.boundPort(handle));
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "startup-stubs");

        const methods = [_][]const u8{
            "Inspector.enable",
            "HeapProfiler.enable",
            "Target.setAutoAttach",
        };
        for (methods, 0..) |method, index| {
            const cmd = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ index + 1, method });
            defer alloc.free(cmd);
            try writeMaskedText(stream, cmd);
            const marker = try std.fmt.allocPrint(alloc, "\"id\":{d}", .{index + 1});
            defer alloc.free(marker);
            var matched = false;
            var spins: usize = 0;
            while (!matched and spins < 40) : (spins += 1) {
                _ = dispatch.tickInstance(id);
                const frame_opt = try reader.readTimed(alloc, 50);
                if (frame_opt) |frame| {
                    defer alloc.free(frame.payload);
                    if (frame.opcode != 0x1) continue;
                    if (std.mem.indexOf(u8, frame.payload, marker) == null) continue;
                    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"error\"") == null);
                    try testing.expect(std.mem.indexOf(u8, frame.payload, "\"result\":{}") != null);
                    matched = true;
                }
            }
            try testing.expect(matched);
        }
    }

    test "inspector: engine.destroy closes the inspector and frees the console buffer" {
        const alloc = testing.allocator;
        const before = inspector.liveConsoleEntries();
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        const handle = try inspector.start(id, .{
            .port = 0,
            .target_id = "destroy-inspector",
        });
        const port = inspector.boundPort(handle);
        const stream = try connect(port);
        defer stream.close();
        var reader = FrameReader.init(stream);
        defer reader.deinit(alloc);
        try doWsHandshake(alloc, stream, "destroy-inspector");
        try writeMaskedText(stream, "{\"id\":1,\"method\":\"Runtime.enable\"}");
        const enabled = try waitForFrame(alloc, id, &reader, containsIdOne, 2000);
        try testing.expect(enabled != null);
        alloc.free(enabled.?.payload);
        const ran = engine.evalScript(id, "console.log('destroy-buffer')", "destroy.js");
        if (ran.result) |text| std.heap.c_allocator.free(text);
        if (ran.err) |text| std.heap.c_allocator.free(text);
        _ = dispatch.tickInstance(id);
        try testing.expect(inspector.liveConsoleEntries() > before);
        engine.destroy(id);
        try testing.expectEqual(before, inspector.liveConsoleEntries());
        try testing.expectError(error.ConnectFailed, connect(port));
    }
};

comptime {
    _ = InspectorEnabledTests5;
}
