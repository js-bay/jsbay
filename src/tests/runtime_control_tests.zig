//! Tests for src/runtime/runtime_control.zig — interrupt handling, GC, memory usage.
//!
//! Coverage:
//!   1. runGc on a fresh engine is a no-op that doesn't break subsequent evals
//!   2. getMemoryUsage: QJS returns non-zero allocations; JSC reports zeros
//!   3. requestInterrupt from another thread aborts `while (true) {}`
//!   4. clearInterrupt re-enables normal execution after a caught interrupt
//!   5. setExecutionTimeLimit auto-aborts after the deadline
//! 6. setExecutionTimeLimit(0) disables the limit; only explicit requestInterrupt stops infinite scripts

const std = @import("std");
const io = @import("../platform/io.zig");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const rc = @import("../runtime/runtime_control.zig");
const sample_hook = @import("../inspector/sample_hook.zig");
const types = @import("../types.zig");

// ---------------------------------------------------------------------------
// 1. Basic GC on a fresh engine
// ---------------------------------------------------------------------------

test "runtime_control: runGc is safe on a fresh engine" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            try testing.expect(rc.runGc(id));

            // Re-evaluate afterwards to prove the runtime is still healthy.
            try helpers.expectEvalEquals(id, "1 + 2", "3");

            // Second GC after running code.
            try testing.expect(rc.runGc(id));
            try helpers.expectEvalEquals(id, "'post-gc'", "post-gc");
        }
    }.run);
}

test "runtime_control: runGc/getMemoryUsage on unknown id returns false/null" {
    try testing.expect(!rc.runGc(99_991));
    try testing.expect(rc.getMemoryUsage(99_991) == null);
    try testing.expect(!rc.requestInterrupt(99_991));
    try testing.expect(!rc.clearInterrupt(99_991));
    try testing.expect(!rc.setExecutionTimeLimit(99_991, 100));
    try testing.expect(!rc.deinit(99_991));
}

// ---------------------------------------------------------------------------
// 2. Memory usage snapshot
// ---------------------------------------------------------------------------

test "runtime_control: getMemoryUsage shape matches backend" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            // Exercise the runtime a little so there's real allocator state.
            try helpers.evalOk(id,
                \\const xs = [];
                \\for (let i = 0; i < 1000; i++) xs.push({i, s: 'hello ' + i});
                \\xs.length;
            );

            const usage = rc.getMemoryUsage(id) orelse return error.NoUsage;

            switch (backend.active_backend) {
                .quickjs, .quickjs_ng => {
                    // QJS computes real stats. At least one of malloc_size or obj_count must be non-zero after the script above.
                    try testing.expect(usage.malloc_size > 0);
                    try testing.expect(usage.obj_count > 0);
                },
                .jsc => {
                    // JSC does not expose memory stats through the public C API — we report all zeros as a documented limitation.
                    try testing.expectEqual(@as(u64, 0), usage.malloc_size);
                    try testing.expectEqual(@as(u64, 0), usage.obj_count);
                },
            }
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. Runtime memory limit
// ---------------------------------------------------------------------------

test "runtime_control: memory limit is enforced by QuickJS and rejected by JSC" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            if (backend.active_backend == .jsc) {
                // JSC has no public C API for a per-runtime heap cap. Returning false prevents hosts from assuming an unenforced limit protects an untrusted script.
                try testing.expect(!rc.setMemoryLimit(id, 1));
                return;
            }

            const before = rc.getMemoryUsage(id) orelse return error.NoUsage;
            try testing.expect(before.malloc_size > 0);

            // Base the cap on the live runtime, then ask for an allocation substantially larger than the remaining budget. This avoids relying on a fixed startup size.
            const cap = std.math.add(u64, before.malloc_size, 64 * 1024) catch return error.Overflow;
            try testing.expect(rc.setMemoryLimit(id, cap));

            const limited = engine.evalScript(id, "new ArrayBuffer(4 * 1024 * 1024)", "<memory-limit>");
            defer helpers.freeEvalResult(limited);
            try testing.expect(limited.err != null);

            // Removing the cap must leave the runtime usable.
            try testing.expect(rc.setMemoryLimit(id, 0));
            const unlimited = rc.getMemoryUsage(id) orelse return error.NoUsage;
            try testing.expectEqual(@as(u64, 0), unlimited.malloc_limit);
            try helpers.expectEvalEquals(id, "6 * 7", "42");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. Interrupt from another thread cancels `while (true) {}`
// ---------------------------------------------------------------------------

