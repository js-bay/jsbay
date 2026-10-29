//! CDP console arguments and events collected while Runtime is enabled. QuickJS only.
//!
//! Session wiring follows `cdp_reference_tests.zig`: ephemeral inspector, WebSocket handshake, then JSON-RPC commands on the test stream.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");
const types = @import("../types.zig");
const wire = @import("inspector_tests.zig");

const Conn = struct {
    alloc: std.mem.Allocator,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    got: std.ArrayList(u8),
    next_id: i64 = 1,

    fn deinit(self: *Conn) void {
        self.reader.deinit(self.alloc);
        self.stream.close();
        self.got.deinit(self.alloc);
    }

    fn command(self: *Conn, method: []const u8, params: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        const text = if (params.len == 0)
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method })
        else
            try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
        defer self.alloc.free(text);
        try wire.writeMaskedText(self.stream, text);
        return id;
    }

    fn waitFrom(self: *Conn, start: usize, needle: []const u8, spins: usize) !bool {
        var i: usize = 0;
        while (i < spins) : (i += 1) {
            try wire.readTextFrames(self.alloc, &self.reader, &self.got, 1);
            const region = if (start < self.got.items.len) self.got.items[start..] else "";
            if (std.mem.indexOf(u8, region, needle) != null) return true;
        }
        return false;
    }

    fn wait(self: *Conn, needle: []const u8, spins: usize) !bool {
        return self.waitFrom(0, needle, spins);
    }

    fn expect(self: *Conn, ok: bool) !void {
        if (ok) return;
        std.debug.print("cdp console bytes:\n{s}\n", .{self.got.items});
        return error.TestUnexpectedResult;
    }
};

const Session = struct {
    conn: Conn,
    id: i32,
    handle: *inspector.Handle,

    fn deinit(self: *Session) void {
        self.conn.deinit();
        inspector.stop(self.handle);
        engine.destroy(self.id);
    }
};

fn openConn(alloc: std.mem.Allocator, port: u16, target_id: []const u8) !Conn {
    const stream = try wire.connect(port);
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{
        .alloc = alloc,
        .stream = stream,
        .reader = wire.FrameReader.init(stream),
        .got = .empty,
    };
}

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const conn = try openConn(alloc, inspector.boundPort(handle), target_id);
    return .{
        .conn = conn,
        .id = id,
        .handle = handle,
    };
}

fn idMarker(alloc: std.mem.Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "\"id\":{d},", .{id});
}

fn discardEval(res: types.EvalResult) void {
    if (res.result) |text| std.heap.c_allocator.free(text);
    if (res.err) |text| {
        if (res.err_is_heap) std.heap.c_allocator.free(text);
    }
}

fn extractObject(text: []const u8, start: usize) ?[]const u8 {
    if (start >= text.len or text[start] != '{') return null;
    var depth: i32 = 0;
    var in_string = false;
    var escaped = false;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return text[start .. i + 1];
            },
            else => {},
        }
    }
    return null;
}

fn nthConsoleEvent(
    alloc: std.mem.Allocator,
    text: []const u8,
    from: usize,
    n: usize,
) !std.json.Parsed(std.json.Value) {
    const key = "{\"method\":\"Runtime.consoleAPICalled\"";
    var rest = from;
    var seen: usize = 0;
    while (rest < text.len) {
        const rel = std.mem.indexOf(u8, text[rest..], key) orelse break;
        const start = rest + rel;
        const slice = extractObject(text, start) orelse return error.TestUnexpectedResult;
        if (seen == n) {
            return std.json.parseFromSlice(std.json.Value, alloc, slice, .{});
        }
        seen += 1;
        rest = start + slice.len;
    }
    return error.TestUnexpectedResult;
}

fn expectStringArg(arg: std.json.Value, text: []const u8) !void {
    try testing.expectEqualStrings("string", arg.object.get("type").?.string);
    try testing.expectEqualStrings(text, arg.object.get("value").?.string);
}

fn expectNumberArg(arg: std.json.Value, n: i64) !void {
    try testing.expectEqualStrings("number", arg.object.get("type").?.string);
    switch (arg.object.get("value").?) {
        .integer => |i| try testing.expectEqual(n, i),
        .float => |f| try testing.expectEqual(@as(f64, @floatFromInt(n)), f),
        else => return error.TestUnexpectedResult,
    }
}

fn enableRuntime(conn: *Conn) !void {
    const id = try conn.command("Runtime.enable", "");
    const marker = try idMarker(conn.alloc, id);
    defer conn.alloc.free(marker);
    try conn.expect(try conn.wait(marker, 40));
    try conn.expect(try conn.wait("Runtime.executionContextCreated", 40));
}

