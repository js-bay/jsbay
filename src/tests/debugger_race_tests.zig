//! CDP debugger commands must not resurrect native hooks from the transport reader, run a dead session's queued enable, or lose configuration that arrives beside a first enable request.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const inspector_state = @import("../inspector/root.zig").state;
const helpers = @import("test_helpers.zig");
const wire = @import("inspector_tests.zig");

const Session = struct {
    alloc: std.mem.Allocator,
    id: i32,
    handle: *inspector.Handle,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    got: std.ArrayList(u8) = .empty,
    owns_instance: bool = true,

    fn deinit(self: *Session) void {
        self.got.deinit(self.alloc);
        self.reader.deinit(self.alloc);
        self.stream.close();
        if (self.owns_instance) {
            inspector.stop(self.handle);
            engine.destroy(self.id);
        }
    }
};

const EvalProbe = struct {
    id: i32,
    result: @import("../types.zig").EvalResult = .{},

    fn run(self: *EvalProbe) void {
        self.result = engine.evalScript(self.id, "globalThis.__debuggerBatch = 1;", "debugger-batch.js");
    }

    fn deinit(self: *EvalProbe) void {
        if (self.result.result) |value| std.heap.c_allocator.free(value);
        if (self.result.err) |value| if (self.result.err_is_heap) std.heap.c_allocator.free(value);
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
    };
}

fn openAdditionalSession(alloc: std.mem.Allocator, primary: *const Session, target_id: []const u8) !Session {
    const stream = try wire.connect(inspector.boundPort(primary.handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{
        .alloc = alloc,
        .id = primary.id,
        .handle = primary.handle,
        .stream = stream,
        .reader = wire.FrameReader.init(stream),
        .owns_instance = false,
    };
}

fn send(session: *Session, method: []const u8, params: []const u8, id: i64) !usize {
    const before = session.got.items.len;
    const text = if (params.len == 0)
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\"}}", .{ id, method })
    else
        try std.fmt.allocPrint(session.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
    defer session.alloc.free(text);
    try wire.writeMaskedText(session.stream, text);
    return before;
}

fn responseReceivedWithoutTick(session: *Session, from: usize, id: i64) !bool {
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, from, id)) return true;
    }
    return false;
}

fn pumpResponse(session: *Session, from: usize, id: i64) ![]const u8 {
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, from, id)) return session.got.items[from..];
    }
    std.debug.print("missing CDP response {d}:\n{s}\n", .{ id, session.got.items });
    return error.TestUnexpectedResult;
}

fn responseIsSuccess(payload: []const u8, id: i64) bool {
    var marker: [32]u8 = undefined;
    const expected = std.fmt.bufPrint(&marker, "\"id\":{d},\"result\":", .{id}) catch return false;
    return std.mem.indexOf(u8, payload, expected) != null;
}

fn waitForSessionCount(state: *inspector_state.InspectorState, expected: usize) !void {
    var tries: usize = 0;
    while (tries < 10_000) : (tries += 1) {
        if (inspector_state.sessionCount(state) == expected) return;
        std.Thread.yield() catch {};
    }
    return error.TestUnexpectedResult;
}

fn disconnect(session: *Session) void {
    session.reader.deinit(session.alloc);
    session.stream.close();
    session.stream.handle = -1;
}

fn reconnect(session: *Session, target_id: []const u8) !void {
    session.stream = try wire.connect(inspector.boundPort(session.handle));
    try wire.doWsHandshake(session.alloc, session.stream, target_id);
    session.reader = wire.FrameReader.init(session.stream);
}

test "cold debugger configuration never arms handlers on the reader thread" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-reader-reader-rearm");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    const enable_at = try send(&session, "Debugger.enable", "", 6101);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 6101), 6101));
    try testing.expect(debugger_mod.handlerInstallThreadId(session.id) != 0);

    disconnect(&session);
    try waitForSessionCount(state, 0);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(session.id));

    try reconnect(&session, "debugger-reader-reader-rearm");
    const configure_at = try send(&session, "Debugger.setPauseOnExceptions", "{\"state\":\"all\"}", 6102);
    try testing.expect(try responseReceivedWithoutTick(&session, configure_at, 6102));
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(session.id));
}