const InterruptThreadCtx = struct {
    instance_id: i32,
    delay_ms: u64,
};

fn interruptAfterDelay(c: InterruptThreadCtx) void {
    io.sleepMs(@intCast(c.delay_ms));
    _ = rc.requestInterrupt(c.instance_id);
}

var sample_hook_interrupt_target = std.atomic.Value(i32).init(-1);
var sample_hook_interrupt_calls = std.atomic.Value(usize).init(0);

fn requestInterruptFromSampleHook(instance_id: i32) void {
    if (sample_hook_interrupt_target.load(.monotonic) != instance_id) return;
    _ = sample_hook_interrupt_calls.fetchAdd(1, .monotonic);
    _ = rc.requestInterrupt(instance_id);
}

test "runtime_control: requestInterrupt from another thread aborts infinite loop" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            // Spawn a thread that calls requestInterrupt after 50ms.
            const ctx = InterruptThreadCtx{ .instance_id = id, .delay_ms = 50 };
            var thread = try std.Thread.spawn(.{}, interruptAfterDelay, .{ctx});

            // This script would spin forever without the interrupt.
            const started = io.milliTimestamp();
            const res = engine.evalScript(id, "while (true) {}", "<interrupt-test>");
            defer helpers.freeEvalResult(res);
            const elapsed = io.milliTimestamp() - started;

            thread.join();

            // Must have produced an error (the engine translated the interrupt into a JS-visible exception).
            try testing.expect(res.err != null);

            // Reasonable upper bound: interrupt latency of a few seconds, well under the test-timeout watchdog.
            try testing.expect(elapsed < 5_000);

            // Clear the flag so subsequent operations on this instance (e.g. teardown-time helpers) don't see a stale request.
            _ = rc.clearInterrupt(id);
        }
    }.run);
}

test "runtime_control: interrupt requested by the first watchdog hook reaches the next check" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            const previous_hook = sample_hook.load();
            sample_hook_interrupt_target.store(id, .monotonic);
            sample_hook_interrupt_calls.store(0, .monotonic);
            sample_hook.store(requestInterruptFromSampleHook);
            defer sample_hook.store(previous_hook);
            defer sample_hook_interrupt_target.store(-1, .monotonic);
            defer _ = rc.clearInterrupt(id);

            // Backends invoke this hook after checking the interrupt flag. The hook therefore requests an interrupt only after the first check has chosen to continue, which requires a later check to abort.
            const res = engine.evalScript(id, "while (true) {}", "<sample-hook-interrupt-test>");
            defer helpers.freeEvalResult(res);

            try testing.expect(res.err != null);
            try testing.expect(sample_hook_interrupt_calls.load(.monotonic) > 0);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. clearInterrupt re-enables normal evaluation
// ---------------------------------------------------------------------------

test "runtime_control: clearInterrupt restores normal execution" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            // Request interrupt BEFORE eval — the handler should fire immediately on the first interrupt check.
            _ = rc.requestInterrupt(id);

            const res1 = engine.evalScript(id, "let i = 0; while (true) i++;", "<t>");
            defer helpers.freeEvalResult(res1);
            try testing.expect(res1.err != null);

            // Clear and try again — a finite script should run to completion.
            try testing.expect(rc.clearInterrupt(id));
            try helpers.expectEvalEquals(id, "40 + 2", "42");

            // And a bounded loop should succeed.
            try helpers.expectEvalEquals(id, "let s = 0; for (let i = 0; i < 100; i++) s += i; s", "4950");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 5. Execution time limit triggers interrupt
// ---------------------------------------------------------------------------

test "runtime_control: setExecutionTimeLimit interrupts long-running script" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            try testing.expect(rc.setExecutionTimeLimit(id, 100));

            const started = io.milliTimestamp();
            const res = engine.evalScript(id, "while (true) {}", "<timelimit-test>");
            defer helpers.freeEvalResult(res);
            const elapsed = io.milliTimestamp() - started;

            try testing.expect(res.err != null);
            // Must interrupt within a reasonable window.
            try testing.expect(elapsed >= 50);
            try testing.expect(elapsed < 5_000);

            // Disable the limit and clear any residual flag so subsequent finite scripts on the same instance aren't affected.
            try testing.expect(rc.setExecutionTimeLimit(id, 0));
            _ = rc.clearInterrupt(id);

            try helpers.expectEvalEquals(id, "'after-limit'", "after-limit");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 6. Time limit of zero = no limit; explicit requestInterrupt still works
// ---------------------------------------------------------------------------

