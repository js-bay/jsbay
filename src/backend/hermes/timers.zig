//! setTimeout / setInterval / clearTimeout / clearInterval + queueMicrotask polyfill for Hermes.
//! Native failures return `{__jsbay_timer_err}` and a JS wrapper throws — avoids throwing
//! `jsi::JSError` across the hermes_bridge.o / libjsi.so exception ABI boundary (ABRT).

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

const timer_throw_wrap =
    \\(function(){
    \\  function wrap(name){
    \\    var raw=globalThis[name];
    \\    if(typeof raw!=='function'||raw.__jsbayWrapped)return;
    \\    var w=function(){
    \\      var r=raw.apply(this,arguments);
    \\      if(r&&typeof r==='object'&&typeof r.__jsbay_timer_err==='string'){
    \\        throw new Error(r.__jsbay_timer_err);
    \\      }
    \\      return r;
    \\    };
    \\    w.__jsbayWrapped=true;
    \\    globalThis[name]=w;
    \\  }
    \\  wrap('setTimeout');
    \\  wrap('setInterval');
    \\})()
;

fn instanceIdFromCtx(ctx: Context) i32 {
    const p = c_api.hermes_context_get_opaque(ctx) orelse return 0;
    return @bitCast(@as(u32, @truncate(@intFromPtr(p))));
}

fn failMsg(ctx: Context, msg: []const u8) Value {
    const obj = value_mod.newObject(ctx);
    if (obj == null) return null;
    const s = value_mod.newStringVal(ctx, msg);
    if (s == null) {
        value_mod.freeValue(ctx, obj);
        return null;
    }
    value_mod.setPropertyStr(ctx, obj, "__jsbay_timer_err", s);
    return obj;
}

fn bindGlobal(ctx: Context, name: [*:0]const u8, fn_ptr: c_api.NativeFn) void {
    const fn_val = value_mod.makeFunction(ctx, std.mem.span(name), fn_ptr, null);
    if (fn_val == null) return;
    const global = value_mod.getGlobalObject(ctx);
    defer value_mod.freeValue(ctx, global);
    _ = c_api.hermes_set_property(ctx, global, name, fn_val);
    value_mod.freeValue(ctx, fn_val);
}

fn createTimer(ctx: Context, args: ?[*]const Value, argc: usize, is_interval: bool) Value {
    if (argc < 1 or args == null or !value_mod.isFunction(ctx, args.?[0])) {
        return failMsg(ctx, "Expected function");
    }
    var delay_ms: u64 = 0;
    if (argc >= 2) {
        const d = value_mod.toFloat64(ctx, args.?[1]) orelse 0;
        delay_ms = timers_mod.normalizeDelay(d);
    }
    const id = instanceIdFromCtx(ctx);
    const callback = value_mod.dupValue(ctx, args.?[0]);
    if (callback == null) return failMsg(ctx, "Timer allocation failed");
    const trace = async_stack.capture(id);
    const timer_id = timers_mod.schedule(id, ctx, callback, delay_ms, is_interval, trace) orelse {
        value_mod.freeValue(ctx, callback);
        if (trace) |captured| async_stack.freeTrace(captured);
        return failMsg(ctx, "Timer allocation failed");
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

    // Wrap so native failure objects become JS exceptions without crossing the jsi throw ABI.
    const wrap = value_mod.evalValue(ctx, timer_throw_wrap, "<timer-wrap>");
    defer if (wrap.err_text) |t| std.heap.c_allocator.free(t);
    defer if (wrap.exception != null) value_mod.freeValue(ctx, wrap.exception);
    defer if (wrap.value != null) value_mod.freeValue(ctx, wrap.value);

    const r = value_mod.evalValue(ctx, queue_microtask_polyfill, "<queueMicrotask>");
    defer if (r.err_text) |t| std.heap.c_allocator.free(t);
    defer if (r.exception != null) value_mod.freeValue(ctx, r.exception);
    defer if (r.value != null) value_mod.freeValue(ctx, r.value);
    if (r.err_text != null or r.value == null) return;
    if (!value_mod.isFunction(ctx, r.value)) return;

    const reporter = value_mod.makeFunction(ctx, "queueMicrotaskReport", jsReportUncaughtMicrotask, null);
    if (reporter == null) return;
    defer value_mod.freeValue(ctx, reporter);

    const global = value_mod.getGlobalObject(ctx);
    defer value_mod.freeValue(ctx, global);
    const call_args = [_]Value{reporter};
    _ = value_mod.callFunction(ctx, r.value, global, &call_args);
}
