//! JSC async-stack behaviour at the CDP/WebSocket boundary.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
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

fn consoleEventForToken(payloads: []const u8, token: []const u8) ?[]const u8 {
    const token_at = std.mem.indexOf(u8, payloads, token) orelse return null;
    const event_start = std.mem.lastIndexOf(u8, payloads[0..token_at], "{\"method\":\"Runtime.consoleAPICalled\"") orelse return null;
    const event_end = std.mem.indexOfPos(u8, payloads, event_start, "}}}") orelse return null;
    return payloads[event_start .. event_end + 3];
}

fn pumpConsoleToken(session: *Session, from: usize, token: []const u8) ![]const u8 {
    var tries: usize = 0;
    while (tries < 80) : (tries += 1) {
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[from..], token) != null) {
            return consoleEventForToken(session.got.items[from..], token) orelse error.TestUnexpectedResult;
        }
    }
    std.debug.print("missing console token {s}:\n{s}\n", .{ token, session.got.items[from..] });
    return error.TestUnexpectedResult;
}

test "JSC async stack: an application then wrapper creates one Promise parent" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "jsc-async-wrapper-parent");
    defer session.deinit();

    const runtime_at = try send(&session, "Runtime.enable", "", 8101);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, runtime_at, 8101), 8101));

    const first_depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":1}", 8102);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, first_depth_at, 8102), 8102));
    const wrapped = engine.evalScript(
        session.id,
        "globalThis.__jscWrappedThen = Promise.prototype.then; Promise.prototype.then = function(a,b){ return globalThis.__jscWrappedThen.call(this,a,b); };",
        "jsc-async-wrapper-page.js",
    );
    defer helpers.freeEvalResult(wrapped);
    try testing.expect(wrapped.err == null);

    const zero_depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":0}", 8103);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, zero_depth_at, 8103), 8103));

    // Depth two makes both physical wrappers observable. There is still one application-level Promise scheduling edge, so its parent chain has one Promise link.
    const second_depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":2}", 8104);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, second_depth_at, 8104), 8104));

    const from = session.got.items.len;
    const scheduled = engine.evalScript(
        session.id,
        "function scheduleWrappedPromise(){ Promise.resolve().then(function wrappedPromiseCallback(){ console.log('jsc-wrapper-parent-token'); }); } scheduleWrappedPromise();",
        "jsc-async-wrapper-page.js",
    );
    defer helpers.freeEvalResult(scheduled);
    try testing.expect(scheduled.err == null);

    const event = try pumpConsoleToken(&session, from, "jsc-wrapper-parent-token");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, event, "\"description\":\"Promise\""));
    try testing.expect(std.mem.indexOf(u8, event, "scheduleWrappedPromise") != null);
}

test "JSC async stack: a closure then wrapper creates one Promise parent" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "jsc-async-closure-wrapper-parent");
    defer session.deinit();

    const runtime_at = try send(&session, "Runtime.enable", "", 8201);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, runtime_at, 8201), 8201));

    const first_depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":32}", 8202);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, first_depth_at, 8202), 8202));
    const wrapped = engine.evalScript(
        session.id,
        "globalThis.__jscClosureWrappedThen = Promise.prototype.then; Promise.prototype.then = function(a,b){ return globalThis.__jscClosureWrappedThen.call(this, typeof a === 'function' ? function(v){ return a(v); } : a, b); };",
        "jsc-async-closure-wrapper-page.js",
    );
    defer helpers.freeEvalResult(wrapped);
    try testing.expect(wrapped.err == null);

    const zero_depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":0}", 8203);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, zero_depth_at, 8203), 8203));
    const second_depth_at = try send(&session, "Debugger.setAsyncCallStackDepth", "{\"maxDepth\":32}", 8204);
    try testing.expect(responseIsSuccess(try pumpResponse(&session, second_depth_at, 8204), 8204));

    const from = session.got.items.len;
    const scheduled = engine.evalScript(
        session.id,
        "function scheduleClosureWrappedPromise(){ Promise.resolve().then(function closureWrappedPromiseCallback(){ console.log('jsc-closure-wrapper-parent-token'); }); } scheduleClosureWrappedPromise();",
        "jsc-async-closure-wrapper-page.js",
    );
    defer helpers.freeEvalResult(scheduled);
    try testing.expect(scheduled.err == null);

    const event = try pumpConsoleToken(&session, from, "jsc-closure-wrapper-parent-token");
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, event, "\"description\":\"Promise\""));
    try testing.expect(std.mem.indexOf(u8, event, "scheduleClosureWrappedPromise") != null);
}