test "runtime_control: setExecutionTimeLimit(0) disables limit, requestInterrupt still works" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            // Explicitly disable the limit.
            try testing.expect(rc.setExecutionTimeLimit(id, 0));

            // A short finite script should not be interrupted, even after a brief wall-clock sleep (the deadline is 0 = disabled).
            try helpers.expectEvalEquals(id, "let s = 0; for (let i = 0; i < 1000; i++) s += i; s", "499500");

            // Now confirm requestInterrupt still works for an infinite loop.
            const ctx = InterruptThreadCtx{ .instance_id = id, .delay_ms = 50 };
            var thread = try std.Thread.spawn(.{}, interruptAfterDelay, .{ctx});
            const res = engine.evalScript(id, "while (true) {}", "<no-limit>");
            defer helpers.freeEvalResult(res);
            thread.join();

            try testing.expect(res.err != null);
            _ = rc.clearInterrupt(id);
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 7. init/deinit idempotency
// ---------------------------------------------------------------------------

test "runtime_control: init is idempotent; deinit is idempotent" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            try testing.expect(rc.init(id)); // second call returns true, no double-install
            try helpers.expectEvalEquals(id, "1", "1");

            try testing.expect(rc.deinit(id));
            try testing.expect(!rc.deinit(id)); // already torn down

            // After deinit, further runtime_control API calls return false.
            try testing.expect(!rc.requestInterrupt(id));
            try testing.expect(!rc.setExecutionTimeLimit(id, 100));

            // But runGc/getMemoryUsage still work (they don't require init).
            try testing.expect(rc.runGc(id));
            try testing.expect(rc.getMemoryUsage(id) != null);

            // Engine itself is still usable.
            try helpers.expectEvalEquals(id, "2", "2");
        }
    }.run);
}

test "runtime_control: clearing lifecycle stop preserves user interrupt and deadline" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.init(id));
            try testing.expect(rc.setExecutionTimeLimit(id, 5_000));
            const deadline = rc.executionDeadlineMillis(id) orelse return error.NoDeadline;

            try testing.expect(rc.requestInterrupt(id));
            try testing.expect(rc.requestStopInterrupt(id));
            try testing.expect(rc.clearStopInterrupt(id));
            try testing.expect(rc.isInterruptRequested(id));
            try testing.expectEqual(deadline, rc.executionDeadlineMillis(id).?);

            try testing.expect(rc.clearInterrupt(id));
            try testing.expect(!rc.isInterruptRequested(id));
            try testing.expectEqual(deadline, rc.executionDeadlineMillis(id).?);
            try testing.expect(rc.setExecutionTimeLimit(id, 0));
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 8. An interrupt unwinds through script-level try/catch/finally, promise executors, and microtask jobs.
//
// ---------------------------------------------------------------------------

const InterruptSource = enum { requested_from_thread, time_limit };

/// Runs `script` on a fresh engine while an interrupt fires, then proves the interrupt was neither caught by the script nor left the engine unusable. The script marks `__swallowed` inside any catch it owns and `__past` at any point only reachable if the interrupt was caught. Returns whether the evaluation itself reported an error.
fn evalInterruptedExpectingNoSwallow(script: []const u8, source: InterruptSource) !bool {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(rc.init(id));
    defer _ = rc.deinit(id);

    var thread: ?std.Thread = null;
    switch (source) {
        .requested_from_thread => thread = try std.Thread.spawn(.{}, interruptAfterDelay, .{InterruptThreadCtx{ .instance_id = id, .delay_ms = 50 }}),
        .time_limit => try testing.expect(rc.setExecutionTimeLimit(id, 100)),
    }
    const started = io.milliTimestamp();
    const res = engine.evalScript(id, script, "<interrupt-unwind>");
    defer helpers.freeEvalResult(res);
    const elapsed = io.milliTimestamp() - started;
    if (thread) |t| t.join();
    try testing.expect(elapsed < 5_000);

    try testing.expect(rc.setExecutionTimeLimit(id, 0));
    try testing.expect(rc.clearInterrupt(id));

    try helpers.expectEvalEquals(id, "String(typeof globalThis.__swallowed === 'undefined' && typeof globalThis.__past === 'undefined')", "true");

    // The job queue is drained and the engine accepts new work, including new microtasks.
    try helpers.evalOk(id, "globalThis.__ran = 0; Promise.resolve().then(function () { globalThis.__ran = 1; });");
    try helpers.expectEvalEquals(id, "String(globalThis.__ran)", "1");
    try helpers.expectEvalEquals(id, "40 + 2", "42");
    return res.err != null;
}

