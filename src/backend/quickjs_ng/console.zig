//! `console.*` callbacks bound onto the global object by `lifecycle.registerConsole`. One C function handles every method; the per-method kind is QuickJS's "magic" integer.
//!
//! `log_handler` still receives one joined string. The console tap also sees the raw JS values, the CDP type, and a borrowed debug stack so the inspector can emit one RemoteObject per argument.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const exception = @import("exception.zig");
const types = @import("../../types.zig");
const console_tap = @import("../../inspector/console_tap.zig");
const console_format = @import("../console_format.zig");
const console_log = @import("../console_log.zig");
const console_timers = @import("../console_timers.zig");

fn appendPart(buf: *std.ArrayList(u8), part: []const u8) void {
    buf.ensureUnusedCapacity(std.heap.c_allocator, part.len) catch return;
    buf.appendSliceAssumeCapacity(part);
}

fn instanceIdFromCtx(ctx: ?*qjs.JSContext) i32 {
    const ptr = qjs.JS_GetContextOpaque(ctx);
    return @bitCast(@as(u32, @truncate(@intFromPtr(ptr))));
}

const Mode = enum { normal, time, time_end, assert };

const Kind = struct {
    level: types.LogLevel,
    cdp_type: []const u8,
    mode: Mode,
};

/// One row is both the QuickJS magic integer and the CDP console type. `lifecycle.registerConsole` binds `js_name`; `kindFromMagic` looks up `magic`. `cdp_type` is not derived from the method name: `group` is `"startGroup"`, and `time` is empty because `console.time` emits no console event.
pub const ConsoleBinding = struct {
    js_name: [*:0]const u8,
    magic: c_int,
    level: types.LogLevel,
    cdp_type: []const u8,
    mode: Mode,
};

pub const console_bindings = [_]ConsoleBinding{
    .{ .js_name = "log", .magic = 0, .level = .debug, .cdp_type = "log", .mode = .normal },
    .{ .js_name = "debug", .magic = 4, .level = .debug, .cdp_type = "debug", .mode = .normal },
    .{ .js_name = "info", .magic = 1, .level = .info, .cdp_type = "info", .mode = .normal },
    .{ .js_name = "warn", .magic = 2, .level = .warn, .cdp_type = "warning", .mode = .normal },
    .{ .js_name = "error", .magic = 3, .level = .err, .cdp_type = "error", .mode = .normal },
    .{ .js_name = "dir", .magic = 5, .level = .debug, .cdp_type = "dir", .mode = .normal },
    .{ .js_name = "table", .magic = 6, .level = .debug, .cdp_type = "table", .mode = .normal },
    .{ .js_name = "trace", .magic = 7, .level = .debug, .cdp_type = "trace", .mode = .normal },
    .{ .js_name = "assert", .magic = 8, .level = .err, .cdp_type = "assert", .mode = .assert },
    .{ .js_name = "group", .magic = 9, .level = .debug, .cdp_type = "startGroup", .mode = .normal },
    .{ .js_name = "groupCollapsed", .magic = 10, .level = .debug, .cdp_type = "startGroupCollapsed", .mode = .normal },
    .{ .js_name = "groupEnd", .magic = 11, .level = .debug, .cdp_type = "endGroup", .mode = .normal },
    .{ .js_name = "time", .magic = 12, .level = .debug, .cdp_type = "", .mode = .time },
    .{ .js_name = "timeEnd", .magic = 13, .level = .debug, .cdp_type = "timeEnd", .mode = .time_end },
};

const default_timer_label = "default";

fn kindFromMagic(magic: c_int) Kind {
    for (console_bindings) |binding| {
        if (binding.magic == magic) {
            return .{
                .level = binding.level,
                .cdp_type = binding.cdp_type,
                .mode = binding.mode,
            };
        }
    }
    return .{ .level = .debug, .cdp_type = "log", .mode = .normal };
}

fn argLabel(ctx: ?*qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue) ?[]u8 {
    if (argc <= 0) return std.heap.c_allocator.dupe(u8, default_timer_label) catch null;
    if (exception.valueToString(ctx, argv[0])) |s| {
        const copy = std.heap.c_allocator.dupe(u8, s) catch {
            std.heap.c_allocator.free(@constCast(s));
            return std.heap.c_allocator.dupe(u8, default_timer_label) catch null;
        };
        std.heap.c_allocator.free(@constCast(s));
        return copy;
    }
    return std.heap.c_allocator.dupe(u8, default_timer_label) catch null;
}

fn appendJoined(ctx: ?*qjs.JSContext, buf: *std.ArrayList(u8), argc: c_int, argv: [*c]qjs.JSValue) void {
    var i: c_int = 0;
    while (i < argc) : (i += 1) {
        if (i > 0) appendPart(buf, " ");
        const val = argv[@intCast(i)];
        if (c.jsIsObject(val)) {
            if (exception.jsonStringify(ctx, val)) |s| {
                appendPart(buf, s);
                std.heap.c_allocator.free(@constCast(s));
            } else {
                appendPart(buf, "[object Object]");
            }
        } else if (exception.valueToString(ctx, val)) |s| {
            appendPart(buf, s);
            std.heap.c_allocator.free(@constCast(s));
        }
    }
}

