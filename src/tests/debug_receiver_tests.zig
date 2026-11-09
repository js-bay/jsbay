const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const inspector = @import("../inspector/root.zig");
const helpers = @import("test_helpers.zig");
const wire = @import("inspector_tests.zig");

const EvalBox = struct {
    id: i32,
    script: []const u8,
    filename: []const u8,
    result: []u8 = &.{},
    result_owned: bool = false,

    fn deinit(self: *EvalBox) void {
        if (self.result_owned) std.heap.c_allocator.free(self.result);
    }
};

fn evalMain(box: *EvalBox) void {
    const result = engine.evalScript(box.id, box.script, box.filename);
    if (result.result) |text| {
        defer std.heap.c_allocator.free(text);
        box.result = std.heap.c_allocator.dupe(u8, text) catch &.{};
        box.result_owned = box.result.len == text.len;
    }
    if (result.err) |text| if (result.err_is_heap) std.heap.c_allocator.free(text);
}

const Session = struct {
    alloc: std.mem.Allocator,
    id: i32,
    handle: *inspector.Handle,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    got: std.ArrayList(u8) = .empty,
    next_id: i64 = 1,
    eval_thread: ?std.Thread = null,

    fn deinit(self: *Session) void {
        debugger_mod.setBreakpointsActive(self.id, false);
        debugger_mod.abandon(self.id);
        if (self.eval_thread) |thread| {
            debugger_mod.resumeExecution(self.id);
            thread.join();
        }
        self.reader.deinit(self.alloc);
        self.stream.close();
        inspector.stop(self.handle);
        engine.destroy(self.id);
        self.got.deinit(self.alloc);
    }

    fn command(self: *Session, method: []const u8, params: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        const message = try std.fmt.allocPrint(self.alloc, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}", .{ id, method, params });
        defer self.alloc.free(message);
        try wire.writeMaskedText(self.stream, message);
        return id;
    }

    fn waitFrom(self: *Session, start: usize, needle: []const u8, attempts: usize) !bool {
        for (0..attempts) |_| {
            try wire.readTextFrames(self.alloc, &self.reader, &self.got, 1);
            if (std.mem.indexOf(u8, self.got.items[start..], needle) != null) return true;
        }
        return false;
    }

    fn waitId(self: *Session, start: usize, id: i64) !bool {
        const marker = try std.fmt.allocPrint(self.alloc, "\"id\":{d},", .{id});
        defer self.alloc.free(marker);
        return self.waitFrom(start, marker, 80);
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

fn enable(session: *Session) !void {
    const at = session.got.items.len;
    const id = try session.command("Debugger.enable", "{}");
    const marker = try std.fmt.allocPrint(session.alloc, "\"id\":{d},", .{id});
    defer session.alloc.free(marker);
    for (0..80) |_| {
        _ = dispatch.tickInstance(session.id);
        engine.runEventLoopOnce(session.id);
        try wire.readTextFrames(session.alloc, &session.reader, &session.got, 1);
        if (std.mem.indexOf(u8, session.got.items[at..], marker) != null) return;
    }
    return error.TestUnexpectedResult;
}

fn pause(session: *Session, box: *EvalBox) !usize {
    const at = session.got.items.len;
    session.eval_thread = try std.Thread.spawn(.{}, evalMain, .{box});
    try testing.expect(try session.waitFrom(at, "Debugger.paused", 160));
    return at;
}

fn evaluateReply(session: *Session, expression: []const u8) !std.json.Parsed(std.json.Value) {
    const at = session.got.items.len;
    const params = try std.fmt.allocPrint(session.alloc, "{{\"callFrameId\":\"0\",\"expression\":{f}}}", .{std.json.fmt(expression, .{})});
    defer session.alloc.free(params);
    const id = try session.command("Debugger.evaluateOnCallFrame", params);
    try testing.expect(try session.waitId(at, id));
    var lines = std.mem.splitScalar(u8, session.got.items[at..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const reply = try std.json.parseFromSlice(std.json.Value, session.alloc, line, .{ .allocate = .alloc_always });
        if (reply.value == .object) {
            if (reply.value.object.get("id")) |actual_id| {
                if (actual_id == .integer and actual_id.integer == id) {
                    errdefer reply.deinit();
                    try testing.expect(reply.value.object.get("error") == null);
                    return reply;
                }
            }
        }
        reply.deinit();
    }
    return error.MissingEvaluationReply;
}

fn evaluate(session: *Session, expression: []const u8, expected: []const u8) !void {
    const reply = try evaluateReply(session, expression);
    defer reply.deinit();
    const text = try std.fmt.allocPrint(session.alloc, "{f}", .{std.json.fmt(reply.value, .{})});
    defer session.alloc.free(text);
    if (std.mem.indexOf(u8, text, expected) == null)
        std.debug.print("receiver evaluation: {s}\n", .{text});
    try testing.expect(std.mem.indexOf(u8, text, expected) != null);
}

fn resumeSession(session: *Session) !void {
    const at = session.got.items.len;
    _ = try session.command("Debugger.resume", "{}");
    try testing.expect(try session.waitFrom(at, "Debugger.resumed", 80));
    const thread = session.eval_thread orelse return;
    thread.join();
    session.eval_thread = null;
}

fn receiverScenario(name: []const u8, source: []const u8, expression: []const u8, expected: []const u8) !void {
    const alloc = testing.allocator;
    var session = try openSession(alloc, name);
    defer session.deinit();
    try enable(&session);
    var box = EvalBox{ .id = session.id, .script = source, .filename = name };
    defer box.deinit();
    _ = try pause(&session, &box);
    try evaluate(&session, expression, expected);
    try resumeSession(&session);
}

test "cdp receiver: optimized-out ordinary receiver remains inspectable" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-ordinary.js", "function f(){ debugger; } ({ receiver: 99, f: f }).f();", "this.receiver", "\"value\":99");
}

test "cdp receiver: strict undefined is preserved" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-strict.js", "function f(){ 'use strict'; debugger; } f();", "this === undefined", "\"value\":true");
}

