//! Observable browser-style event-loop contracts.
//!
//! A host tick may start at most one queued JavaScript task.  Its complete microtask checkpoint follows before another queued task may start.  The tests record from native callbacks so inspection cannot itself drain a pending microtask and hide a broken task boundary.

const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");
const sync = @import("zev");
const tsfn = @import("../runtime/tsfn.zig");
const timers = @import("../runtime/timers.zig");
const value = @import("../value/root.zig");
const event_loop = @import("js_event_loop");

const ActiveEngine = backend.ActiveEngine;

const Trace = struct {
    var mutex: sync.Mutex = .{};
    var bytes: [64]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        mutex.lock();
        defer mutex.unlock();
        len = 0;
    }

    fn append(byte: u8) void {
        mutex.lock();
        defer mutex.unlock();
        std.debug.assert(len < bytes.len);
        bytes[len] = byte;
        len += 1;
    }

    fn expect(expected: []const u8) !void {
        mutex.lock();
        defer mutex.unlock();
        try testing.expectEqualStrings(expected, bytes[0..len]);
    }

    fn expectLen(expected: usize) !void {
        mutex.lock();
        defer mutex.unlock();
        try testing.expectEqual(expected, len);
    }

    fn snapshot(out: *[64]u8) []const u8 {
        mutex.lock();
        defer mutex.unlock();
        @memcpy(out[0..len], bytes[0..len]);
        return out[0..len];
    }
};

fn record(_: i32, args: value.NativeArgs) value.NativeResult {
    const token = args.toString(0) orelse return .undefined_val;
    defer value.freeString(token);
    if (token.len == 1) Trace.append(token[0]);
    return .undefined_val;
}

fn enqueueC(instance_id: i32, _: value.NativeArgs) value.NativeResult {
    std.debug.assert(engine.dispatchTask(instance_id, "__browserRecord__('C'); queueMicrotask(() => __browserRecord__('c'));"));
    return .undefined_val;
}

fn installRecorder(id: i32) void {
    value.registerFunction(id, null, "__browserRecord__", &record);
}

fn callbackFromGlobal(id: i32, name: [*:0]const u8) !ActiveEngine.Value {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    return ActiveEngine.getPropertyVal(ctx, global, name) orelse error.CallbackMissing;
}

fn expectTaskAndCheckpointPair(expected_task: u8, expected_microtask: u8) !void {
    var snapshot: [64]u8 = undefined;
    const trace = Trace.snapshot(&snapshot);
    try testing.expectEqual(@as(usize, 2), trace.len);
    try testing.expectEqual(expected_task, trace[0]);
    try testing.expectEqual(expected_microtask, trace[1]);
}

test "browser event loop: host scripts run one task then its microtask checkpoint" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('A'); queueMicrotask(() => __browserRecord__('a'));"));
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('B'); queueMicrotask(() => __browserRecord__('b'));"));

            _ = engine.testing.advance(id, 100);
            try expectTaskAndCheckpointPair('A', 'a');
            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaBb");
        }
    }.run);
}

test "browser event loop: native dispatch runs one task then its microtask checkpoint" {
    const State = struct {
        fn first(_: ?*anyopaque) void {
            const result = engine.evalScript(id_for_callback, "__browserRecord__('A'); queueMicrotask(() => __browserRecord__('a'));", "<native-A>");
            helpers.freeEvalResult(result);
        }
        fn second(_: ?*anyopaque) void {
            const result = engine.evalScript(id_for_callback, "__browserRecord__('B'); queueMicrotask(() => __browserRecord__('b'));", "<native-B>");
            helpers.freeEvalResult(result);
        }
        var id_for_callback: i32 = 0;
    };
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            State.id_for_callback = id;
            try testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = State.first }));
            try testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = State.second }));

            _ = engine.testing.advance(id, 100);
            try expectTaskAndCheckpointPair('A', 'a');
            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaBb");
        }
    }.run);
}

test "browser event loop: one TSFN payload and its microtask run per host tick" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try helpers.evalOk(id, "globalThis.__browserTsfn__ = (x) => { __browserRecord__(x); queueMicrotask(() => __browserRecord__(x.toLowerCase())); };");
            const callback = try callbackFromGlobal(id, "__browserTsfn__");
            const ctx = engine.getContext(id) orelse return error.NoContext;
            defer ActiveEngine.freeValue(ctx, callback);
            const handle = tsfn.acquire(id, callback) orelse return error.AcquireFailed;
            defer tsfn.release(handle);
            try testing.expect(tsfn.call(handle, "A"));
            try testing.expect(tsfn.call(handle, "B"));

            _ = engine.testing.advance(id, 100);
            try expectTaskAndCheckpointPair('A', 'a');
            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaBb");
        }
    }.run);
}

