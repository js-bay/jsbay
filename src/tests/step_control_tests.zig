//! The CDP peer controls an engine that remains on its creating thread.
const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const inspector = @import("../inspector/root.zig");
const debugger_mod = @import("../inspector/debugger.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const io = @import("../platform/io.zig");
const value = @import("../value/root.zig");
const helpers = @import("test_helpers.zig");
const wire = @import("inspector_test_wire.zig");
const Json = std.json.Value;
const Message = std.json.Parsed(Json);
const alloc = testing.allocator;

const Owner = struct {
    id: i32,
    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    host_ready: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    port: std.atomic.Value(u16) = .init(0),
    created: bool = false,

    fn hostReady(instance_id: i32, _: value.NativeArgs) value.NativeResult {
        if (active_owner) |owner| if (owner.id == instance_id) {
            owner.host_ready.store(true, .release);
            return .{ .boolean = owner.stop.load(.acquire) };
        };
        return .{ .boolean = true };
    }

    fn hostDone(instance_id: i32, _: value.NativeArgs) value.NativeResult {
        if (active_owner) |owner| if (owner.id == instance_id) owner.finished.store(true, .release);
        return .{ .number = 42 };
    }

    fn run(owner: *Owner) void {
        defer owner.ready.store(true, .release);
        if (!engine.create(owner.id, .{ .max_stack_size = 48 * 1024 * 1024 })) return;
        defer engine.destroy(owner.id);
        value.registerFunction(owner.id, null, "__cdpHostReady", &hostReady);
        value.registerFunction(owner.id, null, "__cdpHostDone", &hostDone);
        const handle = inspector.start(owner.id, .{ .port = 0, .target_id = "step-control-owner" }) catch return;
        defer inspector.stop(handle);
        owner.port.store(inspector.boundPort(handle), .release);
        owner.created = true;
        owner.ready.store(true, .release);
        while (!owner.stop.load(.acquire)) {
            _ = dispatch.tickInstance(owner.id);
            engine.runEventLoopOnce(owner.id);
            std.Thread.yield() catch {};
        }
    }
};
var active_owner: ?*Owner = null;

fn waitFlag(flag: *std.atomic.Value(bool)) !void {
    const deadline = io.monotonicMilliseconds() + 10_000;
    while (!flag.load(.acquire)) {
        if (io.monotonicMilliseconds() >= deadline) return error.OwnerTimeout;
        std.Thread.yield() catch {};
    }
}

fn field(object: Json, key: []const u8) !Json {
    if (object != .object) return error.ExpectedObject;
    return object.object.get(key) orelse error.MissingField;
}

fn topFrame(message: Json) !Json {
    const frames = try field(try field(message, "params"), "callFrames");
    if (frames != .array or frames.array.items.len == 0) return error.MissingFrame;
    return frames.array.items[0];
}

const Session = struct {
    owner: *Owner,
    thread: std.Thread,
    stream: wire.TestStream,
    reader: wire.FrameReader,
    pending: std.ArrayList(Message) = .empty,
    next_id: i64 = 1,

    fn open(owner: *Owner) !Session {
        active_owner = owner;
        errdefer active_owner = null;
        const thread = try std.Thread.spawn(.{ .stack_size = 128 * 1024 * 1024 }, Owner.run, .{owner});
        errdefer stopOwner(owner, thread);
        try waitFlag(&owner.ready);
        try testing.expect(owner.created);
        const stream = try wire.connect(owner.port.load(.acquire));
        errdefer stream.close();
        try wire.doWsHandshake(alloc, stream, "step-control-owner");
        return .{ .owner = owner, .thread = thread, .stream = stream, .reader = wire.FrameReader.init(stream) };
    }

    fn stopOwner(owner: *Owner, thread: std.Thread) void {
        owner.stop.store(true, .release);
        debugger_mod.abandon(owner.id);
        _ = runtime_control.requestInterrupt(owner.id);
        thread.join();
    }

    fn deinit(self: *Session) void {
        stopOwner(self.owner, self.thread);
        self.reader.deinit(alloc);
        self.stream.close();
        for (self.pending.items) |message| message.deinit();
        self.pending.deinit(alloc);
        active_owner = null;
    }

    fn send(self: *Session, method: []const u8, params: []const u8) !i64 {
        const id = self.next_id;
        self.next_id += 1;
        const text = try std.fmt.allocPrint(alloc, "{{\"id\":{d},\"method\":{f},\"params\":{s}}}", .{ id, std.json.fmt(method, .{}), params });
        defer alloc.free(text);
        try wire.writeMaskedText(self.stream, text);
        return id;
    }

    fn receive(self: *Session, id: ?i64, method: ?[]const u8) !Message {
        const deadline = io.monotonicMilliseconds() + 10_000;
        while (io.monotonicMilliseconds() < deadline) {
            for (self.pending.items, 0..) |message, index| {
                const object = message.value.object;
                const matches = if (id) |wanted| blk: {
                    const actual = object.get("id") orelse break :blk false;
                    break :blk actual == .integer and actual.integer == wanted;
                } else blk: {
                    const actual = object.get("method") orelse break :blk false;
                    break :blk actual == .string and std.mem.eql(u8, actual.string, method.?);
                };
                if (matches) return self.pending.orderedRemove(index);
            }
            try self.pump();
        }
        return error.CdpTimeout;
    }

    fn pump(self: *Session) !void {
        const frame = (try self.reader.readTimed(alloc, 40)) orelse return;
        defer alloc.free(frame.payload);
        if (frame.opcode != 1) return;
        const parsed = try std.json.parseFromSlice(Json, alloc, frame.payload, .{ .allocate = .alloc_always });
        errdefer parsed.deinit();
        try self.pending.append(alloc, parsed);
    }

    fn expectNoPause(self: *Session) !void {
        for (self.pending.items) |message| {
            const method = message.value.object.get("method") orelse continue;
            if (method == .string and std.mem.eql(u8, method.string, "Debugger.paused")) {
                std.debug.print("unexpected pause: {f}\n", .{std.json.fmt(try topFrame(message.value), .{})});
                return error.UnexpectedPause;
            }
        }
    }

    fn waitFinished(self: *Session) !void {
        const deadline = io.monotonicMilliseconds() + 10_000;
        while (!self.owner.finished.load(.acquire)) {
            try self.expectNoPause();
            if (io.monotonicMilliseconds() >= deadline) return error.OwnerTimeout;
            try self.pump();
        }
        try self.expectNoPause();
    }

    fn reply(self: *Session, id: i64) !Message {
        const message = try self.receive(id, null);
        errdefer message.deinit();
        if (message.value.object.get("error") != null) {
            std.debug.print("CDP error: {f}\n", .{std.json.fmt(message.value, .{})});
            return error.CdpCommandFailed;
        }
        return message;
    }

    fn command(self: *Session, method: []const u8, params: []const u8) !void {
        const message = try self.reply(try self.send(method, params));
        defer message.deinit();
    }

    fn pause(self: *Session) !Message {
        return self.receive(null, "Debugger.paused");
    }

    fn evaluate(self: *Session, source: []const u8) !i64 {
        const params = try std.fmt.allocPrint(alloc, "{{\"expression\":{f},\"returnByValue\":true}}", .{std.json.fmt(source, .{})});
        defer alloc.free(params);
        return self.send("Runtime.evaluate", params);
    }
};

fn expectTop(pause: Json, name: []const u8, line: ?i64) !void {
    const frame = try topFrame(pause);
    try testing.expectEqualStrings(name, (try field(frame, "functionName")).string);
    if (line) |expected| try testing.expectEqual(expected, (try field(try field(frame, "location"), "lineNumber")).integer);
}

fn expectNumber(reply: Json, expected: i64) !void {
    const result = try field(try field(reply, "result"), "result");
    try testing.expectEqual(expected, (try field(result, "value")).integer);
}

fn expectTopAt(pause: Json, name: []const u8, line: i64, column: i64) !void {
    const frame = try topFrame(pause);
    try testing.expectEqualStrings(name, (try field(frame, "functionName")).string);
    const location = try field(frame, "location");
    try testing.expectEqual(line, (try field(location, "lineNumber")).integer);
    try testing.expectEqual(column, (try field(location, "columnNumber")).integer);
}

fn forOfColumnBreakpoints(source: []const u8, url: []const u8, column: i64, expected_column: i64, expected_pauses: usize, check_progress: bool, expected_values: []const u8) !void {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    const params = try std.fmt.allocPrint(alloc, "{{\"url\":{f},\"lineNumber\":1,\"columnNumber\":{d}}}", .{ std.json.fmt(url, .{}), column });
    defer alloc.free(params);
    const breakpoint = try session.reply(try session.send("Debugger.setBreakpointByUrl", params));
    defer breakpoint.deinit();
    const evaluation = try session.evaluate(source);
    for (0..expected_pauses) |index| {
        const paused = try session.pause();
        defer paused.deinit();
        try expectTopAt(paused.value, "run", 1, expected_column);
        if (index == 0 and std.mem.eql(u8, url, "owner-forof-columns.js") and column == 5) {
            const script_id = (try field(try field(try topFrame(paused.value), "location"), "scriptId")).string;
            const possible_params = try std.fmt.allocPrint(alloc, "{{\"start\":{{\"scriptId\":{f},\"lineNumber\":1}},\"end\":{{\"scriptId\":{f},\"lineNumber\":2}}}}", .{ std.json.fmt(script_id, .{}), std.json.fmt(script_id, .{}) });
            defer alloc.free(possible_params);
            const possible = try session.reply(try session.send("Debugger.getPossibleBreakpoints", possible_params));
            defer possible.deinit();
            const locations = try field(try field(possible.value, "result"), "locations");
            try testing.expect(locations == .array);
            var found = [_]bool{ false, false, false, false };
            for (locations.array.items, 0..) |location, location_index| {
                try testing.expectEqual(@as(i64, 1), (try field(location, "lineNumber")).integer);
                const location_column = (try field(location, "columnNumber")).integer;
                for (locations.array.items[0..location_index]) |previous| {
                    try testing.expect((try field(previous, "columnNumber")).integer != location_column);
                }
                inline for ([_]i64{ 5, 13, 16, 25 }, 0..) |wanted, wanted_index| {
                    if (location_column == wanted) {
                        try testing.expect(!found[wanted_index]);
                        found[wanted_index] = true;
                    }
                }
            }
            for (found) |present| try testing.expect(present);
        }
        if (check_progress) {
            const seen = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"globalThis.seen.length\"}"));
            defer seen.deinit();
            try expectNumber(seen.value, @intCast(index));
        }
        try session.command("Debugger.resume", "{}");
    }
    try session.waitFinished();
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    const completion_result = try field(try field(completion.value, "result"), "result");
    if (completion_result.object.get("value")) |completion_value| {
        if (completion_value == .integer) try testing.expectEqual(@as(i64, 42), completion_value.integer);
    }
    try testing.expect((try field(completion.value, "result")).object.get("exceptionDetails") == null);
    if (check_progress) {
        const seen = try session.reply(try session.evaluate("globalThis.seen.length"));
        defer seen.deinit();
        try expectNumber(seen.value, @intCast(expected_pauses));
    }
    const values = try session.reply(try session.evaluate("globalThis.seen.join(',')"));
    defer values.deinit();
    const serialized_values = try field(try field(try field(values.value, "result"), "result"), "value");
    try testing.expectEqualStrings(expected_values, serialized_values.string);
    try session.expectNoPause();
}

