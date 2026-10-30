//! Native function registration: `registerFunction` / `registerObjectWithFunctions` plus the comptime-generated per-backend trampolines that marshal NativeArgs in and NativeResult out. Consumers interact only with `NativeHandler` and `FunctionEntry`; the wrappers stay private to this module.

const std = @import("std");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const native_args = @import("native_args.zig");
const native_result = @import("native_result.zig");
const dispatch = @import("dispatch.zig");

const ActiveEngine = backend.ActiveEngine;

const NativeArgs = native_args.NativeArgs;
const NativeResult = native_result.NativeResult;

/// Native function handler type. Consumers implement this — no backend types exposed.
pub const NativeHandler = *const fn (instance_id: i32, args: NativeArgs) NativeResult;

/// Register a native function on a global JS object. If parent_name is null, registers on globalThis directly. The handler receives unified NativeArgs and returns NativeResult.
pub fn registerFunction(
    instance_id: i32,
    parent_name: ?[*:0]const u8,
    fn_name: [*:0]const u8,
    comptime handler: NativeHandler,
) void {
    const ctx = instance_map.withInstanceReturn(
        instance_id,
        struct {
            pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?ActiveEngine.Context {
                return inst.ctx;
            }
        }{},
    ) orelse return;

    // Generate the backend-specific wrapper at comptime
    const wrapper = BackendWrapper(handler);
    wrapper.register(ctx, parent_name, fn_name);
}

/// Entry type for `registerObjectWithFunctions`. Exposed as a named type so consumers can build slices of entries in their own code without running into the anonymous-struct type-identity problem.
pub const FunctionEntry = struct {
    name: [*:0]const u8,
    handler: NativeHandler,
};

/// Register a native function on an existing JS object (by instance + object path). Convenience for `registerFunction` when you need to create the parent object too.
pub fn registerObjectWithFunctions(
    instance_id: i32,
    obj_name: [*:0]const u8,
    comptime handlers: []const FunctionEntry,
) void {
    const ctx = instance_map.withInstanceReturn(
        instance_id,
        struct {
            pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?ActiveEngine.Context {
                return inst.ctx;
            }
        }{},
    ) orelse return;

    const global = ActiveEngine.getGlobalObject(ctx);
    const obj = ActiveEngine.newObject(ctx);
    inline for (handlers) |h| {
        const w = BackendWrapper(h.handler);
        w.setOnObject(ctx, obj, h.name);
    }
    ActiveEngine.setPropertyStr(ctx, global, obj_name, obj);
    ActiveEngine.freeValue(ctx, global);
}

// ---- Comptime backend wrapper generation ----

fn BackendWrapper(comptime handler: NativeHandler) type {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => QuickJsWrapper(handler),
        .jsc => JscWrapper(handler),
        .escargot => EscargotWrapper(handler),
        .hermes => HermesWrapper(handler),
    };
}

