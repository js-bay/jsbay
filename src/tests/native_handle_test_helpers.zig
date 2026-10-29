//! Shared test scaffolding for the NativeHandle test suites.

const std = @import("std");
const types = @import("../value/native_handle/types.zig");
pub const c_api = @import("../backend.zig").ActiveEngineModule.c_api;
const class = @import("../value/native_handle/class.zig");

pub const c = types.c;
pub const testing = std.testing;

pub const JS_UNDEFINED = types.JS_UNDEFINED;

pub fn zLen(code: [*:0]const u8) usize {
    return types.zLen(code);
}

/// Shared test helper: spin up a fresh QuickJS runtime + context with NativeHandle registered, run the test body, tear down.
pub fn withTestEngine(comptime testFn: fn (?*c.JSContext, ?*c.JSRuntime) anyerror!void) !void {
    const rt = c.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    errdefer c.JS_FreeRuntime(rt);
    class.init(rt);
    const ctx = c.JS_NewContext(rt) orelse return error.ContextCreationFailed;
    try testFn(ctx, rt);
    const teardown_result = c.JS_Eval(
        ctx,
        \\globalThis.h = undefined;
        \\delete globalThis.h;
        \\globalThis.saved = undefined;
        \\globalThis.tmp = undefined;
        \\globalThis.arr = undefined;
        \\globalThis.closure = undefined;
        \\globalThis.a = undefined;
        \\globalThis.b = undefined;
        \\globalThis.x = undefined;
        \\globalThis.y = undefined;
        \\globalThis.z = undefined;
        \\globalThis.host = undefined;
        \\globalThis.pair = undefined;
        \\globalThis.captureFn = undefined;
        \\globalThis.listFn = undefined;
        \\globalThis.__marker__ = undefined;
        \\globalThis.promiseResult = undefined;
        \\globalThis.wr = undefined;
        \\globalThis.s = undefined;
    ,
        (
            \\globalThis.h = undefined;
            \\delete globalThis.h;
            \\globalThis.saved = undefined;
            \\globalThis.tmp = undefined;
            \\globalThis.arr = undefined;
            \\globalThis.closure = undefined;
            \\globalThis.a = undefined;
            \\globalThis.b = undefined;
            \\globalThis.x = undefined;
            \\globalThis.y = undefined;
            \\globalThis.z = undefined;
            \\globalThis.host = undefined;
            \\globalThis.pair = undefined;
            \\globalThis.captureFn = undefined;
            \\globalThis.listFn = undefined;
            \\globalThis.__marker__ = undefined;
            \\globalThis.promiseResult = undefined;
            \\globalThis.wr = undefined;
            \\globalThis.s = undefined;
        ).len,
        "<teardown>",
        c.JS_EVAL_TYPE_GLOBAL,
    );
    c.JS_FreeValue(ctx, teardown_result);
    const pending_exception = c.JS_GetException(ctx);
    c.JS_FreeValue(ctx, pending_exception);
    c.JS_RunGC(rt);
    c.JS_FreeContext(ctx);
    c.JS_RunGC(rt);
    c.JS_FreeRuntime(rt);
}

/// Evaluate a JS snippet and return the CString result (caller must free).
pub fn evalToString(ctx: ?*c.JSContext, code: [*:0]const u8) ![]const u8 {
    const val = c.JS_Eval(ctx, code, zLen(code), "<test>", c.JS_EVAL_TYPE_GLOBAL);
    if (c_api.jsIsException(val)) {
        // Drain exception so it doesn't poison later evals.
        const exc = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, exc);
        return error.JSException;
    }
    defer c.JS_FreeValue(ctx, val);
    var len: usize = 0;
    const ptr = c.JS_ToCStringLen(ctx, &len, val);
    if (ptr == null) return error.NotAString;
    return ptr[0..len];
}

pub fn evalToBool(ctx: ?*c.JSContext, code: [*:0]const u8) !bool {
    const val = c.JS_Eval(ctx, code, zLen(code), "<test>", c.JS_EVAL_TYPE_GLOBAL);
    if (c_api.jsIsException(val)) {
        const exc = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, exc);
        return error.JSException;
    }
    defer c.JS_FreeValue(ctx, val);
    return c.JS_ToBool(ctx, val) != 0;
}

pub fn evalToInt(ctx: ?*c.JSContext, code: [*:0]const u8) !i64 {
    const val = c.JS_Eval(ctx, code, zLen(code), "<test>", c.JS_EVAL_TYPE_GLOBAL);
    if (c_api.jsIsException(val)) {
        const exc = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, exc);
        return error.JSException;
    }
    defer c.JS_FreeValue(ctx, val);
    var result: i64 = 0;
    if (c.JS_ToInt64(ctx, &result, val) < 0) return error.NotANumber;
    return result;
}

pub fn evalIsException(ctx: ?*c.JSContext, code: [*:0]const u8) bool {
    const val = c.JS_Eval(ctx, code, zLen(code), "<test>", c.JS_EVAL_TYPE_GLOBAL);
    if (c_api.jsIsException(val)) {
        const exc = c.JS_GetException(ctx);
        c.JS_FreeValue(ctx, exc);
        return true;
    }
    c.JS_FreeValue(ctx, val);
    return false;
}

// ── Shared test fixture state ────────────────────────────────────────────

/// Mutable counter accessible from native callbacks.
pub const TestCounter = struct {
    call_count: i32 = 0,
    finalize_count: i32 = 0,
    last_argc: c_int = 0,
};

pub var g_test_counter: TestCounter = .{};

pub fn resetTestCounter() void {
    g_test_counter = .{};
}

pub fn testCallFn(
    ctx: ?*c.JSContext,
    ptr: ?*anyopaque,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    _ = argv;
    _ = ptr;
    g_test_counter.call_count += 1;
    g_test_counter.last_argc = argc;
    return c.JS_NewInt32(ctx, g_test_counter.call_count);
}

pub fn testFinalizeFn(ptr: ?*anyopaque) void {
    _ = ptr;
    g_test_counter.finalize_count += 1;
}

// ── Method bodies that read/write the shared counter via getOpaque ───────

const handle = @import("../value/native_handle/handle.zig");

pub fn testMethodGetValue(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const data = handle.getOpaque(ctx, this) orelse
        return c.JS_ThrowTypeError(ctx, "no opaque");
    const counter: *TestCounter = @ptrCast(@alignCast(data.ptr.?));
    return c.JS_NewInt32(ctx, counter.call_count);
}

pub fn testMethodIncrement(
    ctx: ?*c.JSContext,
    this: c.JSValue,
    _: c_int,
    _: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    const data = handle.getOpaque(ctx, this) orelse
        return c.JS_ThrowTypeError(ctx, "no opaque");
    const counter: *TestCounter = @ptrCast(@alignCast(data.ptr.?));
    counter.call_count += 1;
    return c.JS_NewInt32(ctx, counter.call_count);
}

// Returns the first string argument echoed back, proving argv passthrough.
pub fn testMethodEcho(
    ctx: ?*c.JSContext,
    _: c.JSValue,
    argc: c_int,
    argv: [*c]c.JSValue,
) callconv(.c) c.JSValue {
    if (argc < 1) return c.JS_NewString(ctx, "");
    return c.JS_DupValue(ctx, argv[0]);
}
