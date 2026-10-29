//! CDP scenarios retargeted at our WebSocket inspector from public debugger suites. Upstream runners cannot be executed here (in-process inspector harnesses or `node --inspect`). Each test describes the scenario it follows.
//!
//! Not ported, because this inspector does not implement them yet: conditional breakpoints, `urlRegex`, blackboxing, async call stacks, wasm stepping, and heap snapshots.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const inspector = @import("../inspector/root.zig");
const inspector_state = @import("../inspector/root.zig").state;
const host_value = @import("../abi/host_value.zig");
const io = @import("../platform/io.zig");
const helpers = @import("test_helpers.zig");
const wire = @import("inspector_tests.zig");

const EvalBox = struct {
    id: i32,
    script: []const u8,
    filename: []const u8,
    ok: bool = false,
    result: []u8 = &.{},
    result_owned: bool = false,

    fn deinit(self: *EvalBox) void {
        if (self.result_owned) std.heap.c_allocator.free(self.result);
    }
};

const StopProbe = struct {
    handle: *inspector.Handle,
    done: std.atomic.Value(bool) = .init(false),

    fn run(probe: *StopProbe) void {
        inspector.stop(probe.handle);
        probe.done.store(true, .seq_cst);
    }
};

const PumpProbe = struct {
    id: i32,
    stop: std.atomic.Value(bool) = .init(false),
    thread_id: std.atomic.Value(u64) = .init(0),

    fn run(probe: *PumpProbe) void {
        probe.thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
        while (!probe.stop.load(.seq_cst)) {
            engine.runEventLoopOnce(probe.id);
            _ = dispatch.tickInstance(probe.id);
            io.sleepMs(1);
        }
    }
};

const ReentrantStopHost = struct {
    handle: *inspector.Handle,
    called: std.atomic.Value(bool) = .init(false),
    callback_thread_id: std.atomic.Value(u64) = .init(0),

    fn call(
        _: c_int,
        user_data: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *ReentrantStopHost = @ptrCast(@alignCast(user_data.?));
        self.callback_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
        self.called.store(true, .seq_cst);
        inspector.stop(self.handle);
        host_value.clear(out);
        return 0;
    }
};

const ReentrantDestroyHost = struct {
    handle: *inspector.Handle,
    instance_id: i32,
    called: std.atomic.Value(bool) = .init(false),

    fn call(
        _: c_int,
        user_data: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *ReentrantDestroyHost = @ptrCast(@alignCast(user_data.?));
        self.called.store(true, .seq_cst);
        inspector.stop(self.handle);
        engine.destroy(self.instance_id);
        host_value.clear(out);
        return 0;
    }
};

fn evalMain(box: *EvalBox) void {
    const res = engine.evalScript(box.id, box.script, box.filename);
    box.ok = res.err == null;
    if (res.result) |text| {
        defer std.heap.c_allocator.free(text);
        if (text.len != 0) {
            box.result = std.heap.c_allocator.dupe(u8, text) catch &.{};
            box.result_owned = box.result.len == text.len;
        }
    }
    if (res.err) |text| {
        if (res.err_is_heap) std.heap.c_allocator.free(text);
    }
}

const Session = struct {
    alloc: std.mem.Allocator,
    id: i32,
    handle: *inspector.Handle,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    got: std.ArrayList(u8),
    next_id: i64 = 1,
    eval_thread: ?std.Thread = null,
    joined: bool = true,

    fn deinit(self: *Session) void {
        // A resume can land on another breakpoint, and a pause can also arrive after this cleanup has already stopped checking. Mark the debugger dead so enterPause returns and join cannot wait there.
        debugger_mod.setBreakpointsActive(self.id, false);
        debugger_mod.setExceptionPause(self.id, .none);
        debugger_mod.abandon(self.id);
        self.joinEval();
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
        self.got.deinit(self.alloc);
    }

    fn joinEval(self: *Session) void {
        if (self.eval_thread) |thread| {
            if (!self.joined) thread.join();
            self.joined = true;
            self.eval_thread = null;
        }
    }

    fn command(self: *Session, method: []const u8, params: []const u8) !i64 {
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

    fn wait(self: *Session, needle: []const u8, spins: usize) !bool {
        return self.waitFrom(0, needle, spins);
    }

    fn waitFrom(self: *Session, start: usize, needle: []const u8, spins: usize) !bool {
        var i: usize = 0;
        while (i < spins) : (i += 1) {
            try wire.readTextFrames(self.alloc, &self.reader, &self.got, 1);
            const region = if (start < self.got.items.len) self.got.items[start..] else "";
            if (std.mem.indexOf(u8, region, needle) != null) return true;
        }
        return false;
    }

    fn waitResponseId(self: *Session, start: usize, id: i64, spins: usize) !bool {
        var i: usize = 0;
        while (i < spins) : (i += 1) {
            try wire.readTextFrames(self.alloc, &self.reader, &self.got, 1);
            if (try wire.hasResponseIdSince(self.alloc, self.got.items, start, id)) return true;
        }
        return false;
    }

    fn expect(self: *Session, ok: bool) !void {
        if (ok) return;
        std.debug.print("cdp bytes:\n{s}\n", .{self.got.items});
        return error.TestUnexpectedResult;
    }

    fn spawn(self: *Session, box: *EvalBox) !void {
        self.joinEval();
        self.eval_thread = try std.Thread.spawn(.{}, evalMain, .{box});
        self.joined = false;
    }
};

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{
        .alloc = alloc,
        .id = id,
        .handle = handle,
        .stream = stream,
        .reader = wire.FrameReader.init(stream),
        .got = .empty,
    };
}

fn idMarker(alloc: std.mem.Allocator, id: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "\"id\":{d},", .{id});
}

