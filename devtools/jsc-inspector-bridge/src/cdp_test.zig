//! Bridge tests that run without a simulator: a scripted relay stands in for `webinspectord` and a recorder stands in for the CDP transport.

const std = @import("std");
const cdp = @import("cdp.zig");
const wir = @import("wir.zig");
const zev = @import("zev");
const transport = @import("inspector_transport");

const Allocator = std.mem.Allocator;

const Recorded = struct {
    const Kind = enum { data, connect, did_close };

    kind: Kind,
    json: []u8,
};

/// Stands in for the relay connection. Records what the bridge sends and can hold `sendDidClose` open so a close can be interleaved with another session opening.
const FakeRelay = struct {
    allocator: Allocator,
    mutex: zev.Mutex = .{},
    recorded: std.ArrayListUnmanaged(Recorded) = .empty,
    attached: bool = false,
    closed: bool = false,
    hold_close: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    close_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    close_released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn record(self: *FakeRelay, kind: Recorded.Kind, json: []const u8) void {
        const copy = self.allocator.dupe(u8, json) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.recorded.append(self.allocator, .{ .kind = kind, .json = copy }) catch self.allocator.free(copy);
    }

    fn connectFrontend(ctx: *anyopaque, target: *const wir.Target) void {
        _ = target;
        const self: *FakeRelay = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        self.attached = true;
        self.mutex.unlock();
        self.record(.connect, "");
    }

    fn sendDidClose(ctx: *anyopaque, target: *const wir.Target) void {
        _ = target;
        const self: *FakeRelay = @ptrCast(@alignCast(ctx));
        if (self.hold_close.load(.acquire)) {
            self.close_entered.store(true, .release);
            while (!self.close_released.load(.acquire)) zev.sleepMilliseconds(1);
        }
        self.mutex.lock();
        self.attached = false;
        self.mutex.unlock();
        self.record(.did_close, "");
    }

    fn sendData(ctx: *anyopaque, target: *const wir.Target, json: []const u8) void {
        _ = target;
        const self: *FakeRelay = @ptrCast(@alignCast(ctx));
        self.record(.data, json);
    }

    fn isClosed(ctx: *anyopaque) bool {
        const self: *FakeRelay = @ptrCast(@alignCast(ctx));
        return self.closed;
    }

    fn nextData(ctx: *anyopaque, timeout_ms: u64, allocator: Allocator) anyerror!?[]u8 {
        _ = ctx;
        _ = timeout_ms;
        _ = allocator;
        return null;
    }

    fn relay(self: *FakeRelay) cdp.Relay {
        return .{ .ctx = self, .vtable = &.{
            .connectFrontend = connectFrontend,
            .sendDidClose = sendDidClose,
            .sendData = sendData,
            .isClosed = isClosed,
            .nextData = nextData,
        } };
    }

    fn attachedNow(self: *FakeRelay) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.attached;
    }

    /// Commands the bridge forwarded, in order.
    fn commands(self: *FakeRelay, allocator: Allocator) !std.ArrayListUnmanaged([]const u8) {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.recorded.items) |entry| {
            if (entry.kind != .data) continue;
            try out.append(allocator, try allocator.dupe(u8, entry.json));
        }
        return out;
    }

    fn lastCommand(self: *FakeRelay) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var index = self.recorded.items.len;
        while (index > 0) {
            index -= 1;
            if (self.recorded.items[index].kind == .data) return self.recorded.items[index].json;
        }
        return null;
    }
};

const Outgoing = struct {
    session: transport.SessionId,
    json: []u8,
};

