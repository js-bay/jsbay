//! Promise microtasks run before a setTimeout(0) macrotask.
//!
//! Public script entries and queued tasks drain their microtasks at completion. A scheduler turn without a task does not create a new task boundary.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

const engine = @import("../engine.zig");
const io = @import("../platform/io.zig");
const backend = @import("../backend.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const helpers = @import("test_helpers.zig");
const value = @import("../value/root.zig");
const dispatch = @import("../runtime/dispatch.zig");

var completed_promise_boundaries: usize = 0;

fn recordPromiseBoundary(_: i32, _: value.NativeArgs) value.NativeResult {
    completed_promise_boundaries += 1;
    return .undefined_val;
}

test "microtask: public script completion drains Promise before returning to the host" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            completed_promise_boundaries = 0;
            value.registerFunction(id, null, "__recordPromiseBoundary", &recordPromiseBoundary);
            try helpers.evalOk(id, "Promise.resolve().then(__recordPromiseBoundary);");
            try testing.expectEqual(@as(usize, 1), completed_promise_boundaries);
        }
    }.run);
}

test "microtask: raw QuickJS jobs wait for a real task boundary rather than an idle tick" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            completed_promise_boundaries = 0;
            value.registerFunction(id, null, "__recordPromiseBoundary", &recordPromiseBoundary);
            const c = if (backend.active_backend == .quickjs) @import("../backend/quickjs/c_api.zig") else @import("../backend/quickjs_ng/c_api.zig");
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const source: [:0]const u8 = "Promise.resolve().then(__recordPromiseBoundary);";
            const result = c.qjs.JS_Eval(ctx, source.ptr, source.len, "<raw-promise-boundary>", c.qjs.JS_EVAL_TYPE_GLOBAL);
            defer c.jsbay_qjs_JS_FreeValue(ctx, result);
            try testing.expect(!c.jsIsException(result));
            try testing.expectEqual(@as(usize, 0), completed_promise_boundaries);

            _ = engine.testing.advance(id, 0);
            try testing.expectEqual(@as(usize, 0), completed_promise_boundaries);

            try testing.expect(dispatch.postTask(id, .{ .ctx = null, .run = struct {
                fn run(_: ?*anyopaque) void {}
            }.run }));
            _ = engine.testing.advance(id, 0);
            try testing.expectEqual(@as(usize, 1), completed_promise_boundaries);
        }
    }.run);
}

fn requestInterruptFromMicrotask(id: i32, _: value.NativeArgs) value.NativeResult {
    _ = runtime_control.requestInterrupt(id);
    return .undefined_val;
}

fn expireDeadlineFromMicrotask(id: i32, _: value.NativeArgs) value.NativeResult {
    _ = runtime_control.setExecutionTimeLimit(id, 1);
    io.sleepMs(2);
    return .undefined_val;
}

test "microtask: Promise.then appends A before setTimeout(0) appends B" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const kind = try helpers.evalString(testing.allocator, id, "typeof setTimeout");
            defer testing.allocator.free(kind);
            if (!std.mem.eql(u8, kind, "function")) return;

            try helpers.evalOk(id,
                \\globalThis.__seq = '';
                \\Promise.resolve().then(function () { globalThis.__seq += 'A'; });
                \\setTimeout(function () { globalThis.__seq += 'B'; }, 0);
            );

            var i: u32 = 0;
            while (i < 50) : (i += 1) {
                engine.runEventLoopOnce(id);
                const seq = try helpers.evalString(testing.allocator, id, "globalThis.__seq");
                const done = std.mem.eql(u8, seq, "AB");
                testing.allocator.free(seq);
                if (done) break;
                io.sleepMs(1);
            }
            try helpers.expectEvalEquals(id, "globalThis.__seq", "AB");
        }
    }.run);
}