const for_of_columns_source = "globalThis.seen=[]; function f(v){seen.push(v);} function run(){\n for(const v of [1,2,3]) f(v);\n}\nrun();__cdpHostDone();\n//# sourceURL=owner-forof-columns.js";

test "cdp: QuickJS for-of binding column pauses once per binding" {
    try forOfColumnBreakpoints(for_of_columns_source, "owner-forof-columns.js", 5, 5, 3, true, "1,2,3");
}

test "cdp: QuickJS for-of operator column pauses for each next" {
    try forOfColumnBreakpoints(for_of_columns_source, "owner-forof-columns.js", 13, 13, 4, false, "1,2,3");
}

test "cdp: QuickJS for-of initializer and default columns resolve once" {
    try forOfColumnBreakpoints(for_of_columns_source, "owner-forof-columns.js", 16, 16, 1, false, "1,2,3");
    try forOfColumnBreakpoints(for_of_columns_source, "owner-forof-columns.js", 0, 16, 1, false, "1,2,3");
}

test "cdp: QuickJS for-of body column remains bindable" {
    try forOfColumnBreakpoints(for_of_columns_source, "owner-forof-columns.js", 25, 25, 3, false, "1,2,3");
}

test "cdp: QuickJS empty for-of binding has no duplicate pause" {
    const source = "globalThis.seen=[]; function run(){\n for(const v of [1,2]) {}\n}\nrun();__cdpHostDone();\n//# sourceURL=owner-empty-forof-columns.js";
    try forOfColumnBreakpoints(source, "owner-empty-forof-columns.js", 5, 5, 2, false, "");
}