/// Stands in for the loopback CDP transport and records the messages the bridge sends to a client.
const FakeFrontend = struct {
    allocator: Allocator,
    mutex: zev.Mutex = .{},
    sent: std.ArrayListUnmanaged(Outgoing) = .empty,
    closed: std.ArrayListUnmanaged(transport.SessionId) = .empty,

    fn sendText(ctx: *anyopaque, session: transport.SessionId, text: []const u8) void {
        const self: *FakeFrontend = @ptrCast(@alignCast(ctx));
        const copy = self.allocator.dupe(u8, text) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sent.append(self.allocator, .{ .session = session, .json = copy }) catch self.allocator.free(copy);
    }

    fn closeSession(ctx: *anyopaque, session: transport.SessionId) void {
        const self: *FakeFrontend = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed.append(self.allocator, session) catch {};
    }

    fn boundPort(ctx: *anyopaque) u16 {
        _ = ctx;
        return 0;
    }

    fn frontend(self: *FakeFrontend) cdp.Frontend {
        return .{ .ctx = self, .vtable = &.{
            .sendText = sendText,
            .closeSession = closeSession,
            .boundPort = boundPort,
        } };
    }

    fn count(self: *FakeFrontend) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sent.items.len;
    }

    /// Every message the bridge sent to the client, parsed far enough to compare ids.
    fn replyIds(self: *FakeFrontend, allocator: Allocator) ![]std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        var ids: std.ArrayListUnmanaged(std.json.Value) = .empty;
        for (self.sent.items) |entry| {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, entry.json, .{}) catch continue;
            if (parsed.value != .object) continue;
            if (parsed.value.object.get("method") != null) continue;
            const id = parsed.value.object.get("id") orelse continue;
            try ids.append(allocator, id);
        }
        return try ids.toOwnedSlice(allocator);
    }

    fn replyFor(self: *FakeFrontend, allocator: Allocator, id: i64) !?std.json.Value {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sent.items) |entry| {
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, entry.json, .{}) catch continue;
            if (parsed.value != .object) continue;
            if (parsed.value.object.get("method") != null) continue;
            const raw = parsed.value.object.get("id") orelse continue;
            if (raw != .integer or raw.integer != id) continue;
            return parsed.value;
        }
        return null;
    }
};

const Harness = struct {
    allocator: Allocator,
    relay: *FakeRelay,
    frontend: *FakeFrontend,
    bridge: *cdp.Bridge,

    fn create(allocator: Allocator) !Harness {
        const relay = try allocator.create(FakeRelay);
        relay.* = .{ .allocator = allocator };
        const frontend = try allocator.create(FakeFrontend);
        frontend.* = .{ .allocator = allocator };
        const target = wir.Target{
            .application = try allocator.dupe(u8, "PID:1"),
            .application_name = try allocator.dupe(u8, "test-demo"),
            .page = 1,
            .title = try allocator.dupe(u8, "JSContext"),
        };
        const bridge = try cdp.Bridge.init(allocator, relay.relay(), frontend.frontend(), target);
        return .{ .allocator = allocator, .relay = relay, .frontend = frontend, .bridge = bridge };
    }

    fn sessionCount(self: *Harness) usize {
        self.bridge.mutex.lock();
        defer self.bridge.mutex.unlock();
        return self.bridge.sessions.items.len;
    }

    fn pendingCount(self: *Harness) usize {
        self.bridge.mutex.lock();
        defer self.bridge.mutex.unlock();
        return self.bridge.pending.count();
    }

    fn mergeCount(self: *Harness) usize {
        self.bridge.mutex.lock();
        defer self.bridge.mutex.unlock();
        return self.bridge.merges.count();
    }

    /// Relays the reply a real target would send for the nth forwarded command.
    fn replyTo(self: *Harness, command_index: usize, reply_json: []const u8) !void {
        const commands = try self.relay.commands(self.allocator);
        try std.testing.expect(command_index < commands.items.len);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, commands.items[command_index], .{});
        const relay_id = parsed.value.object.get("id").?.integer;
        const text = try std.fmt.allocPrint(self.allocator, "{{\"id\":{d},{s}", .{ relay_id, reply_json[1..] });
        self.bridge.deliver(text);
    }
};

const paused_with_scopes =
    \\{"method":"Debugger.paused","params":{"reason":"other","callFrames":[{"callFrameId":"frame-1","functionName":"tick","location":{"scriptId":"7","lineNumber":3,"columnNumber":2},"url":"","scopeChain":[{"type":"closure","object":{"type":"object","objectId":"local-1"}},{"type":"nestedLexical","object":{"type":"object","objectId":"block-1"}}]}],"hitBreakpoints":[]}}
;

test "bridge forwards an evaluate and returns its result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());
    harness.bridge.openSession(1);

    harness.bridge.onMessage(1, "{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\",\"returnByValue\":true}}");
    try harness.replyTo(0, "{\"result\":{\"result\":{\"type\":\"number\",\"value\":2,\"description\":\"2\"}}}");

    const reply = (try harness.frontend.replyFor(arena.allocator(), 3)) orelse return error.MissingReply;
    try std.testing.expectEqual(@as(i64, 2), reply.object.get("result").?.object.get("result").?.object.get("value").?.integer);
}

