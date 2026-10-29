//! QuickJS-specific host-side installation helpers.
//!
//! Scope:
//! - global/object installation
//! - primitive value conversion
//! - eval / exception formatting helpers
//! - borrowed string handling
//!
//! Non-scope:
//! - app-specific bridge contracts such as `invoke(...)`
//! - product-specific host namespaces

const std = @import("std");
const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
const c = @import("../../backend.zig").ActiveEngineModule.c_api;
const qjs = qjs_mod.qjs;

pub const CFunction = *const fn (
    ctx: ?*qjs.JSContext,
    this_val: qjs.JSValue,
    argc: c_int,
    argv: [*c]qjs.JSValue,
) callconv(.c) qjs.JSValue;

pub const FunctionDef = struct {
    name: [*:0]const u8,
    func: CFunction,
    argc: c_int,
};

pub fn installGlobalFunctions(ctx: ?*qjs.JSContext, defs: []const FunctionDef) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);

    for (defs) |def| {
        const js_fn = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, def.func, def.name, def.argc);
        _ = qjs.JS_SetPropertyStr(ctx, global, def.name, js_fn);
    }
}

pub fn installObjectFunctions(
    ctx: ?*qjs.JSContext,
    obj_name: [*:0]const u8,
    defs: []const FunctionDef,
) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);

    const obj = qjs.JS_NewObject(ctx);
    for (defs) |def| {
        const js_fn = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, def.func, def.name, def.argc);
        _ = qjs.JS_SetPropertyStr(ctx, obj, def.name, js_fn);
    }
    _ = qjs.JS_SetPropertyStr(ctx, global, obj_name, obj);
}

pub fn setGlobalString(ctx: ?*qjs.JSContext, name: [*:0]const u8, value: []const u8) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);

    const js_str = qjs.JS_NewStringLen(ctx, value.ptr, value.len);
    _ = qjs.JS_SetPropertyStr(ctx, global, name, js_str);
}

pub fn setGlobalInt(ctx: ?*qjs.JSContext, name: [*:0]const u8, value: i64) void {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);

    const js_int = qjs.JS_NewInt64(ctx, value);
    _ = qjs.JS_SetPropertyStr(ctx, global, name, js_int);
}

pub fn valueToBorrowedString(ctx: ?*qjs.JSContext, value: qjs.JSValue) ?[]const u8 {
    var len: usize = 0;
    const ptr = qjs.JS_ToCStringLen(ctx, &len, value);
    if (ptr == null) return null;
    return ptr[0..len];
}

pub fn freeBorrowedString(ctx: ?*qjs.JSContext, value: []const u8) void {
    qjs.JS_FreeCString(ctx, value.ptr);
}

pub fn undefinedValue() qjs.JSValue {
    return qjs_mod.JS_UNDEFINED;
}

pub fn boolValue(ctx: ?*qjs.JSContext, value: bool) qjs.JSValue {
    return qjs_mod.jsbay_qjs_JS_NewBool(ctx, if (value) 1 else 0);
}

pub fn stringValue(ctx: ?*qjs.JSContext, value: []const u8) qjs.JSValue {
    return qjs.JS_NewStringLen(ctx, value.ptr, value.len);
}

pub fn valueToInt64(ctx: ?*qjs.JSContext, value: qjs.JSValue) ?i64 {
    var out: i64 = 0;
    if (qjs.JS_ToInt64(ctx, &out, value) < 0) return null;
    return out;
}

pub fn valueToFloat64(ctx: ?*qjs.JSContext, value: qjs.JSValue) ?f64 {
    var out: f64 = 0;
    if (qjs.JS_ToFloat64(ctx, &out, value) < 0) return null;
    return out;
}

pub fn valueToBool(ctx: ?*qjs.JSContext, value: qjs.JSValue) bool {
    return qjs.JS_ToBool(ctx, value) != 0;
}

pub fn stringifyValue(ctx: ?*qjs.JSContext, value: qjs.JSValue) ?[]const u8 {
    return qjs_mod.Backend.jsonStringify(ctx, value);
}

pub fn formatPendingException(ctx: ?*qjs.JSContext) ?[]const u8 {
    return qjs_mod.Backend.getAndFormatException(ctx);
}

pub fn clearPendingException(ctx: ?*qjs.JSContext) void {
    const exc = qjs.JS_GetException(ctx);
    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, exc);
}