test "runtime_control: interrupt is not swallowed by script try/catch/finally" {
    const script =
        \\try {
        \\  while (true) {}
        \\} catch (e) {
        \\  globalThis.__swallowed = true;
        \\} finally {
        \\  globalThis.__finally = true;
        \\}
        \\globalThis.__past = true;
    ;
    try testing.expect(try evalInterruptedExpectingNoSwallow(script, .requested_from_thread));
    try testing.expect(try evalInterruptedExpectingNoSwallow(script, .time_limit));
}

test "runtime_control: interrupt inside a Promise executor is not caught or turned into a rejection" {
    const script =
        \\new Promise(function () {
        \\  try {
        \\    while (true) {}
        \\  } catch (e) {
        \\    globalThis.__swallowed = true;
        \\  }
        \\  globalThis.__past = true;
        \\}).catch(function () {
        \\  globalThis.__swallowed = true;
        \\});
    ;
    _ = try evalInterruptedExpectingNoSwallow(script, .requested_from_thread);
    _ = try evalInterruptedExpectingNoSwallow(script, .time_limit);
}

test "runtime_control: interrupt inside a microtask job is not swallowed and later jobs still run" {
    const then_job =
        \\Promise.resolve().then(function () {
        \\  try {
        \\    while (true) {}
        \\  } catch (e) {
        \\    globalThis.__swallowed = true;
        \\  }
        \\  globalThis.__past = true;
        \\}).catch(function () {
        \\  globalThis.__swallowed = true;
        \\});
    ;
    const async_job =
        \\(async function () {
        \\  await null;
        \\  try {
        \\    while (true) {}
        \\  } catch (e) {
        \\    globalThis.__swallowed = true;
        \\  }
        \\  globalThis.__past = true;
        \\})().catch(function () {
        \\  globalThis.__swallowed = true;
        \\});
    ;
    for ([_][]const u8{ then_job, async_job }) |script| {
        _ = try evalInterruptedExpectingNoSwallow(script, .requested_from_thread);
        _ = try evalInterruptedExpectingNoSwallow(script, .time_limit);
    }
}

// Hitting the cap is an ordinary catchable script error that names the cause, not a process abort, and lifting the cap lets the very same allocation succeed.
test "runtime_control: an allocation refused by the memory limit is catchable and recoverable" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            if (backend.active_backend == .jsc) return;

            const before = rc.getMemoryUsage(id) orelse return error.NoUsage;
            const cap = std.math.add(u64, before.malloc_size, 64 * 1024) catch return error.Overflow;
            try testing.expect(rc.setMemoryLimit(id, cap));

            const text = try helpers.evalString(testing.allocator, id,
                \\(function () {
                \\    try { new ArrayBuffer(4 * 1024 * 1024); return 'allocated'; }
                \\    catch (e) { return String(e.name) + ':' + String(e.message); }
                \\})()
            );
            defer testing.allocator.free(text);
            try testing.expect(std.mem.indexOf(u8, text, "out of memory") != null);

            try testing.expect(rc.setMemoryLimit(id, 0));
            try helpers.expectEvalEquals(id, "new ArrayBuffer(4 * 1024 * 1024).byteLength", "4194304");
        }
    }.run);
}

// Entries whose keys die are reclaimed by collection, so repeated fill-and-collect cycles must not grow the heap by anything near the amount of data that passed through.
test "runtime_control: dead WeakMap keys are reclaimed across repeated collections" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            if (backend.active_backend == .jsc) return;
            try testing.expect(rc.init(id));
            defer _ = rc.deinit(id);

            try helpers.evalOk(id,
                \\globalThis.__wm = new WeakMap();
                \\globalThis.__fill = function () {
                \\    for (var i = 0; i < 2000; i++) globalThis.__wm.set({ i: i, pad: 'x'.repeat(32) }, { v: i });
                \\};
            );
            // Warm up so one-time runtime growth is not mistaken for a leak.
            try helpers.evalOk(id, "__fill();");
            _ = rc.runGc(id);
            const base = rc.getMemoryUsage(id) orelse return error.NoUsage;

            var round: u32 = 0;
            while (round < 20) : (round += 1) {
                try helpers.evalOk(id, "__fill();");
                _ = rc.runGc(id);
            }
            const after = rc.getMemoryUsage(id) orelse return error.NoUsage;

            // 20 rounds x 2000 entries is megabytes if retained; allow for allocator slack only.
            try testing.expect(after.malloc_size < base.malloc_size + 256 * 1024);
            try testing.expect(after.obj_count < base.obj_count + 100);
        }
    }.run);
}