fn publish(
    ctx: ?*qjs.JSContext,
    argc: c_int,
    argv: [*c]qjs.JSValue,
    level: types.LogLevel,
    cdp_type: []const u8,
    c_msg: [*:0]const u8,
) void {
    const id = instanceIdFromCtx(ctx);

    console_log.deliver(id, level, c_msg);

    if (comptime @import("build_options").inspector) {
        var tap = console_tap.begin(id);
        if (!tap.isActive()) return;

        const console_stack_frame_cap = 16;
        var raw_frames: [console_stack_frame_cap]qjs.JSDebugFrameInfo = undefined;
        var copied: [console_stack_frame_cap]console_tap.CallFrame = undefined;
        @import("../../tests/debug_cold_probe.zig").noteDebugStackCopy();
        const frame_count: usize = @intCast(qjs.JS_CopyDebugStack(ctx, &raw_frames, raw_frames.len));
        for (raw_frames[0..frame_count], 0..) |*frame, i| {
            copied[i] = .{
                .function_name = std.mem.span(@as([*:0]const u8, @ptrCast(&frame.name))),
                .url = std.mem.span(@as([*:0]const u8, @ptrCast(&frame.filename))),
                .line = if (frame.line > 0) frame.line - 1 else 0,
                .column = if (frame.column > 0) frame.column - 1 else 0,
                .script_tag = frame.script_tag,
            };
        }
        const arg_count: usize = if (argc > 0) @intCast(argc) else 0;
        const previous_args = console_tap.currentArgView();
        console_tap.setArgView(.{
            .ctx = if (ctx) |p| @ptrCast(p) else null,
            .argc = arg_count,
            .argv = if (arg_count > 0) @ptrCast(argv) else null,
            .cdp_type = cdp_type,
            .frames = copied[0..frame_count],
        });
        defer console_tap.setArgView(previous_args);
        tap.finish(id, level, c_msg);
    }
}

pub fn jsConsoleLog(ctx: ?*qjs.JSContext, _this: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue, magic: c_int) callconv(.c) qjs.JSValue {
    _ = _this;
    const kind = kindFromMagic(magic);
    const id = instanceIdFromCtx(ctx);

    switch (kind.mode) {
        .time => {
            const label = argLabel(ctx, argc, argv) orelse return c.JS_UNDEFINED;
            defer std.heap.c_allocator.free(label);
            console_timers.remember(id, label);
            return c.JS_UNDEFINED;
        },
        .time_end => {
            const label = argLabel(ctx, argc, argv) orelse return c.JS_UNDEFINED;
            defer std.heap.c_allocator.free(label);
            const text = if (console_timers.take(id, label)) |start|
                std.fmt.allocPrint(std.heap.c_allocator, "{s}: {d} ms", .{ label, @import("../../platform/io.zig").milliTimestamp() - start }) catch return c.JS_UNDEFINED
            else
                std.fmt.allocPrint(std.heap.c_allocator, "Timer '{s}' does not exist", .{label}) catch return c.JS_UNDEFINED;
            defer std.heap.c_allocator.free(text);
            const text_z = std.heap.c_allocator.dupeSentinel(u8, text, 0) catch return c.JS_UNDEFINED;
            defer std.heap.c_allocator.free(text_z);
            const js_text = c.jsbay_qjs_JS_NewString(ctx, text_z.ptr);
            defer c.jsbay_qjs_JS_FreeValue(ctx, js_text);
            var one = [_]qjs.JSValue{js_text};
            publish(ctx, 1, &one, kind.level, kind.cdp_type, text_z.ptr);
            return c.JS_UNDEFINED;
        },
        .assert => {
            if (argc > 0) {
                const cond = qjs.JS_ToBool(ctx, argv[0]);
                if (cond < 0) return c.JS_EXCEPTION;
                if (cond > 0) return c.JS_UNDEFINED;
            }
            if (argc <= 1) {
                const text = "console.assert";
                const js_text = c.jsbay_qjs_JS_NewString(ctx, text);
                defer c.jsbay_qjs_JS_FreeValue(ctx, js_text);
                var one = [_]qjs.JSValue{js_text};
                publish(ctx, 1, &one, kind.level, kind.cdp_type, "console.assert");
                return c.JS_UNDEFINED;
            }
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(std.heap.c_allocator);
            appendJoined(ctx, &buf, argc - 1, argv + 1);
            const c_msg = console_format.finishMessage(std.heap.c_allocator, &buf) catch return c.JS_UNDEFINED;
            defer std.heap.c_allocator.free(c_msg);
            publish(ctx, argc - 1, argv + 1, kind.level, kind.cdp_type, c_msg.ptr);
            return c.JS_UNDEFINED;
        },
        .normal => {},
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);
    appendJoined(ctx, &buf, argc, argv);
    const c_msg = console_format.finishMessage(std.heap.c_allocator, &buf) catch return c.JS_UNDEFINED;
    defer std.heap.c_allocator.free(c_msg);
    publish(ctx, argc, argv, kind.level, kind.cdp_type, c_msg.ptr);
    return c.JS_UNDEFINED;
}
