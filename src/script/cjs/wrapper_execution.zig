//! CommonJS module environment and invocation. Inputs are borrowed; the returned exports reference is owned. Backend calls preserve typed values and the caller's admission scope.
const std = @import("std");
const backend = @import("../../backend.zig");
const ActiveEngine = backend.ActiveEngine;
const OwnedValue = @import("../../value/root.zig").OwnedValue;

pub const CallResult = struct { exports: ActiveEngine.Value };
pub const ExceptionSink = *const fn (ActiveEngine.Context, OwnedValue) void;
pub const Environment = struct { exports: ActiveEngine.Value, module: ActiveEngine.Value };
pub const Require = union(enum) {
    module_local: *const fn (ActiveEngine.Context, []const u8) error{ Compile, CallFailed }!ActiveEngine.Value,
    borrowed: ActiveEngine.Value,
};

pub fn invoke(ctx: ActiveEngine.Context, wrapper_fn: ActiveEngine.Value, require: Require, filename: []const u8, dirname: []const u8, environment: ?Environment, exception_sink: ExceptionSink) error{ OutOfMemory, Compile, CallFailed }!CallResult {
    var exports_obj = OwnedValue.init(ctx, if (environment) |env| ActiveEngine.dupValue(ctx, env.exports) else try newExports(ctx));
    defer exports_obj.deinit();
    var module_obj = OwnedValue.init(ctx, if (environment) |env| ActiveEngine.dupValue(ctx, env.module) else try newModule(ctx, exports_obj.borrow()));
    defer module_obj.deinit();
    var filename_val = OwnedValue.init(ctx, ActiveEngine.newStringVal(ctx, filename));
    defer filename_val.deinit();
    var dirname_val = OwnedValue.init(ctx, ActiveEngine.newStringVal(ctx, dirname));
    defer dirname_val.deinit();
    // Module require construction follows environment creation; injection stays borrowed.
    var local_require: ?OwnedValue = switch (require) {
        .module_local => |get| OwnedValue.init(ctx, try get(ctx, filename)),
        .borrowed => null,
    };
    // All resources are already guarded before require creation, which can fail.
    defer if (local_require) |*owned| owned.deinit();
    const require_fn = switch (require) {
        .module_local => local_require.?.borrow(),
        .borrowed => |value| value,
    };
    const argv = [_]ActiveEngine.Value{ exports_obj.borrow(), module_obj.borrow(), require_fn, filename_val.borrow(), dirname_val.borrow() };
    const call_result = try callWrapper(ctx, wrapper_fn, &argv, exception_sink);
    ActiveEngine.freeValue(ctx, call_result);
    const current_exports = try readFinalExports(ctx, module_obj.borrow(), exception_sink);
    return .{ .exports = current_exports };
}

fn callWrapper(ctx: ActiveEngine.Context, function: ActiveEngine.Value, args: []const ActiveEngine.Value, exception_sink: ExceptionSink) error{CallFailed}!ActiveEngine.Value {
    if (comptime backend.active_backend == .jsc) {
        const jsc = @import("../../backend/jsc.zig").jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        var exception: jsc.JSValueRef = null;
        const result = jsc.JSObjectCallAsFunction(ctx_ref, @constCast(function), null, args.len, @ptrCast(args.ptr), &exception);
        if (exception != null) {
            // A nested require may rethrow a captured getter exception. Preserve its identity again as it unwinds through this outer wrapper.
            exception_sink(ctx, OwnedValue.init(ctx, ActiveEngine.dupValue(ctx, exception)));
            return error.CallFailed;
        }
        if (result == null) return error.CallFailed;
        jsc.JSValueProtect(ctx_ref, result);
        return result;
    }
    if (comptime backend.isSpikeBackend(backend.active_backend)) {
        if (comptime backend.active_backend == .escargot) {
            const api = @import("../../backend/escargot/c_api.zig");
            const result = api.escargot_call_result(ctx, function, ActiveEngine.undefinedValue(), if (args.len == 0) null else args.ptr, args.len);
            return consumeSpikeResult(ctx, result, exception_sink);
        } else {
            const api = @import("../../backend/hermes/c_api.zig");
            const result = api.hermes_call_result(ctx, function, ActiveEngine.undefinedValue(), if (args.len == 0) null else args.ptr, args.len);
            return consumeSpikeResult(ctx, result, exception_sink);
        }
    }
    return ActiveEngine.callFunction(ctx, function, ActiveEngine.undefinedValue(), args) orelse error.CallFailed;
}

/// The registry and wrapper share this module and its initial exports object.
pub fn newExports(ctx: ActiveEngine.Context) error{OutOfMemory}!ActiveEngine.Value {
    const value = ActiveEngine.newObject(ctx);
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        if (backend.ActiveEngineModule.jsIsException(value)) return error.OutOfMemory;
    } else if (value == null) return error.OutOfMemory;
    return value;
}