test "merged scope properties answer the client when one half fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());
    harness.bridge.openSession(1);
    harness.bridge.deliver(paused_with_scopes);

    harness.bridge.onMessage(1, "{\"id\":7,\"method\":\"Runtime.getProperties\",\"params\":{\"objectId\":\"local-1\",\"ownProperties\":true}}");
    const commands = try harness.relay.commands(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), commands.items.len);

    try harness.replyTo(0, "{\"result\":{\"result\":{\"properties\":[{\"name\":\"a\",\"value\":{\"type\":\"number\",\"value\":1}}]}}}");
    try harness.replyTo(1, "{\"error\":{\"code\":-32000,\"message\":\"Could not find object with given id\"}}");

    const ids = try harness.frontend.replyIds(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqual(@as(i64, 7), ids[0].integer);
    try std.testing.expectEqual(@as(usize, 0), harness.mergeCount());
}

test "a request with a string id still gets a reply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());
    harness.bridge.openSession(1);

    harness.bridge.onMessage(1, "{\"id\":\"abc\",\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\"}}");

    try std.testing.expectEqual(@as(usize, 1), harness.frontend.count());
}

test "closing a session drops its pending requests and merges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());
    harness.bridge.openSession(1);
    harness.bridge.deliver(paused_with_scopes);
    harness.bridge.onMessage(1, "{\"id\":11,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\"}}");
    harness.bridge.onMessage(1, "{\"id\":12,\"method\":\"Runtime.getProperties\",\"params\":{\"objectId\":\"local-1\"}}");
    try std.testing.expectEqual(@as(usize, 3), harness.pendingCount());

    harness.bridge.closeSession(1);

    try std.testing.expectEqual(@as(usize, 0), harness.pendingCount());
    try std.testing.expectEqual(@as(usize, 0), harness.mergeCount());
}

test "injected debugger commands use their own relay ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());
    harness.bridge.openSession(1);
    harness.bridge.next_id = 1_000_000;

    harness.bridge.onMessage(1, "{\"id\":4,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"1+1\",\"returnByValue\":true}}");
    harness.bridge.onMessage(1, "{\"id\":5,\"method\":\"Debugger.enable\"}");

    const commands = try harness.relay.commands(arena.allocator());
    try std.testing.expectEqual(@as(usize, 4), commands.items.len);

    // Two client commands plus the two commands the bridge injects for `Debugger.enable`.
    var ids: [4]i64 = undefined;
    for (commands.items, 0..) |command, index| {
        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), command, .{});
        ids[index] = parsed.value.object.get("id").?.integer;
    }
    for (ids, 0..) |left, left_index| {
        for (ids[left_index + 1 ..]) |right| {
            try std.testing.expect(left != right);
        }
    }
}

test "an injected command reply never reaches a client" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());
    harness.bridge.openSession(1);

    harness.bridge.onMessage(1, "{\"id\":9,\"method\":\"Debugger.enable\"}");
    const commands = try harness.relay.commands(arena.allocator());
    var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), commands.items[1], .{});
    const injected = try std.fmt.allocPrint(arena.allocator(), "{{\"id\":{d},\"result\":{{}}}}", .{parsed.value.object.get("id").?.integer});

    harness.bridge.deliver(injected);
    try std.testing.expectEqual(@as(usize, 0), harness.frontend.count());

    var enable = try std.json.parseFromSlice(std.json.Value, arena.allocator(), commands.items[0], .{});
    harness.bridge.deliver(try std.fmt.allocPrint(arena.allocator(), "{{\"id\":{d},\"result\":{{\"debuggerId\":\"jsbay-jsc-bridge\"}}}}", .{enable.value.object.get("id").?.integer}));

    const ids = try harness.frontend.replyIds(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), ids.len);
    try std.testing.expectEqual(@as(i64, 9), ids[0].integer);
}

test "a session that opens while the last one closes stays attached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var harness = try Harness.create(arena.allocator());

    harness.bridge.openSession(1);
    harness.relay.hold_close.store(true, .release);

    const Closer = struct {
        fn run(bridge: *cdp.Bridge) void {
            bridge.closeSession(1);
        }
    };
    const Opener = struct {
        fn run(bridge: *cdp.Bridge) void {
            bridge.openSession(2);
        }
    };

    const closer = try std.Thread.spawn(.{}, Closer.run, .{harness.bridge});
    var waited: usize = 0;
    while (!harness.relay.close_entered.load(.acquire) and waited < 2000) : (waited += 1) zev.sleepMilliseconds(1);

    const opener = try std.Thread.spawn(.{}, Opener.run, .{harness.bridge});
    waited = 0;
    while (waited < 2000) : (waited += 1) {
        if (harness.sessionCount() == 1 and harness.relay.attachedNow()) break;
        zev.sleepMilliseconds(1);
    }

    harness.relay.close_released.store(true, .release);
    closer.join();
    opener.join();

    try std.testing.expectEqual(@as(usize, 1), harness.sessionCount());
    try std.testing.expect(harness.relay.attachedNow());
}