test "cdp: QuickJS for-in binding and operator have distinct pauses" {
    const source = "globalThis.seen=[]; function f(v){seen.push(v);} function run(){\n for(const v in {a:1,b:2}) f(v);\n}\nrun();__cdpHostDone();\n//# sourceURL=owner-forin-columns.js";
    try forOfColumnBreakpoints(source, "owner-forin-columns.js", 5, 5, 2, true, "a,b");
    try forOfColumnBreakpoints(source, "owner-forin-columns.js", 13, 13, 3, false, "a,b");
}

test "cdp: QuickJS for-await binding and operator do not repeat after resume" {
    const source = "globalThis.seen=[]; const items={index:0,[Symbol.asyncIterator](){return this;},next(){const value=this.index++;return Promise.resolve(value<3?{value:value+1,done:false}:{done:true});}}; function f(v){seen.push(v);} async function run(){\n for await(const v of items) f(v);\n}\nrun().then(__cdpHostDone);\n//# sourceURL=owner-forawait-columns.js";
    try forOfColumnBreakpoints(source, "owner-forawait-columns.js", 11, 11, 3, true, "1,2,3");
    try forOfColumnBreakpoints(source, "owner-forawait-columns.js", 19, 19, 4, false, "1,2,3");
}

test "cdp: owner-thread stepOver loop remains interruptible" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    const evaluation = try session.evaluate("function spin(){ globalThis.__cdpStop=false; debugger; while(!globalThis.__cdpStop && !__cdpHostReady()){} return 42; }\nspin()\n//# sourceURL=owner-step-loop.js");
    const initial = try session.pause();
    defer initial.deinit();
    try expectTop(initial.value, "spin", null);
    try session.command("Debugger.stepOver", "{}");
    try waitFlag(&owner.host_ready);
    try session.command("Debugger.pause", "{}");
    const interrupted = try session.pause();
    defer interrupted.deinit();
    try expectTop(interrupted.value, "spin", null);
    try session.command("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"globalThis.__cdpStop=true\"}");
    try session.command("Debugger.resume", "{}");
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    try expectNumber(completion.value, 42);
}

