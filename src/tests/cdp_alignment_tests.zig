//! Independent CDP alignment contracts.  These tests deliberately use the transport boundary: a command is not considered implemented merely because the dispatcher recognizes its name.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const host_value = @import("../abi/host_value.zig");
const inspector = @import("../inspector/root.zig");
const inspector_state = @import("../inspector/root.zig").state;
const instance_map = @import("../runtime/instance_map.zig");
const test_faults = @import("inspector_test_faults.zig");
const promise = @import("../runtime/promise.zig");
const helpers = @import("test_helpers.zig");
const wire = @import("inspector_tests.zig");

const Session = struct {
    alloc: std.mem.Allocator,
    id: i32,
    handle: *inspector.Handle,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    got: std.ArrayList(u8) = .empty,
    c_api_owned: bool = false,

    fn deinit(self: *Session) void {
        self.got.deinit(self.alloc);
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        if (self.c_api_owned) {
            c_api.js_bay_engine_destroy(self.id);
        } else {
            engine.destroy(self.id);
        }
    }
};

const EvalProbe = struct {
    id: i32,
    source: []const u8,
    filename: []const u8,
    ok: bool = false,

    fn run(self: *EvalProbe) void {
        const value = engine.evalScript(self.id, self.source, self.filename);
        self.ok = value.err == null;
        if (value.result) |result| std.heap.c_allocator.free(result);
        if (value.err) |err| if (value.err_is_heap) std.heap.c_allocator.free(err);
    }
};

const HostRejectionLog = struct {
    count: u32 = 0,
    saw_handled: bool = false,
};

const NativeStopHost = struct {
    handle: *inspector.Handle,
    entered: std.atomic.Value(bool) = .init(false),

    fn call(_: c_int, user_data: ?*anyopaque, _: u32, _: ?[*]const host_value.HostValue, out: *host_value.HostValue) callconv(.c) c_int {
        const self: *NativeStopHost = @ptrCast(@alignCast(user_data.?));
        self.entered.store(true, .seq_cst);
        std.debug.print("L4_NATIVE_STOP_ENTERED\n", .{});
        inspector.stop(self.handle);
        host_value.clear(out);
        return 0;
    }
};

fn hostRejectionTracker(
    _: i32,
    handled: bool,
    _: [*]const u8,
    _: usize,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const log: *HostRejectionLog = @ptrCast(@alignCast(userdata orelse return));
    log.count += 1;
    log.saw_handled = log.saw_handled or handled;
}

fn openSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    return openSessionWithId(alloc, id, target_id);
}

fn openSessionWithId(alloc: std.mem.Allocator, id: i32, target_id: []const u8) !Session {
    try testing.expect(engine.create(id, .{}));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer engine.destroy(id);
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream) };
}

fn openCapiSession(alloc: std.mem.Allocator, target_id: []const u8) !Session {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    errdefer c_api.js_bay_engine_destroy(id);
    const handle = try inspector.start(id, .{ .port = 0, .target_id = target_id });
    errdefer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    errdefer stream.close();
    try wire.doWsHandshake(alloc, stream, target_id);
    return .{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream), .c_api_owned = true };
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

fn pumpResponse(session: *Session, from: usize, id: i64) ![]const u8 {
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, from, id)) return session.got.items[from..];
    }
    std.debug.print("missing CDP response {d}:\n{s}\n", .{ id, session.got.items });
    return error.TestUnexpectedResult;
}

fn pumpFor(session: *Session, from: usize, needle: []const u8, spins: usize) !bool {
    var i: usize = 0;
    while (i < spins) : (i += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[from..], needle) != null) return true;
    }
    return false;
}

/// A paused evaluator owns the engine thread.  Transport-side Debugger events and resume acknowledgements must therefore be read without ticking the JS dispatcher from this test thread.
fn waitForFrame(session: *Session, from: usize, needle: []const u8, spins: usize) !bool {
    var i: usize = 0;
    while (i < spins) : (i += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[from..], needle) != null) return true;
    }
    return false;
}

fn waitResponseNoTick(session: *Session, from: usize, id: i64) !bool {
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (try wire.hasResponseIdSince(session.alloc, session.got.items, from, id)) return true;
    }
    return false;
}

fn responseIsSuccess(payload: []const u8, id: i64) bool {
    var marker: [32]u8 = undefined;
    const id_marker = std.fmt.bufPrint(&marker, "\"id\":{d},\"result\":", .{id}) catch return false;
    return std.mem.indexOf(u8, payload, id_marker) != null;
}

fn responseHasServerError(payload: []const u8, id: i64) bool {
    var marker: [32]u8 = undefined;
    const id_marker = std.fmt.bufPrint(&marker, "\"id\":{d},\"error\":{{\"code\":-32000", .{id}) catch return false;
    return std.mem.indexOf(u8, payload, id_marker) != null;
}

fn quoteAfter(text: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    if (rest.len == 0 or rest[0] != '"') return null;
    const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return null;
    return rest[1 .. end + 1];
}

fn scriptIdForUrl(text: []const u8, url: []const u8) ?[]const u8 {
    var frames = std.mem.splitScalar(u8, text, '\n');
    while (frames.next()) |frame| {
        if (std.mem.indexOf(u8, frame, url) == null) continue;
        if (quoteAfter(frame, "\"scriptId\":")) |script_id| return script_id;
    }
    return null;
}

fn scriptIdsForUrl(text: []const u8, url: []const u8, out: *[4]?[]const u8) usize {
    var count: usize = 0;
    var frames = std.mem.splitScalar(u8, text, '\n');
    while (frames.next()) |frame| {
        if (std.mem.indexOf(u8, frame, url) == null) continue;
        const script_id = quoteAfter(frame, "\"scriptId\":") orelse continue;
        if (count < out.len) out[count] = script_id;
        count += 1;
    }
    return count;
}

fn waitForScriptIds(session: *Session, url: []const u8, want: usize) !bool {
    var tries: usize = 0;
    while (tries < 40) : (tries += 1) {
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        var ids: [4]?[]const u8 = @splat(null);
        if (scriptIdsForUrl(session.got.items, url, &ids) >= want) return true;
    }
    return false;
}

fn possibleBreakpoints(session: *Session, request_id: i64, script_id: []const u8, end_line: i32) ![]const u8 {
    const params = try std.fmt.allocPrint(session.alloc, "{{\"start\":{{\"scriptId\":\"{s}\",\"lineNumber\":0}},\"end\":{{\"scriptId\":\"{s}\",\"lineNumber\":{d}}}}}", .{ script_id, script_id, end_line });
    defer session.alloc.free(params);
    const at = try send(session, "Debugger.getPossibleBreakpoints", params, request_id);
    return pumpResponse(session, at, request_id);
}

fn possibleBreakpointsToScriptEnd(session: *Session, request_id: i64, script_id: []const u8) ![]const u8 {
    const params = try std.fmt.allocPrint(session.alloc, "{{\"start\":{{\"scriptId\":\"{s}\",\"lineNumber\":0}}}}", .{script_id});
    defer session.alloc.free(params);
    const at = try send(session, "Debugger.getPossibleBreakpoints", params, request_id);
    return pumpResponse(session, at, request_id);
}