fn waitCommand(session: *Session, id: i64) !void {
    const marker = try idMarker(session.alloc, id);
    defer session.alloc.free(marker);
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items, marker) != null) return;
    }
    try session.expect(false);
}

fn quoteAfter(text: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. 1 + end];
}

fn intAfter(text: []const u8, key: []const u8) ?i32 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(i32, rest[0..end], 10) catch null;
}

fn fnvHash(source: []const u8, out: *[16]u8) void {
    var hash: u64 = 0xcbf29ce484222325;
    for (source) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    const hex = "0123456789abcdef";
    for (0..16) |i| {
        const shift: u6 = @intCast((15 - i) * 4);
        out[i] = hex[@as(usize, @intCast((hash >> shift) & 0xf))];
    }
}

fn enableDebugger(session: *Session) !void {
    const id = try session.command("Debugger.enable", "");
    const marker = try idMarker(session.alloc, id);
    defer session.alloc.free(marker);
    // Debugger.enable arms native handlers through the owner-task queue. The transport can receive the command after the first tick, so pump the owner queue until its response is actually observed.
    var attempts: usize = 0;
    while (attempts < 40) : (attempts += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items, marker) != null) return;
    }
    try session.expect(false);
}

fn setBreakpoint(session: *Session, url: []const u8, line: i32) !void {
    const params = try std.fmt.allocPrint(session.alloc, "{{\"url\":\"{s}\",\"lineNumber\":{d}}}", .{ url, line });
    defer session.alloc.free(params);
    const id = try session.command("Debugger.setBreakpointByUrl", params);
    const marker = try idMarker(session.alloc, id);
    defer session.alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
}

fn pauseOn(session: *Session, box: *EvalBox) !usize {
    const mark = session.got.items.len;
    try session.spawn(box);
    try session.expect(try session.waitFrom(mark, "Debugger.paused", 80));
    return mark;
}

fn resumeSession(session: *Session) !void {
    const mark = session.got.items.len;
    _ = try session.command("Debugger.resume", "");
    try session.expect(try session.waitFrom(mark, "Debugger.resumed", 40));
    session.joinEval();
}

test "cdp: scriptParsed reports end position, hash, and source" {
    // V8 debugger/script-end-location.js, script-parsed-hash.js, script-unique-hash.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-script");
    defer session.deinit();

    const first = "var alpha = 1;\nvar beta = 2;\n//# sourceMappingURL=a.js.map\n";
    const second = "var alpha = 1;\nvar beta = 2;\nvar gamma = 3;\n";
    try enableDebugger(&session);
    const loaded = engine.evalScript(session.id, first, "a.js");
    defer if (loaded.result) |text| std.heap.c_allocator.free(text);
    defer if (loaded.err) |text| {
        if (loaded.err_is_heap) std.heap.c_allocator.free(text);
    };
    const loaded_b = engine.evalScript(session.id, second, "b.js");
    defer if (loaded_b.result) |text| std.heap.c_allocator.free(text);
    defer if (loaded_b.err) |text| {
        if (loaded_b.err_is_heap) std.heap.c_allocator.free(text);
    };
    try testing.expect(loaded.err == null and loaded_b.err == null);
    try session.expect(try session.wait("\"url\":\"a.js\"", 40));
    try session.expect(try session.wait("\"url\":\"b.js\"", 40));

    const a_at = std.mem.indexOf(u8, session.got.items, "\"url\":\"a.js\"") orelse return error.TestUnexpectedResult;
    const a_region = session.got.items[a_at..@min(session.got.items.len, a_at + 240)];
    try testing.expect(intAfter(a_region, "\"endLine\":") == 3);
    try testing.expect(std.mem.indexOf(u8, a_region, "a.js.map") != null);
    var expected: [16]u8 = undefined;
    fnvHash(first, &expected);
    try testing.expect(std.mem.indexOf(u8, a_region, &expected) != null);

    const b_at = std.mem.indexOf(u8, session.got.items, "\"url\":\"b.js\"") orelse return error.TestUnexpectedResult;
    const b_region = session.got.items[b_at..@min(session.got.items.len, b_at + 240)];
    fnvHash(second, &expected);
    try testing.expect(std.mem.indexOf(u8, b_region, &expected) != null);
    try testing.expect(intAfter(b_region, "\"endLine\":") == 3);

    const source_id = try session.command("Debugger.getScriptSource", "{\"scriptId\":\"1\"}");
    const marker = try idMarker(alloc, source_id);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 20));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "var alpha = 1;") != null);
}

test "cdp: a breakpoint set before the script resolves when it loads" {
    // Breakpoints applied to newly loaded scripts; set-breakpoint coverage.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-resolve");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "later.js", 1);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"locations\":[]") != null);

    var box = EvalBox{
        .id = session.id,
        .script = "var n = 1;\nn = 2;\nn\n",
        .filename = "later.js",
    };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "Debugger.breakpointResolved") != null);
    try testing.expect(intAfter(session.got.items, "\"lineNumber\":") == 1);
    try resumeSession(&session);
    try testing.expect(box.ok);
    try testing.expectEqualStrings("2", box.result);
}

test "cdp protocol: a source breakpoint pauses with the standard other reason" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-paused-reason");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "paused-reason.js", 1);
    var box = EvalBox{
        .id = session.id,
        .script = "var pausedReasonValue = 1;\npausedReasonValue = 2;\npausedReasonValue",
        .filename = "paused-reason.js",
    };
    defer box.deinit();
    const paused_at = try pauseOn(&session, &box);
    const paused = session.got.items[paused_at..];
    std.debug.print("PAUSED_REASON_EVENT={s}\n", .{paused});
    try testing.expect(std.mem.indexOf(u8, paused, "\"reason\":\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, paused, "\"callFrames\":[") != null);
    try resumeSession(&session);
    try testing.expect(box.ok);
}