test "cdp: owner-thread deep stack preserves step depth beyond copied frames" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(alloc);
    for (0..79) |n| {
        var line: [80]u8 = undefined;
        try source.appendSlice(alloc, try std.fmt.bufPrint(&line, "function deep{d}() {{ return deep{d}(); }}\n", .{ n, n + 1 }));
    }
    try source.appendSlice(alloc, "function deep79() {\n  debugger;\n  return 79;\n}\ndeep0()\n//# sourceURL=owner-deep-step.js");
    const evaluation = try session.evaluate(source.items);
    const initial = try session.pause();
    defer initial.deinit();
    try expectTop(initial.value, "deep79", null);
    const frames = try field(try field(initial.value, "params"), "callFrames");
    try testing.expectEqual(@as(usize, 64), frames.array.items.len);
    try session.command("Debugger.stepOver", "{}");
    const over = try session.pause();
    defer over.deinit();
    try expectTop(over.value, "deep79", 81);
    try session.command("Debugger.stepOut", "{}");
    const out = try session.pause();
    defer out.deinit();
    try expectTop(out.value, "deep78", null);
    try session.command("Debugger.resume", "{}");
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    try expectNumber(completion.value, 79);
}

test "cdp: owner-thread stepOut after await completes without an invented caller" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    _ = try session.evaluate("async function resumed(){\n await 0;\n debugger;\n return __cdpHostDone();\n}\nresumed()\n//# sourceURL=owner-async-step.js");
    const initial = try session.pause();
    defer initial.deinit();
    try expectTop(initial.value, "resumed", null);
    try session.command("Debugger.stepOut", "{}");
    try waitFlag(&owner.finished);
}

const InvocationPath = enum { native, with_evaluation, queued, asynchronous };