fn intAfter(text: []const u8, key: []const u8) ?i64 {
    const at = std.mem.indexOf(u8, text, key) orelse return null;
    const rest = text[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(i64, rest[0..end], 10) catch null;
}

fn discardEval(result: @import("../types.zig").EvalResult) void {
    if (result.result) |value| std.heap.c_allocator.free(value);
    if (result.err) |err| if (result.err_is_heap) std.heap.c_allocator.free(err);
}

fn sessionPresent(state: *inspector_state.InspectorState, session_id: u64) bool {
    state.mutex.lock();
    defer state.mutex.unlock();
    for (state.sessions.items) |entry| {
        if (entry.id == session_id) return true;
    }
    return false;
}

fn onlySessionId(state: *inspector_state.InspectorState) !u64 {
    state.mutex.lock();
    defer state.mutex.unlock();
    if (state.sessions.items.len != 1) return error.TestUnexpectedResult;
    return state.sessions.items[0].id;
}

fn waitForSessionRemoval(state: *inspector_state.InspectorState, session_id: u64) !void {
    var spins: usize = 0;
    while (spins < 10_000 and sessionPresent(state, session_id)) : (spins += 1) {
        std.Thread.yield() catch {};
    }
    try testing.expect(!sessionPresent(state, session_id));
}

fn cApiHostileThrowCoercesReason() !bool {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    const hostile = "throw { toString: function(){ globalThis.__cdpToStringCalled = true; throw new Error('must-not-coerce'); } };";
    const filename = "public-abi-hostile-baseline.js";
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 1), c_api.js_bay_engine_evaluate(id, .{ .data = hostile.ptr, .len = hostile.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_value_release(exception));
    const check = "globalThis.__cdpToStringCalled === undefined";
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_evaluate(id, .{ .data = check.ptr, .len = check.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
    defer testing.expectEqual(@as(c_int, 0), c_api.js_bay_value_release(value)) catch {};
    var uncoerced = false;
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_value_to_bool(value, &uncoerced));
    return !uncoerced;
}

fn evaluatePromise(session: *Session, request_id: i64, expression: []const u8) ![]u8 {
    const params = try std.fmt.allocPrint(session.alloc, "{{\"expression\":\"{s}\"}}", .{expression});
    defer session.alloc.free(params);
    const at = try send(session, "Runtime.evaluate", params, request_id);
    const response = try pumpResponse(session, at, request_id);
    const object_id = quoteAfter(response, "\"objectId\":") orelse return error.TestUnexpectedResult;
    return try session.alloc.dupe(u8, object_id);
}

test "cdp alignment: Runtime awaitPromise awaits settled, pending, rejected, evaluate, and callFunctionOn promises" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-await-promise");
    defer session.deinit();

    const settled = try evaluatePromise(&session, 21, "Promise.resolve(41)");
    defer alloc.free(settled);
    const settled_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{settled});
    defer alloc.free(settled_params);
    var at = try send(&session, "Runtime.awaitPromise", settled_params, 22);
    var response = try pumpResponse(&session, at, 22);
    try testing.expect(responseIsSuccess(response, 22));
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":41") != null);

    const pending = try evaluatePromise(&session, 23, "new Promise(resolve => setTimeout(() => resolve(42), 0))");
    defer alloc.free(pending);
    const pending_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{pending});
    defer alloc.free(pending_params);
    at = try send(&session, "Runtime.awaitPromise", pending_params, 24);
    response = try pumpResponse(&session, at, 24);
    try testing.expect(responseIsSuccess(response, 24));
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":42") != null);

    const rejected = try evaluatePromise(&session, 25, "Promise.reject(new Error('cdp-await-rejected'))");
    defer alloc.free(rejected);
    const rejected_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\"}}", .{rejected});
    defer alloc.free(rejected_params);
    at = try send(&session, "Runtime.awaitPromise", rejected_params, 26);
    response = try pumpResponse(&session, at, 26);
    try testing.expect(responseIsSuccess(response, 26));
    try testing.expect(std.mem.indexOf(u8, response, "\"exceptionDetails\":") != null);
    try testing.expect(std.mem.indexOf(u8, response, "cdp-await-rejected") != null);

    at = try send(&session, "Runtime.evaluate", "{\"expression\":\"Promise.resolve(44)\",\"awaitPromise\":true,\"returnByValue\":true}", 27);
    response = try pumpResponse(&session, at, 27);
    try testing.expect(responseIsSuccess(response, 27));
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":44") != null);

    at = try send(&session, "Runtime.callFunctionOn", "{\"functionDeclaration\":\"function(){ return Promise.resolve(45); }\",\"awaitPromise\":true,\"returnByValue\":true}", 28);
    response = try pumpResponse(&session, at, 28);
    try testing.expect(responseIsSuccess(response, 28));
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":45") != null);
}

test "cdp alignment: JSC Runtime.awaitPromise explicitly reports unsupported" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-jsc-await-unsupported");
    defer session.deinit();
    const promise_id = try evaluatePromise(&session, 29, "Promise.resolve(46)");
    defer alloc.free(promise_id);
    const params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\"}}", .{promise_id});
    defer alloc.free(params);
    const at = try send(&session, "Runtime.awaitPromise", params, 30);
    const response = try pumpResponse(&session, at, 30);
    try testing.expect(std.mem.indexOf(u8, response, "\"id\":30,\"error\":") != null);
    try testing.expect(std.mem.indexOf(u8, response, "unsupported") != null);
    try testing.expect(!responseIsSuccess(response, 30));
}

test "cdp alignment: Runtime.awaitPromise uses native Promise reactions and bounds pending waits" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-await-lifetime");
    defer session.deinit();

    const tampered_promise = try evaluatePromise(&session, 71, "Promise.resolve(71)");
    defer alloc.free(tampered_promise);
    const tamper = engine.evalScript(session.id, "Promise.prototype.then = function(){ throw new Error('tampered-then'); };", "tamper-promise.js");
    defer discardEval(tamper);
    try testing.expect(tamper.err == null);
    const tampered_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{tampered_promise});
    defer alloc.free(tampered_params);
    var at = try send(&session, "Runtime.awaitPromise", tampered_params, 72);
    var response = try pumpResponse(&session, at, 72);
    try testing.expect(responseIsSuccess(response, 72));
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":71") != null);

    // A DevTools client can issue many awaits for never-settling promises. The inspector must cap this per session instead of retaining unbounded JS values and transport state. The public cap is 64 requests.
    var promise_ids: [64][]u8 = undefined;
    var created: usize = 0;
    defer for (promise_ids[0..created]) |object_id| alloc.free(object_id);
    while (created < promise_ids.len) : (created += 1) {
        promise_ids[created] = try evaluatePromise(&session, @as(i64, 80) + @as(i64, @intCast(created)), "new Promise(function(){})");
    }
    for (promise_ids, 0..) |object_id, index| {
        const params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\"}}", .{object_id});
        defer alloc.free(params);
        _ = try send(&session, "Runtime.awaitPromise", params, @as(i64, 200) + @as(i64, @intCast(index)));
    }
    at = try send(&session, "Runtime.awaitPromise", tampered_params, 300);
    response = try pumpResponse(&session, at, 300);
    try testing.expect(std.mem.indexOf(u8, response, "\"error\":") != null);
    try testing.expect(!responseIsSuccess(response, 300));
}

test "cdp alignment: Runtime.awaitPromise does not survive inspector teardown or instance-id reuse" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    const id = helpers.nextInstanceId();
    var old = try openSessionWithId(alloc, id, "cdp-alignment-await-old");
    // This session is deliberately torn down below instead of using deinit.
    const old_promise = try evaluatePromise(&old, 401, "new Promise(resolve => setTimeout(() => resolve('stale-await-result'), 0))");
    defer alloc.free(old_promise);
    const old_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{old_promise});
    defer alloc.free(old_params);
    _ = try send(&old, "Runtime.awaitPromise", old_params, 402);
    // Let the reader admit the request, but do not wait for a completion.
    var ticks: usize = 0;
    while (ticks < 4) : (ticks += 1) {
        _ = dispatch.tickInstance(old.id);
        engine.runEventLoopOnce(old.id);
    }
    old.reader.deinit(old.alloc);
    old.stream.close();
    inspector.stop(old.handle);
    engine.destroy(old.id);
    old.got.deinit(old.alloc);

    var fresh = try openSessionWithId(alloc, id, "cdp-alignment-await-fresh");
    defer fresh.deinit();
    const at = try send(&fresh, "Runtime.evaluate", "{\"expression\":\"88\",\"returnByValue\":true}", 403);
    const response = try pumpResponse(&fresh, at, 403);
    try testing.expect(responseIsSuccess(response, 403));
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":88") != null);
    try testing.expect(std.mem.indexOf(u8, fresh.got.items, "stale-await-result") == null);
}

test "cdp alignment: Runtime.awaitPromise completion is discarded after its WebSocket disconnects" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-await-disconnect");
    defer session.deinit();

    const pending = try evaluatePromise(&session, 411, "new Promise(resolve => globalThis.__cdpDisconnectResolve = resolve)");
    defer alloc.free(pending);
    const params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{pending});
    defer alloc.free(params);
    _ = try send(&session, "Runtime.awaitPromise", params, 412);
    var ticks: usize = 0;
    while (ticks < 4) : (ticks += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
    }

    session.reader.deinit(session.alloc);
    session.stream.close();
    // Replace the closed members so the owning session's normal cleanup cannot double-close; the inspector and engine remain alive for this scenario.
    session.stream = try wire.connect(inspector.boundPort(session.handle));
    try wire.doWsHandshake(alloc, session.stream, "cdp-alignment-await-disconnect");
    session.reader = wire.FrameReader.init(session.stream);
    const resolved = engine.evalScript(session.id, "globalThis.__cdpDisconnectResolve('disconnected-await-result');", "disconnect-await.js");
    defer discardEval(resolved);
    try testing.expect(resolved.err == null);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);

    const at = try send(&session, "Runtime.evaluate", "{\"expression\":\"99\",\"returnByValue\":true}", 413);
    const response = try pumpResponse(&session, at, 413);
    try testing.expect(responseIsSuccess(response, 413));
    try testing.expect(std.mem.indexOf(u8, session.got.items, "disconnected-await-result") == null);
}

