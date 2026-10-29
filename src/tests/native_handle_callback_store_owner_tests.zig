//! Tests CallbackStore ownership, large graphs, and circular references.
//!
//! Basic CallbackStore coverage lives in the corresponding NativeHandle test file.

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

// ──────────────────────────────────────────────────────────────────────────
// 42. CallbackStore: closure references large object graph — GC must not collect while stored, must collect after freeAll ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: large object graph kept alive then freed" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            // Build a linked list in a lexical scope captured by the closure.
            _ = c.JS_Eval(ctx,
                \\var listFn = (function() {
                \\  var head = null;
                \\  for (var i = 0; i < 500; i++) { head = { val: i, next: head }; }
                \\  return function() {
                \\    var n = head, sum = 0;
                \\    while (n) { sum += n.val; n = n.next; }
                \\    return sum;
                \\  };
                \\})();
            , (
                \\var listFn = (function() {
                \\  var head = null;
                \\  for (var i = 0; i < 500; i++) { head = { val: i, next: head }; }
                \\  return function() {
                \\    var n = head, sum = 0;
                \\    while (n) { sum += n.val; n = n.next; }
                \\    return sum;
                \\  };
                \\})();
            ).len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            const fn_val = c.JS_Eval(ctx, "listFn", 6, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);
            _ = store.set(ctx, "sum", fn_val);

            // Delete globals.
            _ = c.JS_Eval(ctx, "listFn=undefined;", "listFn=undefined;".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            // Multiple GC cycles.
            for (0..5) |_| c.JS_RunGC(rt);

            // sum(0..499) = 124750
            const result = store.fire(ctx, "sum", 0, null);
            defer c.JS_FreeValue(ctx, result);
            var val: i64 = 0;
            _ = c.JS_ToInt64(ctx, &val, result);
            try testing.expectEqual(@as(i64, 124750), val);

            // freeAll releases the closure → next GC can collect the 500 nodes.
            store.freeAll(ctx);
            c.JS_RunGC(rt);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 43. CallbackStore: callback mutates global, fire again sees mutation ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: callback mutates and reads global state" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            _ = c.JS_Eval(ctx, "var g = []", "var g = []".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            const push_fn = c.JS_Eval(ctx, "(function(v) { g.push(v); return g.length; })", "(function(v) { g.push(v); return g.length; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, push_fn);
            _ = store.set(ctx, "push", push_fn);

            // Fire 100 times.
            for (0..100) |i| {
                var arg = [1]c.JSValue{c.JS_NewInt32(ctx, @intCast(i))};
                const r = store.fire(ctx, "push", 1, &arg);
                c.JS_FreeValue(ctx, r);
                c.JS_FreeValue(ctx, arg[0]);
            }

            c.JS_RunGC(rt);

            // Verify array length.
            const len = c.JS_Eval(ctx, "g.length", "g.length".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, len);
            var len_val: i64 = 0;
            _ = c.JS_ToInt64(ctx, &len_val, len);
            try testing.expectEqual(@as(i64, 100), len_val);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 44. CallbackStore: double freeAll is safe (idempotent) ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: double freeAll is safe" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const fn_val = c.JS_Eval(ctx, "(function(){})", "(function(){})".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "a", fn_val);
            _ = store.set(ctx, "b", fn_val);

            store.freeAll(ctx);
            store.freeAll(ctx); // must not double-free or crash
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 45. CallbackStore: `this` in callback points to owner (NativeHandle) ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: this is owner object in normal function" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            // Create a NativeHandle with a string prop so we can verify identity.
            const obj = create(ctx, .{});
            setStringProp(ctx, obj, "kind", "audio");

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "host", c.JS_DupValue(ctx, obj));
            c.JS_FreeValue(ctx, global);

            // Set owner so fire() uses it as `this`.
            store.setOwner(ctx, obj);

            // Register a normal function (not arrow) that reads `this.kind`.
            const fn_val = c.JS_Eval(ctx, "(function() { return this.kind; })", "(function() { return this.kind; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "check", fn_val);

            const result = store.fire(ctx, "check", 0, null);
            defer c.JS_FreeValue(ctx, result);

            var len: usize = 0;
            const ptr = c.JS_ToCStringLen(ctx, &len, result);
            try testing.expect(@intFromPtr(ptr) != 0);
            defer c.JS_FreeCString(ctx, ptr);
            try testing.expectEqualStrings("audio", ptr[0..len]);

            store.freeAll(ctx);
            c.JS_FreeValue(ctx, obj);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 47. CallbackStore: without setOwner, this falls back to globalThis ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: no owner falls back to globalThis" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            var store = CallbackStore{}; // no setOwner

            // Set a global property to verify this === globalThis.
            _ = c.JS_Eval(ctx, "var __marker__ = 'global_ok'", "var __marker__ = 'global_ok'".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);

            const fn_val = c.JS_Eval(ctx, "(function() { return this.__marker__; })", "(function() { return this.__marker__; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "check", fn_val);

            const result = store.fire(ctx, "check", 0, null);
            defer c.JS_FreeValue(ctx, result);

            var len: usize = 0;
            const ptr = c.JS_ToCStringLen(ctx, &len, result);
            try testing.expect(@intFromPtr(ptr) != 0);
            defer c.JS_FreeCString(ctx, ptr);
            try testing.expectEqualStrings("global_ok", ptr[0..len]);

            store.freeAll(ctx);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 48. CallbackStore: owner keeps handle alive through GC ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: owner ref keeps handle alive through GC" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            resetTestCounter();
            const obj = create(ctx, .{
                .finalize_fn = testFinalizeFn,
            });
            setStringProp(ctx, obj, "tag", "alive");

            // Assign to global then delete — only store.owner keeps it alive.
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "host", c.JS_DupValue(ctx, obj));
            c.JS_FreeValue(ctx, global);

            store.setOwner(ctx, obj);

            // Delete global ref.
            const g2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g2, "host", helpers.JS_UNDEFINED);
            c.JS_FreeValue(ctx, g2);
            c.JS_FreeValue(ctx, obj);
            c.JS_RunGC(rt);

            // Handle must NOT be finalized — store.owner holds a DupValue ref.
            try testing.expectEqual(@as(i32, 0), g_test_counter.finalize_count);

            // Can still fire callback that reads this.tag.
            const fn_val = c.JS_Eval(ctx, "(function() { return this.tag; })", "(function() { return this.tag; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);
            _ = store.set(ctx, "check", fn_val);

            const result = store.fire(ctx, "check", 0, null);
            defer c.JS_FreeValue(ctx, result);
            var len: usize = 0;
            const ptr = c.JS_ToCStringLen(ctx, &len, result);
            try testing.expect(@intFromPtr(ptr) != 0);
            defer c.JS_FreeCString(ctx, ptr);
            try testing.expectEqualStrings("alive", ptr[0..len]);

            // freeAll releases owner → GC can now collect.
            store.freeAll(ctx);
            c.JS_RunGC(rt);
            try testing.expectEqual(@as(i32, 1), g_test_counter.finalize_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 49. CallbackStore: circular ref — callback captures owner handle ──────────────────────────────────────────────────────────────────────────

test "CallbackStore: circular ref callback captures owner" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, rt: ?*c.JSRuntime) !void {
            var store = CallbackStore{};

            const obj = create(ctx, .{});
            setStringProp(ctx, obj, "name", "player");

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "host", c.JS_DupValue(ctx, obj));
            c.JS_FreeValue(ctx, global);

            store.setOwner(ctx, obj);

            // Callback captures `host` (the handle itself) — circular reference.
            const fn_val = c.JS_Eval(ctx, "(function() { return host.name + '_from_cb'; })", "(function() { return host.name + '_from_cb'; })".len, "<test>", c.JS_EVAL_TYPE_GLOBAL);
            defer c.JS_FreeValue(ctx, fn_val);

            _ = store.set(ctx, "info", fn_val);

            c.JS_RunGC(rt);

            const result = store.fire(ctx, "info", 0, null);
            defer c.JS_FreeValue(ctx, result);
            var len: usize = 0;
            const ptr = c.JS_ToCStringLen(ctx, &len, result);
            try testing.expect(@intFromPtr(ptr) != 0);
            defer c.JS_FreeCString(ctx, ptr);
            try testing.expectEqualStrings("player_from_cb", ptr[0..len]);

            const g2 = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, g2, "host", helpers.JS_UNDEFINED);
            c.JS_FreeValue(ctx, g2);
            store.freeAll(ctx);
            c.JS_FreeValue(ctx, obj);
            c.JS_RunGC(rt);
        }
    }.run);
}