test "cdp: removeBreakpoint lets the script finish" {
    // Remove a previously set breakpoint.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-remove");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "remove.js", 1);
    const removed = try session.command("Debugger.removeBreakpoint", "{\"breakpointId\":\"1\"}");
    const marker = try idMarker(alloc, removed);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 20));

    var box = EvalBox{
        .id = session.id,
        .script = "var n = 1;\nn = 2;\nn\n",
        .filename = "remove.js",
    };
    defer box.deinit();
    try session.spawn(&box);
    try session.expect(!try session.wait("Debugger.paused", 15));
    session.joinEval();
    try testing.expect(box.ok);
    try testing.expectEqualStrings("2", box.result);
}

test "cdp: removing one breakpoint at a line leaves the other" {
    // Multiple breakpoints at the same location; removing one leaves the others active.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-multi");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "multi.js", 1);
    try setBreakpoint(&session, "multi.js", 1);
    const removed = try session.command("Debugger.removeBreakpoint", "{\"breakpointId\":\"1\"}");
    const marker = try idMarker(alloc, removed);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 20));

    var box = EvalBox{
        .id = session.id,
        .script = "var n = 1;\nn = 2;\nn\n",
        .filename = "multi.js",
    };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    try resumeSession(&session);
    try testing.expectEqualStrings("2", box.result);
}

test "cdp: removeBreakpoint while paused does not resume" {
    // V8 debugger/remove-breakpoint-at-breakpoint.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-remove-paused");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "held.js", 1);
    var box = EvalBox{
        .id = session.id,
        .script = "var n = 1;\nn = 2;\nn\n",
        .filename = "held.js",
    };
    defer box.deinit();
    const paused_at = try pauseOn(&session, &box);
    const removed = try session.command("Debugger.removeBreakpoint", "{\"breakpointId\":\"1\"}");
    const marker = try idMarker(alloc, removed);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 20));
    try testing.expect(std.mem.indexOf(u8, session.got.items[paused_at..], "Debugger.resumed") == null);
    try testing.expect(debugger_mod.isPaused(session.id));
    try resumeSession(&session);

    var again = EvalBox{
        .id = session.id,
        .script = "var n = 1;\nn = 2;\nn\n",
        .filename = "held.js",
    };
    defer again.deinit();
    try session.spawn(&again);
    try session.expect(!try session.waitFrom(session.got.items.len, "Debugger.paused", 15));
    session.joinEval();
    try testing.expectEqualStrings("2", again.result);
}

test "cdp: a breakpoint on the last line hits" {
    // V8 debugger/set-breakpoint-at-last-line.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-last");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "last.js", 1);
    var box = EvalBox{
        .id = session.id,
        .script = "var n = 1;\nn = 2;",
        .filename = "last.js",
    };
    defer box.deinit();
    const mark = try pauseOn(&session, &box);
    try testing.expect(intAfter(session.got.items[mark..], "\"lineNumber\":") == 1);
    try resumeSession(&session);
    try testing.expectEqualStrings("2", box.result);
}

const step_script =
    \\function inner() {
    \\  var x = 1;
    \\  return x;
    \\}
    \\function outer() {
    \\  var y = inner();
    \\  return y;
    \\}
    \\outer()
;

test "cdp: stepOver stays in the caller" {
    // V8 debugger/step-over.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-step-over");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "step.js", 5);
    var box = EvalBox{ .id = session.id, .script = step_script, .filename = "step.js" };
    defer box.deinit();
    const first = try pauseOn(&session, &box);
    try testing.expect(std.mem.indexOf(u8, session.got.items[first..], "\"functionName\":\"outer\"") != null);
    const mark = session.got.items.len;
    _ = try session.command("Debugger.stepOver", "");
    try session.expect(try session.waitFrom(mark, "Debugger.paused", 80));
    const landed = session.got.items[mark..];
    const over_line = intAfter(landed, "\"lineNumber\":");
    try testing.expect(std.mem.indexOf(u8, landed, "\"functionName\":\"outer\"") != null);
    try testing.expect(over_line == 6);
    try testing.expect(std.mem.indexOf(u8, landed, "\"functionName\":\"inner\"") == null);
    try resumeSession(&session);
    try testing.expectEqualStrings("1", box.result);
}

test "cdp: stepInto enters the callee and stepOut returns" {
    // V8 debugger/step-into.js and debugger/step-into-out.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-step-into");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "into.js", 5);
    var box = EvalBox{ .id = session.id, .script = step_script, .filename = "into.js" };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    const into_at = session.got.items.len;
    _ = try session.command("Debugger.stepInto", "");
    try session.expect(try session.waitFrom(into_at, "Debugger.paused", 80));
    const into_line = intAfter(session.got.items[into_at..], "\"lineNumber\":");
    try testing.expect(std.mem.indexOf(u8, session.got.items[into_at..], "\"functionName\":\"inner\"") != null);
    // QuickJS reports the function header as well as the first statement.
    try testing.expect(into_line == 0 or into_line == 1);

    const out_at = session.got.items.len;
    _ = try session.command("Debugger.stepOut", "");
    try session.expect(try session.waitFrom(out_at, "Debugger.paused", 80));
    const out_line = intAfter(session.got.items[out_at..], "\"lineNumber\":");
    try testing.expect(std.mem.indexOf(u8, session.got.items[out_at..], "\"functionName\":\"outer\"") != null);
    try testing.expect(out_line == 6);
    try resumeSession(&session);
    try testing.expectEqualStrings("1", box.result);
}