test "cdp alignment: last Debugger session disconnect cools native hooks when reconcile posting fails" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-disconnect-cooldown");
    defer session.deinit();

    const enable_at = try send(&session, "Debugger.enable", "", 3001);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, enable_at, 3001), 3001));
    try testing.expect(debugger_mod.handlerInstallThreadId(session.id) != 0);

    const state = inspector_state.stateByInstance(session.id) orelse return error.InspectorStateMissing;
    test_faults.arm(session.id, .debugger_reconcile_post);
    session.stream.close();
    session.stream.handle = -1;

    var attempts: usize = 0;
    while (attempts < 10_000 and inspector_state.sessionCount(state) != 0) : (attempts += 1) {
        std.Thread.yield() catch {};
    }
    try testing.expectEqual(@as(usize, 0), inspector_state.sessionCount(state));
    // Session removal becomes visible before the reader consumes the injected post failure. Wait for that step before testing the owner fallback.
    attempts = 0;
    while (attempts < 10_000 and !test_faults.wasConsumed(session.id, .debugger_reconcile_post)) : (attempts += 1) {
        std.Thread.yield() catch {};
    }
    try testing.expect(test_faults.wasConsumed(session.id, .debugger_reconcile_post));

    // Do not tick after the close: this eval must observe the transport-side fallback itself, with no queued reconciliation task available to help.
    const evaluated = engine.evalScript(session.id, "globalThis.afterDisconnect = 1;", "after-debugger-disconnect.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expectEqual(@as(u64, 0), debugger_mod.handlerInstallThreadId(session.id));
    try testing.expectEqual(@as(u32, 0), debugger_mod.scriptIdForUrl(session.id, "after-debugger-disconnect.js"));
}

test "cdp alignment: async depth without Debugger.enable keeps an explicitly attached debugger armed" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-debugger-explicit-attach-async-depth");
    defer session.deinit();

    const instance = instance_map.getInstance(session.id) orelse return error.MissingEngine;
    _ = debugger_mod.attach(session.id, @ptrCast(@constCast(instance.runtime)));
    try testing.expect(debugger_mod.handlerInstallThreadId(session.id) != 0);

    const at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 3011);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, at, 3011), 3011));
    try testing.expect(debugger_mod.handlerInstallThreadId(session.id) != 0);
}

test "cdp alignment: Debugger.setSkipAllPauses suppresses and restores debugger statements" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-skip-pauses");
    defer session.deinit();

    var at = try send(&session, "Debugger.enable", "", 31);
    var response = try pumpResponse(&session, at, 31);
    try testing.expect(responseIsSuccess(response, 31));

    at = try send(&session, "Debugger.setSkipAllPauses", "{\"skip\":true}", 32);
    response = try pumpResponse(&session, at, 32);
    try testing.expect(responseIsSuccess(response, 32));

    var skipped = EvalProbe{ .id = session.id, .source = "debugger; globalThis.__skipPause = 1;", .filename = "skip-pauses.js" };
    var skipped_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&skipped});
    const skipped_from = session.got.items.len;
    const paused_while_skipped = try waitForFrame(&session, skipped_from, "Debugger.paused", 20);
    // Always resume before joining: a broken implementation can pause without successfully delivering its event, and the test must fail rather than hang.
    at = try send(&session, "Debugger.resume", "", 33);
    try testing.expect(try waitResponseNoTick(&session, at, 33));
    skipped_thread.join();
    try testing.expect(!paused_while_skipped);
    try testing.expect(skipped.ok);

    at = try send(&session, "Debugger.setSkipAllPauses", "{\"skip\":false}", 34);
    response = try pumpResponse(&session, at, 34);
    try testing.expect(responseIsSuccess(response, 34));

    var restored = EvalProbe{ .id = session.id, .source = "debugger; globalThis.__skipPause = 2;", .filename = "skip-pauses.js" };
    var restored_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&restored});
    const restored_from = session.got.items.len;
    const paused_after_restore = try waitForFrame(&session, restored_from, "Debugger.paused", 40);
    at = try send(&session, "Debugger.resume", "", 35);
    try testing.expect(try waitResponseNoTick(&session, at, 35));
    restored_thread.join();
    try testing.expect(paused_after_restore);
    try testing.expect(restored.ok);
}

test "cdp alignment: Debugger.getPossibleBreakpoints excludes a comment-only line" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-possible-breakpoints");
    defer session.deinit();

    const enable_at = try send(&session, "Debugger.enable", "", 41);
    _ = try pumpResponse(&session, enable_at, 41);
    const evaluated = engine.evalScript(session.id, "var cdpPossible = 1;\n// no executable location here\ncdpPossible += 1;", "possible-breakpoints.js");
    defer if (evaluated.result) |value| std.heap.c_allocator.free(value);
    defer if (evaluated.err) |err| if (evaluated.err_is_heap) std.heap.c_allocator.free(err);
    try testing.expect(evaluated.err == null);

    const found_script = try pumpFor(&session, 0, "\"url\":\"possible-breakpoints.js\"", 20);
    try testing.expect(found_script);
    const script_id = scriptIdForUrl(session.got.items, "\"url\":\"possible-breakpoints.js\"") orelse return error.TestUnexpectedResult;
    const params = try std.fmt.allocPrint(alloc, "{{\"start\":{{\"scriptId\":\"{s}\",\"lineNumber\":0}},\"end\":{{\"scriptId\":\"{s}\",\"lineNumber\":3}}}}", .{ script_id, script_id });
    defer alloc.free(params);
    const at = try send(&session, "Debugger.getPossibleBreakpoints", params, 42);
    const response = try pumpResponse(&session, at, 42);
    try testing.expect(responseIsSuccess(response, 42));
    try testing.expect(std.mem.indexOf(u8, response, "\"locations\":[{") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":0") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":2") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":1") == null);
}

test "cdp alignment: Debugger.getPossibleBreakpoints includes unexecuted locations beyond 32 functions" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-possible-many-functions");
    defer session.deinit();

    var source_writer: std.Io.Writer.Allocating = .init(alloc);
    defer source_writer.deinit();
    for (0..40) |index| {
        try source_writer.writer.print("function dormant_{d}() {{\n  const value_{d} = globalThis.__cdpInput + {d};\n  return value_{d};\n}}\n", .{ index, index, index, index });
    }
    const enabled_at = try send(&session, "Debugger.enable", "", 43);
    _ = try pumpResponse(&session, enabled_at, 43);
    const evaluated = engine.evalScript(session.id, source_writer.written(), "many-dormant-functions.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expect(try pumpFor(&session, 0, "\"url\":\"many-dormant-functions.js\"", 20));
    const script_id = scriptIdForUrl(session.got.items, "\"url\":\"many-dormant-functions.js\"") orelse return error.TestUnexpectedResult;
    const response = try possibleBreakpoints(&session, 44, script_id, 200);
    try testing.expect(responseIsSuccess(response, 44));
    // The last body is line 157 (zero-based). Breakpoint discovery must cover every function, including bodies that have not executed.
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":157") != null);
}

test "cdp alignment: Debugger.getPossibleBreakpoints includes never-executed branch locations" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-possible-unexecuted-branch");
    defer session.deinit();
    const source = "if (globalThis.__cdpNever) {\n  globalThis.__cdpBranchProbe = globalThis.__cdpInput + 1;\n  globalThis.__cdpBranchProbe += 1;\n}\nlet alwaysRan = 2;";
    const enabled_at = try send(&session, "Debugger.enable", "", 45);
    _ = try pumpResponse(&session, enabled_at, 45);
    const evaluated = engine.evalScript(session.id, source, "unexecuted-branch.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expect(try pumpFor(&session, 0, "\"url\":\"unexecuted-branch.js\"", 20));
    const script_id = scriptIdForUrl(session.got.items, "\"url\":\"unexecuted-branch.js\"") orelse return error.TestUnexpectedResult;
    const response = try possibleBreakpoints(&session, 46, script_id, 8);
    try testing.expect(responseIsSuccess(response, 46));
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":1") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":2") != null);
}