test "queued enable cannot attach after its session closes" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-queued-queued-enable-close");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    _ = try send(&session, "Debugger.enable", "", 6201);
    // The reader answers Runtime.getIsolateId directly. Its response proves the earlier enable was admitted before we inspect the owner-task count.
    const barrier_at = try send(&session, "Runtime.getIsolateId", "", 6203);
    try testing.expect(try responseReceivedWithoutTick(&session, barrier_at, 6203));
    try testing.expect(responseIsSuccess(session.got.items[barrier_at..], 6203));
    try testing.expect(inspector_state.hasInspectorTasks(state));
    disconnect(&session);
    try waitForSessionCount(state, 0);

    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(session.id));
    try testing.expect(!inspector_state.hasEnabledDebuggerSession(state));

    try reconnect(&session, "debugger-queued-queued-enable-close");
    const second_enable = try send(&session, "Debugger.enable", "", 6202);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, second_enable, 6202), 6202));
    try testing.expect(debugger_mod.handlerInstallThreadId(session.id) != 0);

    const scripts_from = session.got.items.len;
    const result = engine.evalScript(session.id, "globalThis.__debuggerQueued = 1;", "debugger-queued-reconnected.js");
    defer if (result.result) |value| std.heap.c_allocator.free(value);
    defer if (result.err) |value| if (result.err_is_heap) std.heap.c_allocator.free(value);
    try testing.expect(result.err == null);
    var saw_script = false;
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[scripts_from..], "Debugger.scriptParsed") != null) {
            saw_script = true;
            break;
        }
    }
    try testing.expect(saw_script);
}

test "breakpoint queued beside first enable survives owner admission" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-batch-first-enable-batch");
    defer session.deinit();

    const enable_at = try send(&session, "Debugger.enable", "", 6301);
    const breakpoint_at = try send(&session, "Debugger.setBreakpointByUrl", "{\"url\":\"debugger-batch.js\",\"lineNumber\":0}", 6302);
    // The reader must retain this configuration even though the first enable has not reached its owner task yet. A rejected response here means the command was applied against a nonexistent binding and is lost forever.
    try testing.expect(try responseReceivedWithoutTick(&session, breakpoint_at, 6302));
    try testing.expect(responseIsSuccess(session.got.items[breakpoint_at..], 6302));
    const enable_response = try pumpResponse(&session, enable_at, 6301);
    try testing.expect(responseIsSuccess(enable_response, 6301));

    var eval_probe: EvalProbe = .{ .id = session.id };
    defer eval_probe.deinit();
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&eval_probe});
    const paused_from = session.got.items.len;
    var saw_pause = false;
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[paused_from..], "Debugger.paused") != null) {
            saw_pause = true;
            break;
        }
    }
    const resume_at = try send(&session, "Debugger.resume", "", 6303);
    try testing.expect(try responseReceivedWithoutTick(&session, resume_at, 6303));
    eval_thread.join();
    try testing.expect(saw_pause);
    try testing.expect(eval_probe.result.err == null);
}

test "reader-thread configuration is cold again after its session disconnects" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-reader-disconnect-cold");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    const enable_at = try send(&session, "Debugger.enable", "", 6111);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 6111), 6111));
    disconnect(&session);
    try waitForSessionCount(state, 0);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(session.id));

    try reconnect(&session, "debugger-reader-disconnect-cold");
    const configure_at = try send(&session, "Debugger.setPauseOnExceptions", "{\"state\":\"all\"}", 6112);
    try testing.expect(try responseReceivedWithoutTick(&session, configure_at, 6112));
    disconnect(&session);
    try waitForSessionCount(state, 0);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);

    const result = engine.evalScript(session.id, "globalThis.__debuggerReader = 1;", "debugger-reader-after-disconnect.js");
    defer if (result.result) |value| std.heap.c_allocator.free(value);
    defer if (result.err) |value| if (result.err_is_heap) std.heap.c_allocator.free(value);
    try testing.expect(result.err == null);
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(session.id));
    try testing.expectEqual(@as(u32, 0), debugger_mod.scriptIdForUrl(session.id, "debugger-reader-after-disconnect.js"));
}

test "exception mode beside first enable pauses after owner admission" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-batch-exception-batch");
    defer session.deinit();

    const enable_at = try send(&session, "Debugger.enable", "", 6311);
    const mode_at = try send(&session, "Debugger.setPauseOnExceptions", "{\"state\":\"all\"}", 6312);
    try testing.expect(try responseReceivedWithoutTick(&session, mode_at, 6312));
    try testing.expect(responseIsSuccess(session.got.items[mode_at..], 6312));
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 6311), 6311));

    const ExceptionProbe = struct {
        id: i32,
        result: @import("../types.zig").EvalResult = .{},

        fn run(self: *@This()) void {
            self.result = engine.evalScript(self.id, "throw new Error('debugger-batch-exception');", "debugger-batch-exception.js");
        }

        fn deinit(self: *@This()) void {
            if (self.result.result) |value| std.heap.c_allocator.free(value);
            if (self.result.err) |value| if (self.result.err_is_heap) std.heap.c_allocator.free(value);
        }
    };
    var probe: ExceptionProbe = .{ .id = session.id };
    defer probe.deinit();
    const eval_thread = try std.Thread.spawn(.{}, ExceptionProbe.run, .{&probe});
    const paused_from = session.got.items.len;
    var saw_pause = false;
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[paused_from..], "Debugger.paused") != null) {
            saw_pause = true;
            break;
        }
    }
    if (saw_pause) {
        const resume_at = try send(&session, "Debugger.resume", "", 6313);
        try testing.expect(try responseReceivedWithoutTick(&session, resume_at, 6313));
    }
    eval_thread.join();
    try testing.expect(saw_pause);
    try testing.expect(probe.result.err != null);
}