fn EscargotWrapper(comptime handler: NativeHandler) type {
    const c_api = backend.ActiveEngineModule.c_api_mod;
    return struct {
        fn callback(ctx: ?*c_api.Context, this_val: c_api.Value, args_ptr: ?[*]const c_api.Value, argc: usize, _: ?*anyopaque) callconv(.c) c_api.Value {
            const id = ActiveEngine.instanceIdFromCtx(ctx);
            const args = NativeArgs{
                .instance_id = id,
                ._count = argc,
                ._ctx = ctx,
                ._argv_raw = if (args_ptr) |p| @ptrCast(p) else @ptrCast(&[_]c_api.Value{}),
                ._this = this_val,
            };
            const result = handler(id, args);
            return nativeResultToEscargot(ctx, result);
        }

        fn nativeResultToEscargot(ctx: ?*c_api.Context, result: NativeResult) c_api.Value {
            switch (result) {
                .null_val => return c_api.escargot_null(),
                .undefined_val => return c_api.escargot_undefined(),
                .boolean => |v| return c_api.escargot_new_bool(v),
                .number => |v| return c_api.escargot_new_float64(v),
                .string => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return c_api.escargot_new_string(ctx, s.ptr, s.len);
                },
                .json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return c_api.escargot_json_parse(ctx, s.ptr, s.len) orelse c_api.escargot_null();
                },
                .err => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    var buf: [512]u8 = undefined;
                    const n = @min(s.len, buf.len - 1);
                    @memcpy(buf[0..n], s[0..n]);
                    buf[n] = 0;
                    c_api.escargot_throw(ctx, @ptrCast(&buf));
                    return null;
                },
                .value => |v| return v,
                .promise => |v| return v,
                .array_buffer => |p| {
                    const val = ActiveEngine.newArrayBufferCopyVal(ctx, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .typed_array => |p| {
                    const val = dispatch.newTypedArrayFromBytes(ctx, p.kind, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .date_ms => |ms| return ActiveEngine.newDate(ctx, ms),
                .big_int_i64 => |v| return ActiveEngine.newBigIntI64(ctx, v),
                .big_int_u64 => |v| return ActiveEngine.newBigIntU64(ctx, v),
                .map_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return ActiveEngine.newMapFromJson(ctx, s) orelse c_api.escargot_null();
                },
                .set_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return ActiveEngine.newSetFromJson(ctx, s) orelse c_api.escargot_null();
                },
                .data_view => |p| {
                    const val = ActiveEngine.newDataViewFromBuffer(ctx, ActiveEngine.newArrayBufferCopyVal(ctx, p.buffer.bytes), p.byte_offset, p.byte_length);
                    if (p.buffer.free_after_copy) std.heap.c_allocator.free(@constCast(p.buffer.bytes));
                    return val;
                },
            }
        }

        pub fn register(ctx: ActiveEngine.Context, parent_name: ?[*:0]const u8, fn_name: [*:0]const u8) void {
            const name = std.mem.span(fn_name);
            const func = ActiveEngine.makeNativeFunction(ctx, name, &callback, null) orelse return;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            if (parent_name) |pn| {
                const parent = ActiveEngine.getPropertyVal(ctx, global, pn) orelse blk: {
                    const obj = ActiveEngine.newObject(ctx);
                    ActiveEngine.setPropertyStr(ctx, global, pn, ActiveEngine.dupValue(ctx, obj));
                    break :blk obj;
                };
                defer ActiveEngine.freeValue(ctx, parent);
                ActiveEngine.setPropertyStr(ctx, parent, fn_name, func);
            } else {
                ActiveEngine.setPropertyStr(ctx, global, fn_name, func);
            }
        }

        pub fn setOnObject(ctx: ActiveEngine.Context, obj: ActiveEngine.Value, fn_name: [*:0]const u8) void {
            const name = std.mem.span(fn_name);
            const func = ActiveEngine.makeNativeFunction(ctx, name, &callback, null) orelse return;
            ActiveEngine.setPropertyStr(ctx, obj, fn_name, func);
        }
    };
}

