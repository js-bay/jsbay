//! WebSocket debugger protocol regressions.
//!
//! These cover owner-marshaled Debugger enable/disable timing and configuration sent before the first enable. They intentionally drive the TCP/WebSocket transport.

const std = @import("std");
const testing = std.testing;

const async_stack = @import("../inspector/async_stack.zig");
const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const debugger_mod = @import("../inspector/debugger.zig");
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

fn firstPausedFrameMatches(events: []const u8, line: i32, column: i32) bool {
    const paused_start = std.mem.indexOf(u8, events, "\"method\":\"Debugger.paused\"") orelse return false;
    const paused_tail = events[paused_start..];
    const paused_event = paused_tail[0 .. std.mem.indexOfScalar(u8, paused_tail, '\n') orelse paused_tail.len];
    const frames_start = std.mem.indexOf(u8, paused_event, "\"callFrames\":[{") orelse return false;
    const frame_tail = paused_event[frames_start..];
    const location_start = std.mem.indexOf(u8, frame_tail, "\"location\":{") orelse return false;
    const location_tail = frame_tail[location_start..];
    const location_end = std.mem.indexOf(u8, location_tail, "},\"url\":") orelse return false;
    var expected: [80]u8 = undefined;
    const location = std.fmt.bufPrint(&expected, "\"lineNumber\":{d},\"columnNumber\":{d}", .{ line, column }) catch return false;
    return std.mem.indexOf(u8, location_tail[0..location_end], location) != null;
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
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
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
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
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

test "debugger protocol: pauses a function compiled before Debugger.enable" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "preenabled-function-breakpoint");
    defer session.deinit();

    const source =
        \\globalThis.__preenabledFunction = function() {
        \\  const value = 40;
        \\  return value + 2;
        \\};
        \\globalThis.__preenabledAfterFunction = true;
    ;
    const prepared = engine.evalScript(session.id, source, "preenabled-function.js");
    defer if (prepared.result) |value| std.heap.c_allocator.free(value);
    defer if (prepared.err) |value| if (prepared.err_is_heap) std.heap.c_allocator.free(value);
    try testing.expect(prepared.err == null);
    const script_id = debugger_mod.scriptIdForUrl(session.id, "preenabled-function.js");
    try testing.expect(script_id != 0);
    const locations = try debugger_mod.possibleBreakpoints(session.id, script_id, 0, 0, 4, 0);
    defer std.heap.c_allocator.free(locations);
    try testing.expect(locations.len != 0);

    const enable_at = try send(&session, "Debugger.enable", "", 7401);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 7401), 7401));
    // QuickJS retains the constant initialization; QuickJS-NG folds it into the return.
    const expected_line: i32 = if (comptime backend.active_backend == .quickjs) 1 else 2;
    const expected_column: i32 = if (comptime backend.active_backend == .quickjs) 14 else 9;
    const breakpoint_at = try send(&session, "Debugger.setBreakpointByUrl", "{\"url\":\"preenabled-function.js\",\"lineNumber\":1}", 7402);
    const breakpoint_response = try pumpResponse(&session, breakpoint_at, 7402);
    try testing.expect(responseIsSuccess(breakpoint_response, 7402));
    try testing.expect(std.mem.indexOf(u8, breakpoint_response, "\"scriptId\"") != null);
    const expected_line_json = try std.fmt.allocPrint(alloc, "\"lineNumber\":{d}", .{expected_line});
    defer alloc.free(expected_line_json);
    const expected_column_json = try std.fmt.allocPrint(alloc, "\"columnNumber\":{d}", .{expected_column});
    defer alloc.free(expected_column_json);
    try testing.expect(std.mem.indexOf(u8, breakpoint_response, expected_line_json) != null);
    try testing.expect(std.mem.indexOf(u8, breakpoint_response, expected_column_json) != null);

    var probe: EvalProbe = .{ .id = session.id, .source = "globalThis.__preenabledFunction();", .filename = "preenabled-function-driver.js" };
    defer probe.deinit();
    const first_pause_from = session.got.items.len;
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    const first_pause = try waitForPause(&session, first_pause_from);
    try testing.expect(first_pause);
    try testing.expect(std.mem.indexOf(u8, session.got.items[first_pause_from..], "preenabled-function.js") != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items[first_pause_from..], expected_line_json) != null);
    try testing.expect(std.mem.indexOf(u8, session.got.items[first_pause_from..], expected_column_json) != null);
    const step_pause_from = session.got.items.len;
    const step_at = try send(&session, "Debugger.stepOver", "", 7403);
    try testing.expect(try waitResponseWithoutTick(&session, step_at, 7403));
    const stepped_pause = try waitForPause(&session, step_pause_from);
    const resume_at = try send(&session, "Debugger.resume", "", 7404);
    try testing.expect(try waitResponseWithoutTick(&session, resume_at, 7404));
    eval_thread.join();

    try testing.expect(stepped_pause);
    try testing.expect(probe.result.err == null);
}

