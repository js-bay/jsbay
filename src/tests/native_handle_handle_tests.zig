//! Tests covering the basic NativeHandle API.
//!
//! Lifecycle and CallbackStore coverage live in their corresponding NativeHandle test files.

const helpers = @import("native_handle_test_helpers.zig");
const handle = @import("../value/native_handle/handle.zig");
const method = @import("../value/native_handle/method.zig");
const types = @import("../value/native_handle/types.zig");

const c = helpers.c;
const testing = helpers.testing;

const JS_UNDEFINED = helpers.JS_UNDEFINED;
const withTestEngine = helpers.withTestEngine;
const evalToInt = helpers.evalToInt;
const evalToString = helpers.evalToString;
const evalIsException = helpers.evalIsException;
const resetTestCounter = helpers.resetTestCounter;
const g_test_counter = &helpers.g_test_counter;
const testCallFn = helpers.testCallFn;
const testFinalizeFn = helpers.testFinalizeFn;
const testMethodGetValue = helpers.testMethodGetValue;
const testMethodIncrement = helpers.testMethodIncrement;
const testMethodEcho = helpers.testMethodEcho;

const create = handle.create;
const createWithMethods = handle.createWithMethods;
const setStringProp = handle.setStringProp;
const setIntProp = handle.setIntProp;
const getOpaque = handle.getOpaque;
const setMethod = method.setMethod;
const MethodFn = types.MethodFn;