test "cdp receiver: arrow keeps its captured receiver" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-arrow.js", "function f(){ return () => { debugger; }; } const arrow = ({ receiver: 71, f: f }).f(); arrow.call({ receiver: 12 });", "this.receiver", "\"value\":71");
}

test "cdp receiver: nested arrow keeps its captured receiver" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-nested-arrow.js", "function f(){ return () => () => { debugger; }; } const outer = ({ receiver: 73, f: f }).f(); outer().call({ receiver: 14 });", "this.receiver", "\"value\":73");
}

test "cdp receiver: direct eval arrow keeps its captured receiver" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-eval-arrow.js", "function f(){ return eval('() => { debugger; }'); } const arrow = ({ receiver: 83, f: f }).f(); arrow.call({ receiver: 12 });", "this.receiver", "\"value\":83");
}

test "cdp receiver: top-level direct eval arrow keeps the global receiver" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-top-level-eval-arrow.js", "const arrow = eval('() => { debugger; }'); arrow.call({ receiver: 12 });", "this === globalThis", "\"value\":true");
}

test "cdp receiver: non-strict primitive receiver is boxed" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-primitive.js", "function f(){ debugger; } f.call(5);", "this.valueOf()", "\"value\":5");
}

test "cdp receiver: strict primitive receiver is preserved" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-strict-primitive.js", "function f(){ 'use strict'; debugger; } f.call(5);", "this === 5", "\"value\":true");
}

test "cdp receiver: local eval binding remains inspectable" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-local-eval.js", "function f(){ const eval = 7; debugger; } f();", "eval", "\"value\":7");
}

test "cdp receiver: generator receiver survives suspension" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-generator.js", "function* f(){ yield 0; debugger; } const iterator = ({ receiver: 37, f: f }).f(); iterator.next(); iterator.next();", "this.receiver", "\"value\":37");
}

test "cdp receiver: async receiver survives suspension" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-async.js", "async function f(){ await 0; debugger; } ({ receiver: 53, f: f }).f();", "this.receiver", "\"value\":53");
}

test "cdp receiver: derived constructor can create an arrow before super" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "receiver-derived-arrow.js");
    defer session.deinit();
    try enable(&session);
    var box = EvalBox{ .id = session.id, .script = "class Base {} class Child extends Base { constructor(){ const arrow = () => { debugger; }; arrow(); super(); } } new Child(); 1", .filename = "receiver-derived-arrow.js" };
    defer box.deinit();
    _ = try pause(&session, &box);
    try resumeSession(&session);
    try testing.expectEqualStrings("1", box.result);
}

test "cdp receiver: derived constructor keeps this in TDZ before super" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-derived-tdz.js", "class Base {} class Child extends Base { constructor(){ debugger; super(); } } new Child();", "this", "ReferenceError");
}

test "cdp receiver: derived arrow keeps this in TDZ before super" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-derived-arrow-tdz.js", "class Base {} class Child extends Base { constructor(){ const arrow = () => { debugger; }; arrow.call({ r: 1 }); super(); } } new Child();", "this.r", "ReferenceError");
}