const throw_script =
    \\function boom() {
    \\  throw new Error("x");
    \\}
    \\function caller() {
    \\  var n = 0;
    \\  try {
    \\    boom();
    \\  } catch (e) {
    \\    n = 5;
    \\  }
    \\  return n;
    \\}
    \\caller()
;

test "cdp: stepOver moves past a caught throw" {
    // Step over a throwing call.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-step-throw");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "throw.js", 6);
    var box = EvalBox{ .id = session.id, .script = throw_script, .filename = "throw.js" };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    const mark = session.got.items.len;
    _ = try session.command("Debugger.stepOver", "");
    try session.expect(try session.waitFrom(mark, "Debugger.paused", 80));
    const landed = session.got.items[mark..];
    const line = intAfter(landed, "\"lineNumber\":") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, landed, "\"functionName\":\"caller\"") != null);
    try testing.expect(line > 6);
    try resumeSession(&session);
    try testing.expectEqualStrings("5", box.result);
}

test "cdp: setPauseOnExceptions distinguishes none, uncaught, and all" {
    // V8 debugger/caught-uncaught-exceptions.js and debugger/break-on-exception.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-exceptions");
    defer session.deinit();
    try enableDebugger(&session);

    try waitCommand(&session, try session.command("Debugger.setPauseOnExceptions", "{\"state\":\"none\"}"));
    var ignored = EvalBox{ .id = session.id, .script = "throw 1", .filename = "none.js" };
    defer ignored.deinit();
    try session.spawn(&ignored);
    try session.expect(!try session.wait("Debugger.paused", 15));
    session.joinEval();
    try testing.expect(!ignored.ok);

    try waitCommand(&session, try session.command("Debugger.setPauseOnExceptions", "{\"state\":\"uncaught\"}"));
    var caught = EvalBox{ .id = session.id, .script = "try { throw 1 } catch (e) { 3 }", .filename = "caught.js" };
    defer caught.deinit();
    try session.spawn(&caught);
    try session.expect(!try session.waitFrom(session.got.items.len, "Debugger.paused", 15));
    session.joinEval();
    try testing.expectEqualStrings("3", caught.result);

    var uncaught = EvalBox{ .id = session.id, .script = "throw 1", .filename = "uncaught.js" };
    defer uncaught.deinit();
    const uncaught_at = try pauseOn(&session, &uncaught);
    try testing.expect(std.mem.indexOf(u8, session.got.items[uncaught_at..], "\"reason\":\"exception\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items[uncaught_at..], "\"url\":\"uncaught.js\"") != null);
    try resumeSession(&session);
    try testing.expect(!uncaught.ok);

    try waitCommand(&session, try session.command("Debugger.setPauseOnExceptions", "{\"state\":\"all\"}"));
    var both = EvalBox{ .id = session.id, .script = "try { throw 1 } catch (e) { 4 }", .filename = "all.js" };
    defer both.deinit();
    const all_at = try pauseOn(&session, &both);
    try testing.expect(std.mem.indexOf(u8, session.got.items[all_at..], "\"reason\":\"exception\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items[all_at..], "\"url\":\"all.js\"") != null);
    try resumeSession(&session);
    try testing.expectEqualStrings("4", both.result);
}

const closure_script =
    \\function outer() {
    \\  var secret = 7;
    \\  function inner() {
    \\    var n = secret + 1;
    \\    return n;
    \\  }
    \\  return inner();
    \\}
    \\outer()
;

test "cdp: evaluateOnCallFrame reads a local and its closure" {
    // V8 debugger/evaluate-on-call-frame.js and debugger/scope-chain-outer-scopes.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-closure");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "closure.js", 4);
    var box = EvalBox{ .id = session.id, .script = closure_script, .filename = "closure.js" };
    defer box.deinit();
    const mark = try pauseOn(&session, &box);
    const paused = session.got.items[mark..];
    const name_at = std.mem.indexOf(u8, paused, "\"functionName\":\"inner\"") orelse return error.TestUnexpectedResult;
    const frame = paused[name_at..];
    const local_at = std.mem.indexOf(u8, frame, "\"type\":\"local\"") orelse return error.TestUnexpectedResult;
    const closure_at = std.mem.indexOf(u8, frame, "\"type\":\"closure\"") orelse return error.TestUnexpectedResult;
    const global_at = std.mem.indexOf(u8, frame, "\"type\":\"global\"") orelse return error.TestUnexpectedResult;
    try testing.expect(local_at < closure_at and closure_at < global_at);

    const local_id = quoteAfter(frame[local_at..], "\"objectId\":") orelse return error.TestUnexpectedResult;
    const props_params = try std.fmt.allocPrint(alloc, "{{\"objectId\":\"{s}\"}}", .{local_id});
    defer alloc.free(props_params);
    const props_id = try session.command("Runtime.getProperties", props_params);
    const props_marker = try idMarker(alloc, props_id);
    defer alloc.free(props_marker);
    try session.expect(try session.wait(props_marker, 40));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"name\":\"n\"") != null);

    const n_id = try session.command("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"n\"}");
    const secret_id = try session.command("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"secret\"}");
    const n_marker = try idMarker(alloc, n_id);
    defer alloc.free(n_marker);
    const secret_marker = try idMarker(alloc, secret_id);
    defer alloc.free(secret_marker);
    try session.expect(try session.wait(n_marker, 40));
    try session.expect(try session.wait(secret_marker, 40));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"value\":8") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"value\":7") != null);
    try resumeSession(&session);
    try testing.expectEqualStrings("8", box.result);
}

const method_script =
    \\function Box(v) {
    \\  this.v = v;
    \\}
    \\Box.prototype.method = function () {
    \\  return this.v;
    \\};
    \\var box = new Box(3);
    \\box.method();
;

