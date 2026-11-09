pub fn Module(comptime Host: type) type {
    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const state_mod = @import("state.zig").Module(Host);
        const json_writer = @import("json_writer.zig").Module(Host);
        const InspectorState = state_mod.InspectorState;
        const enabled = backend.active_backend == .hermes;
        const api = if (enabled) backend.ActiveEngineModule.c_api else struct {};
        const Callback = *const fn (?*anyopaque) callconv(.c) void;

        const MessageInfo = if (enabled) api.InspectorMessageInfo else void;

        // The native bridge copies these decoded fields inside the sink. No JSON allocation or borrowed slice crosses the callback's lifetime.
        fn parseMessage(json: [*]const u8, len: usize, sink: *const fn (?*anyopaque, *const MessageInfo) callconv(.c) void, target: ?*anyopaque) callconv(.c) bool {
            const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, json[0..len], .{}) catch return false;
            defer parsed.deinit();
            if (parsed.value != .object) return false;
            const object = parsed.value.object;
            var info: MessageInfo = std.mem.zeroes(MessageInfo);
            if (object.get("id")) |id| {
                if (id == .integer) {
                    info.id = id.integer;
                    info.flags |= 1;
                }
            }
            if (object.contains("result") and !object.contains("error")) info.flags |= 2;
            if (object.get("method")) |method| {
                if (method == .string) {
                    info.method = method.string.ptr;
                    info.method_len = method.string.len;
                }
            }
            if (object.get("params")) |params| {
                if (params == .object) {
                    if (params.object.get("scriptId")) |id| {
                        if (id == .string) {
                            info.script_id = id.string.ptr;
                            info.script_id_len = id.string.len;
                        }
                    }
                    if (params.object.get("expression")) |expression| {
                        if (expression == .string) {
                            info.expression = expression.string.ptr;
                            info.expression_len = expression.string.len;
                            info.flags |= 4;
                        }
                    }
                }
            }
            sink(target, &info);
            return true;
        }

        const Task = struct {
            run_callback: Callback,
            cancel_callback: Callback,
            data: ?*anyopaque,

            fn run(raw: ?*anyopaque) void {
                const task: *Task = @ptrCast(@alignCast(raw.?));
                defer std.heap.c_allocator.destroy(task);
                task.run_callback(task.data);
            }

            fn cancel(raw: ?*anyopaque) void {
                const task: *Task = @ptrCast(@alignCast(raw.?));
                defer std.heap.c_allocator.destroy(task);
                task.cancel_callback(task.data);
            }
        };

        // Accepted native tasks hold a state lease through the owner turn. After admission closes, Hermes runs mandatory agent disposal through its AsyncDebugger queue when the native API is destroyed.
        fn enqueue(run: Callback, cancel: Callback, data: ?*anyopaque, user: ?*anyopaque) callconv(.c) bool {
            const state: *InspectorState = @ptrCast(@alignCast(user.?));
            const task = std.heap.c_allocator.create(Task) catch return false;
            task.* = .{ .run_callback = run, .cancel_callback = cancel, .data = data };
            if (!state_mod.postInspectorBoundaryTask(state, .{
                .ctx = task,
                .run = Task.run,
                .cancel = Task.cancel,
                .owner = state,
            })) {
                std.heap.c_allocator.destroy(task);
                return false;
            }
            return true;
        }

        fn emit(session_id: u64, json: [*]const u8, len: usize, user: ?*anyopaque) callconv(.c) void {
            const state: *InspectorState = @ptrCast(@alignCast(user.?));
            if (!state_mod.tryAcquireStateLease(state)) return;
            var frame: Host.dispatch.TaskOwnerFrame = undefined;
            Host.dispatch.enterTaskOwnerFrame(&frame, state.instance_id, state);
            defer {
                Host.dispatch.leaveTaskOwnerFrame(&frame);
                state_mod.releaseStateLease(state);
            }
            if (state_mod.hasSession(state, session_id)) _ = state.transport.sendText(session_id, json[0..len]);
        }

        // Native Hermes invokes this only from its dedicated sender thread, after it has stopped accepting replies for the session. The transport owns the matching session_closed callback, which retires the native agent outside Hermes' outbound callback mutex.
        fn close(session_id: u64, user: ?*anyopaque) callconv(.c) void {
            const state: *InspectorState = @ptrCast(@alignCast(user.?));
            if (!state_mod.tryAcquireStateLease(state)) return;
            var frame: Host.dispatch.TaskOwnerFrame = undefined;
            Host.dispatch.enterTaskOwnerFrame(&frame, state.instance_id, state);
            defer {
                Host.dispatch.leaveTaskOwnerFrame(&frame);
                state_mod.releaseStateLease(state);
            }
            if (state_mod.hasSession(state, session_id)) state.transport.closeSession(session_id);
        }

        pub fn start(state: *InspectorState) bool {
            if (comptime !enabled) return true;
            const ctx = Host.engine.getContext(state.instance_id) orelse return false;
            state.native_debugger = api.hermes_inspector_start(ctx, state.instance_id, emit, close, enqueue, state, parseMessage) orelse return false;
            return true;
        }

        pub fn sessionOpened(state: *InspectorState, session_id: u64) bool {
            if (comptime !enabled) return true;
            return api.hermes_inspector_session_open(@ptrCast(state.native_debugger), session_id);
        }

        pub fn sessionClosed(state: *InspectorState, session_id: u64) void {
            if (comptime !enabled) return;
            api.hermes_inspector_session_close(@ptrCast(state.native_debugger), session_id);
        }

        pub fn handle(state: *InspectorState, session_id: u64, request_id: i64, method: []const u8, text: []const u8) bool {
            if (comptime !enabled) return false;
            // Keep every engine-owned object handle in the native agent's namespace, including values returned by paused-frame evaluation.
            if (!std.mem.startsWith(u8, method, "Runtime.") and !std.mem.startsWith(u8, method, "Debugger.") and !std.mem.startsWith(u8, method, "Profiler.") and !std.mem.startsWith(u8, method, "HeapProfiler.")) return false;
            if (!api.hermes_inspector_message(@ptrCast(state.native_debugger), session_id, text.ptr, text.len)) {
                json_writer.sendError(state, session_id, request_id, -32000, "Native debugger rejected the command");
            }
            return true;
        }

        pub fn closeSessions(state: *InspectorState) void {
            if (comptime !enabled) return;
            if (state.native_debugger) |native| api.hermes_inspector_close_sessions(@ptrCast(native));
        }

        pub fn stop(state: *InspectorState) void {
            if (comptime !enabled) return;
            if (state.native_debugger) |native| {
                closeSessions(state);
                Host.dispatch.releaseTasksForOwner(state.instance_id, state);
                api.hermes_inspector_stop(@ptrCast(native));
                Host.dispatch.releaseTasksForOwner(state.instance_id, state);
                state.native_debugger = null;
            }
        }
    };
}