test "cdp receiver: evaluation helper bindings do not hide global names" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-helper-globals.js", "var scope=42, __jsbayScope=43, __jsbayExpression=44, __jsbayReceiver=45; function f(){ debugger; } f();", "[scope,__jsbayScope,__jsbayExpression,__jsbayReceiver].join(',')", "\"value\":\"42,43,44,45\"");
}

test "cdp receiver: local callable eval only runs when user code invokes it" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "receiver-callable-eval.js");
    defer session.deinit();
    try enable(&session);
    var box = EvalBox{ .id = session.id, .script = "globalThis.evalHits=0; function f(){ const eval = text => { globalThis.evalHits++; return text.length+9; }; debugger; } f();", .filename = "receiver-callable-eval.js" };
    defer box.deinit();
    _ = try pause(&session, &box);
    try evaluate(&session, "1+1", "\"value\":2");
    try evaluate(&session, "globalThis.evalHits", "\"value\":0");
    try evaluate(&session, "eval('abc')", "\"value\":12");
    try evaluate(&session, "globalThis.evalHits", "\"value\":1");
    try resumeSession(&session);
}

test "cdp receiver: local non-callable eval preserves expression semantics" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "receiver-noncallable-eval.js");
    defer session.deinit();
    try enable(&session);
    var box = EvalBox{ .id = session.id, .script = "function f(){ const eval=7; const __jsbayExpression=19; debugger; } f();", .filename = "receiver-noncallable-eval.js" };
    defer box.deinit();
    _ = try pause(&session, &box);
    try evaluate(&session, "typeof eval", "\"value\":\"number\"");
    try evaluate(&session, "eval('x')", "TypeError");
    try evaluate(&session, "__jsbayExpression", "\"value\":19");
    try resumeSession(&session);
}

test "cdp receiver: snapshot bindings bypass Object prototype accessors" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try receiverScenario("receiver-prototype-isolation.js", "Object.defineProperty(Object.prototype,'guarded',{get(){throw new Error('prototype getter');},set(){throw new Error('prototype setter');},configurable:true}); function f(){ let guarded=17; debugger; } f();", "guarded", "\"value\":17");
}

test "cdp receiver: script completion preserves ordinary direct eval" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "receiver-script-completion.js");
    defer session.deinit();
    try enable(&session);
    var box = EvalBox{ .id = session.id, .script = "function f(){ debugger; } function g(){var x=1;return eval('x');} f();g();", .filename = "receiver-script-completion.js" };
    defer box.deinit();
    _ = try pause(&session, &box);
    try evaluate(&session, "var scratch=1;\nscratch+=2;\nscratch", "\"value\":3");
    try resumeSession(&session);
    try testing.expectEqualStrings("1", box.result);
}

test "cdp receiver: quoted input does not publish its helper source" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const alloc = testing.allocator;
    var session = try openSession(alloc, "receiver-quoted-input.js");
    defer session.deinit();
    try enable(&session);
    var box = EvalBox{ .id = session.id, .script = "JSON.stringify=()=>{throw new Error('JSON replacement');}; function f(){ debugger; } f();", .filename = "receiver-quoted-input.js" };
    defer box.deinit();
    _ = try pause(&session, &box);
    const start = session.got.items.len;
    const reply = try evaluateReply(&session, "\"quote:\\\" slash:\\\\ newline:\\n separators:\u{2028}\u{2029} */ //# sourceURL=x\"");
    defer reply.deinit();
    const result = reply.value.object.get("result") orelse return error.MissingResult;
    try testing.expect(result.object.get("exceptionDetails") == null);
    const value = (result.object.get("result") orelse return error.MissingValue).object.get("value") orelse return error.MissingValue;
    try testing.expectEqualStrings("quote:\" slash:\\ newline:\n separators:\u{2028}\u{2029} */ //# sourceURL=x", value.string);
    var lines = std.mem.splitScalar(u8, session.got.items[start..], '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const message = try std.json.parseFromSlice(std.json.Value, alloc, line, .{});
        defer message.deinit();
        const method = message.value.object.get("method") orelse continue;
        if (method != .string or !std.mem.eql(u8, method.string, "Debugger.scriptParsed")) continue;
        const params = message.value.object.get("params") orelse return error.MissingParams;
        const url = params.object.get("url") orelse return error.MissingUrl;
        try testing.expect(!std.mem.eql(u8, url.string, "<debugger>"));
    }
    try resumeSession(&session);
}