fn HermesWrapper(comptime handler: NativeHandler) type {
    const c_api = backend.ActiveEngineModule.c_api_mod;
    return struct {
        fn callback(ctx: ?*c_api.Context, this_val: c_api.Value, args_ptr: ?[*]const c_api.Value, argc: usize, _: ?*anyopaque) callconv(.c) c_api.Value {
            const id = ActiveEngine.instanceIdFromCtx(ctx);
            const args = NativeArgs{
                .instance_id = id,
                ._count = argc,
                ._ctx = ctx,
                ._argv_raw = if (args_ptr) |p| @ptrCast(p) else @ptrCast(&[_]c_api.Value{}),
                ._this = this_val,
            };
            const result = handler(id, args);
            return nativeResultToHermes(ctx, result);
        }

        fn nativeResultToHermes(ctx: ?*c_api.Context, result: NativeResult) c_api.Value {
            switch (result) {
                .null_val => return c_api.hermes_null(),
                .undefined_val => return c_api.hermes_undefined(),
                .boolean => |v| return c_api.hermes_new_bool(v),
                .number => |v| return c_api.hermes_new_float64(v),
                .string => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return c_api.hermes_new_string(ctx, s.ptr, s.len);
                },
                .json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return c_api.hermes_json_parse(ctx, s.ptr, s.len) orelse c_api.hermes_null();
                },
                .err => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    var buf: [512]u8 = undefined;
                    const n = @min(s.len, buf.len - 1);
                    @memcpy(buf[0..n], s[0..n]);
                    buf[n] = 0;
                    c_api.hermes_throw(ctx, @ptrCast(&buf));
                    return null;
                },
                .value => |v| return v,
                .promise => |v| return v,
                .array_buffer => |p| {
                    const val = ActiveEngine.newArrayBufferCopyVal(ctx, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .typed_array => |p| {
                    const val = dispatch.newTypedArrayFromBytes(ctx, p.kind, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .date_ms => |ms| return ActiveEngine.newDate(ctx, ms),
                .big_int_i64 => |v| return ActiveEngine.newBigIntI64(ctx, v),
                .big_int_u64 => |v| return ActiveEngine.newBigIntU64(ctx, v),
                .map_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return ActiveEngine.newMapFromJson(ctx, s) orelse c_api.hermes_null();
                },
                .set_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return ActiveEngine.newSetFromJson(ctx, s) orelse c_api.hermes_null();
                },
                .data_view => |p| {
                    const val = ActiveEngine.newDataViewFromBuffer(ctx, ActiveEngine.newArrayBufferCopyVal(ctx, p.buffer.bytes), p.byte_offset, p.byte_length);
                    if (p.buffer.free_after_copy) std.heap.c_allocator.free(@constCast(p.buffer.bytes));
                    return val;
                },
            }
        }

        pub fn register(ctx: ActiveEngine.Context, parent_name: ?[*:0]const u8, fn_name: [*:0]const u8) void {
            const name = std.mem.span(fn_name);
            const func = ActiveEngine.makeNativeFunction(ctx, name, &callback, null) orelse return;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            if (parent_name) |pn| {
                const parent = ActiveEngine.getPropertyVal(ctx, global, pn) orelse blk: {
                    const obj = ActiveEngine.newObject(ctx);
                    ActiveEngine.setPropertyStr(ctx, global, pn, ActiveEngine.dupValue(ctx, obj));
                    break :blk obj;
                };
                defer ActiveEngine.freeValue(ctx, parent);
                ActiveEngine.setPropertyStr(ctx, parent, fn_name, func);
            } else {
                ActiveEngine.setPropertyStr(ctx, global, fn_name, func);
            }
        }

        pub fn setOnObject(ctx: ActiveEngine.Context, obj: ActiveEngine.Value, fn_name: [*:0]const u8) void {
            const name = std.mem.span(fn_name);
            const func = ActiveEngine.makeNativeFunction(ctx, name, &callback, null) orelse return;
            ActiveEngine.setPropertyStr(ctx, obj, fn_name, func);
        }
    };
}