test "browser event loop: same-deadline timers run one task then its microtask checkpoint" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try helpers.evalOk(
                id,
                "setTimeout(() => { __browserRecord__('A'); queueMicrotask(() => __browserRecord__('a')); }, 0);" ++
                    "setTimeout(() => { __browserRecord__('B'); queueMicrotask(() => __browserRecord__('b')); }, 0);",
            );

            _ = engine.testing.advance(id, 100);
            try expectTaskAndCheckpointPair('A', 'a');
            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaBb");
        }
    }.run);
}

test "browser event loop: reentrant host work stays pending behind existing work" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            value.registerFunction(id, null, "__browserEnqueueC__", &enqueueC);
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('A'); __browserEnqueueC__(); queueMicrotask(() => __browserRecord__('a'));"));
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('B'); queueMicrotask(() => __browserRecord__('b'));"));

            _ = engine.testing.advance(id, 100);
            try Trace.expect("Aa");
            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaBb");
            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaBbCc");
        }
    }.run);
}

test "browser event loop: mixed ready sources advance one task per tick without starvation" {
    const Native = struct {
        var id_for_callback: i32 = 0;
        fn run(_: ?*anyopaque) void {
            const result = engine.evalScript(id_for_callback, "__browserRecord__('N'); queueMicrotask(() => __browserRecord__('n'));", "<native-mixed>");
            helpers.freeEvalResult(result);
        }
    };
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            Native.id_for_callback = id;
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('H'); queueMicrotask(() => __browserRecord__('h'));"));
            try testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = Native.run }));
            try helpers.evalOk(id, "globalThis.__browserMixedTsfn__ = () => { __browserRecord__('T'); queueMicrotask(() => __browserRecord__('t')); }; setTimeout(() => { __browserRecord__('R'); queueMicrotask(() => __browserRecord__('r')); }, 0);");
            const callback = try callbackFromGlobal(id, "__browserMixedTsfn__");
            const ctx = engine.getContext(id) orelse return error.NoContext;
            defer ActiveEngine.freeValue(ctx, callback);
            const handle = tsfn.acquire(id, callback) orelse return error.AcquireFailed;
            defer tsfn.release(handle);
            try testing.expect(tsfn.call(handle, "ignored"));

            var turn: usize = 0;
            while (turn < 4) : (turn += 1) {
                _ = engine.testing.advance(id, 100);
                try Trace.expectLen((turn + 1) * 2);
                var snapshot: [64]u8 = undefined;
                const trace = Trace.snapshot(&snapshot);
                const task = trace[turn * 2];
                const microtask = trace[turn * 2 + 1];
                try testing.expect((task == 'H' and microtask == 'h') or (task == 'N' and microtask == 'n') or (task == 'T' and microtask == 't') or (task == 'R' and microtask == 'r'));
            }
            var snapshot: [64]u8 = undefined;
            const trace = Trace.snapshot(&snapshot);
            for ([_]u8{ 'H', 'N', 'T', 'R' }) |task| {
                var occurrences: usize = 0;
                for (trace) |item| {
                    if (item == task) occurrences += 1;
                }
                try testing.expectEqual(@as(usize, 1), occurrences);
            }
        }
    }.run);
}

test "browser event loop: TSFN source preserves enqueue order across handles" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try helpers.evalOk(
                id,
                "globalThis.__browserTsfnA__ = () => { __browserRecord__('A'); queueMicrotask(() => __browserRecord__('a')); };" ++
                    "globalThis.__browserTsfnB__ = () => { __browserRecord__('B'); queueMicrotask(() => __browserRecord__('b')); };",
            );
            const callback_a = try callbackFromGlobal(id, "__browserTsfnA__");
            const ctx = engine.getContext(id) orelse return error.NoContext;
            defer ActiveEngine.freeValue(ctx, callback_a);
            const callback_b = try callbackFromGlobal(id, "__browserTsfnB__");
            defer ActiveEngine.freeValue(ctx, callback_b);
            const handle_a = tsfn.acquire(id, callback_a) orelse return error.AcquireA;
            defer tsfn.release(handle_a);
            const handle_b = tsfn.acquire(id, callback_b) orelse return error.AcquireB;
            defer tsfn.release(handle_b);
            try testing.expect(tsfn.call(handle_b, "B-first"));
            try testing.expect(tsfn.call(handle_a, "A-second"));

            _ = engine.testing.advance(id, 100);
            try Trace.expect("Bb");
            _ = engine.testing.advance(id, 100);
            try Trace.expect("BbAa");
        }
    }.run);
}