fn repeatedInvocations(path: InvocationPath) !void {
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    try session.command("Debugger.setBreakpointByUrl", "{\"url\":\"owner-invocations.js\",\"lineNumber\":1}");
    const function = if (path == .asynchronous)
        "async function callback(value) {\n  await 0;\n  return value;\n}"
    else
        "function callback(value) {\n  return;\n}";
    const calls = switch (path) {
        .native, .with_evaluation => "[17, 29].forEach(callback); __cdpHostDone();",
        .queued => "Promise.resolve().then(function(){callback(17);}).then(function(){callback(29);}).then(__cdpHostDone);",
        .asynchronous => "callback(17).then(function(){return callback(29);}).then(__cdpHostDone);",
    };
    const source = try std.fmt.allocPrint(alloc, "{s}\n{s}\n//# sourceURL=owner-invocations.js", .{ function, calls });
    defer alloc.free(source);
    const evaluation = try session.evaluate(source);
    const first = try session.pause();
    defer first.deinit();
    try expectTop(first.value, "callback", 1);
    if (path == .with_evaluation) {
        const probe = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"(() => { debugger; callback(99); })()\"}"));
        defer probe.deinit();
        const result = try field(probe.value, "result");
        try testing.expect(result.object.get("exceptionDetails") == null);
        try testing.expectEqualStrings("undefined", (try field(try field(result, "result"), "type")).string);
        const suspended = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"value\"}"));
        defer suspended.deinit();
        try expectNumber(suspended.value, 17);
    }
    try session.command("Debugger.resume", "{}");
    const second = try session.pause();
    defer second.deinit();
    try expectTop(second.value, "callback", 1);
    const value_reply = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"value\"}"));
    defer value_reply.deinit();
    try expectNumber(value_reply.value, 29);
    try session.command("Debugger.resume", "{}");
    try waitFlag(&owner.finished);
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    try testing.expect((try field(completion.value, "result")).object.get("exceptionDetails") == null);
}

test "cdp: native callbacks retain a breakpoint for every invocation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try repeatedInvocations(.native);
}

test "cdp: paused evaluation does not replace the suspended invocation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try repeatedInvocations(.with_evaluation);
}

test "cdp: queued callbacks retain a breakpoint for every invocation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try repeatedInvocations(.queued);
}

test "cdp: await preserves identity within each distinct async invocation" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try repeatedInvocations(.asynchronous);
}

test "cdp: a returning call does not repeat its breakpoint after the callee" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    try session.command("Debugger.setBreakpointByUrl", "{\"url\":\"owner-single-call.js\",\"lineNumber\":2}");
    const evaluation = try session.evaluate("function callee(){ return 7; }\nfunction caller(){\n  return callee();\n}\nglobalThis.callResult=caller();\n__cdpHostDone();\n//# sourceURL=owner-single-call.js");
    const pause = try session.pause();
    defer pause.deinit();
    try expectTop(pause.value, "caller", 2);
    try session.command("Debugger.resume", "{}");
    try waitFlag(&owner.finished);
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    try expectNumber(completion.value, 42);
    const result = try session.reply(try session.evaluate("globalThis.callResult"));
    defer result.deinit();
    try expectNumber(result.value, 7);
}

fn generatorResumption(asynchronous: bool, delegated: bool) !void {
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    try session.command("Debugger.setBreakpointByUrl", "{\"url\":\"owner-generator.js\",\"lineNumber\":1}");
    const prefix = if (asynchronous) "async " else "";
    const wait = if (asynchronous) "await " else "";
    const delegate_check = if (delegated)
        "const last = WAITit.next(); if(second.value!==23 || second.done!==false) throw new Error('delegated result');"
    else
        "const last = second;";
    const final_check = try std.mem.replaceOwned(u8, alloc, delegate_check, "WAIT", wait);
    defer alloc.free(final_check);
    const source = try std.fmt.allocPrint(alloc, "{s}function* generator() {{\n  {s}\n  return 29;\n}}\n" ++
        "{s}function drive(){{ const it=generator(); const first={s}it.next(); const second={s}it.next(); {s} " ++
        "if(first.value!==17 || first.done!==false || last.value!==29 || last.done!==true) throw new Error('generator result'); " ++
        "globalThis.generatorResult=last.value; return __cdpHostDone(); }}\ndrive()\n//# sourceURL=owner-generator.js", .{ prefix, if (delegated) "yield* [17, 23];" else "yield 17;", prefix, wait, wait, final_check });
    defer alloc.free(source);
    const evaluation = try session.evaluate(source);
    const first = try session.pause();
    defer first.deinit();
    try expectTop(first.value, "generator", 1);
    try session.command("Debugger.resume", "{}");
    try session.waitFinished();
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    try testing.expect((try field(completion.value, "result")).object.get("exceptionDetails") == null);
    const result = try session.reply(try session.evaluate("globalThis.generatorResult"));
    defer result.deinit();
    try expectNumber(result.value, 29);
    try session.expectNoPause();
}