test "cdp: console.log emits one remote object per argument" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-args");
    defer session.deinit();
    errdefer std.debug.print("cdp console bytes:\n{s}\n", .{session.conn.got.items});

    try enableRuntime(&session.conn);
    const ran = engine.evalScript(session.id, "console.log('A', 123)", "console-args.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);

    try session.conn.expect(try session.conn.wait("Runtime.consoleAPICalled", 40));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, session.conn.got.items, "Runtime.consoleAPICalled"));

    var parsed = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    try testing.expectEqualStrings("log", params.object.get("type").?.string);
    const args = params.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 2), args.items.len);
    try expectStringArg(args.items[0], "A");
    try expectNumberArg(args.items[1], 123);
    try testing.expect(std.mem.indexOf(u8, session.conn.got.items, "\"value\":\"A 123\"") == null);
}

test "cdp: console.log keeps an object argument as its own remote object" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-object");
    defer session.deinit();
    errdefer std.debug.print("cdp console bytes:\n{s}\n", .{session.conn.got.items});

    try enableRuntime(&session.conn);
    const ran = engine.evalScript(session.id, "console.log('A', 123, {x:1})", "console-object.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);

    try session.conn.expect(try session.conn.wait("Runtime.consoleAPICalled", 40));
    var parsed = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    try testing.expectEqualStrings("log", params.object.get("type").?.string);
    const args = params.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 3), args.items.len);
    try expectStringArg(args.items[0], "A");
    try expectNumberArg(args.items[1], 123);
    try testing.expectEqualStrings("object", args.items[2].object.get("type").?.string);
    try testing.expectEqualStrings("Object", args.items[2].object.get("className").?.string);
    try testing.expect(args.items[2].object.get("value") == null);
}

test "cdp: console.log before Runtime.enable is not retained" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-buffer");
    defer session.deinit();
    errdefer std.debug.print("cdp console bytes:\n{s}\n", .{session.conn.got.items});

    const ran = engine.evalScript(session.id, "console.log('pre-enable-token')", "console-buffer.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);
    try testing.expect(!try session.conn.wait("pre-enable-token", 6));
    try testing.expect(std.mem.indexOf(u8, session.conn.got.items, "Runtime.consoleAPICalled") == null);

    try enableRuntime(&session.conn);
    try testing.expectEqual(@as(usize, 0), std.mem.count(u8, session.conn.got.items, "pre-enable-token"));
    const live = engine.evalScript(session.id, "console.log('enabled-token')", "console-enabled.js");
    defer discardEval(live);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("enabled-token", 40));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, session.conn.got.items, "Runtime.consoleAPICalled"));

    var parsed = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    try testing.expectEqualStrings("log", params.object.get("type").?.string);
    const args = params.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 1), args.items.len);
    try expectStringArg(args.items[0], "enabled-token");
}

test "cdp: a later Runtime.enable replays entries collected after the first enable" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-second");
    defer session.deinit();
    errdefer std.debug.print("cdp console bytes:\n{s}\n", .{session.conn.got.items});

    var second = try openConn(alloc, inspector.boundPort(session.handle), "cdp-console-second");
    defer second.deinit();
    errdefer std.debug.print("cdp console second bytes:\n{s}\n", .{second.got.items});

    try enableRuntime(&session.conn);
    const ran = engine.evalScript(session.id, "console.log('early-buf')", "console-second.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("early-buf", 40));
    try testing.expect(!try second.wait("early-buf", 4));

    try enableRuntime(&second);
    try second.expect(try second.wait("early-buf", 40));
    const ctx_at = std.mem.indexOf(u8, second.got.items, "Runtime.executionContextCreated") orelse return error.TestUnexpectedResult;
    const msg_at = std.mem.indexOf(u8, second.got.items, "early-buf") orelse return error.TestUnexpectedResult;
    try testing.expect(msg_at > ctx_at);

    const ran_live = engine.evalScript(session.id, "console.log('live-buf')", "console-second-live.js");
    defer discardEval(ran_live);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("live-buf", 40));
    try second.expect(try second.wait("live-buf", 40));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, session.conn.got.items, "early-buf"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, second.got.items, "early-buf"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, session.conn.got.items, "live-buf"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, second.got.items, "live-buf"));
}

fn countEvents(payload: []const u8) usize {
    return std.mem.count(u8, payload, "Runtime.consoleAPICalled");
}