test "microtask: reaction queued by one timer runs before the next timer" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const kind = try helpers.evalString(testing.allocator, id, "typeof setTimeout");
            defer testing.allocator.free(kind);
            if (!std.mem.eql(u8, kind, "function")) return;

            // Both timers are already queued. The first one's microtask must run before the second timer callback in the same scheduler turn.
            try helpers.evalOk(id,
                \\globalThis.__seq = '';
                \\setTimeout(function () {
                \\  globalThis.__seq += 'A';
                \\  Promise.resolve().then(function () { globalThis.__seq += 'B'; });
                \\}, 0);
                \\setTimeout(function () { globalThis.__seq += 'C'; }, 0);
            );

            var i: u32 = 0;
            while (i < 50) : (i += 1) {
                engine.runEventLoopOnce(id);
                const seq = try helpers.evalString(testing.allocator, id, "globalThis.__seq");
                const done = std.mem.eql(u8, seq, "ABC");
                testing.allocator.free(seq);
                if (done) break;
                io.sleepMs(1);
            }
            try helpers.expectEvalEquals(id, "globalThis.__seq", "ABC");
        }
    }.run);
}

test "microtask: await continuation runs before the next ready timer" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__await_seq = '';
                \\setTimeout(async function () {
                \\  globalThis.__await_seq += 'A';
                \\  await Promise.resolve();
                \\  globalThis.__await_seq += 'B';
                \\}, 0);
                \\setTimeout(function () { globalThis.__await_seq += 'C'; }, 0);
            );

            _ = engine.testing.advance(id, 1000);
            _ = engine.testing.advance(id, 1000);
            try helpers.expectEvalEquals(id, "globalThis.__await_seq", "ABC");
        }
    }.run);
}

test "microtask: queueMicrotask runs before setTimeout(0)" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__seq = '';
                \\queueMicrotask(function () { globalThis.__seq += 'A'; });
                \\setTimeout(function () { globalThis.__seq += 'B'; }, 0);
            );

            var i: u32 = 0;
            while (i < 50) : (i += 1) {
                engine.runEventLoopOnce(id);
                const seq = try helpers.evalString(testing.allocator, id, "globalThis.__seq");
                const done = std.mem.eql(u8, seq, "AB");
                testing.allocator.free(seq);
                if (done) break;
                io.sleepMs(1);
            }
            try helpers.expectEvalEquals(id, "globalThis.__seq", "AB");
        }
    }.run);
}

test "microtask: an uncaught job exception does not delay sibling jobs past the next timer" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__microtask_after_throw = false;
                \\globalThis.__next_timer_saw_microtask = false;
                \\setTimeout(function () {
                \\  queueMicrotask(function () { throw new Error('first microtask failure'); });
                \\  queueMicrotask(function () { globalThis.__microtask_after_throw = true; });
                \\}, 0);
                \\setTimeout(function () {
                \\  globalThis.__next_timer_saw_microtask = globalThis.__microtask_after_throw;
                \\}, 0);
            );

            var i: u32 = 0;
            while (i < 50) : (i += 1) {
                engine.runEventLoopOnce(id);
                const saw = try helpers.evalString(testing.allocator, id, "String(globalThis.__next_timer_saw_microtask)");
                const done = std.mem.eql(u8, saw, "true");
                testing.allocator.free(saw);
                if (done) break;
                io.sleepMs(1);
            }
            try helpers.expectEvalEquals(id, "String(globalThis.__next_timer_saw_microtask)", "true");
        }
    }.run);
}

test "microtask: later jobs run after more than one uncaught job exception" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.evalOk(id,
                \\globalThis.__microtask_after_failures = false;
                \\globalThis.__next_timer_saw_all_microtasks = false;
                \\setTimeout(function () {
                \\  queueMicrotask(function () { throw new Error('first microtask failure'); });
                \\  queueMicrotask(function () { throw new Error('second microtask failure'); });
                \\  queueMicrotask(function () { globalThis.__microtask_after_failures = true; });
                \\}, 0);
                \\setTimeout(function () {
                \\  globalThis.__next_timer_saw_all_microtasks = globalThis.__microtask_after_failures;
                \\}, 0);
            );

            var i: u32 = 0;
            while (i < 50) : (i += 1) {
                engine.runEventLoopOnce(id);
                const saw = try helpers.evalString(testing.allocator, id, "String(globalThis.__next_timer_saw_all_microtasks)");
                const done = std.mem.eql(u8, saw, "true");
                testing.allocator.free(saw);
                if (done) break;
                io.sleepMs(1);
            }
            try helpers.expectEvalEquals(id, "String(globalThis.__next_timer_saw_all_microtasks)", "true");
        }
    }.run);
}

