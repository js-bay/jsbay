//! Tests for setTimeout / setInterval / clearTimeout / clearInterval.
//!
//! These tests exercise the full public engine API including the native event loop. Side effects are observed via globals that JS callbacks mutate through a registered native function (`__bump__`).

const std = @import("std");
const io = @import("../platform/io.zig");
const testing = std.testing;

const engine = @import("../engine.zig");
const types = @import("../types.zig");
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;
const quickjs_api = backend.ActiveEngineModule;
const qjs = quickjs_api.qjs;

// ---------------------------------------------------------------------------
// Shared side-effect globals and native helper registration.
//
// Timers fire JS callbacks asynchronously — we need a way for those JS callbacks to surface an observable signal back to the Zig test. We register a native function `__bump__()` that increments an atomic counter. A test that wants to verify "the timer ran" asserts on the counter value.
//
// All tests that use `__bump__` must call `resetCounters()` at the start.
// ---------------------------------------------------------------------------

var g_bump_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_bump_time_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_timer_reference_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
var g_stop_target_id: std.atomic.Value(i32) = std.atomic.Value(i32).init(0);
var g_reentrant_tick_deadline: std.atomic.Value(i64) = std.atomic.Value(i64).init(-2);

fn resetCounters() void {
    g_bump_count.store(0, .seq_cst);
    g_bump_time_ms.store(0, .seq_cst);
    g_timer_reference_ms.store(0, .seq_cst);
    g_stop_target_id.store(0, .seq_cst);
    g_reentrant_tick_deadline.store(-2, .seq_cst);
}

fn jsBump(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = ctx;
    _ = _this;
    _ = argc;
    _ = argv;
    g_bump_time_ms.store(@import("zev").monotonicMilliseconds(), .seq_cst);
    _ = g_bump_count.fetchAdd(1, .seq_cst);
    return quickjs_api.mkval(qjs.JS_TAG_UNDEFINED);
}

fn jsMarkTimerReference(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = ctx;
    _ = _this;
    _ = argc;
    _ = argv;
    g_timer_reference_ms.store(@import("zev").monotonicMilliseconds(), .seq_cst);
    return quickjs_api.mkval(qjs.JS_TAG_UNDEFINED);
}

fn jsStopLoop(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = _this;
    _ = argc;
    _ = argv;
    const id = ActiveEngine.instanceIdFromCtx(ctx);
    engine.stopEventLoop(id);
    return quickjs_api.mkval(qjs.JS_TAG_UNDEFINED);
}

fn jsReentrantTick(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = _this;
    _ = argc;
    _ = argv;
    const id = ActiveEngine.instanceIdFromCtx(ctx);
    g_reentrant_tick_deadline.store(engine.testing.advance(id, 3000), .seq_cst);
    return quickjs_api.mkval(qjs.JS_TAG_UNDEFINED);
}

/// Install `__bump__` and `__stop__` on the global object so JS callbacks can signal back to the test.
fn installHelpers(id: i32) void {
    const ctx = engine.getContext(id) orelse return;
    const global = ActiveEngine.getGlobalObject(ctx);
    ActiveEngine.setPropertyStr(
        ctx,
        global,
        "__bump__",
        ActiveEngine.newCFunction(ctx, &jsBump, "__bump__", 0),
    );
    ActiveEngine.setPropertyStr(
        ctx,
        global,
        "__stop__",
        ActiveEngine.newCFunction(ctx, &jsStopLoop, "__stop__", 0),
    );
    ActiveEngine.setPropertyStr(
        ctx,
        global,
        "__markTimerReference__",
        ActiveEngine.newCFunction(ctx, &jsMarkTimerReference, "__markTimerReference__", 0),
    );
    ActiveEngine.setPropertyStr(
        ctx,
        global,
        "__reentrantTick__",
        ActiveEngine.newCFunction(ctx, &jsReentrantTick, "__reentrantTick__", 0),
    );
    ActiveEngine.freeValue(ctx, global);
}

/// Drain the event loop non-blockingly until `cond()` returns true or we hit the iteration cap. Sleeps briefly between ticks so real timers get a chance to expire.
fn drainUntil(id: i32, cond: *const fn () bool) !void {
    var i: u32 = 0;
    while (i < 200) : (i += 1) {
        engine.runEventLoopOnce(id);
        if (cond()) return;
        io.sleepMs(5);
    }
    return error.TimedOut;
}

fn bumpReachedOne() bool {
    return g_bump_count.load(.seq_cst) >= 1;
}

fn bumpReachedTwo() bool {
    return g_bump_count.load(.seq_cst) >= 2;
}