test "cdp alignment: Debugger.getPossibleBreakpoints keeps separate tables for same-url sources" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-possible-same-url");
    defer session.deinit();
    // Dynamic reads retain executable bytecode positions; literal-only initializers can be folded away before QuickJS writes pc2line records.
    const enabled_at = try send(&session, "Debugger.enable", "", 47);
    _ = try pumpResponse(&session, enabled_at, 47);
    const first = engine.evalScript(session.id, "let firstOnly = globalThis.__sameInput;\nfirstOnly += 1;", "same-url.js");
    defer discardEval(first);
    const second = engine.evalScript(session.id, "\n\n\n\n\nlet secondOnly = globalThis.__sameInput;\nsecondOnly += 1;", "same-url.js");
    defer discardEval(second);
    try testing.expect(first.err == null and second.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"same-url.js\"", 2));
    var ids: [4]?[]const u8 = @splat(null);
    try testing.expectEqual(@as(usize, 2), scriptIdsForUrl(session.got.items, "\"url\":\"same-url.js\"", &ids));
    // Responses append to `got` and may reallocate it, so the script-id slices borrowed from scriptParsed must be owned before the first query.
    const first_id = try alloc.dupe(u8, ids[0].?);
    defer alloc.free(first_id);
    const second_id = try alloc.dupe(u8, ids[1].?);
    defer alloc.free(second_id);
    const first_response = try possibleBreakpoints(&session, 48, first_id, 4);
    try testing.expect(responseIsSuccess(first_response, 48));
    try testing.expect(std.mem.indexOf(u8, first_response, "\"lineNumber\":0") != null);
    try testing.expect(std.mem.indexOf(u8, first_response, "\"lineNumber\":1") != null);
    const second_response = try possibleBreakpoints(&session, 49, second_id, 8);
    try testing.expect(responseIsSuccess(second_response, 49));
    try testing.expect(std.mem.indexOf(u8, second_response, "\"lineNumber\":5") != null);
    try testing.expect(std.mem.indexOf(u8, second_response, "\"lineNumber\":6") != null);
}

test "cdp alignment: Runtime.exceptionThrown reports direct uncaught eval but not caught eval" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-sync-exception");
    defer session.deinit();

    const enable_at = try send(&session, "Runtime.enable", "", 51);
    _ = try pumpResponse(&session, enable_at, 51);

    const uncaught_from = session.got.items.len;
    const uncaught = engine.evalScript(session.id, "throw new Error('cdp-direct-uncaught');", "direct-throw.js");
    defer discardEval(uncaught);
    try testing.expect(uncaught.err != null);
    try testing.expect(try pumpFor(&session, uncaught_from, "Runtime.exceptionThrown", 40));
    const uncaught_event = session.got.items[uncaught_from..];
    try testing.expect(std.mem.indexOf(u8, uncaught_event, "cdp-direct-uncaught") != null);
    try testing.expect(intAfter(uncaught_event, "\"exceptionId\":") != null);

    const caught_from = session.got.items.len;
    const caught = engine.evalScript(session.id, "try { throw new Error('cdp-caught-must-not-notify'); } catch (_) {}", "caught-throw.js");
    defer discardEval(caught);
    try testing.expect(caught.err == null);
    try testing.expect(!try pumpFor(&session, caught_from, "cdp-caught-must-not-notify", 12));
}

test "cdp alignment: Runtime.exceptionThrown reports a public C ABI evaluate exception without coercing it" {
    const alloc = testing.allocator;
    // JSC itself coerces a thrown object while producing a native exception. The inspector may not add another coercion; compare the inspector path with an otherwise identical C ABI evaluation without an inspector.
    const baseline_coerced = try cApiHostileThrowCoercesReason();
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.js_bay_engine_create(id, null, null));
    defer c_api.js_bay_engine_destroy(id);
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "cdp-alignment-public-abi-exception" });
    defer inspector.stop(handle);
    const stream = try wire.connect(inspector.boundPort(handle));
    defer stream.close();
    try wire.doWsHandshake(alloc, stream, "cdp-alignment-public-abi-exception");
    var session = Session{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream) };
    defer {
        session.reader.deinit(alloc);
        session.got.deinit(alloc);
    }

    const enabled_at = try send(&session, "Runtime.enable", "", 63);
    _ = try pumpResponse(&session, enabled_at, 63);
    const from = session.got.items.len;
    const source = "throw new Error('public-abi-marker');";
    const filename = "public-abi-throw.js";
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 1), c_api.js_bay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
    try testing.expect(value == 0 and exception != 0);
    try testing.expect(try pumpFor(&session, from, "Runtime.exceptionThrown", 40));
    const event = session.got.items[from..];
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        // QuickJS exposes Error's native own-data message without evaluating arbitrary user coercion hooks, so a useful description is available.
        try testing.expect(std.mem.indexOf(u8, event, "public-abi-marker") != null);
    } else {
        // Public JSC cannot read an arbitrary thrown value's message without risking getters/Proxy traps. Preserve a live RemoteObject and let an explicit DevTools evaluation request inspect the known Error object.
        const object_id = quoteAfter(event, "\"objectId\":") orelse return error.TestUnexpectedResult;
        const params = try std.fmt.allocPrint(alloc, "{{\"objectId\":\"{s}\",\"functionDeclaration\":\"function(){{ return this.message; }}\",\"returnByValue\":true}}", .{object_id});
        defer alloc.free(params);
        const message_at = try send(&session, "Runtime.callFunctionOn", params, 65);
        const message = try pumpResponse(&session, message_at, 65);
        try testing.expect(responseIsSuccess(message, 65));
        try testing.expect(std.mem.indexOf(u8, message, "public-abi-marker") != null);
    }
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_value_release(exception));

    const hostile = "throw { marker: 'public-abi-hostile', toString: function(){ globalThis.__cdpToStringCalled = true; throw new Error('must-not-coerce'); } };";
    value = 0;
    exception = 0;
    const hostile_from = session.got.items.len;
    try testing.expectEqual(@as(c_int, 1), c_api.js_bay_engine_evaluate(id, .{ .data = hostile.ptr, .len = hostile.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
    try testing.expect(try pumpFor(&session, hostile_from, "Runtime.exceptionThrown", 40));
    const check_at = try send(&session, "Runtime.evaluate", "{\"expression\":\"globalThis.__cdpToStringCalled === undefined\",\"returnByValue\":true}", 64);
    const check = try pumpResponse(&session, check_at, 64);
    try testing.expect(responseIsSuccess(check, 64));
    const inspector_coerced = std.mem.indexOf(u8, check, "\"value\":true") == null;
    try testing.expectEqual(baseline_coerced, inspector_coerced);
    try testing.expectEqual(@as(c_int, 0), c_api.js_bay_value_release(exception));
}

test "cdp alignment: Runtime.exceptionThrown reports an uncaught timer callback throw" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-timer-exception");
    defer session.deinit();

    const enable_at = try send(&session, "Runtime.enable", "", 55);
    _ = try pumpResponse(&session, enable_at, 55);
    const from = session.got.items.len;
    const scheduled = engine.evalScript(session.id, "setTimeout(function(){ throw new Error('cdp-timer-uncaught'); }, 0);", "timer-throw.js");
    defer discardEval(scheduled);
    try testing.expect(scheduled.err == null);
    try testing.expect(try pumpFor(&session, from, "Runtime.exceptionThrown", 80));
    const event = session.got.items[from..];
    try testing.expect(std.mem.indexOf(u8, event, "cdp-timer-uncaught") != null);
}

test "cdp alignment: Runtime.exceptionThrown reports an uncaught queueMicrotask throw" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-microtask-exception");
    defer session.deinit();

    const enable_at = try send(&session, "Runtime.enable", "", 56);
    _ = try pumpResponse(&session, enable_at, 56);
    const from = session.got.items.len;
    const scheduled = engine.evalScript(session.id, "queueMicrotask(function(){ throw new Error('cdp-microtask-uncaught'); });", "microtask-throw.js");
    defer discardEval(scheduled);
    try testing.expect(scheduled.err == null);
    try testing.expect(try pumpFor(&session, from, "Runtime.exceptionThrown", 80));
    const event = session.got.items[from..];
    try testing.expect(std.mem.indexOf(u8, event, "cdp-microtask-uncaught") != null);
}

test "cdp alignment: Runtime revokes the same exceptionId after a late Promise catch" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-rejection-exception");
    defer session.deinit();

    const enable_at = try send(&session, "Runtime.enable", "", 61);
    _ = try pumpResponse(&session, enable_at, 61);

    const rejected_from = session.got.items.len;
    const rejected = engine.evalScript(session.id, "globalThis.__cdpLateCatch = Promise.reject(new Error('cdp-late-rejection'));", "late-rejection.js");
    defer discardEval(rejected);
    try testing.expect(rejected.err == null);
    try testing.expect(try pumpFor(&session, rejected_from, "Runtime.exceptionThrown", 40));
    const rejection_event = session.got.items[rejected_from..];
    try testing.expect(std.mem.indexOf(u8, rejection_event, "cdp-late-rejection") != null);
    const exception_id = intAfter(rejection_event, "\"exceptionId\":") orelse return error.TestUnexpectedResult;

    const revoked_from = session.got.items.len;
    const handled = engine.evalScript(session.id, "globalThis.__cdpLateCatch.catch(function () {});", "late-rejection.js");
    defer discardEval(handled);
    try testing.expect(handled.err == null);
    try testing.expect(try pumpFor(&session, revoked_from, "Runtime.exceptionRevoked", 40));
    const revoked_event = session.got.items[revoked_from..];
    var id_marker: [48]u8 = undefined;
    const expected_id = try std.fmt.bufPrint(&id_marker, "\"exceptionId\":{d}", .{exception_id});
    try testing.expect(std.mem.indexOf(u8, revoked_event, expected_id) != null);
}

