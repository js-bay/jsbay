pub fn Module(comptime Host: type) type {
    // Chrome DevTools Protocol Debugger domain.
    //
    // Breakpoints, stepping, and script lookup are answered on the reader thread. Stack capture and `Debugger.evaluateOnCallFrame` run on the engine thread: while paused that thread is inside the location hook and drains posted tasks, so the live stack is still there.

    return struct {
        const std = @import("std");
        const async_stack = Host.async_stack;
        const backend = Host.backend;
        const debugger_mod = Host.debugger;
        const dispatch = Host.dispatch;
        const engine = Host.engine;
        const instance_map = Host.instance_map;
        const json_writer = @import("json_writer.zig").Module(Host);
        const remote_object = @import("remote_object.zig").Module(Host);
        const request_box = @import("request_box.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);
        const sync = Host.sync;
        const transport_mod = @import("transport.zig");

        const InspectorState = state_mod.InspectorState;
        const ActiveEngine = backend.ActiveEngine;
        const pause_group = "cdp-pause";

        var debugger_session_mutex: sync.Mutex = .{};

        fn setDebuggerSession(state: *InspectorState, session_id: transport_mod.SessionId, enabled: bool) void {
            debugger_session_mutex.lock();
            defer debugger_session_mutex.unlock();
            if (state_mod.isClosing(state)) {
                state_mod.setSessionDebuggerEnabled(state, session_id, false);
                debugger_mod.setDebuggerStatements(state.instance_id, false);
                debugger_mod.resumeExecution(state.instance_id);
                return;
            }
            state_mod.setSessionDebuggerEnabled(state, session_id, enabled);
            const has_debugger_session = state_mod.hasEnabledDebuggerSession(state);
            debugger_mod.setDebuggerStatements(state.instance_id, has_debugger_session);
            if (!has_debugger_session) debugger_mod.resumeExecution(state.instance_id);
        }

        // Atomically admit a queued enable with respect to session closure. The transport reader removes sessions under the same mutex, so a task that observes a live session here owns the only path that can attach native handlers for it.
        const EnableAdmission = enum {
            enabled,
            session_unavailable,
            attach_failed,
        };

        fn enableDebuggerSessionOnOwner(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            runtime: ?*anyopaque,
        ) EnableAdmission {
            debugger_session_mutex.lock();
            defer debugger_session_mutex.unlock();
            if (state_mod.isClosing(state) or !state_mod.hasSession(state, session_id)) return .session_unavailable;
            // Classic QuickJS and JSC have always acknowledged Debugger.enable while exposing no bytecode hooks. Preserve that protocol contract; only the NG hook backend needs a successful native attach before enabling.
            if (comptime backend.supportsDebugger(backend.active_backend)) {
                if (!debugger_mod.attach(state.instance_id, runtime orelse return .attach_failed)) return .attach_failed;
            }
            state_mod.setSessionDebuggerEnabled(state, session_id, true);
            const has_debugger_session = state_mod.hasEnabledDebuggerSession(state);
            debugger_mod.setDebuggerStatements(state.instance_id, has_debugger_session);
            return .enabled;
        }

        fn prepareDebuggerConfiguration(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) bool {
            if (comptime backend.supportsDebugger(backend.active_backend)) {
                if (!debugger_mod.prepare(state.instance_id)) {
                    json_writer.sendError(state, session_id, request_id, -32000, "Unable to prepare debugger configuration");
                    return false;
                }
            }
            return true;
        }

        fn disableNeedsOwnerTurn(state: *InspectorState) bool {
            return async_stack.depth(state.instance_id) != 0 or
                state_mod.hasPendingAsyncDepthReconciliationForState(state) or
                state_mod.hasInspectorTasks(state);
        }

        pub fn sessionClosed(state: *InspectorState, session_id: transport_mod.SessionId) void {
            debugger_session_mutex.lock();
            defer debugger_session_mutex.unlock();
            const removal = state_mod.removeSessionAndMarkReconciliation(state, session_id);
            if (state_mod.isClosing(state)) {
                debugger_mod.setDebuggerStatements(state.instance_id, false);
                debugger_mod.resumeExecution(state.instance_id);
                return;
            }
            const has_debugger_session = state_mod.hasEnabledDebuggerSession(state);
            debugger_mod.setDebuggerStatements(state.instance_id, has_debugger_session);
            if (!has_debugger_session) {
                debugger_mod.resumeExecution(state.instance_id);
            }
            if (removal.removed) {
                const post_failed = Host.test_faults.take(state.instance_id, .debugger_reconcile_post);
                scheduleAsyncDepthReconcile(state, post_failed);
            }
        }

        pub fn stopInstance(state: *InspectorState) void {
            debugger_session_mutex.lock();
            defer debugger_session_mutex.unlock();
            debugger_mod.setDebuggerStatements(state.instance_id, false);
            debugger_mod.resumeExecution(state.instance_id);
            // Inspector finalization also clears the backend state directly. Marking this here makes an already-running owner tick cool a stopped listener even when a transport callback raced with shutdown.
            state.mutex.lock();
            state.debugger_cooldown_pending = true;
            state_mod.markAsyncDepthReconcilePendingLocked(state);
            for (state.sessions.items) |*session| session.async_stack_depth = 0;
            state.mutex.unlock();
            scheduleAsyncDepthReconcile(state, false);
        }

        // A static task avoids an allocator failure dropping the last-session cool down. If dispatch cannot create its queue, the pending bit remains set and `dispatch.tickInstance` or the next owner admission will reconcile both debugger hooks and async depth.
        fn reconcileAsyncDepthTask(raw: ?*anyopaque) void {
            const state: *InspectorState = @ptrCast(@alignCast(raw.?));
            reconcilePendingAsyncDepthForState(state);
        }

        fn scheduleAsyncDepthReconcile(state: *InspectorState, debugger_post_failed: bool) void {
            // Exercise allocation-free owner recovery when debugger reconciliation or the async-depth post fails; the pending state must remain available.
            if (debugger_post_failed or
                Host.test_faults.take(state.instance_id, .async_depth_reconcile_post)) return;
            _ = state_mod.postInspectorTask(state, .{ .ctx = state, .run = reconcileAsyncDepthTask });
        }

        fn reconcilePendingAsyncDepthForState(state: *InspectorState) void {
            const pending = state_mod.takePendingAsyncStackDepth(state) orelse return;
            // Re-read sessions on the owner. A late static task for an old state can only cool its own instance, and never detaches an active debugger.
            if (pending.debugger_cooldown and !state_mod.hasEnabledDebuggerSession(state)) debugger_mod.coolDown(state.instance_id);
            const instance = instance_map.getInstance(state.instance_id) orelse return;
            setAsyncStackDepthOnOwner(state.instance_id, instance.monoRuntime().?, pending.depth);
        }

        // Called by the per-instance owner tick as the allocation-free fallback for a session-close reconciliation that could not be posted from the transport thread. It is harmless when no inspector or no change is pending.
        pub fn reconcilePendingAsyncDepthOnOwner(instance_id: i32) void {
            if (!state_mod.hasPendingAsyncDepthReconciliation()) return;
            const state = state_mod.stateByInstance(instance_id) orelse return;
            reconcilePendingAsyncDepthForState(state);
        }

        pub fn handle(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            method: []const u8,
            root: std.json.Value,
        ) bool {
            debugger_mod.setHooks(onPause, onScript);
            if (comptime !backend.supportsDebugger(backend.active_backend)) {
                if (requiresDebuggerHooks(method)) {
                    json_writer.sendError(state, session_id, request_id, -32000, "Debugger command is unavailable for this backend");
                    return true;
                }
            }
            if (std.mem.eql(u8, method, "Debugger.enable")) {
                if (comptime backend.supportsDebugger(backend.active_backend)) {
                    scheduleEnable(state, session_id, request_id);
                } else if (disableNeedsOwnerTurn(state)) {
                    // A preceding disable owns a queued reconciliation. Keep the following enable behind it so an older task cannot turn this session back off after its response has been sent.
                    scheduleEnable(state, session_id, request_id);
                } else switch (enableDebuggerSessionOnOwner(state, session_id, null)) {
                    .enabled => {
                        json_writer.sendDebuggerEnabled(state, session_id, request_id);
                        replayScripts(state, session_id);
                    },
                    .session_unavailable => json_writer.sendError(state, session_id, request_id, -32000, "Debugger session is not available"),
                    .attach_failed => unreachable,
                }
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.disable")) {
                if (comptime backend.supportsDebugger(backend.active_backend)) {
                    scheduleDisable(state, session_id, request_id);
                } else if (disableNeedsOwnerTurn(state)) {
                    scheduleDisable(state, session_id, request_id);
                } else {
                    setDebuggerSession(state, session_id, false);
                    _ = state_mod.clearSessionAsyncStackDepth(state, session_id);
                    scheduleAsyncDepthReconcile(state, false);
                    json_writer.sendEmptyResult(state, session_id, request_id);
                }
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.setBreakpointByUrl")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const url = stringField(params, "url");
                const url_regex = stringField(params, "urlRegex");
                const pattern = url orelse url_regex orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "url");
                    return true;
                };
                const line0 = intField(params, "lineNumber") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "lineNumber");
                    return true;
                };
                const column0: i32 = @intCast(intField(params, "columnNumber") orelse 0);
                const condition = stringField(params, "condition") orelse "";
                if (!prepareDebuggerConfiguration(state, session_id, request_id)) return true;
                const id = debugger_mod.setBreakpointEx(
                    state.instance_id,
                    pattern,
                    @intCast(line0 + 1),
                    column0,
                    url == null,
                    condition,
                );
                if (id == 0) {
                    json_writer.sendInvalidParams(state, session_id, request_id, "breakpoint");
                    return true;
                }
                const found = debugger_mod.locationsForId(state.instance_id, id);
                defer std.heap.c_allocator.free(found);
                const locations = state.allocator.alloc(json_writer.BreakLocationJson, found.len) catch {
                    json_writer.sendBreakpointResult(state, session_id, request_id, id, &.{});
                    return true;
                };
                defer state.allocator.free(locations);
                for (found, 0..) |item, i| {
                    locations[i] = .{
                        .script_id = item.script_id,
                        .line = item.line,
                        .column = item.column,
                    };
                }
                json_writer.sendBreakpointResult(state, session_id, request_id, id, locations);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.removeBreakpoint")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const raw = stringField(params, "breakpointId") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "breakpointId");
                    return true;
                };
                const id = std.fmt.parseInt(u32, raw, 10) catch 0;
                _ = debugger_mod.removeBreakpoint(state.instance_id, id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.getPossibleBreakpoints")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                if (params.get("restrictToFunction")) |value| {
                    if (value != .bool) {
                        json_writer.sendInvalidParams(state, session_id, request_id, "restrictToFunction");
                        return true;
                    }
                    if (!value.bool) {
                        // `false` is the protocol default and is equivalent to omitting it.
                    } else {
                        json_writer.sendError(state, session_id, request_id, -32000, "restrictToFunction is unavailable: QuickJS-NG does not expose stable function ranges");
                        return true;
                    }
                }
                const start = locationParams(params, "start") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "start");
                    return true;
                };
                const end = if (params.get("end") != null)
                    locationParams(params, "end") orelse {
                        json_writer.sendInvalidParams(state, session_id, request_id, "end");
                        return true;
                    }
                else blk: {
                    const script = debugger_mod.scriptById(state.instance_id, start.script_id) orelse {
                        json_writer.sendInvalidParams(state, session_id, request_id, "start.scriptId");
                        return true;
                    };
                    defer debugger_mod.freeScriptInfo(script);
                    break :blk LocationParams{
                        .script_id = start.script_id,
                        .line = script.end_line,
                        .column = script.end_column,
                    };
                };
                if (start.script_id != end.script_id) {
                    json_writer.sendInvalidParams(state, session_id, request_id, "start and end scriptId must match");
                    return true;
                }
                const found = debugger_mod.possibleBreakpoints(
                    state.instance_id,
                    start.script_id,
                    start.line,
                    start.column,
                    end.line,
                    end.column,
                ) catch |err| {
                    const message = switch (err) {
                        error.ScriptUnknown => "unknown scriptId",
                        error.LocationsUnavailable => "possible breakpoint locations are unavailable for this script",
                        error.LocationsTruncated => "possible breakpoint location collection exceeded its bounded budget",
                    };
                    json_writer.sendError(state, session_id, request_id, -32000, message);
                    return true;
                };
                defer std.heap.c_allocator.free(found);
                const locations = state.allocator.alloc(json_writer.BreakLocationJson, found.len) catch {
                    json_writer.sendError(state, session_id, request_id, -32000, "out of memory while encoding possible breakpoint locations");
                    return true;
                };
                defer state.allocator.free(locations);
                for (found, 0..) |item, i| locations[i] = .{
                    .script_id = item.script_id,
                    .line = item.line,
                    .column = item.column,
                };
                json_writer.sendPossibleBreakpoints(state, session_id, request_id, locations);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.getScriptSource")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const raw = stringField(params, "scriptId") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "scriptId");
                    return true;
                };
                const id = std.fmt.parseInt(u32, raw, 10) catch 0;
                const script = debugger_mod.scriptById(state.instance_id, id) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "scriptId");
                    return true;
                };
                defer debugger_mod.freeScriptInfo(script);
                json_writer.sendScriptSource(state, session_id, request_id, script.source);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.resume")) {
                debugger_mod.resumeExecution(state.instance_id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                sendResumed(state);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.stepInto")) {
                debugger_mod.stepIn(state.instance_id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                sendResumed(state);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.stepOver")) {
                debugger_mod.stepOver(state.instance_id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                sendResumed(state);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.stepOut")) {
                debugger_mod.stepOut(state.instance_id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                sendResumed(state);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.pause")) {
                debugger_mod.requestPause(state.instance_id);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.setBlackboxPatterns")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const patterns = stringArrayField(params, "patterns") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "patterns");
                    return true;
                };
                defer std.heap.c_allocator.free(patterns);
                if (!prepareDebuggerConfiguration(state, session_id, request_id)) return true;
                debugger_mod.setBlackboxPatterns(state.instance_id, patterns);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.setAsyncCallStackDepth")) {
                const params = objectParams(root);
                const raw = if (params) |p| intField(p, "maxDepth") orelse 0 else 0;
                const depth: u32 = if (raw <= 0) 0 else @intCast(@min(raw, 8));
                scheduleAsyncStackDepth(state, session_id, request_id, depth);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.setBreakpointsActive")) {
                const params = objectParams(root);
                const active = if (params) |p| boolField(p, "active") orelse true else true;
                if (!prepareDebuggerConfiguration(state, session_id, request_id)) return true;
                debugger_mod.setBreakpointsActive(state.instance_id, active);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.setSkipAllPauses")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const skip = boolField(params, "skip") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "skip");
                    return true;
                };
                if (!prepareDebuggerConfiguration(state, session_id, request_id)) return true;
                debugger_mod.setSkipAllPauses(state.instance_id, skip);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.setPauseOnExceptions")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const mode_name = stringField(params, "state") orelse "none";
                const mode: debugger_mod.ExceptionPause = if (std.mem.eql(u8, mode_name, "all"))
                    .all
                else if (std.mem.eql(u8, mode_name, "uncaught"))
                    .uncaught
                else
                    .none;
                if (!prepareDebuggerConfiguration(state, session_id, request_id)) return true;
                debugger_mod.setExceptionPause(state.instance_id, mode);
                json_writer.sendEmptyResult(state, session_id, request_id);
                return true;
            }
            if (std.mem.eql(u8, method, "Debugger.evaluateOnCallFrame")) {
                const params = objectParams(root) orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "params");
                    return true;
                };
                const expression = stringField(params, "expression") orelse {
                    json_writer.sendInvalidParams(state, session_id, request_id, "expression");
                    return true;
                };
                const frame_raw = stringField(params, "callFrameId") orelse "0";
                const frame_index = std.fmt.parseInt(i32, frame_raw, 10) catch 0;
                if (!debugger_mod.isPaused(state.instance_id)) {
                    json_writer.sendInvalidParams(state, session_id, request_id, "callFrameId");
                    return true;
                }
                const box = state.allocator.create(request_box.RequestBox) catch return true;
                box.* = .{
                    .state = state,
                    .session_id = session_id,
                    .request_id = request_id,
                    .run_fn = runEvalOnCallFrame,
                    .expression = state.allocator.dupe(u8, expression) catch &.{},
                    .frame_index = frame_index,
                };
                if (stringField(params, "objectGroup")) |group| {
                    box.object_group = state.allocator.dupe(u8, group) catch &.{};
                }
                if (!request_box.postJsRequest(state, box)) {
                    request_box.freeRequestBox(state.allocator, box);
                    json_writer.sendInvalidParams(state, session_id, request_id, "paused");
                }
                return true;
            }
            return false;
        }

        const AsyncStackDepthTask = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,
            depth: u32,

            fn run(raw: ?*anyopaque) void {
                const task: *AsyncStackDepthTask = @ptrCast(@alignCast(raw.?));
                defer task.state.allocator.destroy(task);
                if (!state_mod.setSessionAsyncStackDepth(task.state, task.session_id, task.depth)) {
                    json_writer.sendError(task.state, task.session_id, task.request_id, -32000, "Debugger session is not available");
                    return;
                }
                const instance = instance_map.getInstance(task.state.instance_id) orelse {
                    json_writer.sendError(task.state, task.session_id, task.request_id, -32000, "Engine is not available");
                    return;
                };
                _ = instance;
                reconcilePendingAsyncDepthForState(task.state);
                json_writer.sendEmptyResult(task.state, task.session_id, task.request_id);
            }

            fn cancel(raw: ?*anyopaque) void {
                const task: *AsyncStackDepthTask = @ptrCast(@alignCast(raw.?));
                task.state.allocator.destroy(task);
            }
        };

        // Owner-thread-only counterpart used by Inspector teardown as well as the CDP task. Keeping all depth transitions here ensures a stopped Inspector cannot leave a QuickJS native job callback armed.
        pub fn clearAsyncStackDepthOnOwner(instance_id: i32, runtime: backend.ActiveEngine.Runtime) void {
            setAsyncStackDepthOnOwner(instance_id, runtime, 0);
        }

        fn setAsyncStackDepthOnOwner(instance_id: i32, runtime: backend.ActiveEngine.Runtime, depth: u32) void {
            switch (backend.active_backend) {
                .quickjs => Host.quickjs_jobs.setAsyncStackDepth(runtime, instance_id, depth),
                .quickjs_ng => Host.quickjs_ng_jobs.setAsyncStackDepth(runtime, instance_id, depth),
                .jsc => {
                    const ctx = Host.engine.getContext(instance_id) orelse return;
                    Host.jsc_async_hooks.setDepth(ctx, instance_id, depth);
                },
            }
        }

        fn scheduleAsyncStackDepth(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64, depth: u32) void {
            const task = state.allocator.create(AsyncStackDepthTask) catch {
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to schedule Debugger.setAsyncCallStackDepth");
                return;
            };
            task.* = .{ .state = state, .session_id = session_id, .request_id = request_id, .depth = depth };
            if (!state_mod.postInspectorTask(state, .{ .ctx = task, .run = AsyncStackDepthTask.run, .cancel = AsyncStackDepthTask.cancel })) {
                state.allocator.destroy(task);
                json_writer.sendError(state, session_id, request_id, -32000, "Debugger is closing");
            }
        }

        const EnableTask = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,

            fn run(raw: ?*anyopaque) void {
                const task: *EnableTask = @ptrCast(@alignCast(raw.?));
                defer task.state.allocator.destroy(task);
                const instance = instance_map.getInstance(task.state.instance_id) orelse {
                    json_writer.sendError(task.state, task.session_id, task.request_id, -32000, "Engine is not available");
                    return;
                };
                switch (enableDebuggerSessionOnOwner(task.state, task.session_id, @ptrCast(@constCast(instance.monoRuntime().?)))) {
                    .enabled => {},
                    .session_unavailable => {
                        json_writer.sendError(task.state, task.session_id, task.request_id, -32000, "Debugger session is not available");
                        return;
                    },
                    .attach_failed => {
                        json_writer.sendError(task.state, task.session_id, task.request_id, -32000, "Unable to initialize debugger");
                        return;
                    },
                }
                json_writer.sendDebuggerEnabled(task.state, task.session_id, task.request_id);
                replayScripts(task.state, task.session_id);
            }

            fn cancel(raw: ?*anyopaque) void {
                const task: *EnableTask = @ptrCast(@alignCast(raw.?));
                task.state.allocator.destroy(task);
            }
        };

        fn scheduleEnable(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            // Subsequent reader-thread configuration may arrive before this task gets an owner turn. Keep it in a dormant binding without touching the native runtime; EnableTask performs the only attach after admission.
            if (comptime backend.supportsDebugger(backend.active_backend)) {
                if (!debugger_mod.prepare(state.instance_id)) {
                    json_writer.sendError(state, session_id, request_id, -32000, "Unable to prepare debugger configuration");
                    return;
                }
            }
            const task = state.allocator.create(EnableTask) catch {
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to schedule Debugger.enable");
                return;
            };
            task.* = .{ .state = state, .session_id = session_id, .request_id = request_id };
            if (!state_mod.postInspectorTask(state, .{ .ctx = task, .run = EnableTask.run, .cancel = EnableTask.cancel })) {
                state.allocator.destroy(task);
                json_writer.sendError(state, session_id, request_id, -32000, "Debugger is closing");
            }
        }

        const DisableTask = struct {
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            request_id: i64,

            fn run(raw: ?*anyopaque) void {
                const task: *DisableTask = @ptrCast(@alignCast(raw.?));
                defer task.state.allocator.destroy(task);
                setDebuggerSession(task.state, task.session_id, false);
                _ = state_mod.clearSessionAsyncStackDepth(task.state, task.session_id);
                reconcilePendingAsyncDepthForState(task.state);
                if (!state_mod.hasEnabledDebuggerSession(task.state)) debugger_mod.coolDown(task.state.instance_id);
                json_writer.sendEmptyResult(task.state, task.session_id, task.request_id);
            }

            fn cancel(raw: ?*anyopaque) void {
                const task: *DisableTask = @ptrCast(@alignCast(raw.?));
                task.state.allocator.destroy(task);
            }
        };

        fn scheduleDisable(state: *InspectorState, session_id: transport_mod.SessionId, request_id: i64) void {
            const task = state.allocator.create(DisableTask) catch {
                json_writer.sendError(state, session_id, request_id, -32000, "Unable to schedule Debugger.disable");
                return;
            };
            task.* = .{ .state = state, .session_id = session_id, .request_id = request_id };
            if (!state_mod.postInspectorTask(state, .{ .ctx = task, .run = DisableTask.run, .cancel = DisableTask.cancel })) {
                state.allocator.destroy(task);
                json_writer.sendError(state, session_id, request_id, -32000, "Debugger is closing");
            }
        }

        fn requiresDebuggerHooks(method: []const u8) bool {
            const methods = [_][]const u8{
                "Debugger.setBreakpointByUrl",
                "Debugger.removeBreakpoint",
                "Debugger.getPossibleBreakpoints",
                "Debugger.getScriptSource",
                "Debugger.resume",
                "Debugger.stepInto",
                "Debugger.stepOver",
                "Debugger.stepOut",
                "Debugger.pause",
                "Debugger.setBlackboxPatterns",
                "Debugger.setBreakpointsActive",
                "Debugger.setSkipAllPauses",
                "Debugger.setPauseOnExceptions",
                "Debugger.evaluateOnCallFrame",
            };
            for (methods) |candidate| {
                if (std.mem.eql(u8, method, candidate)) return true;
            }
            return false;
        }

        fn replayScripts(state: *InspectorState, session_id: transport_mod.SessionId) void {
            const scripts = debugger_mod.snapshotScripts(state.instance_id);
            defer debugger_mod.freeScriptSnapshot(scripts);
            for (scripts) |script| {
                json_writer.sendScriptParsed(
                    state,
                    session_id,
                    script.id,
                    script.url,
                    script.end_line,
                    script.end_column,
                    script.hash,
                    script.source_map_url,
                );
                const hits = debugger_mod.breakpointsOnScript(state.instance_id, script.id);
                defer std.heap.c_allocator.free(hits);
                for (hits) |hit| {
                    json_writer.sendBreakpointResolved(
                        state,
                        session_id,
                        hit.breakpoint_id,
                        hit.script_id,
                        hit.line,
                        hit.column,
                    );
                }
            }
        }

        fn sendResumed(state: *InspectorState) void {
            var sessions: std.ArrayList(transport_mod.SessionId) = .empty;
            defer sessions.deinit(state.allocator);
            state_mod.snapshotDebuggerSessions(state, &sessions);
            for (sessions.items) |session_id| {
                json_writer.sendDebuggerResumed(state, session_id);
            }
        }

        fn onPause(instance_id: i32, info: debugger_mod.PauseInfo) void {
            const state = state_mod.acquireStateLeaseByInstance(instance_id) orelse return;
            defer state_mod.releaseStateLease(state);
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, instance_id, state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            const ctx = Host.engine.getContext(instance_id) orelse return;
            _ = state.object_table.releaseGroup(ctx, pause_group);

            const stack = debugger_mod.copyDebugStack(instance_id);
            defer {
                for (stack) |frame| {
                    std.heap.c_allocator.free(frame.name);
                    std.heap.c_allocator.free(frame.url);
                }
                std.heap.c_allocator.free(stack);
            }

            const frames = state.allocator.alloc(json_writer.PausedFrame, stack.len) catch return;
            defer state.allocator.free(frames);
            for (stack, 0..) |frame, i| {
                const local = retainScope(state, ctx, instance_id, @intCast(i), 0);
                const closure = retainScope(state, ctx, instance_id, @intCast(i), 1);
                const global = retainScope(state, ctx, instance_id, @intCast(i), 2);
                const this_id = retainThis(state, ctx, instance_id, @intCast(i)) orelse global;
                const script_id = debugger_mod.scriptIdForTag(instance_id, frame.script_tag);
                frames[i] = .{
                    .call_frame_id = @intCast(i),
                    .function_name = frame.name,
                    .script_id = script_id,
                    .url = frame.url,
                    .line = frame.line,
                    .column = frame.column,
                    .local_id = local,
                    .closure_id = closure,
                    .global_id = global,
                    .this_id = this_id,
                };
            }

            const reason = switch (info.reason) {
                .breakpoint => "other",
                .step => "step",
                .exception => "exception",
                .other => "other",
            };
            var sessions: std.ArrayList(transport_mod.SessionId) = .empty;
            defer sessions.deinit(state.allocator);
            state_mod.snapshotDebuggerSessions(state, &sessions);
            for (sessions.items) |session_id| {
                json_writer.sendDebuggerPaused(state, session_id, reason, frames);
            }
        }

        fn retainThis(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            instance_id: i32,
            frame_index: i32,
        ) ?u64 {
            const value = debugger_mod.copyDebugThis(instance_id, frame_index) orelse return null;
            const id = state.object_table.retain(ctx, value, pause_group) orelse {
                ActiveEngine.freeValue(ctx, value);
                return null;
            };
            ActiveEngine.freeValue(ctx, value);
            if (id == state_mod.ObjectTable.invalid_id) return null;
            return id;
        }

        fn retainScope(
            state: *InspectorState,
            ctx: ActiveEngine.Context,
            instance_id: i32,
            frame_index: i32,
            scope: u8,
        ) u64 {
            const value = debugger_mod.copyDebugScope(instance_id, frame_index, scope) orelse return state_mod.ObjectTable.invalid_id;
            const id = state.object_table.retain(ctx, value, pause_group) orelse {
                ActiveEngine.freeValue(ctx, value);
                return state_mod.ObjectTable.invalid_id;
            };
            ActiveEngine.freeValue(ctx, value);
            return id;
        }

        fn onScript(instance_id: i32, info: debugger_mod.ScriptInfo) void {
            const state = state_mod.acquireStateLeaseByInstance(instance_id) orelse return;
            defer state_mod.releaseStateLease(state);
            var owner_frame: dispatch.TaskOwnerFrame = undefined;
            dispatch.enterTaskOwnerFrame(&owner_frame, instance_id, state);
            defer dispatch.leaveTaskOwnerFrame(&owner_frame);
            var sessions: std.ArrayList(transport_mod.SessionId) = .empty;
            defer sessions.deinit(state.allocator);
            state_mod.snapshotDebuggerSessions(state, &sessions);
            for (sessions.items) |session_id| {
                json_writer.sendScriptParsed(
                    state,
                    session_id,
                    info.id,
                    info.url,
                    info.end_line,
                    info.end_column,
                    info.hash,
                    info.source_map_url,
                );
            }
            const hits = debugger_mod.breakpointsOnScript(instance_id, info.id);
            defer std.heap.c_allocator.free(hits);
            for (sessions.items) |session_id| {
                for (hits) |hit| {
                    json_writer.sendBreakpointResolved(
                        state,
                        session_id,
                        hit.breakpoint_id,
                        hit.script_id,
                        hit.line,
                        hit.column,
                    );
                }
            }
        }

        fn runEvalOnCallFrame(box: *request_box.RequestBox, ctx: ActiveEngine.Context) void {
            if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) {
                json_writer.sendInvalidParams(box.state, box.session_id, box.request_id, "paused");
                return;
            }
            if (!debugger_mod.isPaused(box.state.instance_id)) {
                json_writer.sendInvalidParams(box.state, box.session_id, box.request_id, "paused");
                return;
            }
            const qjs = Host.backend.ActiveEngineModule.c_api.qjs;
            const value = qjs.JS_EvalInDebugFrame(ctx, box.frame_index, box.expression.ptr, box.expression.len);
            if (value.tag == Host.backend.ActiveEngineModule.qjs.JS_TAG_EXCEPTION) {
                const thrown = qjs.JS_GetException(ctx);
                const text = ActiveEngine.valueToString(ctx, thrown) orelse "exception";
                const owned = text;
                remote_object.sendEvalException(box.state, box.session_id, box.request_id, owned);
                if (owned.ptr != "exception".ptr) std.heap.c_allocator.free(@constCast(owned));
                ActiveEngine.freeValue(ctx, thrown);
                return;
            }
            var aw: std.Io.Writer.Allocating = .init(box.state.allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.print("{{\"id\":{d},\"result\":{{\"result\":", .{box.request_id}) catch {
                ActiveEngine.freeValue(ctx, value);
                return;
            };
            const group: ?[]const u8 = if (box.object_group.len == 0) null else box.object_group;
            remote_object.writeRemoteObject(box.state, ctx, w, value, group) catch {
                ActiveEngine.freeValue(ctx, value);
                return;
            };
            ActiveEngine.freeValue(ctx, value);
            w.writeAll("}}") catch return;
            json_writer.sendJson(box.state, box.session_id, aw.written());
        }

        fn objectParams(root: std.json.Value) ?std.json.ObjectMap {
            if (root != .object) return null;
            const params = root.object.get("params") orelse return null;
            if (params != .object) return null;
            return params.object;
        }

        fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
            const value = object.get(name) orelse return null;
            if (value != .string) return null;
            return value.string;
        }

        fn intField(object: std.json.ObjectMap, name: []const u8) ?i64 {
            const value = object.get(name) orelse return null;
            return switch (value) {
                .integer => |n| n,
                .float => |n| @intFromFloat(n),
                else => null,
            };
        }

        const LocationParams = struct {
            script_id: u32,
            line: i32,
            column: i32,
        };

        fn locationParams(params: std.json.ObjectMap, name: []const u8) ?LocationParams {
            const value = params.get(name) orelse return null;
            if (value != .object) return null;
            const object = value.object;
            const raw_script_id = stringField(object, "scriptId") orelse return null;
            const script_id = std.fmt.parseInt(u32, raw_script_id, 10) catch return null;
            const raw_line = nonnegativeI32Field(object, "lineNumber") orelse return null;
            const raw_column = if (object.get("columnNumber") != null)
                nonnegativeI32Field(object, "columnNumber") orelse return null
            else
                0;
            return .{
                .script_id = script_id,
                .line = raw_line,
                .column = raw_column,
            };
        }

        fn nonnegativeI32Field(object: std.json.ObjectMap, name: []const u8) ?i32 {
            const value = object.get(name) orelse return null;
            const raw = switch (value) {
                .integer => |n| n,
                else => return null,
            };
            if (raw < 0 or raw > std.math.maxInt(i32)) return null;
            return @intCast(raw);
        }

        fn boolField(object: std.json.ObjectMap, name: []const u8) ?bool {
            const value = object.get(name) orelse return null;
            if (value != .bool) return null;
            return value.bool;
        }

        fn stringArrayField(object: std.json.ObjectMap, name: []const u8) ?[]const []const u8 {
            const value = object.get(name) orelse return null;
            if (value != .array) return null;
            var list: std.ArrayList([]const u8) = .empty;
            for (value.array.items) |item| {
                if (item != .string) continue;
                list.append(std.heap.c_allocator, item.string) catch {};
            }
            return list.toOwnedSlice(std.heap.c_allocator) catch null;
        }

        pub const TestCases = if (@import("builtin").is_test) struct {
            pub fn debuggerEnableCannotReopenGateAfterClosingBegins() !void {
                const testing = std.testing;
                if (comptime !backend.supportsDebugger(backend.active_backend)) return;
                const instance_id: i32 = 1_987_654_321;
                try testing.expect(engine.create(instance_id, .{}));
                defer engine.destroy(instance_id);
                const instance = instance_map.getInstance(instance_id) orelse return error.MissingEngine;
                _ = debugger_mod.attach(instance_id, @ptrCast(@constCast(instance.monoRuntime().?)));

                var state = InspectorState{
                    .instance_id = instance_id,
                    .allocator = std.heap.c_allocator,
                    .transport = undefined,
                    .title = &.{},
                    .url = &.{},
                    .target_id = &.{},
                    .sessions = .empty,
                    .object_table = state_mod.ObjectTable.init(std.heap.c_allocator),
                };
                defer state.sessions.deinit(std.heap.c_allocator);
                defer state.deinitSynchronization();
                defer state.object_table.deinit(engine.getContext(instance_id));
                _ = state_mod.addSession(&state, 1);

                setDebuggerSession(&state, 1, true);
                try testing.expect(debugger_mod.debuggerStatementsEnabled(instance_id));
                state_mod.beginClosing(&state);
                stopInstance(&state);
                setDebuggerSession(&state, 1, true);
                try testing.expect(!debugger_mod.debuggerStatementsEnabled(instance_id));
                try testing.expect(!state_mod.hasEnabledDebuggerSession(&state));
            }
        } else struct {};
    };
}
