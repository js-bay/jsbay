//! `setTimeout` / `setInterval` / `clearTimeout` / `clearInterval` callbacks bound onto the global object by `lifecycle.registerTimers`. All four share the shared Zig timer scheduler.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const async_stack = @import("../../inspector/async_stack.zig");
const timers_mod = @import("../../runtime/timers.zig");

fn instanceIdFromCtx(ctx: ?*qjs.JSContext) i32 {
    const ptr = qjs.JS_GetContextOpaque(ctx);
    return @bitCast(@as(u32, @truncate(@intFromPtr(ptr))));
}

pub fn jsSetTimeout(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = _this;
    return createTimer(ctx, argc, argv, false);
}

pub fn jsSetInterval(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = _this;
    return createTimer(ctx, argc, argv, true);
}

fn createTimer(ctx: ?*qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue, is_interval: bool) qjs.JSValue {
    if (argc < 1 or c.jsbay_qjs_JS_IsFunction(ctx, argv[0]) == 0) {
        return qjs.JS_ThrowTypeError(ctx, "Expected function");
    }

    var delay_ms: u64 = 0;
    if (argc >= 2) {
        var delay: f64 = 0;
        if (qjs.JS_ToFloat64(ctx, &delay, argv[1]) != 0) return c.JS_EXCEPTION;
        delay_ms = timers_mod.normalizeDelay(delay);
    }

    const id = instanceIdFromCtx(ctx);
    const callback = c.jsbay_qjs_JS_DupValue(ctx, argv[0]);
    const trace = async_stack.capture(id);
    var callback_slot = callback;
    const ctx_addr: usize = if (ctx) |p| @intFromPtr(p) else 0;
    const timer_id = timers_mod.scheduleOpaque(id, ctx_addr, std.mem.asBytes(&callback_slot), delay_ms, is_interval, trace) orelse {
        c.jsbay_qjs_JS_FreeValue(ctx, callback);
        if (trace) |captured| async_stack.freeTrace(captured);
        return qjs.JS_ThrowInternalError(ctx, "Timer allocation failed");
    };
    return c.jsbay_qjs_JS_NewInt32(ctx, timer_id);
}

pub fn jsClearTimer(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    _ = _this;
    if (argc < 1) return c.JS_UNDEFINED;

    var timer_id: i32 = 0;
    _ = qjs.JS_ToInt32(ctx, &timer_id, argv[0]);
    const id = instanceIdFromCtx(ctx);

    timers_mod.cancel(id, timer_id);

    return c.JS_UNDEFINED;
}