test "microtask: an interrupt stops the current drain before a later job starts" {
    if (!backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(runtime_control.init(id));
            defer _ = runtime_control.deinit(id);
            value.registerFunction(id, null, "__requestInterruptFromMicrotask", &requestInterruptFromMicrotask);

            try helpers.evalOk(id,
                \\globalThis.__job_after_interrupt = false;
                \\globalThis.__next_timer_saw_interrupted_job = null;
                \\setTimeout(function () {
                \\  setTimeout(function () {
                \\    globalThis.__next_timer_saw_interrupted_job = globalThis.__job_after_interrupt;
                \\  }, 0);
                \\  queueMicrotask(function () { __requestInterruptFromMicrotask(); });
                \\  queueMicrotask(function () { globalThis.__job_after_interrupt = true; });
                \\}, 0);
            );

            io.sleepMs(1);
            engine.runEventLoopOnce(id);
            try testing.expect(runtime_control.isInterruptRequested(id));
            try testing.expect(runtime_control.clearInterrupt(id));

            engine.runEventLoopOnce(id);
            try helpers.expectEvalEquals(id, "String(globalThis.__next_timer_saw_interrupted_job)", "false");
            try helpers.expectEvalEquals(id, "String(globalThis.__job_after_interrupt)", "true");
        }
    }.run);
}

test "microtask: an expired deadline stops the current drain before a later job starts" {
    if (!backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    // Windows CI lets the post-deadline microtask run before the follow-up timer observes it.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(runtime_control.init(id));
            defer _ = runtime_control.deinit(id);
            value.registerFunction(id, null, "__expireDeadlineFromMicrotask", &expireDeadlineFromMicrotask);

            try helpers.evalOk(id,
                \\globalThis.__job_after_deadline = false;
                \\globalThis.__next_timer_saw_deadline_job = null;
                \\setTimeout(function () {
                \\  setTimeout(function () {
                \\    globalThis.__next_timer_saw_deadline_job = globalThis.__job_after_deadline;
                \\  }, 0);
                \\  queueMicrotask(function () { __expireDeadlineFromMicrotask(); });
                \\  queueMicrotask(function () { globalThis.__job_after_deadline = true; });
                \\}, 0);
            );

            io.sleepMs(1);
            engine.runEventLoopOnce(id);
            try testing.expect(!runtime_control.isInterruptRequested(id));
            try testing.expect(runtime_control.executionDeadlineMillis(id) != null);
            try testing.expect(runtime_control.setExecutionTimeLimit(id, 0));

            engine.runEventLoopOnce(id);
            try helpers.expectEvalEquals(id, "String(globalThis.__next_timer_saw_deadline_job)", "false");
            try helpers.expectEvalEquals(id, "String(globalThis.__job_after_deadline)", "true");
        }
    }.run);
}

// An exception thrown by a queued job belongs to that job. The evaluation that queued it still reports its own completion value with no error, a job queued after the failing one still runs, and the next evaluation starts clean.
test "microtask: a throwing queued job does not change the result of the evaluation that queued it" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id,
                \\globalThis.__after = 0;
                \\queueMicrotask(function () { throw new Error('job failure'); });
                \\queueMicrotask(function () { globalThis.__after = 1; });
                \\7
            , "7");
            try helpers.expectEvalEquals(id, "String(globalThis.__after)", "1");
            try helpers.expectEvalEquals(id, "1 + 1", "2");
        }
    }.run);
}
