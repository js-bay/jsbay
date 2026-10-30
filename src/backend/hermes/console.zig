//! console.{log,debug,info,warn,error} for the Hermes backend.
//! Joins args (objects via JSON.stringify, else ToString) and delivers to log_handler + console_tap.

const std = @import("std");
const types = @import("../../types.zig");
const console_tap = @import("../../inspector/console_tap.zig");
const console_format = @import("../console_format.zig");
const console_log = @import("../console_log.zig");
const c_api = @import("c_api.zig");
const value_mod = @import("value.zig");

const Context = value_mod.Context;
const Value = value_mod.Value;

fn appendPart(buf: *std.ArrayList(u8), part: []const u8) void {
    buf.ensureUnusedCapacity(std.heap.c_allocator, part.len) catch return;
    buf.appendSliceAssumeCapacity(part);
}

fn instanceIdFromCtx(ctx: Context) i32 {
    const p = c_api.hermes_context_get_opaque(ctx) orelse return 0;
    return @bitCast(@as(u32, @truncate(@intFromPtr(p))));
}

fn consoleImpl(ctx: ?*c_api.Context, args: ?[*]const Value, argc: usize, level: types.LogLevel) Value {
    const c = ctx orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) appendPart(&buf, " ");
        const val = args.?[i];
        if (c_api.hermes_is_object(val) and !c_api.hermes_is_string(val)) {
            if (value_mod.jsonStringifyVal(c, val)) |s| {
                defer std.heap.c_allocator.free(@constCast(s));
                appendPart(&buf, s);
            } else {
                appendPart(&buf, "[object Object]");
            }
        } else if (value_mod.valueToStringAlloc(std.heap.c_allocator, c, val)) |s| {
            defer std.heap.c_allocator.free(s);
            appendPart(&buf, s);
        }
    }

    const id = instanceIdFromCtx(c);
    const c_msg = console_format.finishMessage(std.heap.c_allocator, &buf) catch return null;
    defer std.heap.c_allocator.free(c_msg);

    console_log.deliver(id, level, c_msg.ptr);
    console_tap.fire(id, level, c_msg.ptr);
    return value_mod.undefinedValue();
}

fn jsLog(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return consoleImpl(ctx, args, argc, .debug);
}
fn jsDebug(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return consoleImpl(ctx, args, argc, .debug);
}
fn jsInfo(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return consoleImpl(ctx, args, argc, .info);
}
fn jsWarn(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return consoleImpl(ctx, args, argc, .warn);
}
fn jsError(ctx: ?*c_api.Context, _: Value, args: ?[*]const Value, argc: usize, _: ?*anyopaque) callconv(.c) Value {
    return consoleImpl(ctx, args, argc, .err);
}

fn bindMethod(ctx: Context, console: Value, name: []const u8, fn_ptr: c_api.NativeFn) void {
    const fn_val = value_mod.makeFunction(ctx, name, fn_ptr, null) orelse return;
    defer value_mod.freeValue(ctx, fn_val);
    var buf: [32]u8 = undefined;
    if (name.len >= buf.len) return;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    _ = c_api.hermes_set_property(ctx, console, @ptrCast(&buf), fn_val);
}

pub fn registerConsole(ctx: Context) void {
    const console = value_mod.newObject(ctx) orelse return;
    defer value_mod.freeValue(ctx, console);
    bindMethod(ctx, console, "log", jsLog);
    bindMethod(ctx, console, "debug", jsDebug);
    bindMethod(ctx, console, "info", jsInfo);
    bindMethod(ctx, console, "warn", jsWarn);
    bindMethod(ctx, console, "error", jsError);
    const global = value_mod.getGlobalObject(ctx);
    if (global == null) return;
    defer value_mod.freeValue(ctx, global);
    _ = c_api.hermes_set_property(ctx, global, "console", console);
}
