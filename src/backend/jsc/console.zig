//! console.{log, debug, info, warn, error} bridge for the JSC backend.
//!
//! Forwards each call to the engine's `log_handler` (via instance_map) and to the global `console_tap` so tests can intercept output without installing a per-instance handler.

const std = @import("std");
const types = @import("../../types.zig");
const console_tap = @import("../../inspector/console_tap.zig");
const common = @import("common.zig");
const console_format = @import("../console_format.zig");
const console_log = @import("../console_log.zig");

const jsc = common.jsc;

fn appendPart(buf: *std.ArrayList(u8), part: []const u8) void {
    buf.ensureUnusedCapacity(std.heap.c_allocator, part.len) catch return;
    buf.appendSliceAssumeCapacity(part);
}

pub fn registerConsole(ctx: jsc.JSGlobalContextRef) void {
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const global = jsc.JSContextGetGlobalObject(jsc_ctx);
    const console = jsc.JSObjectMake(jsc_ctx, null, null);
    const log = common.makeFunction(jsc_ctx, "log", jsConsoleLog) orelse return;
    const debug = common.makeFunction(jsc_ctx, "debug", jsConsoleDebug) orelse return;
    const info = common.makeFunction(jsc_ctx, "info", jsConsoleInfo) orelse return;
    const warn = common.makeFunction(jsc_ctx, "warn", jsConsoleWarn) orelse return;
    const err = common.makeFunction(jsc_ctx, "error", jsConsoleError) orelse return;
    common.setProperty(jsc_ctx, console, "log", @ptrCast(log));
    common.setProperty(jsc_ctx, console, "debug", @ptrCast(debug));
    common.setProperty(jsc_ctx, console, "info", @ptrCast(info));
    common.setProperty(jsc_ctx, console, "warn", @ptrCast(warn));
    common.setProperty(jsc_ctx, console, "error", @ptrCast(err));
    common.setProperty(jsc_ctx, global, "console", @ptrCast(console));
}

fn consoleImpl(ctx_ref: jsc.JSContextRef, argument_count: usize, arguments: [*c]const jsc.JSValueRef, level: types.LogLevel) jsc.JSValueRef {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);

    var i: usize = 0;
    while (i < argument_count) : (i += 1) {
        if (i > 0) appendPart(&buf, " ");
        const val = arguments[i];
        if (jsc.JSValueIsObject(ctx_ref, val)) {
            if (common.jsonStringify(ctx_ref, val)) |s| {
                appendPart(&buf, s);
                std.heap.c_allocator.free(@constCast(s));
            } else {
                appendPart(&buf, "[object Object]");
            }
        } else if (common.valueToString(ctx_ref, val)) |s| {
            appendPart(&buf, s);
            std.heap.c_allocator.free(@constCast(s));
        }
    }

    const id = common.instanceIdFromCtx(@constCast(ctx_ref));

    // Transfer the formatted buffer into one NUL-terminated allocation. This keeps the same pointer shared by both callbacks without copying the ArrayList a second time.
    const c_msg = console_format.finishMessage(std.heap.c_allocator, &buf) catch
        return jsc.JSValueMakeUndefined(ctx_ref);
    defer std.heap.c_allocator.free(c_msg);

    console_log.deliver(id, level, c_msg.ptr);

    // Fire the console tap OUTSIDE the instance_map lock so the tap callback cannot deadlock with instance_map operations.
    console_tap.fire(id, level, c_msg.ptr);

    return jsc.JSValueMakeUndefined(ctx_ref);
}

fn jsConsoleLog(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, _e: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    _ = _e;
    return consoleImpl(ctx, argc, argv, .debug);
}
fn jsConsoleDebug(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, _e: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    _ = _e;
    return consoleImpl(ctx, argc, argv, .debug);
}
fn jsConsoleInfo(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, _e: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    _ = _e;
    return consoleImpl(ctx, argc, argv, .info);
}
fn jsConsoleWarn(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, _e: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    _ = _e;
    return consoleImpl(ctx, argc, argv, .warn);
}
fn jsConsoleError(ctx: jsc.JSContextRef, _f: jsc.JSObjectRef, _t: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, _e: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    _ = _f;
    _ = _t;
    _ = _e;
    return consoleImpl(ctx, argc, argv, .err);
}