fn QuickJsWrapper(comptime handler: NativeHandler) type {
    const qjs_mod = backend.ActiveEngineModule;
    const qjs = qjs_mod.qjs;

    return struct {
        fn callback(ctx: ?*qjs.JSContext, this_val: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
            const id = ActiveEngine.instanceIdFromCtx(ctx);
            const args = NativeArgs{
                .instance_id = id,
                ._count = if (argc > 0) @intCast(argc) else 0,
                ._ctx = ctx,
                ._argv_raw = @ptrCast(argv),
                ._this = this_val,
            };

            const result = handler(id, args);
            return nativeResultToQjs(ctx, result);
        }

        fn nativeResultToQjs(ctx: ?*qjs.JSContext, result: NativeResult) qjs.JSValue {
            switch (result) {
                .null_val => return qjs_mod.JS_NULL,
                .undefined_val => return qjs_mod.JS_UNDEFINED,
                .boolean => |v| return qjs_mod.jsbay_qjs_JS_NewBool(ctx, if (v) 1 else 0),
                .number => |v| return qjs_mod.jsbay_qjs_JS_NewFloat64(ctx, v),
                .string => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    return qjs.JS_NewStringLen(ctx, s.ptr, s.len);
                },
                .json => |s| {
                    // NUL-terminate before handing to JS_ParseJSON: QuickJS' JSON lexer looks one byte past buf_len, and a bare c_allocator.dupe slice is not NUL-terminated. On Linux glibc that occasionally tails into a non-whitespace byte and produces a phantom "unexpected data at the end" error.
                    const buf = std.heap.c_allocator.dupeSentinel(u8, s, 0) catch {
                        std.heap.c_allocator.free(@constCast(s));
                        return qjs_mod.JS_NULL;
                    };
                    defer std.heap.c_allocator.free(buf);
                    std.heap.c_allocator.free(@constCast(s));
                    const p = qjs.JS_ParseJSON(ctx, buf.ptr, buf.len, "<native>");
                    if (ActiveEngine.jsIsException(p)) {
                        const pending = qjs.JS_GetException(ctx);
                        if (!ActiveEngine.jsIsNull(pending)) qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                        return qjs_mod.JS_NULL;
                    }
                    return p;
                },
                .err => |s| {
                    const z = std.heap.c_allocator.dupeSentinel(u8, s, 0) catch return qjs_mod.JS_EXCEPTION;
                    defer std.heap.c_allocator.free(z);
                    std.heap.c_allocator.free(@constCast(s));
                    return qjs.JS_ThrowInternalError(ctx, "%s", z.ptr);
                },
                .value => |v| return v,
                .promise => |v| return v,
                .array_buffer => |p| {
                    const val = ActiveEngine.newArrayBufferCopyVal(ctx, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .typed_array => |p| {
                    const val = dispatch.newTypedArrayFromBytes(ctx, p.kind, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .date_ms => |ms| return dispatch.newDateVal(ctx, ms),
                .big_int_i64 => |v| return dispatch.newBigIntI64Val(ctx, v),
                .big_int_u64 => |v| return dispatch.newBigIntU64Val(ctx, v),
                .map_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    const v = dispatch.newMapFromJsonVal(ctx, s);
                    if (ActiveEngine.jsIsException(v)) {
                        const pending = qjs.JS_GetException(ctx);
                        if (!ActiveEngine.jsIsNull(pending)) qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                        return qjs_mod.JS_NULL;
                    }
                    return v;
                },
                .set_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    const v = dispatch.newSetFromJsonVal(ctx, s);
                    if (ActiveEngine.jsIsException(v)) return qjs_mod.JS_NULL;
                    return v;
                },
                .data_view => |p| {
                    const val = dispatch.newDataView(ctx, p.buffer, p.byte_offset, p.byte_length);
                    if (p.buffer.free_after_copy) std.heap.c_allocator.free(@constCast(p.buffer.bytes));
                    return val;
                },
            }
        }

        pub fn register(ctx: ActiveEngine.Context, parent_name: ?[*:0]const u8, fn_name: [*:0]const u8) void {
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const func = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, &callback, fn_name, 1);

            if (parent_name) |pn| {
                const parent = qjs.JS_GetPropertyStr(ctx, global, pn);
                if (!ActiveEngine.jsIsUndefined(parent) and !ActiveEngine.jsIsNull(parent)) {
                    _ = qjs.JS_SetPropertyStr(ctx, parent, fn_name, func);
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, parent);
                } else {
                    // Parent doesn't exist, create it
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, parent);
                    const obj = qjs.JS_NewObject(ctx);
                    _ = qjs.JS_SetPropertyStr(ctx, obj, fn_name, func);
                    _ = qjs.JS_SetPropertyStr(ctx, global, pn, obj);
                }
            } else {
                _ = qjs.JS_SetPropertyStr(ctx, global, fn_name, func);
            }
        }

        pub fn setOnObject(ctx: ActiveEngine.Context, obj: ActiveEngine.Value, fn_name: [*:0]const u8) void {
            const func = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, &callback, fn_name, 1);
            _ = qjs.JS_SetPropertyStr(ctx, obj, fn_name, func);
        }
    };
}