test "cdp: console.debug is debug and objects include a preview" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-debug");
    defer session.deinit();
    try enableRuntime(&session.conn);
    const ran = engine.evalScript(session.id, "console.debug('D'); console.log({x:1})", "console-debug.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);
    var spins: usize = 0;
    while (spins < 40 and countEvents(session.conn.got.items) < 2) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        try wire.readTextFrames(session.conn.alloc, &session.conn.reader, &session.conn.got, 1);
    }
    try testing.expect(countEvents(session.conn.got.items) >= 2);
    var first = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer first.deinit();
    try testing.expectEqualStrings("debug", first.value.object.get("params").?.object.get("type").?.string);
    var second = try nthConsoleEvent(alloc, session.conn.got.items, 0, 1);
    defer second.deinit();
    const arg = second.value.object.get("params").?.object.get("args").?.array.items[0];
    try testing.expect(arg.object.get("preview") != null);
}

test "cdp: discardConsoleEntries drops the replay buffer" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-discard");
    defer session.deinit();
    try enableRuntime(&session.conn);
    const ran = engine.evalScript(session.id, "console.log('stale')", "discard.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("stale", 40));
    const id = try session.conn.command("Runtime.discardConsoleEntries", "");
    const marker = try idMarker(session.conn.alloc, id);
    defer session.conn.alloc.free(marker);
    var replied = false;
    var spins: usize = 0;
    while (!replied and spins < 40) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        replied = try session.conn.waitFrom(0, marker, 1);
    }
    try session.conn.expect(replied);
    var second = try openConn(alloc, inspector.boundPort(session.handle), "cdp-console-discard");
    defer second.deinit();
    try enableRuntime(&second);
    try testing.expectEqual(@as(usize, 0), countEvents(second.got.items));
}

test "cdp: console object handles are released when their buffered event is evicted" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-evict-handles");
    defer session.deinit();
    try enableRuntime(&session.conn);

    const first = engine.evalScript(session.id, "console.log({staleConsoleObject: true})", "console-evict-first.js");
    defer discardEval(first);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("staleConsoleObject", 40));
    var event = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer event.deinit();
    const arg = event.value.object.get("params").?.object.get("args").?.array.items[0].object;
    const stale_id = arg.get("objectId").?.string;
    const stale_params = try std.fmt.allocPrint(alloc, "{{\"objectId\":\"{s}\"}}", .{stale_id});
    defer alloc.free(stale_params);

    const burst = engine.evalScript(session.id, "for (let i = 0; i < 101; i++) console.log()", "console-evict-burst.js");
    defer discardEval(burst);
    _ = dispatch.tickInstance(session.id);

    const props_id = try session.conn.command("Runtime.getProperties", stale_params);
    const props_marker = try idMarker(alloc, props_id);
    defer alloc.free(props_marker);
    var replied = false;
    var spins: usize = 0;
    // The 101 live console events precede this reply on the same connection.
    while (!replied and spins < 141) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        replied = try session.conn.waitFrom(0, props_marker, 1);
    }
    try session.conn.expect(replied);
    try testing.expect(std.mem.indexOf(u8, session.conn.got.items, "Could not find object with given id") != null);
}

test "cdp: discardConsoleEntries keeps non-console object handles" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-discard-keeps-eval");
    defer session.deinit();
    try enableRuntime(&session.conn);

    const eval_start = session.conn.got.items.len;
    const eval_id = try session.conn.command("Runtime.evaluate", "{\"expression\":\"({persistentAfterDiscard: 7})\"}");
    const eval_marker = try idMarker(alloc, eval_id);
    defer alloc.free(eval_marker);
    var eval_replied = false;
    var spins: usize = 0;
    while (!eval_replied and spins < 40) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        eval_replied = try session.conn.waitFrom(eval_start, eval_marker, 1);
    }
    try session.conn.expect(eval_replied);
    const eval_at = eval_start + (std.mem.indexOf(u8, session.conn.got.items[eval_start..], "{\"id\":") orelse return error.TestUnexpectedResult);
    const eval_reply = extractObject(session.conn.got.items, eval_at) orelse return error.TestUnexpectedResult;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, eval_reply, .{});
    defer parsed.deinit();
    const object_id = parsed.value.object.get("result").?.object.get("result").?.object.get("objectId").?.string;
    const props_params = try std.fmt.allocPrint(alloc, "{{\"objectId\":\"{s}\"}}", .{object_id});
    defer alloc.free(props_params);

    const logged = engine.evalScript(session.id, "console.log({discardedConsoleObject: true})", "console-discard-object.js");
    defer discardEval(logged);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("discardedConsoleObject", 40));
    var console_event = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer console_event.deinit();
    const console_object_id = console_event.value.object.get("params").?.object.get("args").?.array.items[0].object.get("objectId").?.string;
    const console_props_params = try std.fmt.allocPrint(alloc, "{{\"objectId\":\"{s}\"}}", .{console_object_id});
    defer alloc.free(console_props_params);
    const discard_id = try session.conn.command("Runtime.discardConsoleEntries", "");
    const discard_marker = try idMarker(alloc, discard_id);
    defer alloc.free(discard_marker);
    var discard_replied = false;
    spins = 0;
    while (!discard_replied and spins < 40) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        discard_replied = try session.conn.waitFrom(0, discard_marker, 1);
    }
    try session.conn.expect(discard_replied);

    const console_props_id = try session.conn.command("Runtime.getProperties", console_props_params);
    const console_props_marker = try idMarker(alloc, console_props_id);
    defer alloc.free(console_props_marker);
    var console_props_replied = false;
    spins = 0;
    while (!console_props_replied and spins < 40) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        console_props_replied = try session.conn.waitFrom(0, console_props_marker, 1);
    }
    try session.conn.expect(console_props_replied);
    try testing.expect(std.mem.indexOf(u8, session.conn.got.items, "Could not find object with given id") != null);

    const props_id = try session.conn.command("Runtime.getProperties", props_params);
    const props_marker = try idMarker(alloc, props_id);
    defer alloc.free(props_marker);
    var props_replied = false;
    spins = 0;
    while (!props_replied and spins < 40) : (spins += 1) {
        _ = dispatch.tickInstance(session.id);
        props_replied = try session.conn.waitFrom(0, props_marker, 1);
    }
    try session.conn.expect(props_replied);
    try testing.expect(std.mem.indexOf(u8, session.conn.got.items, "persistentAfterDiscard") != null);
}