// ──────────────────────────────────────────────────────────────────────────
// 1. Basic callable: create → call from JS → verify side effect ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: direct call dispatches to call_fn" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", c.JS_DupValue(ctx, obj));
            c.JS_FreeValue(ctx, global);
            c.JS_FreeValue(ctx, obj);

            const result = try evalToInt(ctx, "h()");
            try testing.expectEqual(@as(i64, 1), result);
            try testing.expectEqual(@as(i32, 1), g_test_counter.call_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 2. Multiple calls accumulate state ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: multiple calls accumulate" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            _ = try evalToInt(ctx, "h()");
            _ = try evalToInt(ctx, "h()");
            const result = try evalToInt(ctx, "h()");
            try testing.expectEqual(@as(i64, 3), result);
            try testing.expectEqual(@as(i32, 3), g_test_counter.call_count);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 3. Arguments pass through correctly ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: call arguments forwarded" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            _ = try evalToInt(ctx, "h('a', 'b', 'c', 'd', 'e')");
            try testing.expectEqual(@as(c_int, 5), g_test_counter.last_argc);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 4. Calling a handle without call_fn throws TypeError ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: call without call_fn throws" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{}); // no call_fn
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            try testing.expect(evalIsException(ctx, "h()"));
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 7. Method call with opaque state ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: method reads opaque state" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            g_test_counter.call_count = 42;

            const obj = create(ctx, .{ .ptr = @ptrCast(g_test_counter) });
            setMethod(ctx, obj, "getValue", testMethodGetValue, 0);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            const result = try evalToInt(ctx, "h.getValue()");
            try testing.expectEqual(@as(i64, 42), result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 8. Method mutates opaque state ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: method mutates opaque state" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            g_test_counter.call_count = 0;

            const obj = create(ctx, .{ .ptr = @ptrCast(g_test_counter) });
            setMethod(ctx, obj, "inc", testMethodIncrement, 0);
            setMethod(ctx, obj, "get", testMethodGetValue, 0);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            _ = try evalToInt(ctx, "h.inc()");
            _ = try evalToInt(ctx, "h.inc()");
            _ = try evalToInt(ctx, "h.inc()");
            const result = try evalToInt(ctx, "h.get()");
            try testing.expectEqual(@as(i64, 3), result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 9. Detached method — `const fn = h.method; fn()` still works ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: detached method retains correct this" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            g_test_counter.call_count = 99;

            const obj = create(ctx, .{ .ptr = @ptrCast(g_test_counter) });
            setMethod(ctx, obj, "get", testMethodGetValue, 0);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // Detach the method and call it standalone.
            const result = try evalToInt(ctx, "var fn = h.get; fn()");
            try testing.expectEqual(@as(i64, 99), result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 11. Method argument passthrough ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: method arguments pass through" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{});
            setMethod(ctx, obj, "echo", testMethodEcho, 1);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            const result = try evalToString(ctx, "h.echo('hello world')");
            defer c.JS_FreeCString(ctx, result.ptr);
            try testing.expectEqualStrings("hello world", result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 12. String and int properties ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: string and int properties" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{});
            setStringProp(ctx, obj, "type", "webview");
            setIntProp(ctx, obj, "id", 42);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            const t = try evalToString(ctx, "h.type");
            defer c.JS_FreeCString(ctx, t.ptr);
            try testing.expectEqualStrings("webview", t);

            const id = try evalToInt(ctx, "h.id");
            try testing.expectEqual(@as(i64, 42), id);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 13. createWithMethods convenience ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: createWithMethods" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            g_test_counter.call_count = 10;

            const methods = [_]struct {
                name: [*:0]const u8,
                func: MethodFn,
                argc: c_int,
            }{
                .{ .name = "get", .func = testMethodGetValue, .argc = 0 },
                .{ .name = "inc", .func = testMethodIncrement, .argc = 0 },
                .{ .name = "echo", .func = testMethodEcho, .argc = 1 },
            };
            const obj = createWithMethods(ctx, .{
                .ptr = @ptrCast(g_test_counter),
                .call_fn = testCallFn,
            }, &methods);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // call_fn works
            _ = try evalToInt(ctx, "h()");
            // methods work
            const v = try evalToInt(ctx, "h.get()");
            // call_fn incremented g_test_counter.call_count from 10→11
            try testing.expectEqual(@as(i64, 11), v);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 14. Callable + methods on same object (hybrid) ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: callable with methods on same object" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            setMethod(ctx, obj, "echo", testMethodEcho, 1);
            setStringProp(ctx, obj, "name", "test");

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // Direct call
            const call_result = try evalToInt(ctx, "h()");
            try testing.expectEqual(@as(i64, 1), call_result);

            // Method
            const echo_result = try evalToString(ctx, "h.echo('ping')");
            defer c.JS_FreeCString(ctx, echo_result.ptr);
            try testing.expectEqualStrings("ping", echo_result);

            // Property
            const name = try evalToString(ctx, "h.name");
            defer c.JS_FreeCString(ctx, name.ptr);
            try testing.expectEqualStrings("test", name);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 15. typeof reports "function" for callable handle ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: typeof is function when callable" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            const t = try evalToString(ctx, "typeof h");
            defer c.JS_FreeCString(ctx, t.ptr);
            try testing.expectEqualStrings("function", t);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 19. Handle passed as argument to another JS function ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: passed as JS function argument" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // Pass handle to a JS function that calls it.
            const result = try evalToInt(ctx, "(function(fn) { return fn() + fn() + fn(); })(h)");
            try testing.expectEqual(@as(i64, 6), result); // 1+2+3
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 20. Handle stored in JS Map and retrieved ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: stored in Map and retrieved" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            const result = try evalToInt(ctx, "var m = new Map(); m.set('key', h); m.get('key')()");
            try testing.expectEqual(@as(i64, 1), result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 25. getOpaque returns null on non-NativeHandle value ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: getOpaque on plain object returns null" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const plain = c.JS_NewObject(ctx);
            defer c.JS_FreeValue(ctx, plain);
            try testing.expect(getOpaque(ctx, plain) == null);

            // Also test on primitives.
            const num = c.JS_NewInt32(ctx, 123);
            defer c.JS_FreeValue(ctx, num);
            try testing.expect(getOpaque(ctx, num) == null);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 26. Zero-argument direct call ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: zero-argument call" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            resetTestCounter();
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            _ = try evalToInt(ctx, "h()");
            try testing.expectEqual(@as(c_int, 0), g_test_counter.last_argc);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 27. Handle used as constructor (new handle()) — should throw ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: new handle() throws" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{ .call_fn = testCallFn });
            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // `new` on a NativeHandle should throw (no constructor bit set).
            try testing.expect(evalIsException(ctx, "new h()"));
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 28. Overwrite method on the fly ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: JS can overwrite methods" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{});
            setMethod(ctx, obj, "echo", testMethodEcho, 1);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", obj);
            c.JS_FreeValue(ctx, global);

            // Overwrite with a JS function.
            const overwrite_result = c.JS_Eval(
                ctx,
                "h.echo = function() { return 'overridden'; };",
                "h.echo = function() { return 'overridden'; };".len,
                "<test>",
                c.JS_EVAL_TYPE_GLOBAL,
            );
            c.JS_FreeValue(ctx, overwrite_result);

            const result = try evalToString(ctx, "h.echo()");
            defer c.JS_FreeCString(ctx, result.ptr);
            try testing.expectEqualStrings("overridden", result);
        }
    }.run);
}

// ──────────────────────────────────────────────────────────────────────────
// 29. Handle JSON.stringify — should not crash, returns something ──────────────────────────────────────────────────────────────────────────

test "NativeHandle: JSON.stringify does not crash" {
    try withTestEngine(struct {
        fn run(ctx: ?*c.JSContext, _: ?*c.JSRuntime) !void {
            const obj = create(ctx, .{});
            setStringProp(ctx, obj, "type", "webview");
            setIntProp(ctx, obj, "id", 7);

            const global = c.JS_GetGlobalObject(ctx);
            _ = c.JS_SetPropertyStr(ctx, global, "h", c.JS_DupValue(ctx, obj));
            c.JS_FreeValue(ctx, global);
            c.JS_FreeValue(ctx, obj);

            // Functions serialize as undefined, but properties should appear.
            const result = try evalToString(ctx, "h.toJSON = function() { return { type: this.type, id: this.id }; }; JSON.stringify(h)");
            defer c.JS_FreeCString(ctx, result.ptr);
            const std = @import("std");
            try testing.expect(std.mem.indexOf(u8, result, "webview") != null);
        }
    }.run);
}
