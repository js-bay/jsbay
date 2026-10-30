//! setTimeout / setInterval / clearTimeout / clearInterval + queueMicrotask polyfill for Escargot.

const std = @import("std");
const async_stack = @import("../../inspector/async_stack.zig");
const timers_mod = @import("../../runtime/timers.zig");
const c_api = @import("c_api.zig");
const value_mod = @import("value.zig");

const Context = value_mod.Context;
const Value = value_mod.Value;

const queue_microtask_polyfill =
    \\(function(){if(typeof globalThis.queueMicrotask==='function')return;var then=Promise.prototype.then;var resolved=Promise.resolve();return function(report){globalThis.queueMicrotask=function(callback){if(typeof callback!=='function')throw new TypeError('queueMicrotask callback must be a function');then.call(resolved,function(){try{callback();}catch(error){report(error);}});};};})()
;

fn instanceIdFromCtx(ctx: Context) i32 {
    const p = c_api.escargot_context_get_opaque(ctx) orelse return 0;
    return @bitCast(@as(u32, @truncate(@intFromPtr(p))));
}

fn throwMsg(ctx: Context, msg: [*:0]const u8) Value {
    c_api.escargot_throw(ctx, msg);
    return null;
}

fn bindGlobal(ctx: Context, name: [*:0]const u8, fn_ptr: c_api.NativeFn) void {
    const fn_val = value_mod.makeFunction(ctx, std.mem.span(name), fn_ptr, null);
    if (fn_val == null) return;
    const global = value_mod.getGlobalObject(ctx);
    defer value_mod.freeValue(ctx, global);
    _ = c_api.escargot_set_property(ctx, global, name, fn_val);
    value_mod.freeValue(ctx, fn_val);
}

fn createTimer(ctx: Context, args: ?[*]const Value, argc: usize, is_interval: bool) Value {
    if (argc < 1 or args == null or !value_mod.isFunction(ctx, args.?[0])) {
        return throwMsg(ctx, "Expected function");
    }
    var delay_ms: u64 = 0;
    if (argc >= 2) {
        const d = value_mod.toFloat64(ctx, args.?[1]) orelse 0;
        delay_ms = timers_mod.normalizeDelay(d);
    }
    const id = instanceIdFromCtx(ctx);
    const callback = value_mod.dupValue(ctx, args.?[0]);
    if (callback == null) return throwMsg(ctx, "Timer allocation failed");
    const trace = async_stack.capture(id);
    const timer_id = timers_mod.schedule(id, ctx, callback, delay_ms, is_interval, trace) orelse {
        value_mod.freeValue(ctx, callback);
        if (trace) |captured| async_stack.freeTrace(captured);
        return throwMsg(ctx, "Timer allocation failed");
    };
    return value_mod.newInt32Val(ctx, timer_id);
}

fn jsSetTimeout(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return createTimer(ctx, args, argc, false);
}
fn jsSetInterval(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return createTimer(ctx, args, argc, true);
}
fn jsClearTimer(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    const c = ctx orelse return null;
    if (argc < 1 or args == null) return value_mod.undefinedValue();
    const number = value_mod.toFloat64(c, args.?[0]) orelse return value_mod.undefinedValue();
    if (!std.math.isFinite(number) or number < @as(f64, @floatFromInt(std.math.minInt(i32))) or number > @as(f64, @floatFromInt(std.math.maxInt(i32)))) {
        return value_mod.undefinedValue();
    }
    const timer_id: i32 = @intFromFloat(@trunc(number));
    timers_mod.cancel(instanceIdFromCtx(c), timer_id);
    return value_mod.undefinedValue();
}

fn jsReportUncaughtMicrotask(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    const c = ctx orelse return null;
    if (argc > 0 and args != null) {
        if (value_mod.valueToStringAlloc(std.heap.c_allocator, c, args.?[0])) |message| {
            defer std.heap.c_allocator.free(message);
            @import("../../inspector/root.zig").exceptions.reportUncaught(instanceIdFromCtx(c), message, "");
        }
    }
    return value_mod.undefinedValue();
}

pub fn registerTimers(ctx: Context) void {
    bindGlobal(ctx, "setTimeout", jsSetTimeout);
    bindGlobal(ctx, "setInterval", jsSetInterval);
    bindGlobal(ctx, "clearTimeout", jsClearTimer);
    bindGlobal(ctx, "clearInterval", jsClearTimer);

    const r = value_mod.evalValue(ctx, queue_microtask_polyfill, "<queueMicrotask>");
    defer if (r.err_text) |t| std.heap.c_allocator.free(t);
    defer if (r.exception != null) value_mod.freeValue(ctx, r.exception);
    defer if (r.value != null) value_mod.freeValue(ctx, r.value);
    if (r.err_text != null or r.value == null) return;
    // Already present: polyfill returns undefined.
    if (!value_mod.isFunction(ctx, r.value)) return;

    const reporter = value_mod.makeFunction(ctx, "queueMicrotaskReport", jsReportUncaughtMicrotask, null);
    if (reporter == null) return;
    defer value_mod.freeValue(ctx, reporter);

    const global = value_mod.getGlobalObject(ctx);
    defer value_mod.freeValue(ctx, global);
    const call_args = [_]Value{reporter};
    _ = value_mod.callFunction(ctx, r.value, global, &call_args);
}