fn JscWrapper(comptime handler: NativeHandler) type {
    const jsc_mod = backend.EngineModule(.jsc);
    const jsc = jsc_mod.jsc;

    return struct {
        fn callback(
            ctx: jsc.JSContextRef,
            _function: jsc.JSObjectRef,
            _this_object: jsc.JSObjectRef,
            argument_count: usize,
            arguments: [*c]const jsc.JSValueRef,
            exception: [*c]jsc.JSValueRef,
        ) callconv(.c) jsc.JSValueRef {
            _ = _function;
            const id = ActiveEngine.instanceIdFromCtx(@constCast(ctx));
            const args = NativeArgs{
                .instance_id = id,
                ._count = argument_count,
                ._ctx = @constCast(ctx),
                ._argv_raw = @ptrCast(arguments),
                // JSObjectRef coerces to JSValueRef (adds const). Null stays null, which the value layer treats as undefined.
                ._this = _this_object,
            };

            const result = handler(id, args);
            return nativeResultToJsc(ctx, exception, result);
        }

        fn nativeResultToJsc(ctx: jsc.JSContextRef, exception: [*c]jsc.JSValueRef, result: NativeResult) jsc.JSValueRef {
            const B = ActiveEngine;
            switch (result) {
                .null_val => return jsc.JSValueMakeNull(ctx),
                .undefined_val => return jsc.JSValueMakeUndefined(ctx),
                .boolean => |v| return jsc.JSValueMakeBoolean(ctx, v),
                .number => |v| return jsc.JSValueMakeNumber(ctx, v),
                .string => |s| {
                    const val = B.makeStringValue(ctx, s);
                    std.heap.c_allocator.free(@constCast(s));
                    return val;
                },
                .json => |s| {
                    const val = B.jsonParse(ctx, s);
                    std.heap.c_allocator.free(@constCast(s));
                    return if (val != null) val else jsc.JSValueMakeNull(ctx);
                },
                .err => |s| {
                    const val = B.throwError(ctx, exception, s);
                    std.heap.c_allocator.free(@constCast(s));
                    return val;
                },
                .value => |v| return v,
                .promise => |v| return v,
                .array_buffer => |p| {
                    const val = B.newArrayBufferCopyVal(@constCast(ctx), p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .typed_array => |p| {
                    const val = dispatch.newTypedArrayFromBytes(@constCast(ctx), p.kind, p.bytes);
                    if (p.free_after_copy) std.heap.c_allocator.free(@constCast(p.bytes));
                    return val;
                },
                .date_ms => |ms| return dispatch.newDateVal(@constCast(ctx), ms),
                .big_int_i64 => |v| return dispatch.newBigIntI64Val(@constCast(ctx), v),
                .big_int_u64 => |v| return dispatch.newBigIntU64Val(@constCast(ctx), v),
                .map_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    const v = dispatch.newMapFromJsonVal(@constCast(ctx), s);
                    return if (v != null) v else jsc.JSValueMakeNull(ctx);
                },
                .set_json => |s| {
                    defer std.heap.c_allocator.free(@constCast(s));
                    const v = dispatch.newSetFromJsonVal(@constCast(ctx), s);
                    return if (v != null) v else jsc.JSValueMakeNull(ctx);
                },
                .data_view => |p| {
                    const val = dispatch.newDataView(@constCast(ctx), p.buffer, p.byte_offset, p.byte_length);
                    if (p.buffer.free_after_copy) std.heap.c_allocator.free(@constCast(p.buffer.bytes));
                    return val;
                },
            }
        }

        pub fn register(ctx: ActiveEngine.Context, parent_name: ?[*:0]const u8, fn_name: [*:0]const u8) void {
            const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
            const global = jsc.JSContextGetGlobalObject(jsc_ctx);
            const fn_name_slice = std.mem.span(fn_name);
            const func_obj = ActiveEngine.makeFunction(jsc_ctx, fn_name_slice, &callback) orelse return;

            if (parent_name) |pn| {
                const pn_slice = std.mem.span(pn);
                const js_pn = ActiveEngine.jsStringFromSlice(pn_slice) orelse return;
                defer jsc.JSStringRelease(js_pn);
                var exc: jsc.JSValueRef = null;
                const parent_val = jsc.JSObjectGetProperty(jsc_ctx, global, js_pn, &exc);
                if (parent_val != null and jsc.JSValueIsObject(jsc_ctx, parent_val)) {
                    ActiveEngine.setProperty(jsc_ctx, @constCast(parent_val), fn_name_slice, @ptrCast(func_obj));
                } else {
                    const obj = jsc.JSObjectMake(jsc_ctx, null, null);
                    ActiveEngine.setProperty(jsc_ctx, obj, fn_name_slice, @ptrCast(func_obj));
                    ActiveEngine.setProperty(jsc_ctx, global, pn_slice, @ptrCast(obj));
                }
            } else {
                ActiveEngine.setProperty(jsc_ctx, global, fn_name_slice, @ptrCast(func_obj));
            }
        }

        pub fn setOnObject(ctx: ActiveEngine.Context, obj: ActiveEngine.Value, fn_name: [*:0]const u8) void {
            const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
            const fn_name_slice = std.mem.span(fn_name);
            const func_obj = ActiveEngine.makeFunction(jsc_ctx, fn_name_slice, &callback) orelse return;
            ActiveEngine.setProperty(jsc_ctx, @constCast(obj), fn_name_slice, @ptrCast(func_obj));
        }
    };
}