test "cdp alignment: inspector exception reporting does not replace an existing host rejection tracker" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var host_log = HostRejectionLog{};
    try testing.expect(promise.setRejectionTracker(id, hostRejectionTracker, &host_log));
    const handle = try inspector.start(id, .{ .port = 0, .target_id = "cdp-alignment-host-rejection-tracker" });
    const stream = try wire.connect(inspector.boundPort(handle));
    try wire.doWsHandshake(alloc, stream, "cdp-alignment-host-rejection-tracker");
    var session = Session{ .alloc = alloc, .id = id, .handle = handle, .stream = stream, .reader = wire.FrameReader.init(stream) };
    defer session.deinit();
    // The public callback owns host data, so detach it before Session.deinit destroys the engine. Inspector reporting must only add a subscriber.
    defer _ = promise.setRejectionTracker(id, null, null);

    const enable_at = try send(&session, "Runtime.enable", "", 62);
    _ = try pumpResponse(&session, enable_at, 62);
    const from = session.got.items.len;
    const rejected = engine.evalScript(id, "Promise.reject(new Error('cdp-host-tracker-still-called'));", "host-tracker.js");
    defer discardEval(rejected);
    try testing.expect(rejected.err == null);
    try testing.expect(try pumpFor(&session, from, "Runtime.exceptionThrown", 40));
    try testing.expectEqual(@as(u32, 1), host_log.count);
    try testing.expect(!host_log.saw_handled);
}

test "cdp alignment: Profiler.setSamplingInterval validates and configures the next profile" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-profiler");
    defer session.deinit();

    var at = try send(&session, "Profiler.enable", "", 1);
    var response = try pumpResponse(&session, at, 1);
    try testing.expect(responseIsSuccess(response, 1));

    at = try send(&session, "Profiler.setSamplingInterval", "{\"interval\":1000}", 2);
    response = try pumpResponse(&session, at, 2);
    try testing.expect(responseIsSuccess(response, 2));

    at = try send(&session, "Profiler.start", "", 3);
    response = try pumpResponse(&session, at, 3);
    try testing.expect(responseIsSuccess(response, 3));

    at = try send(&session, "Profiler.setSamplingInterval", "{\"interval\":0}", 4);
    response = try pumpResponse(&session, at, 4);
    try testing.expect(responseHasServerError(response, 4));

    at = try send(&session, "Profiler.setSamplingInterval", "{\"interval\":2000}", 5);
    response = try pumpResponse(&session, at, 5);
    // V8's inspector returns ServerError while a profile is active; this is a state error, rather than a malformed-parameter error.
    try testing.expect(responseHasServerError(response, 5));

    at = try send(&session, "Profiler.stop", "", 6);
    response = try pumpResponse(&session, at, 6);
    try testing.expect(responseIsSuccess(response, 6));
}

test "cdp alignment: Profiler.start does not override the configured sampling interval" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-profiler-start-interval");
    defer session.deinit();

    var at = try send(&session, "Profiler.enable", "", 1);
    var response = try pumpResponse(&session, at, 1);
    try testing.expect(responseIsSuccess(response, 1));

    at = try send(&session, "Profiler.setSamplingInterval", "{\"interval\":2000000000}", 2);
    response = try pumpResponse(&session, at, 2);
    try testing.expect(responseIsSuccess(response, 2));

    at = try send(&session, "Profiler.start", "{\"samplingInterval\":0}", 3);
    response = try pumpResponse(&session, at, 3);
    try testing.expect(responseIsSuccess(response, 3));

    const evaluated = engine.evalScript(session.id, "function configuredIntervalSpin(){var i=0;while(i<2000000)i++;}configuredIntervalSpin();", "configured-interval.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);

    at = try send(&session, "Profiler.stop", "", 4);
    response = try pumpResponse(&session, at, 4);
    try testing.expect(responseIsSuccess(response, 4));
    try testing.expect(std.mem.indexOf(u8, response, "\"totalSamples\":1") != null);
}

test "cdp alignment: Performance metrics have a live timestamp and real heap usage" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-performance");
    defer session.deinit();

    const evaluated = engine.evalScript(session.id, "globalThis.__cdpMetricBlob = new Array(4096).fill('cdp-metric-pad');", "metrics.js");
    defer if (evaluated.result) |value| std.heap.c_allocator.free(value);
    defer if (evaluated.err) |err| if (evaluated.err_is_heap) std.heap.c_allocator.free(err);
    try testing.expect(evaluated.err == null);

    var at = try send(&session, "Performance.enable", "", 11);
    var response = try pumpResponse(&session, at, 11);
    try testing.expect(responseIsSuccess(response, 11));

    at = try send(&session, "Performance.getMetrics", "", 12);
    response = try pumpResponse(&session, at, 12);
    try testing.expect(responseIsSuccess(response, 12));
    try testing.expect(std.mem.indexOf(u8, response, "\"metrics\":[") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Timestamp\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"JSHeapUsedSize\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"JSHeapTotalSize\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"value\":0") == null);

    at = try send(&session, "Performance.disable", "", 13);
    response = try pumpResponse(&session, at, 13);
    try testing.expect(responseIsSuccess(response, 13));

    at = try send(&session, "Performance.getMetrics", "", 14);
    response = try pumpResponse(&session, at, 14);
    // Chromium returns success with an empty list while Performance is disabled.
    try testing.expect(responseIsSuccess(response, 14));
    try testing.expect(std.mem.indexOf(u8, response, "\"metrics\":[]") != null);
}

test "cdp alignment: Performance reports backend-specific measurable metrics" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-performance-backend");
    defer session.deinit();

    const enable_at = try send(&session, "Performance.enable", "", 15);
    var response = try pumpResponse(&session, enable_at, 15);
    try testing.expect(responseIsSuccess(response, 15));

    const metrics_at = try send(&session, "Performance.getMetrics", "", 16);
    response = try pumpResponse(&session, metrics_at, 16);
    try testing.expect(responseIsSuccess(response, 16));
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Timestamp\"") != null);
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"JSHeapUsedSize\"") != null);
        try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"JSHeapTotalSize\"") != null);
    } else {
        // Public JSC exposes no trustworthy heap byte counter.  A zero-valued pseudo metric would be a false capability claim.
        try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"JSHeapUsedSize\"") == null);
        try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"JSHeapTotalSize\"") == null);
    }
}

test "cdp alignment: Performance rejects unsupported threadTicks at both protocol entry points" {
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-alignment-performance-time-domain");
    defer session.deinit();

    var at = try send(&session, "Performance.setTimeDomain", "{\"timeDomain\":\"threadTicks\"}", 17);
    var response = try pumpResponse(&session, at, 17);
    try testing.expect(responseHasServerError(response, 17));

    at = try send(&session, "Performance.enable", "{\"timeDomain\":\"threadTicks\"}", 18);
    response = try pumpResponse(&session, at, 18);
    try testing.expect(responseHasServerError(response, 18));

    at = try send(&session, "Performance.enable", "{\"timeDomain\":\"timeTicks\"}", 19);
    response = try pumpResponse(&session, at, 19);
    try testing.expect(responseIsSuccess(response, 19));

    // CDP also requires a time-domain change after enable to fail, even when the caller asks for the currently selected domain.
    at = try send(&session, "Performance.setTimeDomain", "{\"timeDomain\":\"timeTicks\"}", 20);
    response = try pumpResponse(&session, at, 20);
    try testing.expect(responseHasServerError(response, 20));
}

test "cdp regression: Debugger.getPossibleBreakpoints defaults end to script end" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-possible-default-end");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 801), 801);
    const evaluated = engine.evalScript(session.id, "let first = globalThis.__reviewInput;\nfirst += 1;", "review-default-end.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expect(try pumpFor(&session, 0, "\"url\":\"review-default-end.js\"", 20));
    const script_id = scriptIdForUrl(session.got.items, "\"url\":\"review-default-end.js\"") orelse return error.TestUnexpectedResult;
    const response = try possibleBreakpointsToScriptEnd(&session, 802, script_id);
    try testing.expect(responseIsSuccess(response, 802));
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":1") != null);
}