test "cdp: evaluateOnCallFrame sees the receiver as this" {
    // Evaluate on call frame with a typed `this`.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-this");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "method.js", 4);
    var box = EvalBox{ .id = session.id, .script = method_script, .filename = "method.js" };
    defer box.deinit();
    const mark = try pauseOn(&session, &box);
    const paused = session.got.items[mark..];
    const this_at = std.mem.indexOf(u8, paused, "\"this\":") orelse return error.TestUnexpectedResult;
    const this_id = quoteAfter(paused[this_at..], "\"objectId\":") orelse return error.TestUnexpectedResult;
    const props_params = try std.fmt.allocPrint(alloc, "{{\"objectId\":\"{s}\"}}", .{this_id});
    defer alloc.free(props_params);
    const props_id = try session.command("Runtime.getProperties", props_params);
    const props_marker = try idMarker(alloc, props_id);
    defer alloc.free(props_marker);
    try session.expect(try session.wait(props_marker, 40));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"name\":\"v\"") != null);
    const id = try session.command("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"this.v\"}");
    const marker = try idMarker(alloc, id);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"value\":3") != null);
    try resumeSession(&session);
    try testing.expectEqualStrings("3", box.result);
}

test "cdp: Runtime.evaluate while paused does not see locals" {
    // Runtime.evaluate while the debugger is paused.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-paused-eval");
    defer session.deinit();
    try enableDebugger(&session);
    try setBreakpoint(&session, "paused-eval.js", 2);
    var box = EvalBox{
        .id = session.id,
        .script = "function f() {\n  var n = 42;\n  return n;\n}\nf()\n",
        .filename = "paused-eval.js",
    };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    const local_id = try session.command("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"n\"}");
    const global_id = try session.command("Runtime.evaluate", "{\"expression\":\"typeof n\"}");
    const sum_id = try session.command("Runtime.evaluate", "{\"expression\":\"1+1\"}");
    const local_marker = try idMarker(alloc, local_id);
    defer alloc.free(local_marker);
    const global_marker = try idMarker(alloc, global_id);
    defer alloc.free(global_marker);
    const sum_marker = try idMarker(alloc, sum_id);
    defer alloc.free(sum_marker);
    try session.expect(try session.wait(local_marker, 40));
    try session.expect(try session.wait(global_marker, 40));
    try session.expect(try session.wait(sum_marker, 40));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"value\":42") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"value\":\"undefined\"") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"value\":2") != null);
    try resumeSession(&session);
}

test "cdp: Debugger.pause stops a running loop" {
    // Async Debugger.pause while a script is running. A fixed trip count can finish before Debugger.pause is observed. Grow the loop until a pause lands. If this attempt is abandoned, resume first so join cannot sit in enterPause.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-pause-now");
    defer session.deinit();
    try enableDebugger(&session);
    var limit: usize = 2_000_000;
    while (limit <= 512_000_000) : (limit *= 4) {
        var script_buf: [96]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf, "var n = 0;\nwhile (n < {d}) n++;\nn\n", .{limit}) catch unreachable;
        var box = EvalBox{
            .id = session.id,
            .script = script,
            .filename = "loop.js",
        };
        defer box.deinit();
        const mark = session.got.items.len;
        try session.spawn(&box);
        io.sleepMs(5);
        if (box.ok) {
            session.joinEval();
            continue;
        }
        _ = try session.command("Debugger.pause", "");
        const paused = try session.waitFrom(mark, "\"reason\":\"other\"", 200);
        if (!paused) {
            debugger_mod.resumeExecution(session.id);
            session.joinEval();
            if (box.ok) continue;
            try session.expect(false);
        }
        try resumeSession(&session);
        var expect_buf: [32]u8 = undefined;
        const expect_text = std.fmt.bufPrint(&expect_buf, "{d}", .{limit}) catch unreachable;
        try testing.expectEqualStrings(expect_text, box.result);
        return;
    }
    return error.LoopFinishedBeforePause;
}

test "cdp: Runtime.enable reports the default execution context" {
    // V8 runtime/create-context.js.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-context");
    defer session.deinit();
    const id = try session.command("Runtime.enable", "");
    const marker = try idMarker(alloc, id);
    defer alloc.free(marker);
    try session.expect(try session.wait("Runtime.executionContextCreated", 40));
    try session.expect(try session.wait(marker, 20));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"isDefault\":true") != null);
}

test "cdp: console methods map onto consoleAPICalled types" {
    // Runtime console method coverage.
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-console");
    defer session.deinit();
    const id = try session.command("Runtime.enable", "");
    const marker = try idMarker(alloc, id);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
    const ran = engine.evalScript(session.id, "console.log('L'); console.warn('W'); console.error('E'); 1", "console.js");
    defer if (ran.result) |text| std.heap.c_allocator.free(text);
    defer if (ran.err) |text| {
        if (ran.err_is_heap) std.heap.c_allocator.free(text);
    };
    _ = dispatch.tickInstance(session.id);
    try session.expect(try session.wait("\"type\":\"log\"", 40));
    try session.expect(try session.wait("\"type\":\"warning\"", 20));
    try session.expect(try session.wait("\"type\":\"error\"", 20));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "L") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "W") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "E") != null);
}

test "cdp: debugger statement pauses" {
    // V8 debugger/debugger-statement.js. reason is "other".
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-stmt");
    defer session.deinit();
    try enableDebugger(&session);
    var box = EvalBox{
        .id = session.id,
        .script = "var n = 1;\ndebugger;\nn = 2;\nn\n",
        .filename = "dbg.js",
    };
    defer box.deinit();
    const mark = try pauseOn(&session, &box);
    const paused = session.got.items[mark..];
    try testing.expect(std.mem.indexOf(u8, paused, "\"reason\":\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, paused, "\"url\":\"dbg.js\"") != null);
    try testing.expect(std.mem.indexOf(u8, paused, "\"lineNumber\":1") != null);
    try resumeSession(&session);
    try testing.expectEqualStrings("2", box.result);
}