test "cdp: generator resumption does not repeat the yield breakpoint" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try generatorResumption(false, false);
}

test "cdp: delegated generator resumption does not repeat the yield breakpoint" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try generatorResumption(false, true);
}

test "cdp: async generator resumption does not repeat the yield breakpoint" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try generatorResumption(true, false);
}

test "cdp: delegated async generator resumption does not repeat the yield breakpoint" {
    if (comptime !backend.supportsDebugger(backend.active_backend)) return;
    try generatorResumption(true, true);
}

const ExpectedStop = struct { name: []const u8, line: i64 };

fn breakpointExecutions(source: []const u8, lines: []const usize, stops: []const ExpectedStop, condition: []const u8, paused_evaluation: bool) !void {
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    for (lines) |line| {
        const params = try std.fmt.allocPrint(alloc, "{{\"url\":\"owner-repeat.js\",\"lineNumber\":{d},\"condition\":{f}}}", .{ line, std.json.fmt(condition, .{}) });
        defer alloc.free(params);
        try session.command("Debugger.setBreakpointByUrl", params);
    }
    const script = try std.fmt.allocPrint(alloc, "{s}\n__cdpHostDone();\n//# sourceURL=owner-repeat.js", .{source});
    defer alloc.free(script);
    const evaluation = try session.evaluate(script);
    for (stops, 0..) |stop, index| {
        const paused = try session.pause();
        defer paused.deinit();
        try expectTop(paused.value, stop.name, stop.line);
        if (paused_evaluation and index == 0) {
            const probe = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"inner()\"}"));
            defer probe.deinit();
            try expectNumber(probe.value, 7);
        }
        try session.command("Debugger.resume", "{}");
    }
    try session.waitFinished();
    const completion = try session.reply(evaluation);
    defer completion.deinit();
    try expectNumber(completion.value, 42);
    try session.expectNoPause();
}

const nested_stops = [_]ExpectedStop{ .{ .name = "caller", .line = 4 }, .{ .name = "inner", .line = 1 } };

test "cdp: nested breakpoint resumes each returning call once" {
    try breakpointExecutions("function inner(){\n return 7;\n}\nfunction caller(){\n return inner();\n}\ncaller();", &.{ 1, 4 }, &nested_stops, "", false);
}

test "cdp: nested breakpoint resumes each assigned call once" {
    try breakpointExecutions("function inner(){\n return 7;\n}\nfunction caller(){\n let y=inner();\n return y;\n}\ncaller();", &.{ 1, 4 }, &nested_stops, "", false);
}

test "cdp: paused nested evaluation preserves caller breakpoint progress" {
    try breakpointExecutions("function inner(){\n return 7;\n}\nfunction caller(){\n return inner();\n}\ncaller();", &.{ 1, 4 }, &nested_stops, "", true);
}

test "cdp: direct eval preserves caller breakpoint progress" {
    try breakpointExecutions("function inner(){\n return 7;\n}\nfunction caller(){\n return eval('inner()');\n}\ncaller();", &.{ 1, 4 }, &nested_stops, "", false);
}

test "cdp: condition evaluation preserves caller breakpoint progress" {
    const stops = [_]ExpectedStop{.{ .name = "caller", .line = 4 }};
    try breakpointExecutions("function inner(){\n return 7;\n}\nfunction caller(){\n return inner();\n}\ncaller();", &.{4}, &stops, "inner() === 7", false);
}

test "cdp: single-coordinate loop pauses on every execution" {
    const stops = [_]ExpectedStop{ .{ .name = "run", .line = 2 }, .{ .name = "run", .line = 2 }, .{ .name = "run", .line = 2 }, .{ .name = "run", .line = 2 } };
    try breakpointExecutions("let n=0; function step(){return n++<3;}\nfunction run(){\n while(step());\n}\nrun();", &.{2}, &stops, "", false);
}

test "cdp: finally call breakpoint pauses once for each loop execution" {
    const stops = [_]ExpectedStop{ .{ .name = "run", .line = 3 }, .{ .name = "run", .line = 3 }, .{ .name = "run", .line = 3 } };
    try breakpointExecutions("function inner(){return 7;}\nfunction run(){\n for(let i=0;i<3;i++){\n try { let y=inner(); } finally {}\n }\n}\nrun();", &.{3}, &stops, "", false);
}

