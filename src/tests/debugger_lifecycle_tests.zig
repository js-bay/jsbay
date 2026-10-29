//! Inspector debugger lifecycle regressions.
//!
//! The WebSocket case crosses the real inspector transport boundary. The binding case is deterministic and deliberately does not claim to cover nested owner-tick teardown, which needs a separate scheduling hook.

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

    fn deinit(self: *Session) void {
        // A failing assertion must not leave an evaluator blocked in a stale pause while cleanup joins the inspector and engine.
        debugger_mod.abandon(self.id);
        debugger_mod.resumeExecution(self.id);
        self.got.deinit(self.alloc);
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
    }
};

const EvalProbe = struct {
    id: i32,
    result: @import("../types.zig").EvalResult = .{},

    fn run(self: *EvalProbe) void {
        self.result = engine.evalScript(self.id, "globalThis.__debuggerLifecycle = 1;", "debugger-fresh.js");
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
    return .{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream) };
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

fn responseIsSuccess(payload: []const u8, id: i64) bool {
    var marker: [32]u8 = undefined;
    const expected = std.fmt.bufPrint(&marker, "\"id\":{d},\"result\":", .{id}) catch return false;
    return std.mem.indexOf(u8, payload, expected) != null;
}

fn pumpResponse(session: *Session, from: usize, id: i64) ![]const u8 {
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, from, id)) return session.got.items[from..];
    }
    return error.TestUnexpectedResult;
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

test "debugger lifecycle: stale pause cannot cross disable close into a new session" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-stale-pause");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    const enable = try send(&session, "Debugger.enable", "", 7101);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable, 7101), 7101));
    // No host JavaScript is executing: this leaves a pending native pause request rather than entering a pause at this point.
    const pause = try send(&session, "Debugger.pause", "", 7102);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, pause, 7102), 7102));
    const disable = try send(&session, "Debugger.disable", "", 7103);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, disable, 7103), 7103));

    disconnect(&session);
    try waitForSessionCount(state, 0);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);
    try reconnect(&session, "debugger-stale-pause");
    const reenable = try send(&session, "Debugger.enable", "", 7104);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, reenable, 7104), 7104));

    var probe: EvalProbe = .{ .id = session.id };
    defer probe.deinit();
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    const after_reenable = session.got.items.len;
    var saw_unexpected_pause = false;
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[after_reenable..], "Debugger.paused") != null) {
            saw_unexpected_pause = true;
            break;
        }
    }
    if (saw_unexpected_pause) {
        const resume_at = try send(&session, "Debugger.resume", "", 7105);
        _ = try pumpResponse(&session, resume_at, 7105);
    }
    eval_thread.join();
    try testing.expect(!saw_unexpected_pause);
    try testing.expect(probe.result.err == null);
}

test "debugger lifecycle: abandon makes a prepared binding permanently unattachable" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    defer debugger_mod.detach(id);
    const runtime = engine.getRuntime(id) orelse return error.MissingRuntime;

    try testing.expect(debugger_mod.prepare(id));
    debugger_mod.abandon(id);
    try testing.expect(!debugger_mod.attach(id, @ptrCast(@constCast(runtime))));
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(id));
}