test "cdp: disconnecting the last Debugger session disables debugger statements" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-disconnect");
    defer session.deinit();
    try enableDebugger(&session);
    try testing.expect(debugger_mod.debuggerStatementsEnabled(session.id));

    session.stream.close();
    var spins: usize = 0;
    while (spins < 100 and inspector_state.hasEnabledDebuggerSession(inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing)) : (spins += 1) {
        io.sleepMs(5);
    }
    try testing.expect(!inspector_state.hasEnabledDebuggerSession(inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing));
    try testing.expect(!debugger_mod.debuggerStatementsEnabled(session.id));
}

test "cdp: disconnecting the last Debugger session resumes a paused evaluation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-disconnect-paused");
    defer session.deinit();
    try enableDebugger(&session);

    var box = EvalBox{
        .id = session.id,
        .script = "debugger; 42;",
        .filename = "disconnect-paused.js",
    };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    try testing.expect(debugger_mod.isPaused(session.id));

    session.stream.close();
    var spins: usize = 0;
    while (spins < 100 and inspector_state.hasEnabledDebuggerSession(inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing)) : (spins += 1) {
        io.sleepMs(5);
    }
    try testing.expect(!inspector_state.hasEnabledDebuggerSession(inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing));
    try testing.expect(!debugger_mod.isPaused(session.id));
    session.joinEval();
    try testing.expectEqualStrings("42", box.result);
}

test "cdp: Debugger.enable does not install QuickJS handlers on the reader thread" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const creation_thread_id: u64 = @intCast(std.Thread.getCurrentId());
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-handler-thread");
    defer session.deinit();
    try enableDebugger(&session);
    try testing.expect(debugger_mod.debuggerStatementsEnabled(session.id));
    try testing.expectEqual(creation_thread_id, debugger_mod.handlerInstallThreadId(session.id));
}

test "cdp: disabling the last Debugger session resumes a paused evaluation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-disable-paused");
    defer session.deinit();
    try enableDebugger(&session);

    var box = EvalBox{
        .id = session.id,
        .script = "debugger; 42;",
        .filename = "disable-paused.js",
    };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    try testing.expect(debugger_mod.isPaused(session.id));

    const disabled = try session.command("Debugger.disable", "");
    try waitCommand(&session, disabled);
    try testing.expect(!debugger_mod.isPaused(session.id));
    session.joinEval();
    try testing.expectEqualStrings("42", box.result);
}

test "cdp: external stop resumes a paused Runtime.evaluate task before waiting for its lease" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-stop-runtime-evaluate-paused");
    var stop_probe = StopProbe{ .handle = session.handle };
    var stop_thread: ?std.Thread = null;
    var stop_started = false;
    var pump_probe = PumpProbe{ .id = session.id };
    var pump_thread: ?std.Thread = null;
    defer {
        if (stop_thread) |thread| {
            if (!stop_probe.done.load(.seq_cst)) debugger_mod.resumeExecution(session.id);
            thread.join();
        }
        pump_probe.stop.store(true, .seq_cst);
        if (pump_thread) |thread| thread.join();
        if (!stop_started) inspector.stop(session.handle);
        session.stream.close();
        engine.destroy(session.id);
        session.got.deinit(alloc);
    }

    try enableDebugger(&session);
    pump_thread = try std.Thread.spawn(.{}, PumpProbe.run, .{&pump_probe});
    const mark = session.got.items.len;
    _ = try session.command("Runtime.evaluate", "{\"expression\":\"debugger; 42\"}");
    try session.expect(try session.waitFrom(mark, "Debugger.paused", 80));
    try testing.expect(debugger_mod.isPaused(session.id));

    stop_thread = try std.Thread.spawn(.{}, StopProbe.run, .{&stop_probe});
    stop_started = true;
    var spins: usize = 0;
    while (spins < 100 and !stop_probe.done.load(.seq_cst)) : (spins += 1) io.sleepMs(5);
    const stopped_without_resume = stop_probe.done.load(.seq_cst);
    if (!stopped_without_resume) debugger_mod.resumeExecution(session.id);
    stop_thread.?.join();
    stop_thread = null;
    try testing.expect(stopped_without_resume);
}

test "cdp: Runtime.evaluate can stop its inspector from a native host callback" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-reentrant-stop-host-callback");
    var host = ReentrantStopHost{ .handle = session.handle };
    var pump = PumpProbe{ .id = session.id };
    var pump_thread: ?std.Thread = null;
    defer {
        pump.stop.store(true, .seq_cst);
        if (pump_thread) |thread| thread.join();
        session.deinit();
    }

    try testing.expect(engine_thread.hostInstall(
        session.id,
        "stopInspectorFromHost",
        ReentrantStopHost.call,
        @ptrCast(&host),
    ));
    pump_thread = try std.Thread.spawn(.{}, PumpProbe.run, .{&pump});
    var spins: usize = 0;
    while (spins < 100 and pump.thread_id.load(.seq_cst) == 0) : (spins += 1) io.sleepMs(1);
    try testing.expect(pump.thread_id.load(.seq_cst) != 0);

    const response_start = session.got.items.len;
    const request_id = try session.command(
        "Runtime.evaluate",
        "{\"expression\":\"stopInspectorFromHost(); 42\"}",
    );
    try session.expect(try session.waitResponseId(response_start, request_id, 200));
    try testing.expect(host.called.load(.seq_cst));
    try testing.expectEqual(pump.thread_id.load(.seq_cst), host.callback_thread_id.load(.seq_cst));
    var cleanup_polls: usize = 0;
    while (inspector_state.stateByInstance(session.id) != null and cleanup_polls < 5_000) : (cleanup_polls += 1) io.sleepMs(1);
    try testing.expect(inspector_state.stateByInstance(session.id) == null);
    var buf: [64]u8 = undefined;
    var closed = false;
    var close_polls: usize = 0;
    while (close_polls < 100 and !closed) : (close_polls += 1) {
        const n = session.stream.read(&buf) catch 0;
        closed = n == 0;
        if (!closed) io.sleepMs(10);
    }
    try testing.expect(closed);
}