test "cdp regression: Debugger keeps B locations after A B A with one URL" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-same-url-aba");
    defer session.deinit();
    const a_source = "globalThis.__reviewA = globalThis.__reviewInput;\nglobalThis.__reviewA += 1;";
    const b_source = "\n\n\nglobalThis.__reviewB = globalThis.__reviewInput;\nglobalThis.__reviewB += 1;";
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 811), 811);
    const a1 = engine.evalScript(session.id, a_source, "review-aba.js");
    defer discardEval(a1);
    const b = engine.evalScript(session.id, b_source, "review-aba.js");
    defer discardEval(b);
    const a2 = engine.evalScript(session.id, a_source, "review-aba.js");
    defer discardEval(a2);
    try testing.expect(a1.err == null and b.err == null and a2.err == null);
    // The third A execution reuses A's existing id, so there are two distinct script entries: A and B.  Query B after the reuse.
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"review-aba.js\"", 2));
    var ids: [4]?[]const u8 = @splat(null);
    try testing.expectEqual(@as(usize, 2), scriptIdsForUrl(session.got.items, "\"url\":\"review-aba.js\"", &ids));
    const b_id = try alloc.dupe(u8, ids[1].?);
    defer alloc.free(b_id);
    const response = try possibleBreakpoints(&session, 812, b_id, 8);
    try testing.expect(responseIsSuccess(response, 812));
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":3") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"lineNumber\":4") != null);
}

test "cdp regression: Runtime.evaluate input scriptId has its own locations" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-runtime-input-script");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 821), 821);
    const response = try pumpResponse(&session, try send(&session, "Runtime.evaluate", "{\"expression\":\"let inputValue = globalThis.__reviewInput;\\ninputValue += 1;\"}", 822), 822);
    try testing.expect(responseIsSuccess(response, 822));
    try testing.expect(try pumpFor(&session, 0, "\"url\":\"<input>\"", 20));
    const script_id = scriptIdForUrl(session.got.items, "\"url\":\"<input>\"") orelse return error.TestUnexpectedResult;
    const locations = try possibleBreakpoints(&session, 823, script_id, 4);
    try testing.expect(responseIsSuccess(locations, 823));
    try testing.expect(std.mem.indexOf(u8, locations, "\"lineNumber\":1") != null);
}

test "cdp regression: Runtime.evaluate A B A keeps B possible breakpoints" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-repl-aba");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 841), 841);

    const a = "globalThis.__reviewR3A = globalThis.__reviewInput;\nglobalThis.__reviewR3A += 1;";
    const b = "\n\n\nglobalThis.__reviewR3B = globalThis.__reviewInput;\nglobalThis.__reviewR3B += 1;";
    var params = try std.fmt.allocPrint(alloc, "{{\"expression\":{f}}}", .{std.json.fmt(a, .{})});
    defer alloc.free(params);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, try send(&session, "Runtime.evaluate", params, 842), 842), 842));
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"<input>\"", 1));
    const a_id_slice = scriptIdForUrl(session.got.items, "\"url\":\"<input>\"") orelse return error.TestUnexpectedResult;
    const a_id = try alloc.dupe(u8, a_id_slice);
    defer alloc.free(a_id);

    alloc.free(params);
    params = try std.fmt.allocPrint(alloc, "{{\"expression\":{f}}}", .{std.json.fmt(b, .{})});
    try testing.expect(responseIsSuccess(try pumpResponse(&session, try send(&session, "Runtime.evaluate", params, 843), 843), 843));
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"<input>\"", 2));
    var ids: [4]?[]const u8 = @splat(null);
    try testing.expectEqual(@as(usize, 2), scriptIdsForUrl(session.got.items, "\"url\":\"<input>\"", &ids));
    const b_id = try alloc.dupe(u8, ids[1].?);
    defer alloc.free(b_id);

    alloc.free(params);
    params = try std.fmt.allocPrint(alloc, "{{\"expression\":{f}}}", .{std.json.fmt(a, .{})});
    try testing.expect(responseIsSuccess(try pumpResponse(&session, try send(&session, "Runtime.evaluate", params, 844), 844), 844));

    const b_locations = try possibleBreakpoints(&session, 845, b_id, 8);
    try testing.expect(responseIsSuccess(b_locations, 845));
    try testing.expect(std.mem.indexOf(u8, b_locations, "\"lineNumber\":3") != null);
    try testing.expect(std.mem.indexOf(u8, b_locations, "\"lineNumber\":4") != null);
    const a_locations = try possibleBreakpoints(&session, 846, a_id, 4);
    try testing.expect(responseIsSuccess(a_locations, 846));
    try testing.expect(std.mem.indexOf(u8, a_locations, "\"lineNumber\":0") != null);
    try testing.expect(std.mem.indexOf(u8, a_locations, "\"lineNumber\":1") != null);
}

test "cdp regression: awaitPromise by-value serialization failures reply" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-await-by-value-errors");
    defer session.deinit();
    const cyclic = try evaluatePromise(&session, 831, "Promise.resolve((function(){ const x = {}; x.self = x; return x; })())");
    defer alloc.free(cyclic);
    const cyclic_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{cyclic});
    defer alloc.free(cyclic_params);
    var response = try pumpResponse(&session, try send(&session, "Runtime.awaitPromise", cyclic_params, 832), 832);
    try testing.expect(!responseIsSuccess(response, 832));
    try testing.expect(std.mem.indexOf(u8, response, "\"error\":") != null or std.mem.indexOf(u8, response, "\"exceptionDetails\":") != null);
    const getter = try evaluatePromise(&session, 833, "Promise.resolve(Object.defineProperty({}, 'x', { enumerable: true, get: function(){ throw new Error('review-getter'); } }))");
    defer alloc.free(getter);
    const getter_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{getter});
    defer alloc.free(getter_params);
    response = try pumpResponse(&session, try send(&session, "Runtime.awaitPromise", getter_params, 834), 834);
    try testing.expect(!responseIsSuccess(response, 834));
    try testing.expect(std.mem.indexOf(u8, response, "\"error\":") != null or std.mem.indexOf(u8, response, "\"exceptionDetails\":") != null);
}

test "cdp regression: awaitPromise does not invoke promise constructor accessors" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-await-species");
    defer session.deinit();
    const promise_id = try evaluatePromise(&session, 841, "(function(){ const p = Promise.resolve(9); Object.defineProperty(p, 'constructor', { get: function(){ globalThis.__reviewConstructorRead = true; return Promise; } }); return p; })()");
    defer alloc.free(promise_id);
    const params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{promise_id});
    defer alloc.free(params);
    const response = try pumpResponse(&session, try send(&session, "Runtime.awaitPromise", params, 842), 842);
    try testing.expect(responseIsSuccess(response, 842));
    const check = try pumpResponse(&session, try send(&session, "Runtime.evaluate", "{\"expression\":\"globalThis.__reviewConstructorRead === undefined\",\"returnByValue\":true}", 843), 843);
    try testing.expect(responseIsSuccess(check, 843));
    try testing.expect(std.mem.indexOf(u8, check, "\"value\":true") != null);
}

test "cdp regression: inspector rejection observer does not coerce hostile reason" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-hostile-rejection");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Runtime.enable", "", 851), 851);
    const rejected = engine.evalScript(session.id, "Promise.reject({ toString: function(){ globalThis.__reviewRejectionCoerced = true; return 'bad'; } });", "review-hostile-rejection.js");
    defer discardEval(rejected);
    try testing.expect(rejected.err == null);
    _ = try pumpFor(&session, session.got.items.len, "Runtime.exceptionThrown", 40);
    const check = try pumpResponse(&session, try send(&session, "Runtime.evaluate", "{\"expression\":\"globalThis.__reviewRejectionCoerced === undefined\",\"returnByValue\":true}", 852), 852);
    try testing.expect(responseIsSuccess(check, 852));
    try testing.expect(std.mem.indexOf(u8, check, "\"value\":true") != null);
}

fn reviewInvalidBreakpointStartLine(line_json: []const u8, request_id: i64) !void {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-invalid-breakpoint-line");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", request_id), request_id);
    const evaluated = engine.evalScript(session.id, "globalThis.__reviewLine = 1;", "review-invalid-line.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expect(try pumpFor(&session, 0, "\"url\":\"review-invalid-line.js\"", 20));
    const script_id = scriptIdForUrl(session.got.items, "\"url\":\"review-invalid-line.js\"") orelse return error.TestUnexpectedResult;
    const params = try std.fmt.allocPrint(alloc, "{{\"start\":{{\"scriptId\":\"{s}\",\"lineNumber\":{s}}}}}", .{ script_id, line_json });
    defer alloc.free(params);
    const bad = try pumpResponse(&session, try send(&session, "Debugger.getPossibleBreakpoints", params, request_id + 1), request_id + 1);
    try testing.expect(std.mem.indexOf(u8, bad, "\"code\":-32602") != null);
    const good = try pumpResponse(&session, try send(&session, "Runtime.evaluate", "{\"expression\":\"1\",\"returnByValue\":true}", request_id + 2), request_id + 2);
    try testing.expect(responseIsSuccess(good, request_id + 2));
}