fn bumpReachedThree() bool {
    return g_bump_count.load(.seq_cst) >= 3;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "timers: setTimeout(fn, 0) fires after runEventLoopOnce drain" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id, "setTimeout(function(){ __bump__(); }, 0);");
    try drainUntil(id, bumpReachedOne);
    try testing.expect(g_bump_count.load(.seq_cst) >= 1);
}

test "timers: setTimeout(fn, 10) fires under blocking runEventLoop with stop" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    // Schedule a timer that bumps the counter AND stops the loop so runEventLoop returns cleanly.
    try helpers.evalOk(id, "setTimeout(function(){ __bump__(); __stop__(); }, 10);");
    engine.runEventLoop(id);
    try testing.expect(g_bump_count.load(.seq_cst) >= 1);
}

test "timers: one-shot callback does not fire before its monotonic deadline" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    const delay_ms: u64 = 20;
    try helpers.evalOk(id, "__markTimerReference__(); setTimeout(function(){ __bump__(); __stop__(); }, 20);");
    engine.runEventLoop(id);
    engine.runEventLoopOnce(id);
    const callback_time = g_bump_time_ms.load(.seq_cst);
    const reference_time = g_timer_reference_ms.load(.seq_cst);
    try testing.expectEqual(@as(u32, 1), g_bump_count.load(.seq_cst));
    try testing.expect(callback_time >= reference_time + delay_ms);
}

test "timers: setTimeout returns a numeric timer id" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    try helpers.expectEvalEquals(
        id,
        "(typeof setTimeout(function(){}, 100) === 'number')",
        "true",
    );
}

test "timers: clearTimeout before fire prevents invocation" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\var tid = setTimeout(function(){ __bump__(); }, 50);
        \\clearTimeout(tid);
    );

    // Drive the loop for a while — the cleared timer must not fire.
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(5);
    }
    try testing.expectEqual(@as(u32, 0), g_bump_count.load(.seq_cst));
}

test "timers: clearInterval from its own callback" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\var intervalCount = 0;
        \\var siblingCount = 0;
        \\var intervalId = setInterval(function(){
        \\  intervalCount++;
        \\  __bump__();
        \\  clearInterval(intervalId);
        \\}, 1);
        \\setTimeout(function(){ siblingCount++; __bump__(); }, 0);
    );

    try drainUntil(id, bumpReachedTwo);
    try helpers.expectEvalEquals(id, "intervalCount", "1");
    try helpers.expectEvalEquals(id, "siblingCount", "1");

    // Continue draining past several interval periods. A self-cleared interval must not be rearmed after its first callback returns.
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(5);
    }
    try testing.expectEqual(@as(u32, 2), g_bump_count.load(.seq_cst));
    try helpers.expectEvalEquals(id, "intervalCount", "1");
    try helpers.expectEvalEquals(id, "siblingCount", "1");
}

test "timers: clearTimeout(invalid_id) is a no-op" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    // Should not throw. Running multiple bogus ids including negative.
    try helpers.evalOk(id,
        \\clearTimeout(99999);
        \\clearTimeout(-1);
        \\clearTimeout(0);
    );
}

test "timers: multiple setTimeout fire roughly in delay order" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\var order = [];
        \\setTimeout(function(){ order.push('c'); __bump__(); }, 30);
        \\setTimeout(function(){ order.push('a'); __bump__(); }, 0);
        \\setTimeout(function(){ order.push('b'); __bump__(); }, 10);
    );

    try drainUntil(id, bumpReachedThree);

    // Verify ordering: shortest delay ('a' @ 0ms) fires first, longest ('c' @ 30ms) last.
    try helpers.expectEvalEquals(id, "order.join(',')", "a,b,c");
}

test "timers: callbacks with the same deadline retain registration order" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\var order = [];
        \\setTimeout(function(){ order.push(1); __bump__(); }, 0);
        \\setTimeout(function(){ order.push(2); __bump__(); }, 0);
    );
    try drainUntil(id, bumpReachedTwo);
    try helpers.expectEvalEquals(id, "order.join(',')", "1,2");
}

test "timers: setInterval fires repeatedly until clearInterval" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\var n = 0;
        \\var iid = setInterval(function(){
        \\  n++;
        \\  __bump__();
        \\  if (n >= 3) clearInterval(iid);
        \\}, 5);
    );

    try drainUntil(id, bumpReachedThree);
    const count = g_bump_count.load(.seq_cst);
    try testing.expect(count >= 3);

    // After clearInterval, the counter should not keep climbing. Drive the loop a bit more and confirm.
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(2);
    }
    const after = g_bump_count.load(.seq_cst);
    // Allow one extra tick slack in case an in-flight firing was already queued
    try testing.expect(after <= count + 2);
}