fn runReentrantStopDestroy(start_engine_thread: bool, target_id: []const u8) !void {
    const alloc = testing.allocator;
    var session = try openSession(alloc, target_id);
    var host = ReentrantDestroyHost{ .handle = session.handle, .instance_id = session.id };
    var pump = PumpProbe{ .id = session.id };
    var pump_thread: ?std.Thread = null;
    defer {
        pump.stop.store(true, .seq_cst);
        if (pump_thread) |thread| thread.join();
        session.deinit();
    }

    try testing.expect(engine_thread.hostInstall(
        session.id,
        "stopAndDestroyFromHost",
        ReentrantDestroyHost.call,
        @ptrCast(&host),
    ));
    if (start_engine_thread) {
        try testing.expect(engine_thread.threadStart(session.id));
        var spins: usize = 0;
        while (engine_thread.threadId(session.id) == 0 and spins < 10_000) : (spins += 1) std.Thread.yield() catch {};
        try testing.expect(engine_thread.threadId(session.id) != 0);
    } else {
        pump_thread = try std.Thread.spawn(.{}, PumpProbe.run, .{&pump});
        var spins: usize = 0;
        while (pump.thread_id.load(.seq_cst) == 0 and spins < 10_000) : (spins += 1) std.Thread.yield() catch {};
        try testing.expect(pump.thread_id.load(.seq_cst) != 0);
    }

    const response_start = session.got.items.len;
    const request_id = try session.command(
        "Runtime.evaluate",
        "{\"expression\":\"stopAndDestroyFromHost(); 42\"}",
    );
    try session.expect(try session.waitResponseId(response_start, request_id, 200));
    try testing.expect(host.called.load(.seq_cst));
    var spins: usize = 0;
    while (inspector_state.stateByInstance(session.id) != null and spins < 5_000) : (spins += 1) io.sleepMs(1);
    try testing.expect(inspector_state.stateByInstance(session.id) == null);
    if (!start_engine_thread) {
        pump.stop.store(true, .seq_cst);
        if (pump_thread) |thread| thread.join();
        pump_thread = null;
        _ = dispatch.tickInstance(session.id);
    } else {
        spins = 0;
        while (engine.getContext(session.id) != null and spins < 5_000) : (spins += 1) io.sleepMs(1);
    }
    try testing.expect(engine.getContext(session.id) == null);
}

test "CDP Runtime.evaluate can stop and destroy from a host callback without a worker" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try runReentrantStopDestroy(false, "cdp-reentrant-stop-destroy-main");
}

test "CDP Runtime.evaluate can stop and destroy from a host callback on the worker" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try runReentrantStopDestroy(true, "cdp-reentrant-stop-destroy-worker");
}

test "inspector.stop from a foreign thread retires JS values until the owner enters again" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "retired-stop-owner-entry" });
    const state = inspector_state.stateByInstance(id) orelse return error.InspectorStateMissing;
    const owner_thread_id = state.engine_thread_id.load(.seq_cst);
    try testing.expectEqual(@as(u64, @intCast(std.Thread.getCurrentId())), owner_thread_id);
    const stream = try wire.connect(inspector.boundPort(handle));
    try wire.doWsHandshake(testing.allocator, stream, "retired-stop-owner-entry");
    defer stream.close();

    var stop_probe = StopProbe{ .handle = handle };
    const stop_thread = try std.Thread.spawn(.{}, StopProbe.run, .{&stop_probe});
    stop_thread.join();
    try testing.expect(stop_probe.done.load(.seq_cst));
    try testing.expectEqual(@as(usize, 1), inspector_state.retiredStateCount(id));

    var buf: [64]u8 = undefined;
    var closed = false;
    var close_polls: usize = 0;
    while (close_polls < 100 and !closed) : (close_polls += 1) {
        const n = stream.read(&buf) catch 0;
        closed = n == 0;
        if (!closed) io.sleepMs(10);
    }
    try testing.expect(closed);

    const result = engine.evalScript(id, "6 * 7", "retired-stop.js");
    defer if (result.result) |text| std.heap.c_allocator.free(text);
    try testing.expect(result.err == null);
    try testing.expectEqual(@as(usize, 0), inspector_state.retiredStateCount(id));
    engine.destroy(id);
}

test "foreign stop automatically drains retired values on an idle engine owner" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "idle-owner-stop-drain" });
    try testing.expect(engine_thread.threadStart(id));
    defer engine_thread.threadStop(id);
    var spins: usize = 0;
    while (engine_thread.threadId(id) == 0 and spins < 10_000) : (spins += 1) std.Thread.yield() catch {};
    try testing.expect(engine_thread.threadId(id) != 0);

    inspector.stop(handle);
    spins = 0;
    while (inspector_state.retiredStateCount(id) != 0 and spins < 10_000) : (spins += 1) std.Thread.yield() catch {};
    try testing.expectEqual(@as(usize, 0), inspector_state.retiredStateCount(id));
}