test "cdp regression: huge positive breakpoint line is an invalid request" {
    try reviewInvalidBreakpointStartLine("1e100", 861);
}

test "cdp regression: huge negative breakpoint line is an invalid request" {
    try reviewInvalidBreakpointStartLine("-1e100", 871);
}

test "cdp regression: fractional breakpoint line is an invalid request" {
    try reviewInvalidBreakpointStartLine("0.5", 881);
}

test "cdp regression: i32 overflow breakpoint line is an invalid request" {
    try reviewInvalidBreakpointStartLine("2147483648", 891);
}

test "cdp governance: an old closure pause keeps its original same-url script identity" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-governance-old-closure");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 1301), 1301);

    const original_source = "globalThis.__governanceOld = function(){ debugger; return 1; };";
    const original = engine.evalScript(session.id, original_source, "governance-same-url.js");
    defer discardEval(original);
    try testing.expect(original.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-same-url.js\"", 1));
    var ids: [4]?[]const u8 = @splat(null);
    try testing.expectEqual(@as(usize, 1), scriptIdsForUrl(session.got.items, "\"url\":\"governance-same-url.js\"", &ids));
    const original_id = try alloc.dupe(u8, ids[0].?);
    defer alloc.free(original_id);

    const replacement = engine.evalScript(session.id, "globalThis.__governanceReplacement = 2;", "governance-same-url.js");
    defer discardEval(replacement);
    try testing.expect(replacement.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-same-url.js\"", 2));
    ids = @splat(null);
    try testing.expectEqual(@as(usize, 2), scriptIdsForUrl(session.got.items, "\"url\":\"governance-same-url.js\"", &ids));
    const replacement_id = try alloc.dupe(u8, ids[1].?);
    defer alloc.free(replacement_id);
    try testing.expect(!std.mem.eql(u8, original_id, replacement_id));

    const source_params = try std.fmt.allocPrint(alloc, "{{\"scriptId\":\"{s}\"}}", .{original_id});
    defer alloc.free(source_params);
    const source = try pumpResponse(&session, try send(&session, "Debugger.getScriptSource", source_params, 1302), 1302);
    try testing.expect(std.mem.indexOf(u8, source, "__governanceOld") != null);

    var invoke = EvalProbe{ .id = session.id, .source = "globalThis.__governanceOld();", .filename = "governance-trigger.js" };
    const invoke_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&invoke});
    const paused_from = session.got.items.len;
    const paused = try waitForFrame(&session, paused_from, "Debugger.paused", 80);
    const paused_event = session.got.items[paused_from..];
    const resume_at = try send(&session, "Debugger.resume", "", 1303);
    try testing.expect(try waitResponseNoTick(&session, resume_at, 1303));
    invoke_thread.join();
    try testing.expect(paused);
    try testing.expect(invoke.ok);

    const old_frame = try std.fmt.allocPrint(alloc, "\"scriptId\":\"{s}\"", .{original_id});
    defer alloc.free(old_frame);
    const replacement_frame = try std.fmt.allocPrint(alloc, "\"scriptId\":\"{s}\"", .{replacement_id});
    defer alloc.free(replacement_frame);
    try testing.expect(std.mem.indexOf(u8, paused_event, old_frame) != null);
    try testing.expect(std.mem.indexOf(u8, paused_event, replacement_frame) == null);
}

test "cdp governance: an old closure console stack keeps its original same-url script identity" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-governance-old-console-closure");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Runtime.enable", "", 1311), 1311);
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 1312), 1312);

    const original = engine.evalScript(session.id, "globalThis.__governanceOldConsole = function(){ console.log('governance-old-console'); };", "governance-console-same-url.js");
    defer discardEval(original);
    try testing.expect(original.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-console-same-url.js\"", 1));
    var ids: [4]?[]const u8 = @splat(null);
    try testing.expectEqual(@as(usize, 1), scriptIdsForUrl(session.got.items, "\"url\":\"governance-console-same-url.js\"", &ids));
    const original_id = try alloc.dupe(u8, ids[0].?);
    defer alloc.free(original_id);

    const replacement = engine.evalScript(session.id, "globalThis.__governanceConsoleReplacement = 2;", "governance-console-same-url.js");
    defer discardEval(replacement);
    try testing.expect(replacement.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-console-same-url.js\"", 2));
    ids = @splat(null);
    try testing.expectEqual(@as(usize, 2), scriptIdsForUrl(session.got.items, "\"url\":\"governance-console-same-url.js\"", &ids));
    const replacement_id = try alloc.dupe(u8, ids[1].?);
    defer alloc.free(replacement_id);

    const console_from = session.got.items.len;
    const invoke = engine.evalScript(session.id, "globalThis.__governanceOldConsole();", "governance-console-trigger.js");
    defer discardEval(invoke);
    try testing.expect(invoke.err == null);
    try testing.expect(try pumpFor(&session, console_from, "governance-old-console", 40));
    const console_event = session.got.items[console_from..];
    const old_frame = try std.fmt.allocPrint(alloc, "\"scriptId\":\"{s}\"", .{original_id});
    defer alloc.free(old_frame);
    const replacement_frame = try std.fmt.allocPrint(alloc, "\"scriptId\":\"{s}\"", .{replacement_id});
    defer alloc.free(replacement_frame);
    try testing.expect(std.mem.indexOf(u8, console_event, old_frame) != null);
    try testing.expect(std.mem.indexOf(u8, console_event, replacement_frame) == null);
}

test "cdp governance: nested eval locations do not contaminate the outer script" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-governance-nested-eval");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 1321), 1321);
    const outer_source = "globalThis.__governanceOuter = 1;\neval('\\n\\n\\nglobalThis.__governanceNested = globalThis.__governanceOuter + 1;');";
    const evaluated = engine.evalScript(session.id, outer_source, "governance-nested.js");
    defer discardEval(evaluated);
    try testing.expect(evaluated.err == null);
    try testing.expect(try pumpFor(&session, 0, "\"url\":\"governance-nested.js\"", 20));
    const outer_id = scriptIdForUrl(session.got.items, "\"url\":\"governance-nested.js\"") orelse return error.TestUnexpectedResult;
    const locations = try possibleBreakpoints(&session, 1322, outer_id, 8);
    try testing.expect(responseIsSuccess(locations, 1322));
    try testing.expect(std.mem.indexOf(u8, locations, "\"lineNumber\":0") != null);
    try testing.expect(std.mem.indexOf(u8, locations, "\"lineNumber\":3") == null);
}

test "cdp governance: a cached C ABI closure keeps its script identity after a same-url replacement" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openCapiSession(alloc, "cdp-governance-cached-closure");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 1331), 1331);

    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const cache_dir = try temp.dir.realPathFileAlloc(testing.io, ".", alloc);
    defer alloc.free(cache_dir);
    const source = "globalThis.__governanceCachedClosure = function(){ debugger; return 17; };";
    const filename = "governance-cached-same-url.js";
    var cache_hit = false;
    const options = c_api.EvalOptions{
        .struct_size = @sizeOf(c_api.EvalOptions),
        .cache_dir = .{ .data = cache_dir.ptr, .len = cache_dir.len },
        .cache_version = .{ .data = "governance-v1", .len = "governance-v1".len },
        .out_cache_hit = &cache_hit,
    };
    for (0..2) |run| {
        var value: u64 = 0;
        var exception: u64 = 0;
        cache_hit = false;
        try testing.expectEqual(@as(c_int, 0), c_api.js_bay_engine_evaluate(
            session.id,
            .{ .data = source.ptr, .len = source.len },
            .{ .data = filename.ptr, .len = filename.len },
            &options,
            &value,
            &exception,
        ));
        defer _ = c_api.js_bay_value_release(value);
        try testing.expectEqual(@as(u64, 0), exception);
        try testing.expectEqual(run == 1, cache_hit);
    }
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-cached-same-url.js\"", 1));
    var ids: [4]?[]const u8 = @splat(null);
    try testing.expectEqual(@as(usize, 1), scriptIdsForUrl(session.got.items, "\"url\":\"governance-cached-same-url.js\"", &ids));
    const cached_id = try alloc.dupe(u8, ids[0].?);
    defer alloc.free(cached_id);

    const replacement = engine.evalScript(session.id, "globalThis.__governanceCachedReplacement = 3;", filename);
    defer discardEval(replacement);
    try testing.expect(replacement.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-cached-same-url.js\"", 2));
    ids = @splat(null);
    try testing.expectEqual(@as(usize, 2), scriptIdsForUrl(session.got.items, "\"url\":\"governance-cached-same-url.js\"", &ids));
    const replacement_id = try alloc.dupe(u8, ids[1].?);
    defer alloc.free(replacement_id);

    const source_params = try std.fmt.allocPrint(alloc, "{{\"scriptId\":\"{s}\"}}", .{cached_id});
    defer alloc.free(source_params);
    const cached_source = try pumpResponse(&session, try send(&session, "Debugger.getScriptSource", source_params, 1332), 1332);
    try testing.expect(std.mem.indexOf(u8, cached_source, "__governanceCachedClosure") != null);

    var invoke = EvalProbe{ .id = session.id, .source = "globalThis.__governanceCachedClosure();", .filename = "governance-cached-trigger.js" };
    const invoke_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&invoke});
    const paused_from = session.got.items.len;
    const paused = try waitForFrame(&session, paused_from, "Debugger.paused", 80);
    const paused_event = session.got.items[paused_from..];
    const resume_at = try send(&session, "Debugger.resume", "", 1333);
    try testing.expect(try waitResponseNoTick(&session, resume_at, 1333));
    invoke_thread.join();
    try testing.expect(paused);
    try testing.expect(invoke.ok);

    const cached_frame = try std.fmt.allocPrint(alloc, "\"scriptId\":\"{s}\"", .{cached_id});
    defer alloc.free(cached_frame);
    const replacement_frame = try std.fmt.allocPrint(alloc, "\"scriptId\":\"{s}\"", .{replacement_id});
    defer alloc.free(replacement_frame);
    try testing.expect(std.mem.indexOf(u8, paused_event, cached_frame) != null);
    try testing.expect(std.mem.indexOf(u8, paused_event, replacement_frame) == null);
}

