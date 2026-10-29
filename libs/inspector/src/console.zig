pub fn Module(comptime Host: type) type {
    // Console tap → `Runtime.consoleAPICalled` fan-out.
    //
    // The console tap runs on the JS thread. It formats + sends CDP events inline; `transport.sendText` is thread-safe so this is fine. We never hold `inspector_mutex` across `sendText`: buffering and the enabled-session snapshot share the per-state mutex, then we drop it before sending.
    //
    // QuickJS publishes one RemoteObject per JS argument through the arg view installed around the active tap callback. JSC does not set that view, so it keeps a single string argument. Events collected while Runtime is enabled are buffered for later sessions and replayed from `Runtime.enable`.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const dispatch = Host.dispatch;
        const io = Host.io;
        const transport_mod = @import("transport.zig");
        const types = Host.types;
        const json_writer = @import("json_writer.zig").Module(Host);
        const request_box = @import("request_box.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;

        var console_group_counter: std.atomic.Value(u64) = .init(1);

        pub fn consoleTapCallback(
            ctx: ?*anyopaque,
            instance_id: i32,
            level: types.LogLevel,
            message: [*:0]const u8,
        ) callconv(.c) void {
            const state: *InspectorState = @ptrCast(@alignCast(ctx.?));
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, state.instance_id, state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            const msg_slice = std.mem.span(message);

            var group_buf: [48]u8 = undefined;
            const js_ctx = currentConsoleContext(instance_id);
            const group = if (js_ctx != null) blk: {
                const id = nextConsoleGroupId() orelse break :blk null;
                break :blk std.fmt.bufPrint(&group_buf, "__jsbay_console_{d}", .{id}) catch null;
            } else null;

            var aw: std.Io.Writer.Allocating = .init(state.allocator);
            defer aw.deinit();
            writeConsoleEvent(state, &aw.writer, instance_id, level, msg_slice, group) catch {
                if (js_ctx) |value| {
                    if (group) |name| _ = state.object_table.releaseConsoleGroup(value, name);
                }
                return;
            };

            var ids: std.ArrayList(transport_mod.SessionId) = .empty;
            defer ids.deinit(state.allocator);
            state_mod.bufferConsoleEvent(state, aw.written(), js_ctx, group, &ids) catch {
                if (js_ctx) |value| {
                    if (group) |name| _ = state.object_table.releaseConsoleGroup(value, name);
                }
                return;
            };

            for (ids.items) |sid| {
                _ = state.transport.sendText(sid, aw.written());
            }
        }

        fn nextConsoleGroupId() ?u64 {
            var current = console_group_counter.load(.monotonic);
            while (current != std.math.maxInt(u64)) {
                if (console_group_counter.cmpxchgWeak(current, current + 1, .monotonic, .monotonic) == null) return current;
                current = console_group_counter.load(.monotonic);
            }
            return null;
        }

        fn currentConsoleContext(instance_id: i32) ?backend.ActiveEngine.Context {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return null;
            const console_tap = Host.console_tap;
            if (console_tap.currentArgView()) |view| {
                if (view.ctx) |ctx_ptr| {
                    const Ctx = @typeInfo(backend.ActiveEngine.Context).optional.child;
                    const ctx_raw: Ctx = @ptrCast(@alignCast(ctx_ptr));
                    return ctx_raw;
                }
            }
            _ = instance_id;
            return null;
        }

        pub const TestCases = if (@import("builtin").is_test) struct {
            pub fn consoleGroupSequenceStopsBeforeReusingMaximumValue() !void {
                const testing = std.testing;
                const previous = console_group_counter.swap(std.math.maxInt(u64) - 1, .seq_cst);
                defer console_group_counter.store(previous, .seq_cst);
                try testing.expectEqual(@as(?u64, std.math.maxInt(u64) - 1), nextConsoleGroupId());
                try testing.expectEqual(@as(?u64, null), nextConsoleGroupId());
            }
        } else struct {};

        // Mark the session Runtime-enabled and replay buffered console events. Called from `Runtime.enable` after `executionContextCreated`.
        pub fn enableRuntimeAndReplayConsole(state: *InspectorState, session_id: transport_mod.SessionId) void {
            const buffered = state_mod.enableRuntimeAndCopyConsole(state, session_id);
            defer state_mod.freeBufferedConsole(state, buffered);
            for (buffered.entries) |entry| {
                _ = state.transport.sendText(session_id, entry);
            }
        }

        // Runtime.discardConsoleEntries arrives on the transport thread. The buffer's groups own JS values, so clearing it must be serialized onto the JS thread.
        pub fn handleDiscardConsoleEntries(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            const box = state.allocator.create(request_box.RequestBox) catch {
                json_writer.sendEmptyResult(state, session_id, request_id);
                return;
            };
            box.* = .{
                .state = state,
                .session_id = session_id,
                .request_id = request_id,
                .run_fn = runDiscardConsoleEntries,
            };
            if (!request_box.postJsRequest(state, box)) {
                request_box.freeRequestBox(state.allocator, box);
                json_writer.sendEmptyResult(state, session_id, request_id);
            }
        }

        fn runDiscardConsoleEntries(box: *request_box.RequestBox, ctx: backend.ActiveEngine.Context) void {
            state_mod.clearConsoleEntries(box.state, ctx);
            json_writer.sendEmptyResult(box.state, box.session_id, box.request_id);
        }

        fn cdpType(level: types.LogLevel) []const u8 {
            const console_tap = Host.console_tap;
            if (console_tap.currentArgView()) |view| {
                if (view.cdp_type.len != 0) return view.cdp_type;
            }
            return switch (level) {
                .debug => "log",
                .info => "info",
                .warn => "warning",
                .err => "error",
            };
        }

        fn writeConsoleEvent(
            state: *InspectorState,
            w: anytype,
            instance_id: i32,
            level: types.LogLevel,
            message: []const u8,
            object_group: ?[]const u8,
        ) !void {
            try w.writeAll("{\"method\":\"Runtime.consoleAPICalled\",\"params\":{\"type\":");
            try json_writer.writeJsonString(w, cdpType(level));
            try w.writeAll(",\"args\":[");
            try writeArgList(state, w, message, object_group);
            try w.print("],\"executionContextId\":{d},\"timestamp\":", .{state_mod.default_execution_context_id});
            try w.print("{d}", .{io.milliTimestamp()});
            try w.writeAll(",\"stackTrace\":{\"callFrames\":[");
            try writeStack(instance_id, w);
            try w.writeAll("]");
            const async_stack = Host.async_stack;
            try async_stack.writeParents(instance_id, w);
            try w.writeAll("}}}");
        }

        fn writeStack(instance_id: i32, w: anytype) !void {
            const console_tap = Host.console_tap;
            const view = console_tap.currentArgView() orelse return;
            if (view.frames.len == 0) return;
            const debugger_mod = Host.debugger;
            var wrote = false;
            for (view.frames) |frame| {
                if (frame.url.len == 0) continue;
                if (wrote) try w.writeByte(',');
                wrote = true;
                const script_id = debugger_mod.scriptIdForTag(instance_id, frame.script_tag);
                try w.writeAll("{\"functionName\":");
                try json_writer.writeJsonString(w, frame.function_name);
                try w.print(",\"scriptId\":\"{d}\",\"url\":", .{script_id});
                try json_writer.writeJsonString(w, frame.url);
                try w.print(",\"lineNumber\":{d},\"columnNumber\":{d}}}", .{ frame.line, frame.column });
            }
        }

        fn writeSingleStringArg(w: anytype, message: []const u8) !void {
            try w.writeAll("{\"type\":\"string\",\"value\":");
            try json_writer.writeJsonString(w, message);
            try w.writeByte('}');
        }

        fn writeArgList(state: *InspectorState, w: anytype, message: []const u8, object_group: ?[]const u8) !void {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) {
                try writeSingleStringArg(w, message);
                return;
            }
            if (object_group == null) {
                try writeSingleStringArg(w, message);
                return;
            }
            const console_tap = Host.console_tap;
            const view = console_tap.currentArgView() orelse {
                try writeSingleStringArg(w, message);
                return;
            };
            const remote_object = @import("remote_object.zig").Module(Host);
            const Ctx = @typeInfo(backend.ActiveEngine.Context).optional.child;
            const ctx_ptr = view.ctx orelse {
                try writeSingleStringArg(w, message);
                return;
            };
            const ctx_raw: Ctx = @ptrCast(@alignCast(ctx_ptr));
            const ctx: backend.ActiveEngine.Context = ctx_raw;
            if (view.argc > 0) {
                const argv_ptr = view.argv orelse {
                    try writeSingleStringArg(w, message);
                    return;
                };
                const argv: [*]const backend.ActiveEngine.Value = @ptrCast(@alignCast(argv_ptr));
                for (0..view.argc) |i| {
                    if (i != 0) try w.writeByte(',');
                    try remote_object.writeConsoleRemoteObjectEx(state, ctx, w, argv[i], object_group, true);
                }
            }
        }
    };
}