test "engine destroy takes ownership of retired inspector values before freeing the context" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "retired-stop-destroy" });
    const state = inspector_state.stateByInstance(id) orelse return error.InspectorStateMissing;
    try testing.expectEqual(@as(u64, @intCast(std.Thread.getCurrentId())), state.engine_thread_id.load(.seq_cst));

    var stop_probe = StopProbe{ .handle = handle };
    const stop_thread = try std.Thread.spawn(.{}, StopProbe.run, .{&stop_probe});
    stop_thread.join();
    try testing.expect(stop_probe.done.load(.seq_cst));
    try testing.expectEqual(@as(usize, 1), inspector_state.retiredStateCount(id));

    engine.destroy(id);
    try testing.expectEqual(@as(usize, 0), inspector_state.retiredStateCount(id));
}

test "cdp: disabling Debugger in one session keeps another session enabled" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var first = try openSession(alloc, "cdp-debugger-multisession");
    defer first.deinit();

    const peer_stream = try wire.connect(inspector.boundPort(first.handle));
    errdefer peer_stream.close();
    try wire.doWsHandshake(alloc, peer_stream, "cdp-debugger-multisession");
    var peer = Session{
        .alloc = alloc,
        .id = first.id,
        .handle = first.handle,
        .stream = peer_stream,
        .reader = wire.FrameReader.init(peer_stream),
        .got = .empty,
    };
    defer {
        peer.reader.deinit(alloc);
        peer.stream.close();
        peer.got.deinit(alloc);
    }

    try enableDebugger(&first);
    try enableDebugger(&peer);
    const disabled = try first.command("Debugger.disable", "");
    try waitCommand(&first, disabled);

    var box = EvalBox{
        .id = first.id,
        .script = "debugger; 42;",
        .filename = "multi-session.js",
    };
    defer box.deinit();
    try peer.spawn(&box);
    try peer.expect(try peer.wait("Debugger.paused", 80));
    try resumeSession(&peer);
    try testing.expectEqualStrings("42", box.result);
}

test "cdp: breakpoint column moves to the first breakable column" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-column");
    defer session.deinit();
    try enableDebugger(&session);
    var box = EvalBox{ .id = session.id, .script = "    var a = 1;\n", .filename = "indent.js" };
    defer box.deinit();
    try session.spawn(&box);
    try session.expect(try session.wait("\"url\":\"indent.js\"", 40));
    session.joinEval();
    const id = try session.command("Debugger.setBreakpointByUrl", "{\"url\":\"indent.js\",\"lineNumber\":0,\"columnNumber\":0}");
    const marker = try idMarker(alloc, id);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"columnNumber\":4") != null);
}

test "cdp: urlRegex breakpoint hits a matching script" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-regex");
    defer session.deinit();
    try enableDebugger(&session);
    const id = try session.command("Debugger.setBreakpointByUrl", "{\"urlRegex\":\"rx\\\\.js$\",\"lineNumber\":0}");
    const marker = try idMarker(alloc, id);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
    var box = EvalBox{ .id = session.id, .script = "var a = 1;\na\n", .filename = "rx.js" };
    defer box.deinit();
    _ = try pauseOn(&session, &box);
    try testing.expect(std.mem.indexOf(u8, session.got.items, "\"url\":\"rx.js\"") != null);
    try resumeSession(&session);
    try testing.expectEqualStrings("1", box.result);
}

test "cdp: conditional breakpoint pauses only when the condition is true" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-cond");
    defer session.deinit();
    try enableDebugger(&session);
    const id = try session.command("Debugger.setBreakpointByUrl", "{\"url\":\"cond.js\",\"lineNumber\":1,\"condition\":\"n > 10\"}");
    const marker = try idMarker(alloc, id);
    defer alloc.free(marker);
    try session.expect(try session.wait(marker, 40));
    var skip = EvalBox{ .id = session.id, .script = "var n = 1;\nn = 2;\nn\n", .filename = "cond.js" };
    defer skip.deinit();
    try session.spawn(&skip);
    try session.expect(!try session.waitFrom(session.got.items.len, "Debugger.paused", 20));
    session.joinEval();
    try testing.expectEqualStrings("2", skip.result);

    const again = try session.command("Debugger.setBreakpointByUrl", "{\"url\":\"cond.js\",\"lineNumber\":1,\"condition\":\"n > 0\"}");
    const again_marker = try idMarker(alloc, again);
    defer alloc.free(again_marker);
    try session.expect(try session.wait(again_marker, 40));
    var hit = EvalBox{ .id = session.id, .script = "var n = 1;\nn = 2;\nn\n", .filename = "cond.js" };
    defer hit.deinit();
    _ = try pauseOn(&session, &hit);
    try resumeSession(&session);
    try testing.expectEqualStrings("2", hit.result);
}

test "cdp: blackbox patterns skip pauses in matching scripts" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-blackbox");
    defer session.deinit();
    try enableDebugger(&session);
    const black = try session.command("Debugger.setBlackboxPatterns", "{\"patterns\":[\"blk\\\\.js\"]}");
    const black_marker = try idMarker(alloc, black);
    defer alloc.free(black_marker);
    try session.expect(try session.wait(black_marker, 40));
    try setBreakpoint(&session, "blk.js", 0);
    var hidden = EvalBox{ .id = session.id, .script = "var a = 1;\na\n", .filename = "blk.js" };
    defer hidden.deinit();
    try session.spawn(&hidden);
    try session.expect(!try session.waitFrom(session.got.items.len, "Debugger.paused", 20));
    session.joinEval();
    try testing.expectEqualStrings("1", hidden.result);

    try setBreakpoint(&session, "ok.js", 0);
    var shown = EvalBox{ .id = session.id, .script = "var a = 2;\na\n", .filename = "ok.js" };
    defer shown.deinit();
    _ = try pauseOn(&session, &shown);
    try resumeSession(&session);
    try testing.expectEqualStrings("2", shown.result);
}
