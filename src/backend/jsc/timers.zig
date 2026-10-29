//! setTimeout / setInterval / clearTimeout / clearInterval bridge for the JSC backend. The actual timer machinery lives in the cross-backend `timers.zig`; this file is the JS-callable surface.

const std = @import("std");
const async_stack = @import("../../inspector/async_stack.zig");
const timers_mod = @import("../../runtime/timers.zig");
const common = @import("common.zig");
const value_mod = @import("value.zig");

const jsc = common.jsc;

// Install queueMicrotask only when absent without changing a host implementation or Promise.prototype. The factory receives a private native reporter rather than publishing a helper on the global object.
const queue_microtask_polyfill =
    "(function(){if(typeof globalThis.queueMicrotask==='function')return;var then=Promise.prototype.then;var resolved=Promise.resolve();return function(report){globalThis.queueMicrotask=function(callback){if(typeof callback!=='function')throw new TypeError('queueMicrotask callback must be a function');then.call(resolved,function(){try{callback();}catch(error){report(error);}});};};})()";

pub fn registerTimers(ctx: jsc.JSGlobalContextRef) void {
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const global = jsc.JSContextGetGlobalObject(jsc_ctx);
    const set_timeout = common.makeFunction(jsc_ctx, "setTimeout", jsSetTimeout) orelse return;
    const set_interval = common.makeFunction(jsc_ctx, "setInterval", jsSetInterval) orelse return;
    const clear_timeout = common.makeFunction(jsc_ctx, "clearTimeout", jsClearTimer) orelse return;
    const clear_interval = common.makeFunction(jsc_ctx, "clearInterval", jsClearTimer) orelse return;
    common.setProperty(jsc_ctx, global, "setTimeout", @ptrCast(set_timeout));
    common.setProperty(jsc_ctx, global, "setInterval", @ptrCast(set_interval));
    common.setProperty(jsc_ctx, global, "clearTimeout", @ptrCast(clear_timeout));
    common.setProperty(jsc_ctx, global, "clearInterval", @ptrCast(clear_interval));
    const source = common.jsStringFromSlice(queue_microtask_polyfill) orelse return;
    defer jsc.JSStringRelease(source);
    var exception: jsc.JSValueRef = null;
    const factory_value = jsc.JSEvaluateScript(jsc_ctx, source, null, null, 1, &exception);
    if (exception != null or factory_value == null or !jsc.JSValueIsObject(jsc_ctx, factory_value)) return;

    const factory: jsc.JSObjectRef = @ptrCast(@constCast(factory_value));
    jsc.JSValueProtect(jsc_ctx, factory);
    defer jsc.JSValueUnprotect(jsc_ctx, factory);
    const reporter = common.makeFunction(jsc_ctx, "queueMicrotaskReport", jsReportUncaughtMicrotask) orelse return;
    jsc.JSValueProtect(jsc_ctx, reporter);
    defer jsc.JSValueUnprotect(jsc_ctx, reporter);
    var args = [_]jsc.JSValueRef{reporter};
    exception = null;
    _ = jsc.JSObjectCallAsFunction(jsc_ctx, factory, global, args.len, &args, &exception);
}
fn jsReportUncaughtMicrotask(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, _: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    if (argc > 0) {
        if (common.formatException(ctx, argv[0])) |message| {
            defer std.heap.c_allocator.free(message);
            @import("../../inspector/root.zig").exceptions.reportUncaught(common.instanceIdFromCtx(@ptrCast(@constCast(ctx))), message, "");
        }
    }
    return jsc.JSValueMakeUndefined(ctx);
}

fn jsSetTimeout(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, exc: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    return createTimer(ctx, argc, argv, exc, false);
}
fn jsSetInterval(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, exc: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    return createTimer(ctx, argc, argv, exc, true);
}

fn createTimer(ctx_ref: jsc.JSContextRef, argument_count: usize, arguments: [*c]const jsc.JSValueRef, exception: [*c]jsc.JSValueRef, is_interval: bool) jsc.JSValueRef {
    // JSObjectIsFunction requires an object; primitives should throw, not abort.
    if (argument_count < 1 or !value_mod.isFunction(@constCast(ctx_ref), arguments[0])) {
        return common.throwError(ctx_ref, exception, "Expected function");
    }

    var delay_ms: u64 = 0;
    if (argument_count >= 2) {
        var exc: jsc.JSValueRef = null;
        const d = jsc.JSValueToNumber(ctx_ref, arguments[1], &exc);
        if (exc != null) {
            exception[0] = exc;
            return jsc.JSValueMakeUndefined(ctx_ref);
        }
        delay_ms = timers_mod.normalizeDelay(d);
    }

    const jsc_ctx: jsc.JSGlobalContextRef = @constCast(ctx_ref);
    const id = common.instanceIdFromCtx(jsc_ctx);

    // Protect the callback from GC
    const callback = arguments[0];
    jsc.JSValueProtect(ctx_ref, callback);
    const trace = async_stack.capture(id);
    const timer_id = timers_mod.schedule(id, jsc_ctx, callback, delay_ms, is_interval, trace) orelse {
        jsc.JSValueUnprotect(ctx_ref, callback);
        if (trace) |captured| async_stack.freeTrace(captured);
        return common.throwError(ctx_ref, exception, "Timer allocation failed");
    };
    return jsc.JSValueMakeNumber(ctx_ref, @floatFromInt(timer_id));
}

fn jsClearTimer(ctx_ref: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, exception: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    if (argc < 1) return jsc.JSValueMakeUndefined(ctx_ref);

    var exc: jsc.JSValueRef = null;
    const number = jsc.JSValueToNumber(ctx_ref, argv[0], &exc);
    if (exc != null) {
        exception[0] = exc;
        return jsc.JSValueMakeUndefined(ctx_ref);
    }
    if (!std.math.isFinite(number) or number < @as(f64, @floatFromInt(std.math.minInt(i32))) or number > @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return jsc.JSValueMakeUndefined(ctx_ref);
    }
    const timer_id: i32 = @intFromFloat(@trunc(number));

    const jsc_ctx: jsc.JSGlobalContextRef = @constCast(ctx_ref);
    const id = common.instanceIdFromCtx(jsc_ctx);

    timers_mod.cancel(id, timer_id);

    return jsc.JSValueMakeUndefined(ctx_ref);
}