test "cdp: dir table trace group assert and timeEnd use their CDP types" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-kinds");
    defer session.deinit();
    try enableRuntime(&session.conn);
    const src =
        \\console.assert(true, 'hidden');
        \\console.assert(false, 'shown');
        \\console.dir({d:1});
        \\console.table([1]);
        \\console.group('G');
        \\console.groupEnd();
        \\function traced() { console.trace('T'); }
        \\traced();
        \\console.time('tick');
        \\console.timeEnd('tick');
    ;
    const ran = engine.evalScript(session.id, src, "kinds.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("timeEnd", 40));
    const got = session.conn.got.items;
    try testing.expect(std.mem.indexOf(u8, got, "hidden") == null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"assert\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "shown") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"dir\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"table\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"startGroup\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"endGroup\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"trace\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "kinds.js") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"type\":\"timeEnd\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "tick:") != null);
}

test "cdp: console.log reports a 0-based stack line" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-stack");
    defer session.deinit();
    try enableRuntime(&session.conn);
    const src = "function marker() {\n  console.log('stack-token');\n}\nmarker();\n";
    const ran = engine.evalScript(session.id, src, "stack.js");
    defer discardEval(ran);
    _ = dispatch.tickInstance(session.id);
    try session.conn.expect(try session.conn.wait("stack-token", 40));
    var parsed = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    const frames = params.object.get("stackTrace").?.object.get("callFrames").?.array;
    try testing.expect(frames.items.len > 0);
    const top = frames.items[0].object;
    try testing.expectEqualStrings("marker", top.get("functionName").?.string);
    try testing.expect(std.mem.indexOf(u8, top.get("url").?.string, "stack.js") != null);
    try testing.expectEqual(@as(i64, 1), top.get("lineNumber").?.integer);
}

test "cdp: console event without a JS context still emits the text and stack" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console-fallback");
    defer session.deinit();
    try enableRuntime(&session.conn);
    const console_tap = @import("../inspector/console_tap.zig");
    const console_cdp = @import("../inspector/root.zig").console;
    const frame = console_tap.CallFrame{
        .function_name = "fromTest",
        .url = "fallback.js",
        .line = 4,
        .column = 2,
    };
    console_tap.setArgView(.{
        .ctx = null,
        .argc = 0,
        .argv = null,
        .cdp_type = "debug",
        .frames = &.{frame},
    });
    defer console_tap.setArgView(null);
    console_cdp.consoleTapCallback(@ptrCast(session.handle), session.id, .debug, "fallback-text");
    try session.conn.expect(try session.conn.wait("fallback-text", 40));
    var parsed = try nthConsoleEvent(alloc, session.conn.got.items, 0, 0);
    defer parsed.deinit();
    const params = parsed.value.object.get("params").?;
    try testing.expectEqualStrings("debug", params.object.get("type").?.string);
    const args = params.object.get("args").?.array;
    try testing.expectEqual(@as(usize, 1), args.items.len);
    try expectStringArg(args.items[0], "fallback-text");
    const frames = params.object.get("stackTrace").?.object.get("callFrames").?.array;
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    const top = frames.items[0].object;
    try testing.expectEqualStrings("fromTest", top.get("functionName").?.string);
    try testing.expectEqualStrings("fallback.js", top.get("url").?.string);
    try testing.expectEqual(@as(i64, 4), top.get("lineNumber").?.integer);
    try testing.expectEqual(@as(i64, 2), top.get("columnNumber").?.integer);
}
