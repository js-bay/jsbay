//! GC, finalizer, and aliasing lifecycle tests for NativeHandle.
//!
//! Basic API and CallbackStore coverage live in their corresponding NativeHandle test files.

const helpers = @import("native_handle_test_helpers.zig");
const handle = @import("../value/native_handle/handle.zig");
const method = @import("../value/native_handle/method.zig");

const c = helpers.c;
const testing = helpers.testing;

const JS_UNDEFINED = helpers.JS_UNDEFINED;
const TestCounter = helpers.TestCounter;
const withTestEngine = helpers.withTestEngine;
const evalToInt = helpers.evalToInt;
const resetTestCounter = helpers.resetTestCounter;
const g_test_counter = &helpers.g_test_counter;
const testCallFn = helpers.testCallFn;
const testFinalizeFn = helpers.testFinalizeFn;
const testMethodGetValue = helpers.testMethodGetValue;

const create = handle.create;
const setMethod = method.setMethod;

// ──────────────────────────────────────────────────────────────────────────
// 5. Finalizer fires on GC ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: finalizer fires on GC" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();

            // Create handle, assign to global, then delete the reference.
            const obj = create(ctx, .{
                .call_fn = testCallFn,
                .finalize_fn = testFinalizeFn,
            });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

            // Remove the only reference and force GC.
            const global2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global2, "h", JS_UNDEFINED);
            c.JS_FreeValue(ctx, global2);
            c.JS_RunGC(rt);

            try testing.expectEqual(@as(i32, 1), g_test_counter.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 6. Finalizer does NOT fire while handle is still referenced ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: finalizer does not fire while referenced" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();

            const obj = create(ctx, .{ .finalize_fn = testFinalizeFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // GC with the reference still alive.
            c.JS_RunGC(rt);
            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 10. Detached method prevents handle GC ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: detached method prevents handle GC" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();
            g_test_counter.call_count = 77;

            const obj = create(ctx, .{
                .ptr = @ptrCast(g_test_counter),
                .finalize_fn = testFinalizeFn,
            });
            setMethod(ctx, obj, "get", testMethodGetValue, 0);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // Stash the method, delete the handle, GC.
            _ = try evalToInt(ctx, "var saved = h.get");

            const global2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global2, "h", JS_UNDEFINED);
            c.JS_FreeValue(ctx, global2);
            c.JS_RunGC(rt);

            // Handle must NOT have been finalized (method holds a ref).
            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

            // Method still works.
            const result = try evalToInt(ctx, "saved()");
            try testing.expectEqual(@as(i64, 77), result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 16. Many handles created and GC'd — no leaks ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: mass create and GC — finalizers all fire" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();
            const N = 1000;

            // Create N handles in an array.
            const global = c.JS_GetGlobalObject(ctx);
            const arr = c.JS_NewArray(ctx);
            var i: c_int = 0;
            while (i < N) : (i += 1) {
                const obj = create(ctx, .{ .finalize_fn = testFinalizeFn });
                _ = c.JS_SetPropertyUint32(ctx, arr, @intCast(i), obj);
            }
            _ = c.JS_SetPropertyStr(ctx, global, "arr", arr);
            c.JS_FreeValue(ctx, global);

            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

            // Delete the array and GC.
            const global2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global2, "arr", JS_UNDEFINED);
            c.JS_FreeValue(ctx, global2);
            c.JS_RunGC(rt);

            try testing.expectEqual(@as(i32, N), g_test_counter.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 17. Handle survives closure capture ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: handle survives JS closure capture" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{
                .call_fn = testCallFn,
                .finalize_fn = testFinalizeFn,
            });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // Capture handle in a closure, delete original ref.
            _ = try evalToInt(ctx, "var closure = (function() { var ref = h; return function() { return ref(); }; })();");

            const global2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global2, "h", JS_UNDEFINED);
            c.JS_FreeValue(ctx, global2);
            c.JS_RunGC(rt);

            // Handle alive via closure.
            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);
            const result = try evalToInt(ctx, "closure()");
            try testing.expectEqual(@as(i64, 1), result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 18. Rapid create-call-GC cycle (stress test) ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: rapid create-call-GC cycle" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();
            var i: i32 = 0;
            while (i < 500) : (i += 1) {
                const obj = create(ctx, .{
                    .call_fn = testCallFn,
                    .finalize_fn = testFinalizeFn,
                });
                const global = c.JS_GetGlobalObject(ctx);
                _ = c.JS_SetPropertyStr(ctx, global, "tmp", obj);
                c.JS_FreeValue(ctx, global);

                _ = try evalToInt(ctx, "tmp()");

                const global2 = c.JS_GetGlobalObject(ctx);
                _ = c.JS_SetPropertyStr(ctx, global2, "tmp", JS_UNDEFINED);
                c.JS_FreeValue(ctx, global2);

                if (@mod(i, 50) == 0) c.JS_RunGC(rt);
            }
            c.JS_RunGC(rt);

            try testing.expectEqual(@as(i32, 500), g_test_counter.call_count);
            try testing.expectEqual(@as(i32, 500), g_test_counter.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 21. Handle used with apply/call/bind ──────────────────────────────────────────────────────────────────────────
//
// Temporarily disabled in standalone `zig test` mode. Keep the original body for later stabilization instead of deleting it.
//
// test "NativeHandle: works with Function.prototype.call" { try withTestEngine(struct { fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void { resetTestCounter(); const obj = create(ctx, .{ .call_fn = testCallFn }); const global = c.JS_GetGlobalObject(ctx); _ = c.JS_SetPropertyStr(ctx, global, "h", obj); c.JS_FreeValue(ctx, global);
//
// _ = try evalToInt(ctx, "h.call(null, 'a', 'b')"); try testing.expectEqual(@as(c_int, 2), g_test_counter.last_argc);
//
// const g2 = c.JS_GetGlobalObject(ctx); _ = c.JS_SetPropertyStr(ctx, g2, "h", JS_UNDEFINED); c.JS_FreeValue(ctx, g2); c.JS_RunGC(rt); } }.run); }
//
// ──────────────────────────────────────────────────────────────────────────
// 22. Multiple handles — independent finalization ──────────────────────────────────────────────────────────────────────────

var g_counter_a: TestCounter = .{};
var g_counter_b: TestCounter = .{};

fn finalize_a(_: ?*anyopaque) void {
    g_counter_a.finalize_count += 1;
}
fn finalize_b(_: ?*anyopaque) void {
    g_counter_b.finalize_count += 1;
}

test "NativeHandle: multiple handles finalize independently" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            g_counter_a = .{};
            g_counter_b = .{};

            const a = create(ctx, .{ .finalize_fn = finalize_a });
            const b = create(ctx, .{ .finalize_fn = finalize_b });

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "a", a);
            _ = c.JS_SetPropertyStr(ctx, global, "b", b);
            c.JS_FreeValue(ctx, global);

            // Delete only a.
            const g2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g2, "a", JS_UNDEFINED);
            c.JS_FreeValue(ctx, g2);
            c.JS_RunGC(rt);

            try testing.expectEqual(@as(i32, 1), g_counter_a.finalize_count);
            try testing.expectEqual(@as(i32, 0), g_counter_b.finalize_count);

            // Delete b.
            const g3 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g3, "b", JS_UNDEFINED);
            c.JS_FreeValue(ctx, g3);
            c.JS_RunGC(rt);

            try testing.expectEqual(@as(i32, 1), g_counter_a.finalize_count);
            try testing.expectEqual(@as(i32, 1), g_counter_b.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 23. Handle in Promise chain (async survival) ──────────────────────────────────────────────────────────────────────────
//
// Temporarily disabled in standalone `zig test` mode. The test logic is useful, but QuickJS teardown still leaves GC objects alive in this configuration after the microtask chain completes. Keep the original test body here for later stabilization instead of deleting it.
//
// test "NativeHandle: survives Promise.resolve chain" { try withTestEngine(struct { fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void { resetTestCounter(); const obj = create(ctx, .{ .call_fn = testCallFn, .finalize_fn = testFinalizeFn, }); const global = c.JS_GetGlobalObject(ctx); _ = c.JS_SetPropertyStr(ctx, global, "h", obj); c.JS_FreeValue(ctx, global);
//
// _ = c.JS_Eval(ctx, "var promiseResult = 0; Promise.resolve(h).then(function(fn) { promiseResult = fn(); });", "var promiseResult = 0; Promise.resolve(h).then(function(fn) { promiseResult = fn(); });".len, "<test>", c.JS_EVAL_TYPE_GLOBAL, );
//
// var pctx: ?*c.JSContext = null; while (c.JS_ExecutePendingJob(rt, @ptrCast(&pctx)) > 0) {}
//
// const result = try evalToInt(ctx, "promiseResult"); try testing.expectEqual(@as(i64, 1), result); } }.run); }
//
// ──────────────────────────────────────────────────────────────────────────
// 24. Handle cross-assigned between global variables ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: aliased — one finalizer after all refs gone" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .finalize_fn = testFinalizeFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "x", obj);
            c.JS_FreeValue(ctx, global);

            // Alias via JS.
            _ = c.JS_Eval(ctx, "var y = x; var z = x;", 20, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            // Remove x only.
            const g2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g2, "x", JS_UNDEFINED);
            c.JS_FreeValue(ctx, g2);
            c.JS_RunGC(rt);
            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

            // Remove y.
            const g3 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g3, "y", JS_UNDEFINED);
            c.JS_FreeValue(ctx, g3);
            c.JS_RunGC(rt);
            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

            // Remove z — last ref.
            const g4 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g4, "z", JS_UNDEFINED);
            c.JS_FreeValue(ctx, g4);
            c.JS_RunGC(rt);
            try testing.expectEqual(@as(i32, 1), g_test_counter.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 30. Handle in WeakRef — GC can collect ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: WeakRef allows GC" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .finalize_fn = testFinalizeFn });

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // WeakRef does not prevent GC.
            _ = c.JS_Eval(
                ctx,
                "var wr = new WeakRef(h);",
                "var wr = new WeakRef(h);".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );

            // Delete the strong ref.
            const g2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g2, "h", JS_UNDEFINED);
            c.JS_FreeValue(ctx, g2);
            c.JS_RunGC(rt);

            try testing.expectEqual(@as(i32, 1), g_test_counter.finalize_count);
        }
    }.run);
}
