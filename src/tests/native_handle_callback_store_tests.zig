//! Tests for the CallbackStore registry.
//!
//! Basic API and lifecycle coverage live in their corresponding NativeHandle test files.

const std = @import("std");
const helpers = @import("native_handle_test_helpers.zig");
const handle = @import("../value/native_handle/handle.zig");
const callback_store_mod = @import("../value/native_handle/callback_store.zig");

const c = helpers.c;
const testing = helpers.testing;

const withTestEngine = helpers.withTestEngine;
const resetTestCounter = helpers.resetTestCounter;
const g_test_counter = &helpers.g_test_counter;
const testFinalizeFn = helpers.testFinalizeFn;

const create = handle.create;
const setStringProp = handle.setStringProp;

const CallbackStore = callback_store_mod.CallbackStore;
const MAX_CALLBACKS = callback_store_mod.MAX_CALLBACKS;

// ──────────────────────────────────────────────────────────────────────────
// 31. CallbackStore: set and fire a JS callback ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: set and fire callback" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            // Create a JS function and register it.
            const fn_val = c.JS_Eval(
                ctx,
                "(function() { return 42; })",
                "(function() { return 42; })".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            defer c.JS_FreeValue(ctx, fn_val);
            try testing.expect(!helpers.c_api.jsIsException(fn_val));

            try testing.expect(store.set(ctx, "play", fn_val));
            try testing.expect(store.has("play"));
            try testing.expect(!store.has("stop"));

            // Fire it.
            const result = store.fire(ctx, "play", 0, null);
            defer c.JS_FreeValue(ctx, result);

            var int_val: i64 = 0;
            try testing.expect(c.JS_ToInt64(ctx, &int_val, result) >= 0);
            try testing.expectEqual(@as(i64, 42), int_val);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 32. CallbackStore: replace existing callback ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: replace callback" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn1 = c.JS_Eval(
                ctx,
                "(function() { return 1; })",
                "(function() { return 1; })".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            defer c.JS_FreeValue(ctx, fn1);

            const fn2 = c.JS_Eval(
                ctx,
                "(function() { return 2; })",
                "(function() { return 2; })".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            defer c.JS_FreeValue(ctx, fn2);

            try testing.expect(store.set(ctx, "play", fn1));
            try testing.expect(store.set(ctx, "play", fn2)); // replace

            const result = store.fire(ctx, "play", 0, null);
            defer c.JS_FreeValue(ctx, result);

            var int_val: i64 = 0;
            _ = c.JS_ToInt64(ctx, &int_val, result);
            try testing.expectEqual(@as(i64, 2), int_val);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 33. CallbackStore: remove callback ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: remove callback" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn_val = c.JS_Eval(
                ctx,
                "(function() { return 99; })",
                "(function() { return 99; })".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "play", fn_val);
            try testing.expect(store.has("play"));

            store.remove(ctx, "play");
            try testing.expect(!store.has("play"));

            // Fire returns undefined for removed callback.
            const result = store.fire(ctx, "play", 0, null);
            try testing.expect(result.tag == c.JS_TAG_UNDEFINED);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 34. CallbackStore: callback with closure captures state ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: callback closure captures state" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            // Create a closure that captures a variable.
            const fn_val = c.JS_Eval(
                ctx,
                "(function() { var x = 10; return function() { x += 1; return x; }; })()",
                "(function() { var x = 10; return function() { x += 1; return x; }; })()".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "inc", fn_val);

            // GC — closure must survive because store holds a DupValue'd ref.
            c.JS_RunGC(rt);

            const r1 = store.fire(ctx, "inc", 0, null);
            defer c.JS_FreeValue(ctx, r1);
            var v1: i64 = 0;
            _ = c.JS_ToInt64(ctx, &v1, r1);
            try testing.expectEqual(@as(i64, 11), v1);

            const r2 = store.fire(ctx, "inc", 0, null);
            defer c.JS_FreeValue(ctx, r2);
            var v2: i64 = 0;
            _ = c.JS_ToInt64(ctx, &v2, r2);
            try testing.expectEqual(@as(i64, 12), v2);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 35. CallbackStore: fire with arguments ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: fire with arguments" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn_val = c.JS_Eval(
                ctx,
                "(function(a, b) { return a + b; })",
                "(function(a, b) { return a + b; })".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "add", fn_val);

            var args = [2]c.JSValue{
                c.JS_NewInt32(ctx, 3),
                c.JS_NewInt32(ctx, 7),
            };
            defer c.JS_FreeValue(ctx, args[0]);
            defer c.JS_FreeValue(ctx, args[1]);

            const result = store.fire(ctx, "add", 2, &args);
            defer c.JS_FreeValue(ctx, result);

            var int_val: i64 = 0;
            _ = c.JS_ToInt64(ctx, &int_val, result);
            try testing.expectEqual(@as(i64, 10), int_val);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 36. CallbackStore: closure captures external object, object deleted, GC ────────────────────────────────────────────────────────────────────────── The closure holds a reference to an object created in outer scope. After the outer var is deleted and GC runs, the closure must still see the object because DupValue keeps the function (and its closure chain) alive.