test "browser event loop: native completion follows the task microtask checkpoint" {
    const State = struct {
        var id_for_callback: i32 = 0;
        fn run(_: ?*anyopaque) void {
            const result = engine.evalScript(id_for_callback, "__browserRecord__('A'); queueMicrotask(() => __browserRecord__('a'));", "<native-completion>");
            helpers.freeEvalResult(result);
        }
        fn complete(_: ?*anyopaque) void {
            Trace.append('C');
        }
    };
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            State.id_for_callback = id;
            try testing.expect(dispatch.postTask(id, .{
                .ctx = null,
                .run = State.run,
                .complete = State.complete,
            }));

            _ = engine.testing.advance(id, 100);
            try Trace.expect("AaC");
        }
    }.run);
}

test "browser event loop: native readiness cannot bulk-drain TSFN or timers" {
    const State = struct {
        id: i32,
        fn onNotify(ctx: ?*anyopaque, _: *event_loop.Notifier) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = tsfn.drainPending(self.id);
            timers.fireDue(self.id, 100);
        }
    };
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            try helpers.evalOk(
                id,
                "globalThis.__browserReadyTsfn__ = (x) => { __browserRecord__(x); queueMicrotask(() => __browserRecord__(x.toLowerCase())); };" ++
                    "setTimeout(() => { __browserRecord__('R'); queueMicrotask(() => __browserRecord__('r')); }, 0);" ++
                    "setTimeout(() => { __browserRecord__('S'); queueMicrotask(() => __browserRecord__('s')); }, 0);",
            );
            const callback = try callbackFromGlobal(id, "__browserReadyTsfn__");
            const engine_ctx = engine.getContext(id) orelse return error.NoContext;
            defer ActiveEngine.freeValue(engine_ctx, callback);
            const handle = tsfn.acquire(id, callback) orelse return error.AcquireFailed;
            defer tsfn.release(handle);
            try testing.expect(tsfn.call(handle, "A"));
            try testing.expect(tsfn.call(handle, "B"));

            const loop = (instance_map.getPtrs(id) orelse return error.InstanceMissing).loop;
            var state = State{ .id = id };
            var notifier: event_loop.Notifier = .{};
            notifier.init(loop, &state, State.onNotify);
            defer notifier.close();
            try testing.expect(notifier.notify());

            var turn: usize = 0;
            while (turn < 4) : (turn += 1) {
                _ = engine.testing.advance(id, 100);
                try Trace.expectLen((turn + 1) * 2);
            }
            var snapshot: [64]u8 = undefined;
            const trace = Trace.snapshot(&snapshot);
            for ([_]u8{ 'A', 'B', 'R', 'S' }) |task| {
                var occurrences: usize = 0;
                for (trace) |item| {
                    if (item == task) occurrences += 1;
                }
                try testing.expectEqual(@as(usize, 1), occurrences);
            }
        }
    }.run);
}

test "browser event loop: blocking loop keeps pending work runnable until the stop task" {
    const Native = struct {
        var id_for_callback: i32 = 0;
        fn recordN(_: ?*anyopaque) void {
            const result = engine.evalScript(id_for_callback, "__browserRecord__('N'); queueMicrotask(() => __browserRecord__('n'));", "<blocking-native-N>");
            helpers.freeEvalResult(result);
        }
        fn recordAndStop(_: ?*anyopaque) void {
            const result = engine.evalScript(id_for_callback, "__browserRecord__('S'); queueMicrotask(() => __browserRecord__('s'));", "<blocking-native-stop>");
            helpers.freeEvalResult(result);
            engine.stopEventLoop(id_for_callback);
        }
    };
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            Trace.reset();
            installRecorder(id);
            Native.id_for_callback = id;
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('A'); queueMicrotask(() => __browserRecord__('a')); "));
            std.debug.assert(engine.dispatchTask(id, "__browserRecord__('B'); queueMicrotask(() => __browserRecord__('b')); "));
            try testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = Native.recordN }));
            try testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = Native.recordAndStop }));

            engine.blockOnLoopFor(id, 1_000);
            try Trace.expect("AaNnBbSs");
        }
    }.run);
}