pub fn eval(ctx: ?*qjs.JSContext, script: []const u8, filename: [*:0]const u8) qjs.JSValue {
    return qjs.JS_Eval(ctx, script.ptr, script.len, filename, qjs.JS_EVAL_TYPE_GLOBAL);
}

pub fn evalNoResult(ctx: ?*qjs.JSContext, script: []const u8, filename: [*:0]const u8) !void {
    const result = eval(ctx, script, filename);
    if (c.jsIsException(result)) {
        return error.JSEvalFailed;
    }
    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, result);
}

pub fn evalComptimeNoResult(ctx: ?*qjs.JSContext, comptime script: []const u8, filename: [*:0]const u8) !void {
    const result = eval(ctx, script, filename);
    if (c.jsIsException(result)) {
        return error.JSEvalFailed;
    }
    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, result);
}

pub fn evalStringOwned(
    allocator: std.mem.Allocator,
    ctx: ?*qjs.JSContext,
    script: []const u8,
    filename: [*:0]const u8,
) ![]u8 {
    const result = eval(ctx, script, filename);
    if (c.jsIsException(result)) {
        return error.JSEvalFailed;
    }
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, result);

    const cstr = qjs.JS_ToCString(ctx, result) orelse return error.JSResultNotString;
    defer qjs.JS_FreeCString(ctx, cstr);
    return allocator.dupe(u8, std.mem.span(cstr));
}

pub fn evalInt32(ctx: ?*qjs.JSContext, script: []const u8, filename: [*:0]const u8) !i32 {
    const result = eval(ctx, script, filename);
    if (c.jsIsException(result)) {
        return error.JSEvalFailed;
    }
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, result);

    var out: i32 = 0;
    if (qjs.JS_ToInt32(ctx, &out, result) < 0) return error.JSResultNotInt;
    return out;
}

test "quickjs_host: install global functions" {
    const rt = qjs.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer qjs.JS_FreeRuntime(rt);
    const ctx = qjs.JS_NewContext(rt) orelse return error.ContextCreationFailed;
    defer qjs.JS_FreeContext(ctx);

    const Stub = struct {
        fn call(
            stub_ctx: ?*qjs.JSContext,
            _: qjs.JSValue,
            _: c_int,
            _: [*c]qjs.JSValue,
        ) callconv(.c) qjs.JSValue {
            return qjs_mod.jsbay_qjs_JS_NewInt32(stub_ctx, 42);
        }
    };

    installGlobalFunctions(ctx, &.{
        .{ .name = "__host_test__", .func = Stub.call, .argc = 0 },
    });

    const result = qjs.JS_Eval(ctx, "__host_test__()", "__host_test__()".len, "<host-test>", qjs.JS_EVAL_TYPE_GLOBAL);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, result);

    var out: i32 = 0;
    try std.testing.expect(qjs.JS_ToInt32(ctx, &out, result) == 0);
    try std.testing.expectEqual(@as(i32, 42), out);
}

test "quickjs_host: stringify value" {
    const rt = qjs.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer qjs.JS_FreeRuntime(rt);
    const ctx = qjs.JS_NewContext(rt) orelse return error.ContextCreationFailed;
    defer qjs.JS_FreeContext(ctx);

    const value = qjs.JS_Eval(ctx, "({ ok: true, count: 2 })", "({ ok: true, count: 2 })".len, "<host-json>", qjs.JS_EVAL_TYPE_GLOBAL);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, value);

    const json = stringifyValue(ctx, value) orelse return error.StringifyFailed;
    defer std.heap.c_allocator.free(@constCast(json));

    try std.testing.expect(std.mem.indexOf(u8, json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"count\":2") != null);
}

test "quickjs_host: eval string owned" {
    const rt = qjs.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer qjs.JS_FreeRuntime(rt);
    const ctx = qjs.JS_NewContext(rt) orelse return error.ContextCreationFailed;
    defer qjs.JS_FreeContext(ctx);

    const text = try evalStringOwned(std.testing.allocator, ctx, "'hello'", "<host-eval-string>");
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "quickjs_host: eval int32" {
    const rt = qjs.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer qjs.JS_FreeRuntime(rt);
    const ctx = qjs.JS_NewContext(rt) orelse return error.ContextCreationFailed;
    defer qjs.JS_FreeContext(ctx);

    const value = try evalInt32(ctx, "40 + 2", "<host-eval-int>");
    try std.testing.expectEqual(@as(i32, 42), value);
}