test "CallbackStore: closure survives external object deletion + GC" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            // Capture the object in a local lexical scope, not via a mutable global binding.
            _ = c.JS_Eval(ctx,
                \\var captureFn = (function() {
                \\  var bigObj = { data: new Array(1000).fill("x"), count: 0 };
                \\  return function() { bigObj.count++; return bigObj.count; };
                \\})();
            , (
                \\var captureFn = (function() {
                \\  var bigObj = { data: new Array(1000).fill("x"), count: 0 };
                \\  return function() { bigObj.count++; return bigObj.count; };
                \\})();
            ).len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            // Get the closure and store it.
            const fn_val = c.JS_Eval(ctx, "captureFn", 9, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            try testing.expect(!helpers.c_api.jsIsException(fn_val));
            defer c.JS_FreeValue(ctx, fn_val);
            _ = store.set(ctx, "tick", fn_val);

            // Delete both globals — only the store's DupValue keeps the closure alive.
            _ = c.JS_Eval(ctx,
                \\captureFn = undefined;
            , (
                \\captureFn = undefined;
            ).len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            // Heavy GC pressure.
            c.JS_RunGC(rt);
            c.JS_RunGC(rt);
            c.JS_RunGC(rt);

            // Closure must still work — bigObj lives through the closure's scope chain.
            const r1 = store.fire(ctx, "tick", 0, null);
            defer c.JS_FreeValue(ctx, r1);
            var v1: i64 = 0;
            _ = c.JS_ToInt64(ctx, &v1, r1);
            try testing.expectEqual(@as(i64, 1), v1);

            const r2 = store.fire(ctx, "tick", 0, null);
            defer c.JS_FreeValue(ctx, r2);
            var v2: i64 = 0;
            _ = c.JS_ToInt64(ctx, &v2, r2);
            try testing.expectEqual(@as(i64, 2), v2);

            store.freeAll(ctx);

            // After freeAll, GC should collect the object.
            c.JS_RunGC(rt);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 37. CallbackStore: callback captures another callback's state (cross-ref) ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: cross-referencing closures" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            // Two closures sharing state via a captured lexical object.
            _ = c.JS_Eval(ctx,
                \\var pair = (function() {
                \\  var shared = { val: 0 };
                \\  return {
                \\    writer: function(x) { shared.val = x; return shared.val; },
                \\    reader: function()  { return shared.val; }
                \\  };
                \\})();
            , (
                \\var pair = (function() {
                \\  var shared = { val: 0 };
                \\  return {
                \\    writer: function(x) { shared.val = x; return shared.val; },
                \\    reader: function()  { return shared.val; }
                \\  };
                \\})();
            ).len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            const w = c.JS_Eval(ctx, "pair.writer", "pair.writer".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, w);
            const r = c.JS_Eval(ctx, "pair.reader", "pair.reader".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, r);

            _ = store.set(ctx, "write", w);
            _ = store.set(ctx, "read", r);

            // Delete globals.
            _ = c.JS_Eval(ctx, "pair=undefined;", "pair=undefined;".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            c.JS_RunGC(rt);

            // Write then read through the stored callbacks.
            var write_arg = [1]c.JSValue{c.JS_NewInt32(ctx, 42)};
            defer c.JS_FreeValue(ctx, write_arg[0]);
            const wr = store.fire(ctx, "write", 1, &write_arg);
            c.JS_FreeValue(ctx, wr);

            const rr = store.fire(ctx, "read", 0, null);
            defer c.JS_FreeValue(ctx, rr);
            var val: i64 = 0;
            _ = c.JS_ToInt64(ctx, &val, rr);
            try testing.expectEqual(@as(i64, 42), val);

            store.freeAll(ctx);
            c.JS_RunGC(rt);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 38. CallbackStore: capacity limit — 17th set fails gracefully ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: capacity overflow returns false" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn_val = c.JS_Eval(ctx, "(function(){})", "(function(){})".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            // Fill all 16 slots.
            var names: [MAX_CALLBACKS][8]u8 = undefined;
            for (0..MAX_CALLBACKS) |i| {
                const name = std.fmt.bufPrint(&names[i], "cb{d}", .{i}) catch unreachable;
                try testing.expect(store.set(ctx, name, fn_val));
            }

            // 17th should fail.
            try testing.expect(!store.set(ctx, "overflow", fn_val));

            // Remove one, then it should succeed.
            store.remove(ctx, std.fmt.bufPrint(&names[0], "cb{d}", .{0}) catch unreachable);
            try testing.expect(store.set(ctx, "overflow", fn_val));

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 39. CallbackStore: callback that throws — no leak, no crash ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: throwing callback does not leak" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn_val = c.JS_Eval(ctx, "(function() { throw new Error('boom'); })", "(function() { throw new Error('boom'); })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "explode", fn_val);

            // Fire — should return undefined, not crash.
            const r1 = store.fire(ctx, "explode", 0, null);
            try testing.expect(r1.tag == c.JS_TAG_UNDEFINED);

            // Callback is still registered — can fire again.
            const r2 = store.fire(ctx, "explode", 0, null);
            try testing.expect(r2.tag == c.JS_TAG_UNDEFINED);

            // Non-throwing callback still works.
            const ok_fn = c.JS_Eval(ctx, "(function() { return 1; })", "(function() { return 1; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, ok_fn);
            _ = store.set(ctx, "ok", ok_fn);

            const r3 = store.fire(ctx, "ok", 0, null);
            defer c.JS_FreeValue(ctx, r3);
            var v: i64 = 0;
            _ = c.JS_ToInt64(ctx, &v, r3);
            try testing.expectEqual(@as(i64, 1), v);

            store.freeAll(ctx);
            c.JS_RunGC(rt);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 40. CallbackStore: freeAll then fire returns undefined safely ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: fire after freeAll is safe" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn_val = c.JS_Eval(ctx, "(function() { return 99; })", "(function() { return 99; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "x", fn_val);
            store.freeAll(ctx);

            // Should return undefined, not crash or use-after-free.
            const result = store.fire(ctx, "x", 0, null);
            try testing.expect(result.tag == c.JS_TAG_UNDEFINED);
            try testing.expect(!store.has("x"));
        }
    }.run);
}
