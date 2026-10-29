//! WebSocket debugger protocol regressions.
//!
//! These cover owner-marshaled Debugger enable/disable timing and configuration sent before the first enable. They intentionally drive the TCP/WebSocket transport.

const std = @import("std");
const testing = std.testing;

const async_stack = @import("../inspector/async_stack.zig");
const backend = @import("../backend.zig");
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
        self.got.deinit(self.alloc);
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
    }
};

const EvalProbe = struct {
    id: i32,
    source: []const u8,
    filename: []const u8,
    result: @import("../types.zig").EvalResult = .{},

    fn run(self: *EvalProbe) void {
        self.result = engine.evalScript(self.id, self.source, self.filename);
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

fn waitResponseWithoutTick(session: *Session, from: usize, id: i64) !bool {
    var tries: usize = 0;
    while (tries < 25) : (tries += 1) {
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

fn waitForPause(session: *Session, from: usize) !bool {
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[from..], "Debugger.paused") != null) return true;
    }
    return false;
}

test "debugger protocol: classic and JSC acknowledge enable without owner tick" {
    // Unsupported debugger backends do not need a native attach, so an idle or busy owner must not delay the protocol acknowledgement.
    if (comptime backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-n3-enable");
    defer session.deinit();

    const at = try send(&session, "Debugger.enable", "", 7101);
    try testing.expect(try waitResponseWithoutTick(&session, at, 7101));
    try testing.expect(responseIsSuccess(session.got.items[at..], 7101));
}

test "debugger protocol: classic and JSC acknowledge disable without owner tick" {
    if (comptime backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-n3-disable");
    defer session.deinit();

    const enable_at = try send(&session, "Debugger.enable", "", 7111);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 7111), 7111));

    const disable_at = try send(&session, "Debugger.disable", "", 7112);
    try testing.expect(try waitResponseWithoutTick(&session, disable_at, 7112));
    try testing.expect(responseIsSuccess(session.got.items[disable_at..], 7112));
}

test "debugger protocol: a state lease is not an inspector task" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-state-lease-task-count");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    try testing.expect(inspector_state.tryAcquireStateLease(state));
    defer inspector_state.releaseStateLease(state);
    try testing.expect(!inspector_state.hasInspectorTasks(state));
}

test "debugger protocol: disable waits for an earlier async-depth owner request" {
    if (comptime backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-disable-depth-order");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;

    const depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 7121);
    // Runtime.getIsolateId is answered on the reader. Its response orders this assertion after the preceding async-depth command without owner ticks.
    const barrier_at = try send(&session, "Runtime.getIsolateId", "", 7123);
    try testing.expect(try waitResponseWithoutTick(&session, barrier_at, 7123));
    try testing.expect(responseIsSuccess(session.got.items[barrier_at..], 7123));
    try testing.expect(inspector_state.hasInspectorTasks(state));
    const disable_at = try send(&session, "Debugger.disable", "", 7122);
    try testing.expect(!(try waitResponseWithoutTick(&session, disable_at, 7122)));
    try testing.expect(responseIsSuccess(try pumpResponse(&session, depth_at, 7121), 7121));
    try testing.expect(responseIsSuccess(try pumpResponse(&session, disable_at, 7122), 7122));
    try testing.expectEqual(@as(u32, 0), async_stack.depth(session.id));
}

test "debugger protocol: exception configuration before first enable takes effect" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "debugger-n4-preenable-exception");
    defer session.deinit();

    // A successful configuration reply must still correspond to an eventual pause once the Debugger domain is enabled.
    const mode_at = try send(&session, "Debugger.setPauseOnExceptions", "{\"state\":\"all\"}", 7201);
    try testing.expect(try waitResponseWithoutTick(&session, mode_at, 7201));
    try testing.expect(responseIsSuccess(session.got.items[mode_at..], 7201));

    const enable_at = try send(&session, "Debugger.enable", "", 7202);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 7202), 7202));

    var probe: EvalProbe = .{
        .id = session.id,
        .source = "throw new Error('preenable');",
        .filename = "preenable.js",
    };
    defer probe.deinit();
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    const paused_from = session.got.items.len;
    const paused = try waitForPause(&session, paused_from);
    if (paused) {
        const resume_at = try send(&session, "Debugger.resume", "", 7203);
        try testing.expect(try waitResponseWithoutTick(&session, resume_at, 7203));
    }
    eval_thread.join();

    try testing.expect(paused);
    try testing.expect(probe.result.err != null);
}

test "debugger protocol: breakpoint configuration before first enable takes effect" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "preenable-breakpoint");
    defer session.deinit();

    const breakpoint_at = try send(
        &session,
        "Debugger.setBreakpointByUrl",
        "{\"url\":\"preenable-breakpoint.js\",\"lineNumber\":0}",
        7301,
    );
    try testing.expect(try waitResponseWithoutTick(&session, breakpoint_at, 7301));
    try testing.expect(responseIsSuccess(session.got.items[breakpoint_at..], 7301));

    const enable_at = try send(&session, "Debugger.enable", "", 7302);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 7302), 7302));

    var probe: EvalProbe = .{
        .id = session.id,
        .source = "globalThis.__preenable_breakpoint = 1;",
        .filename = "preenable-breakpoint.js",
    };
    defer probe.deinit();
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    const paused_from = session.got.items.len;
    const paused = try waitForPause(&session, paused_from);
    if (paused) {
        const resume_at = try send(&session, "Debugger.resume", "", 7303);
        try testing.expect(try waitResponseWithoutTick(&session, resume_at, 7303));
    }
    eval_thread.join();

    try testing.expect(paused);
    try testing.expect(probe.result.err == null);
}