test "debugger protocol: reports truncated possible breakpoints for a large classic bundle" {
    if (comptime backend.active_backend != .quickjs) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "classic-break-location-budget");
    defer session.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    try source.appendSlice(alloc, "var value = 0;\n");
    for (0..8_193) |_| try source.appendSlice(alloc, "value += 1;\n");
    const prepared = engine.evalScript(session.id, source.items, "classic-break-location-budget.js");
    defer if (prepared.result) |value| std.heap.c_allocator.free(value);
    defer if (prepared.err) |value| if (prepared.err_is_heap) std.heap.c_allocator.free(value);
    try testing.expect(prepared.err == null);
    const script_id = debugger_mod.scriptIdForUrl(session.id, "classic-break-location-budget.js");
    try testing.expect(script_id != 0);
    try testing.expectError(error.LocationsTruncated, debugger_mod.possibleBreakpoints(session.id, script_id, 0, 0, 8_200, 0));
}

test "debugger protocol: resolves a pending breakpoint after compilation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "pending-compiled-breakpoint");
    defer session.deinit();

    const enable_at = try send(&session, "Debugger.enable", "", 7501);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 7501), 7501));
    const breakpoint_at = try send(&session, "Debugger.setBreakpointByUrl", "{\"url\":\"pending-compiled-breakpoint.js\",\"lineNumber\":1}", 7502);
    const breakpoint_response = try pumpResponse(&session, breakpoint_at, 7502);
    try testing.expect(responseIsSuccess(breakpoint_response, 7502));
    try testing.expect(std.mem.indexOf(u8, breakpoint_response, "\"locations\":[]") != null);

    const source =
        \\globalThis.__pendingCompiledBreakpoint = function() {
        \\  const value = 40;
        \\  return value + 2;
        \\};
        \\globalThis.__pendingCompiledBreakpointValue = globalThis.__pendingCompiledBreakpoint();
    ;
    var probe: EvalProbe = .{ .id = session.id, .source = source, .filename = "pending-compiled-breakpoint.js" };
    defer probe.deinit();
    const from = session.got.items.len;
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    const paused = try waitForPause(&session, from);
    try testing.expect(paused);
    const events = session.got.items[from..];
    const parsed_at = std.mem.indexOf(u8, events, "Debugger.scriptParsed") orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOfPos(u8, events, parsed_at + 1, "Debugger.scriptParsed") == null);
    try testing.expect(std.mem.indexOf(u8, events, "Debugger.breakpointResolved") != null);
    const expected_line = if (comptime backend.active_backend == .quickjs) "\"lineNumber\":1" else "\"lineNumber\":2";
    try testing.expect(std.mem.indexOf(u8, events, expected_line) != null);

    const resume_at = try send(&session, "Debugger.resume", "", 7503);
    try testing.expect(try waitResponseWithoutTick(&session, resume_at, 7503));
    eval_thread.join();
    try testing.expect(probe.result.err == null);
}

test "debugger protocol: NG distinguishes two executable columns on one line" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "same-line-columns");
    defer session.deinit();

    const source = "globalThis.__sameLineFirst = Date.now(); globalThis.__sameLineSecond = Date.now();";
    const prepared = engine.evalScript(session.id, source, "same-line-columns.js");
    defer if (prepared.result) |value| std.heap.c_allocator.free(value);
    defer if (prepared.err) |value| if (prepared.err_is_heap) std.heap.c_allocator.free(value);
    try testing.expect(prepared.err == null);
    const script_id = debugger_mod.scriptIdForUrl(session.id, "same-line-columns.js");
    try testing.expect(script_id != 0);
    const locations = try debugger_mod.possibleBreakpoints(session.id, script_id, 0, 0, 1, 0);
    defer std.heap.c_allocator.free(locations);
    var first: ?debugger_mod.BreakLocation = null;
    var second: ?debugger_mod.BreakLocation = null;
    for (locations, 0..) |location, index| {
        for (locations[index + 1 ..]) |candidate| {
            if (location.line == candidate.line and location.column != candidate.column) {
                first = location;
                second = candidate;
                break;
            }
        }
        if (second != null) break;
    }
    try testing.expect(first != null);
    try testing.expect(second != null);

    const enable_at = try send(&session, "Debugger.enable", "", 7601);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 7601), 7601));
    inline for (.{ .{ first.?, 7602 }, .{ second.?, 7603 } }) |entry| {
        const params = try std.fmt.allocPrint(alloc, "{{\"url\":\"same-line-columns.js\",\"lineNumber\":{d},\"columnNumber\":{d}}}", .{ entry[0].line - 1, entry[0].column });
        defer alloc.free(params);
        const breakpoint_at = try send(&session, "Debugger.setBreakpointByUrl", params, entry[1]);
        const response = try pumpResponse(&session, breakpoint_at, entry[1]);
        try testing.expect(responseIsSuccess(response, entry[1]));
        const column = try std.fmt.allocPrint(alloc, "\"columnNumber\":{d}", .{entry[0].column});
        defer alloc.free(column);
        try testing.expect(std.mem.indexOf(u8, response, column) != null);
    }

    var probe: EvalProbe = .{ .id = session.id, .source = source, .filename = "same-line-columns.js" };
    defer probe.deinit();
    const eval_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&probe});
    var from = session.got.items.len;
    inline for (.{ first.?, second.? }) |location| {
        try testing.expect(try waitForPause(&session, from));
        try testing.expect(firstPausedFrameMatches(session.got.items[from..], location.line - 1, location.column));
        from = session.got.items.len;
        const resume_at = try send(&session, "Debugger.resume", "", 7610 + @as(i64, @intCast(location.column)));
        try testing.expect(try waitResponseWithoutTick(&session, resume_at, 7610 + @as(i64, @intCast(location.column))));
    }
    eval_thread.join();
    try testing.expect(probe.result.err == null);
}