test "debugger session survives async depth and reconnect without native hooks" {
    if (comptime backend.active_backend == .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-cross-backend-debugger-session");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    const first_enable = try send(&session, "Debugger.enable", "", 6401);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, first_enable, 6401), 6401));
    const depth = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":2}", 6402);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, depth, 6402), 6402));

    const breakpoint = try send(&session, "Debugger.setBreakpointByUrl", "{\"url\":\"unavailable.js\",\"lineNumber\":0}", 6403);
    const breakpoint_response = try pumpResponse(&session, breakpoint, 6403);
    try testing.expect(!responseIsSuccess(breakpoint_response, 6403));
    try testing.expect(std.mem.indexOf(u8, breakpoint_response, "unavailable for this backend") != null);
    const pause = try send(&session, "Debugger.pause", "", 6404);
    const pause_response = try pumpResponse(&session, pause, 6404);
    try testing.expect(!responseIsSuccess(pause_response, 6404));
    try testing.expect(std.mem.indexOf(u8, pause_response, "unavailable for this backend") != null);

    disconnect(&session);
    try waitForSessionCount(state, 0);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);
    try reconnect(&session, "debugger-cross-backend-debugger-session");
    const second_enable = try send(&session, "Debugger.enable", "", 6405);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, second_enable, 6405), 6405));
}

test "a second debugger session does not discard another session's pending pause" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var first = try openSession(alloc, "pending-pause-owner");
    defer first.deinit();
    var second = try openAdditionalSession(alloc, &first, "pending-pause-owner");
    defer second.deinit();

    const first_enable = try send(&first, "Debugger.enable", "", 6501);
    try testing.expect(responseIsSuccess(try pumpResponse(&first, first_enable, 6501), 6501));
    const pause = try send(&first, "Debugger.pause", "", 6502);
    try testing.expect(responseIsSuccess(try pumpResponse(&first, pause, 6502), 6502));

    const second_enable = try send(&second, "Debugger.enable", "", 6503);
    try testing.expect(responseIsSuccess(try pumpResponse(&second, second_enable, 6503), 6503));

    var probe: EvalProbe = .{ .id = first.id };
    defer probe.deinit();
    const paused_from = first.got.items.len;
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    var joined = false;
    defer if (!joined) {
        debugger_mod.resumeExecution(first.id);
        eval_thread.join();
    };

    var saw_pause = false;
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        wire.readTextFrames(first.alloc, &first.reader, &first.got, 1) catch break;
        if (std.mem.indexOf(u8, first.got.items[paused_from..], "Debugger.paused") != null) {
            saw_pause = true;
            break;
        }
    }
    const resume_at = send(&first, "Debugger.resume", "", 6504) catch {
        debugger_mod.resumeExecution(first.id);
        eval_thread.join();
        joined = true;
        return error.TestUnexpectedResult;
    };
    _ = responseReceivedWithoutTick(&first, resume_at, 6504) catch {};
    debugger_mod.resumeExecution(first.id);
    eval_thread.join();
    joined = true;

    try testing.expect(saw_pause);
    try testing.expect(probe.result.err == null);
}

test "a queued disable cannot override a later enable on non-native backends" {
    if (comptime backend.active_backend == .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "queued-disable-generation");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    const first_disable = try send(&session, "Debugger.disable", "", 6601);
    try testing.expect(try responseReceivedWithoutTick(&session, first_disable, 6601));
    try testing.expect(responseIsSuccess(session.got.items[first_disable..], 6601));

    const second_enable = try send(&session, "Debugger.enable", "", 6602);
    const third_disable = try send(&session, "Debugger.disable", "", 6603);
    const final_enable = try send(&session, "Debugger.enable", "", 6604);
    try testing.expect(!(try responseReceivedWithoutTick(&session, second_enable, 6602)));
    try testing.expect(!(try responseReceivedWithoutTick(&session, third_disable, 6603)));
    try testing.expect(!(try responseReceivedWithoutTick(&session, final_enable, 6604)));

    try testing.expect(responseIsSuccess(try pumpResponse(&session, second_enable, 6602), 6602));
    try testing.expect(responseIsSuccess(try pumpResponse(&session, third_disable, 6603), 6603));
    try testing.expect(responseIsSuccess(try pumpResponse(&session, final_enable, 6604), 6604));
    const first_enable_reply = std.mem.indexOfPos(u8, session.got.items, second_enable, "\"id\":6602") orelse return error.TestUnexpectedResult;
    const disable_reply = std.mem.indexOfPos(u8, session.got.items, third_disable, "\"id\":6603") orelse return error.TestUnexpectedResult;
    const enable_reply = std.mem.indexOfPos(u8, session.got.items, final_enable, "\"id\":6604") orelse return error.TestUnexpectedResult;
    try testing.expect(first_enable_reply < disable_reply);
    try testing.expect(disable_reply < enable_reply);
    try testing.expect(inspector_state.hasEnabledDebuggerSession(state));
}