test "cdp: generator loop breakpoint pauses on every yielded execution" {
    const stops = [_]ExpectedStop{ .{ .name = "gen", .line = 2 }, .{ .name = "gen", .line = 2 }, .{ .name = "gen", .line = 2 } };
    try breakpointExecutions("function* gen(){\n let v=0;\n while(true) v=yield v;\n}\nconst it=gen();it.next();it.next(1);it.next(2);", &.{2}, &stops, "", false);
}

test "cdp: empty for-of loop pauses once at its initializer" {
    const stops = [_]ExpectedStop{.{ .name = "run", .line = 1 }};
    try breakpointExecutions("function run(){\n for(const v of [1,2,3]);\n}\nrun();", &.{1}, &stops, "", false);
}

test "cdp: empty for-in loop pauses once at its initializer" {
    const stops = [_]ExpectedStop{.{ .name = "run", .line = 1 }};
    try breakpointExecutions("function run(){\n for(const k in {a:1,b:2,c:3}){}\n}\nrun();", &.{1}, &stops, "", false);
}

test "cdp: for-of call loop pauses once at its initializer" {
    const stops = [_]ExpectedStop{.{ .name = "run", .line = 1 }};
    try breakpointExecutions("function f(v){} function run(){\n for(const v of [1,2,3]) f(v);\n}\nrun();", &.{1}, &stops, "", false);
}

test "cdp: outer generator loop pauses once per delegated execution" {
    const stops = [_]ExpectedStop{ .{ .name = "gen", .line = 1 }, .{ .name = "gen", .line = 1 }, .{ .name = "gen", .line = 1 } };
    try breakpointExecutions("function* gen(){\n while(true) yield* [17,23];\n}\nconst it=gen();for(let i=0;i<6;i++)it.next();", &.{1}, &stops, "", false);
}

test "cdp: Escargot scope snapshots do not invoke Object prototype setters" {
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    const evaluation = try session.evaluate("Object.defineProperty(Object.prototype, 'scopeProbe', { set(){ globalThis.scopeSetterHit=(globalThis.scopeSetterHit||0)+1; }, configurable:true }); function run(){ let scopeProbe=7; debugger; return scopeProbe; } run(); __cdpHostDone();\n//# sourceURL=escargot-scope-snapshot.js");
    const paused = try session.pause();
    defer paused.deinit();
    const frame = try topFrame(paused.value);
    const scopes = try field(frame, "scopeChain");
    try testing.expect(scopes == .array);
    var object_id: ?[]const u8 = null;
    for (scopes.array.items) |scope| {
        if ((try field(scope, "type")).string.len != 5 or !std.mem.eql(u8, (try field(scope, "type")).string, "local")) continue;
        object_id = (try field(try field(scope, "object"), "objectId")).string;
        break;
    }
    const id = object_id orelse return error.MissingScopeObject;
    const properties = try std.fmt.allocPrint(alloc, "{{\"objectId\":{f},\"ownProperties\":true}}", .{std.json.fmt(id, .{})});
    defer alloc.free(properties);
    const listed = try session.reply(try session.send("Runtime.getProperties", properties));
    defer listed.deinit();
    const listed_result = try field(try field(listed.value, "result"), "result");
    try testing.expect(listed_result == .array);
    var found_scope_probe = false;
    for (listed_result.array.items) |property| {
        if (!std.mem.eql(u8, (try field(property, "name")).string, "scopeProbe")) continue;
        try testing.expectEqual(@as(i64, 7), (try field(try field(property, "value"), "value")).integer);
        found_scope_probe = true;
        break;
    }
    try testing.expect(found_scope_probe);
    const setter_check = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"globalThis.scopeSetterHit || 0\"}"));
    defer setter_check.deinit();
    try expectNumber(setter_check.value, 0);
    try session.command("Debugger.resume", "{}");
    try session.waitFinished();
    const completed = try session.reply(evaluation);
    defer completed.deinit();
    try expectNumber(completed.value, 42);
}

