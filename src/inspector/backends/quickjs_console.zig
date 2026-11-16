//! Synchronous, borrowed console diagnostics for QuickJS-family backends. Ordinary logs and message ownership stay with the backend.
const std = @import("std");
const types = @import("../../types.zig");
const console_tap = @import("../console_tap.zig");

/// Stateless specialization; every backend uses the same console_tap registry and TLS.
pub fn create(comptime c: type) type {
    return struct {
        const qjs = c.qjs;

        pub fn publishDiagnostic(id: i32, ctx: ?*qjs.JSContext, argc: c_int, argv: [*c]qjs.JSValue, level: types.LogLevel, cdp_type: []const u8, c_msg: [*:0]const u8) void {
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
    };
}