test "cdp governance: an evicted old closure is never attributed to a newer same-url script" {
    if (comptime backend.active_backend != .quickjs_ng) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-governance-evicted-closure");
    defer session.deinit();
    _ = try pumpResponse(&session, try send(&session, "Debugger.enable", "", 1341), 1341);
    const filename = "governance-evicted-same-url.js";
    const original = engine.evalScript(session.id, "globalThis.__governanceEvictedClosure = function(){ debugger; };", filename);
    defer discardEval(original);
    try testing.expect(original.err == null);
    try testing.expect(try waitForScriptIds(&session, "\"url\":\"governance-evicted-same-url.js\"", 1));
    const original_text_id = scriptIdForUrl(session.got.items, "\"url\":\"governance-evicted-same-url.js\"") orelse return error.TestUnexpectedResult;
    const original_id = try std.fmt.parseInt(u32, original_text_id, 10);

    for (0..debugger_mod.max_retained_scripts + 1) |revision| {
        const source = try std.fmt.allocPrint(alloc, "globalThis.__governanceJournalRevision={d};", .{revision});
        defer alloc.free(source);
        const evaluated = engine.evalScript(session.id, source, filename);
        defer discardEval(evaluated);
        try testing.expect(evaluated.err == null);
    }
    try testing.expect(debugger_mod.scriptById(session.id, original_id) == null);

    var invoke = EvalProbe{ .id = session.id, .source = "globalThis.__governanceEvictedClosure();", .filename = "governance-evicted-trigger.js" };
    const invoke_thread = try std.Thread.spawn(.{}, EvalProbe.run, .{&invoke});
    const paused_from = session.got.items.len;
    const paused = try waitForFrame(&session, paused_from, "Debugger.paused", 400);
    const paused_event = session.got.items[paused_from..];
    const resume_at = try send(&session, "Debugger.resume", "", 1342);
    try testing.expect(try waitResponseNoTick(&session, resume_at, 1342));
    invoke_thread.join();
    try testing.expect(paused);
    try testing.expect(invoke.ok);
    try testing.expect(std.mem.indexOf(u8, paused_event, "\"scriptId\":\"0\"") != null);
}

test "cdp regression: by-value await settlement may stop inspector from a host callback" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-l4-native-stop");
    defer {
        session.got.deinit(alloc);
        session.reader.deinit(alloc);
        session.stream.close();
        // The tested host callback normally owns the stop. Retain the normal cleanup path only if an earlier assertion prevented that callback.
        if (inspector_state.stateByInstance(session.id) != null) inspector.stop(session.handle);
        engine.destroy(session.id);
    }
    var host = NativeStopHost{ .handle = session.handle };
    try testing.expect(engine_thread.hostInstall(session.id, "reviewNativeStop", NativeStopHost.call, @ptrCast(&host)));
    // Attach the await while its Promise is still pending. A normal host-side eval then resolves it; the enumerable getter runs in settlement and re-enters inspector.stop while the settlement lease is held.
    const promise_id = try evaluatePromise(&session, 901, "globalThis.__reviewResolve = null; new Promise(function(resolve){ globalThis.__reviewResolve = resolve; })");
    defer alloc.free(promise_id);
    const params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{promise_id});
    defer alloc.free(params);
    _ = try send(&session, "Runtime.awaitPromise", params, 902);
    // The immediate command reply is a reader-order barrier: receiving it proves the preceding await frame was parsed and posted before we drain that posted work on the owner thread.
    _ = try pumpResponse(&session, try send(&session, "Runtime.getIsolateId", "", 903), 903);
    _ = dispatch.tickInstance(session.id);
    engine.runEventLoopOnce(session.id);
    const resolve = engine.evalScript(session.id, "globalThis.__reviewResolve(Object.defineProperty({}, 'x', { enumerable:true, get:function(){ reviewNativeStop(); return 1; } }));", "review-l4-resolve.js");
    defer discardEval(resolve);
    engine.runEventLoopOnce(session.id);
    // A correct implementation returns from stop and lets this ordinary eval complete. The watchdog process records the callback marker on deadlock.
    try testing.expect(host.entered.load(.seq_cst));
}

test "cdp regression: disconnected queued awaits cannot consume the next session's state capacity" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "cdp-review-l5-queued-disconnect");
    defer session.deinit();
    const state = inspector_state.stateByInstance(session.id) orelse return error.TestUnexpectedResult;

    // Obtain the object ID before withholding the owner's pump. Every later await frame is parsed by its reader, then its session is confirmed gone before any queued RequestBox can run on the JS thread.
    const pending = try evaluatePromise(&session, 911, "new Promise(function(){})");
    defer alloc.free(pending);
    const pending_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\"}}", .{pending});
    defer alloc.free(pending_params);

    var batch: usize = 0;
    while (batch < 4) : (batch += 1) {
        if (batch != 0) {
            session.stream = try wire.connect(inspector.boundPort(session.handle));
            try wire.doWsHandshake(alloc, session.stream, "cdp-review-l5-queued-disconnect");
            session.reader = wire.FrameReader.init(session.stream);
        }
        // The reader response confirms this handshake's session_opened event was processed before we observe the session list.
        const barrier_id: i64 = @intCast(900 + batch);
        const barrier_at = try send(&session, "Runtime.getIsolateId", "", barrier_id);
        try testing.expect(try waitResponseNoTick(&session, barrier_at, barrier_id));
        try testing.expect(responseIsSuccess(session.got.items[barrier_at..], barrier_id));
        const old_session_id = try onlySessionId(state);
        var request: usize = 0;
        while (request < 64) : (request += 1) {
            _ = try send(&session, "Runtime.awaitPromise", pending_params, @as(i64, @intCast(batch * 100 + request)) + 920);
        }
        session.stream.close();
        // EOF is delivered after all preceding frames. This state transition proves the reader parsed the batch and dispatched session_closed, without draining the owner queue in between.
        try waitForSessionRemoval(state, old_session_id);
        session.reader.deinit(alloc);
    }

    session.stream = try wire.connect(inspector.boundPort(session.handle));
    try wire.doWsHandshake(alloc, session.stream, "cdp-review-l5-queued-disconnect");
    session.reader = wire.FrameReader.init(session.stream);

    var drained: usize = 0;
    while (drained < 256) : (drained += 1) {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
    }

    const settled = try evaluatePromise(&session, 1301, "Promise.resolve('new-session-await')");
    defer alloc.free(settled);
    const settled_params = try std.fmt.allocPrint(alloc, "{{\"promiseObjectId\":\"{s}\",\"returnByValue\":true}}", .{settled});
    defer alloc.free(settled_params);
    const response = try pumpResponse(&session, try send(&session, "Runtime.awaitPromise", settled_params, 1302), 1302);
    try testing.expect(responseIsSuccess(response, 1302));
    try testing.expect(std.mem.indexOf(u8, response, "new-session-await") != null);
}