test "cdp: Escargot before-super this evaluation reports a TDZ error" {
    if (comptime !backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    const evaluation = try session.evaluate("class Base {} class Derived extends Base { constructor(){ debugger; super(); } } new Derived(); __cdpHostDone();\n//# sourceURL=escargot-before-super.js");
    const paused = try session.pause();
    defer paused.deinit();
    for ([_][]const u8{ "this", "(()=>this)()" }) |expression| {
        const params = try std.fmt.allocPrint(alloc, "{{\"callFrameId\":\"0\",\"expression\":{f}}}", .{std.json.fmt(expression, .{})});
        defer alloc.free(params);
        const reply = try session.reply(try session.send("Debugger.evaluateOnCallFrame", params));
        defer reply.deinit();
        const details = (try field(reply.value, "result")).object.get("exceptionDetails") orelse return error.MissingExceptionDetails;
        const description = (try field(try field(details, "exception"), "description")).string;
        try testing.expect(std.mem.startsWith(u8, description, "ReferenceError:"));
    }
    try session.command("Debugger.resume", "{}");
    try session.waitFinished();
    const completed = try session.reply(evaluation);
    defer completed.deinit();
    try expectNumber(completed.value, 42);
}

test "cdp: a line-granular for-of step remains interruptible" {
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    const evaluation = try session.evaluate("globalThis.stopForOf=false; const endless={ [Symbol.iterator](){return this;}, next(){return {value:1,done:false};} }; function spin(){\n debugger;\n for(const item of endless) if(globalThis.stopForOf || __cdpHostReady()) break;\n return 42;\n}\nspin();\n//# sourceURL=owner-forof-interrupt.js");
    const initial = try session.pause();
    defer initial.deinit();
    try expectTop(initial.value, "spin", 1);
    try session.command("Debugger.stepOver", "{}");
    const head = try session.pause();
    defer head.deinit();
    try expectTop(head.value, "spin", 2);
    try session.command("Debugger.stepOver", "{}");
    try waitFlag(&owner.host_ready);
    try session.command("Debugger.pause", "{}");
    const interrupted = try session.pause();
    defer interrupted.deinit();
    const interrupted_frame = try topFrame(interrupted.value);
    try testing.expectEqualStrings("owner-forof-interrupt.js", (try field(interrupted_frame, "url")).string);
    const interrupted_stack = try field(try field(interrupted.value, "params"), "callFrames");
    var has_loop_caller = false;
    for (interrupted_stack.array.items) |frame| {
        if (std.mem.eql(u8, (try field(frame, "functionName")).string, "spin")) {
            try testing.expectEqual(@as(i64, 2), (try field(try field(frame, "location"), "lineNumber")).integer);
            has_loop_caller = true;
        }
    }
    try testing.expect(has_loop_caller);
    try session.command("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"globalThis.stopForOf=true\"}");
    try session.command("Debugger.resume", "{}");
    const completed = try session.reply(evaluation);
    defer completed.deinit();
    try expectNumber(completed.value, 42);
}

test "cdp: for-of stepOver revisits the head between body executions" {
    var owner = Owner{ .id = helpers.nextInstanceId() };
    var session = try Session.open(&owner);
    defer session.deinit();
    try session.command("Debugger.enable", "{}");
    const evaluation = try session.evaluate("function run(){\n let total=0;\n debugger;\n for(const v of [1,2]){\n  total+=v;\n }\n return total;\n}\nrun();\n//# sourceURL=owner-forof-step.js");
    const initial = try session.pause();
    defer initial.deinit();
    try expectTop(initial.value, "run", 2);
    var bodies: usize = 0;
    var head_after_body = false;
    var returned = false;
    for (0..16) |_| {
        try session.command("Debugger.stepOver", "{}");
        const paused = try session.pause();
        defer paused.deinit();
        try expectTop(paused.value, "run", null);
        const line = (try field(try field(try topFrame(paused.value), "location"), "lineNumber")).integer;
        switch (line) {
            3 => if (bodies == 1) {
                head_after_body = true;
            },
            4 => {
                try testing.expect(bodies < 2);
                if (bodies == 1) try testing.expect(head_after_body);
                const total = try session.reply(try session.send("Debugger.evaluateOnCallFrame", "{\"callFrameId\":\"0\",\"expression\":\"total\"}"));
                defer total.deinit();
                try expectNumber(total.value, if (bodies == 0) 0 else 1);
                bodies += 1;
            },
            5 => {},
            6 => {
                try testing.expectEqual(@as(usize, 2), bodies);
                returned = true;
                break;
            },
            else => return error.UnexpectedStepLocation,
        }
    }
    try testing.expect(returned);
    try session.command("Debugger.resume", "{}");
    const completed = try session.reply(evaluation);
    defer completed.deinit();
    try expectNumber(completed.value, 3);
}