pub fn newModule(ctx: ActiveEngine.Context, exports: ActiveEngine.Value) error{OutOfMemory}!ActiveEngine.Value {
    const module = try newExports(ctx);
    errdefer ActiveEngine.freeValue(ctx, module);
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        const m = backend.ActiveEngineModule;
        // Define an own data property with the intrinsic C API: assignment can invoke an inherited setter before the registry has its loading entry. The C API consumes the duplicate on success AND failure.
        if (m.qjs.JS_DefinePropertyValueStr(ctx, module, "exports", ActiveEngine.dupValue(ctx, exports), m.qjs.JS_PROP_C_W_E) < 0) return error.OutOfMemory;
    } else if (comptime backend.active_backend == .jsc) {
        const jsc = @import("../../backend/jsc.zig").jsc;
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        // JSC's set API is not DefineOwnProperty. Temporarily detach only this fresh, unpublished object's prototype, never the global prototype.
        const prototype = jsc.JSObjectGetPrototype(ctx_ref, @constCast(module));
        jsc.JSValueProtect(ctx_ref, prototype);
        defer jsc.JSValueUnprotect(ctx_ref, prototype);
        jsc.JSObjectSetPrototype(ctx_ref, @constCast(module), jsc.JSValueMakeNull(ctx_ref));
        defer jsc.JSObjectSetPrototype(ctx_ref, @constCast(module), prototype);
        const key = jsc.JSStringCreateWithUTF8CString("exports");
        defer jsc.JSStringRelease(key);
        var exception: jsc.JSValueRef = null;
        jsc.JSObjectSetProperty(ctx_ref, @constCast(module), key, exports, 0, &exception);
        if (exception != null) return error.OutOfMemory;
    } else {
        if (!ActiveEngine.defineDataProperty(ctx, module, "exports", exports, true)) return error.OutOfMemory;
    }
    return module;
}

/// Read final `module.exports` without replacing a successful undefined result with the initial exports object.
///
/// QuickJS-family accessor exceptions remain parked in `ctx` without `JS_GetException`. JSC and spike backends transfer owned exceptions to the supplied sink.
pub fn readFinalExports(
    ctx: ActiveEngine.Context,
    module_obj: ActiveEngine.Value,
    exception_sink: ExceptionSink,
) error{CallFailed}!ActiveEngine.Value {
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        const qjs_mod = backend.ActiveEngineModule;
        const val = qjs_mod.qjs.JS_GetPropertyStr(ctx, module_obj, "exports");
        if (qjs_mod.jsIsException(val)) {
            // `JS_EXCEPTION` is a tag, not a heap object. Freeing the sentinel is a no-op and must not call `JS_GetException`, which would clear the parked getter error that `qjsThrowRequireError` propagates.
            qjs_mod.jsbay_qjs_JS_FreeValue(ctx, val);
            return error.CallFailed;
        }
        return val;
    }
    if (comptime backend.active_backend == .jsc) {
        const jsc_mod = @import("../../backend/jsc.zig");
        const jsc = jsc_mod.jsc;
        const common = @import("../../backend/jsc/common.zig");
        if (module_obj == null or common.isSentinel(module_obj)) {
            return ActiveEngine.newUndefinedVal(ctx);
        }
        const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
        const js_key = jsc.JSStringCreateWithUTF8CString("exports");
        defer jsc.JSStringRelease(js_key);
        var exc: jsc.JSValueRef = null;
        const val = jsc.JSObjectGetProperty(ctx_ref, @constCast(module_obj), js_key, &exc);
        if (exc != null) {
            // JSC has no parked-context exception. Preserve the value before returning through the Zig error union to the native callback.
            exception_sink(ctx, OwnedValue.init(ctx, ActiveEngine.dupValue(ctx, exc)));
            return error.CallFailed;
        }
        if (val == null) return ActiveEngine.newUndefinedVal(ctx);
        jsc.JSValueProtect(ctx_ref, val);
        return val;
    }
    if (comptime backend.isSpikeBackend(backend.active_backend)) {
        const key: [:0]const u8 = "exports";
        if (comptime backend.active_backend == .escargot) {
            const result = @import("../../backend/escargot/c_api.zig").escargot_get_property_result(ctx, module_obj, key.ptr);
            return consumeSpikeResult(ctx, result, exception_sink);
        } else {
            const result = @import("../../backend/hermes/c_api.zig").hermes_get_property_result(ctx, module_obj, key.ptr);
            return consumeSpikeResult(ctx, result, exception_sink);
        }
    }
    unreachable;
}

fn consumeSpikeResult(ctx: ActiveEngine.Context, result: anytype, exception_sink: ExceptionSink) error{CallFailed}!ActiveEngine.Value {
    if (result.exception != null) {
        if (result.value != null) ActiveEngine.freeValue(ctx, result.value);
        exception_sink(ctx, OwnedValue.init(ctx, result.exception));
        return error.CallFailed;
    }
    if (result.value != null) return result.value;
    return error.CallFailed;
}

/// Shared framing bytes remain fingerprinted through the existing cjs_wrapper.zig path.
pub fn appendSource(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), source: []const u8) std.mem.Allocator.Error!void {
    try buf.appendSlice(allocator, @import("../cjs_wrapper.zig").prefix);
    try buf.appendSlice(allocator, source);
    try buf.appendSlice(allocator, @import("../cjs_wrapper.zig").suffix);
}

pub fn wrapSource(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendSource(allocator, &buf, source);
    return buf.toOwnedSlice(allocator);
}