test "timers: throwing callback does not crash engine; subsequent eval still works" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id, "setTimeout(function(){ throw new Error('boom'); }, 0);");
    // Drive the loop; throw is swallowed by the backend callFunctionNoArgs path.
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(2);
    }

    // The engine should still be alive and usable.
    const v = try helpers.evalInt(id, "1 + 2");
    try testing.expectEqual(@as(i64, 3), v);
}

test "timers: setTimeout with non-function throws TypeError at registration" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    try helpers.evalErr(id, "setTimeout('not a function', 0);");
    try helpers.evalErr(id, "setTimeout(42, 0);");
    try helpers.evalErr(id, "setTimeout(null, 0);");
}

test "timers: setTimeout without delay argument defaults to 0" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    // No second argument — createTimer leaves delay at 0 and starts immediately.
    try helpers.evalOk(id, "setTimeout(function(){ __bump__(); });");
    try drainUntil(id, bumpReachedOne);
    try testing.expect(g_bump_count.load(.seq_cst) >= 1);
}

test "timers: delay conversion errors do not schedule callbacks" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\let delayConversionThrew = false;
        \\try { setTimeout(function(){ __bump__(); }, Symbol()); }
        \\catch (error) { delayConversionThrew = error instanceof TypeError; }
        \\globalThis.delayConversionThrew = delayConversionThrew;
    );
    try helpers.expectEvalEquals(id, "delayConversionThrew", "true");

    var i: u32 = 0;
    while (i < 10) : (i += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(2);
    }
    try testing.expectEqual(@as(u32, 0), g_bump_count.load(.seq_cst));
}

test "timers: nested setTimeout fires over successive ticks" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\setTimeout(function(){
        \\  __bump__();
        \\  setTimeout(function(){ __bump__(); }, 0);
        \\}, 0);
    );

    // Each turn fires only the timers that existed when it began.
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 1), g_bump_count.load(.seq_cst));
    engine.runEventLoopOnce(id);
    try testing.expect(g_bump_count.load(.seq_cst) >= 2);
}

test "timers: first explicit tick anchors pre-tick timers and clamps clock rollback" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    // Creating a timer must not silently read the native clock. Its delay starts at the first host tick, so a host can evaluate before it has a clock sample.
    try helpers.evalOk(id, "setTimeout(function(){ __bump__(); }, 10);");
    try testing.expectEqual(@as(i64, 1010), engine.testing.advance(id, 1000));
    try testing.expectEqual(@as(u32, 0), g_bump_count.load(.seq_cst));

    // A stale host timestamp may not move the scheduler backwards or fire early.
    try testing.expectEqual(@as(i64, 1010), engine.testing.advance(id, 900));
    try testing.expectEqual(@as(u32, 0), g_bump_count.load(.seq_cst));
    try testing.expectEqual(@as(i64, -1), engine.testing.advance(id, 1010));
    try testing.expectEqual(@as(u32, 1), g_bump_count.load(.seq_cst));
}

test "timers: nested zero-delay timer waits for the next explicit tick" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\setTimeout(function(){
        \\  __bump__();
        \\  setTimeout(function(){ __bump__(); }, 0);
        \\}, 0);
    );
    try testing.expectEqual(@as(i64, 2000), engine.testing.advance(id, 2000));
    try testing.expectEqual(@as(u32, 1), g_bump_count.load(.seq_cst));
    try testing.expectEqual(@as(i64, -1), engine.testing.advance(id, 2000));
    try testing.expectEqual(@as(u32, 2), g_bump_count.load(.seq_cst));
}

test "timers: reentrant tick only reports a deadline" {
    resetCounters();
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    installHelpers(id);

    try helpers.evalOk(id,
        \\var intervalId = setInterval(function(){
        \\  __reentrantTick__();
        \\  __bump__();
        \\  clearInterval(intervalId);
        \\}, 0);
    );
    try testing.expectEqual(@as(i64, -1), engine.testing.advance(id, 3000));
    try testing.expectEqual(@as(u32, 1), g_bump_count.load(.seq_cst));
    // The nested call saw the current interval but did not execute it again.
    try testing.expectEqual(@as(i64, 3000), g_reentrant_tick_deadline.load(.seq_cst));
}

test "timers: eval drains a queued microtask before returning an error" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    const result = engine.evalScript(id, "queueMicrotask(function(){ globalThis.__microtaskAfterError__ = 1; }); throw new Error('expected');", "<test>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err != null);
    try helpers.expectEvalEquals(id, "globalThis.__microtaskAfterError__", "1");
}

test "timers: setTimeout on instance that is immediately destroyed does not crash" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));

    // Schedule a far-future timer, then destroy without running the loop. Destroy must tear down the pending timer cleanly.
    try helpers.evalOk(id, "setTimeout(function(){}, 10000);");
    engine.destroy(id);

    // If we reach here without aborting, the test passes.
    try testing.expect(true);
}
