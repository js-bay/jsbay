pub fn Module(comptime Host: type) type {
    // Chrome DevTools Protocol inspector using host-provided engine services and a message transport. HTTP/WebSocket is an optional external implementation.
    //
    // This layer speaks CDP: it parses `{"id":N,"method":"...","params":{...}}` JSON-RPC messages from DevTools, fulfils a small set of Runtime/Debugger/ Log/Profiler methods, and pushes `Runtime.consoleAPICalled` events as the engine emits console output.
    //
    // ## Scope
    //
    // - Runtime: owner-thread evaluation, retained object inspection, console and exception events. QuickJS supports native Promise awaiting.
    // - Debugger: QuickJS-NG breakpoints, stepping, scope evaluation and bytecode source locations.
    // - Diagnostics: bounded QuickJS heap graphs and CPU samples; only measurable Performance counters are reported.
    // - Discovery: target id/title/url are registered with the transport so `chrome://inspect` can list the target.
    //
    // Discovery advertises backend/build-specific supported members. Browser DOM, CSS and networking are outside this runtime; compatibility acknowledgments do not indicate implementation of those domains.
    //
    // ## Thread model
    //
    // - `InspectorState` lives in a global `AutoHashMap(i32, *InspectorState)` behind `inspector_mutex` — same pattern as `tsfn.zig` / `console_tap.zig`.
    // - Transport event handlers run on host-selected threads. Commands that do not need JS execute there; evaluation is posted to the owning JS thread.
    // - Console tap runs on the JS thread. It formats + sends CDP events inline; `transport.sendText` is thread-safe so this is fine.
    // - We never hold `inspector_mutex` while calling `transport.sendText` — we copy out what we need, drop the lock, then send.
    //
    // ## Module layout
    //
    // This file is the public entry point only. Implementation is split:
    // - `state.zig` — `InspectorState`, sessions, global state table.
    // - `object_table.zig` — retained-object handle table.
    // - `json_writer.zig` — JSON-escape + fixed-shape reply emitters.
    // - `remote_object.zig` — CDP `RemoteObject` serializer + helpers.
    // - `request_box.zig` — JS-thread marshal pattern.
    // - `runtime_eval.zig` — `Runtime.evaluate` / `callFunctionOn`.
    // - `runtime_objects.zig` — `Runtime.getProperties` / `releaseObject` / `releaseObjectGroup`.
    // - `console.zig` — console tap → `Runtime.consoleAPICalled`.
    // - `dispatcher.zig` — message parse + method routing.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const console_tap = Host.console_tap;
        const dispatch = Host.dispatch;
        const engine = Host.engine;
        const engine_thread = Host.engine_thread;
        const transport_mod = @import("transport.zig");

        const console = @import("console.zig").Module(Host);
        const await_promise = @import("await_promise.zig").Module(Host);
        const dispatcher = @import("dispatcher.zig").Module(Host);
        const debugger_cdp = @import("debugger_cdp.zig").Module(Host);
        const object_table = @import("object_table.zig").Module(Host);
        const profiler = @import("profiler.zig").Module(Host);
        const runtime_objects = @import("runtime_objects.zig").Module(Host);
        const state_mod = @import("state.zig").Module(Host);
        const exceptions = @import("exceptions.zig").Module(Host);
        const json_writer = @import("json_writer.zig").Module(Host);

        const InspectorState = state_mod.InspectorState;

        pub const TestAllocationFailureStage = Host.test_faults.Stage;
        pub const testFailAllocationOnce = Host.test_faults.arm;

        var start_capture_hook_for_testing: ?*const fn (?*anyopaque) void = null;
        var start_cleanup_hook_for_testing: ?*const fn (?*anyopaque) void = null;
        var start_hooks_context_for_testing: ?*anyopaque = null;

        pub fn setStartHooksForTesting(
            capture_hook: ?*const fn (?*anyopaque) void,
            cleanup_hook: ?*const fn (?*anyopaque) void,
            context: ?*anyopaque,
        ) void {
            start_capture_hook_for_testing = capture_hook;
            start_cleanup_hook_for_testing = cleanup_hook;
            start_hooks_context_for_testing = context;
        }

        // ---------------------------------------------------------------------------
        // Public API
        // ---------------------------------------------------------------------------

        pub const StartOptions = struct {
            transport: *transport_mod.Transport,
            title: []const u8 = "js-bay",
            url: []const u8 = "file:///js-bay",
            target_id: ?[]const u8 = null,
        };

        pub const Handle = opaque {};

        pub const StartError = error{
            UnsupportedFeature,
            UnsupportedPlatform,
            AlreadyStarted,
            EngineThreadViolation,
            OutOfMemory,
            TransportStartFailed,
        };

        // Start an inspector server attached to `instance_id`. The caller must keep the engine alive until `stop` is called.
        pub fn start(instance_id: i32, opts: StartOptions) StartError!*Handle {
            const transport = opts.transport;
            if (comptime !Host.build_options.inspector) {
                transport.deinit();
                return error.UnsupportedFeature;
            }
            // Before `start` there cannot be an event callback. This branch covers early allocation/engine failures while preserving the ownership transfer contract.
            var transport_started = false;
            errdefer if (!transport_started) transport.deinit();
            const entry_lease = engine_thread.beginEval(instance_id);
            if (!entry_lease.allowed) return StartError.EngineThreadViolation;
            defer engine.finishEvalEntry(instance_id, entry_lease);
            if (!state_mod.reserveStart(instance_id)) return StartError.AlreadyStarted;
            var reservation_active = true;
            defer if (reservation_active) state_mod.cancelStartReservation(instance_id);

            const alloc = std.heap.c_allocator;

            const state = alloc.create(InspectorState) catch return StartError.OutOfMemory;
            errdefer alloc.destroy(state);
            const title = alloc.dupe(u8, opts.title) catch return StartError.OutOfMemory;
            errdefer alloc.free(title);
            const url = alloc.dupe(u8, opts.url) catch return StartError.OutOfMemory;
            errdefer alloc.free(url);

            state.* = .{
                .instance_id = instance_id,
                .allocator = alloc,
                .transport = undefined,
                .title = title,
                .url = url,
                .target_id = undefined,
                .sessions = .empty,
                .object_table = object_table.ObjectTable.init(alloc),
                .engine_thread_id = .init(@intCast(std.Thread.getCurrentId())),
            };
            errdefer state.deinitSynchronization();
            errdefer state.object_table.deinit(engine.getContext(instance_id));
            errdefer state.sessions.deinit(alloc);
            var intrinsics_captured = false;
            errdefer if (intrinsics_captured) {
                if (start_cleanup_hook_for_testing) |hook| hook(start_hooks_context_for_testing);
                if (engine.getContext(instance_id)) |cleanup_ctx| runtime_objects.releaseRuntimeIntrinsics(cleanup_ctx, state);
            };

            // Target id: caller-supplied, else generate.
            if (opts.target_id) |tid| {
                state.target_id = alloc.dupe(u8, tid) catch return StartError.OutOfMemory;
            } else {
                state.target_id = state_mod.generateTargetId(alloc, instance_id) catch return StartError.OutOfMemory;
            }
            errdefer alloc.free(state.target_id);

            const runtime = engine.getRuntime(instance_id) orelse return StartError.EngineThreadViolation;
            if (!runtime_objects.captureRuntimeIntrinsicsFromFreshRealm(runtime, state)) return StartError.OutOfMemory;
            intrinsics_captured = true;
            if (start_capture_hook_for_testing) |hook| hook(start_hooks_context_for_testing);

            state.transport = transport;

            transport.setDiscoveryTarget(.{
                .title = state.title,
                .kind = "node",
                .url = state.url,
                .id = state.target_id,
            });

            // Register the state BEFORE starting the transport so the handler can already look itself up when the first connection arrives.
            if (!state_mod.registerReservedStart(instance_id, state)) return StartError.AlreadyStarted;
            errdefer _ = state_mod.removeStateByPtr(state);

            // Install the console tap so JS console output flows to DevTools.
            console_tap.setLeased(instance_id, state, console.consoleTapCallback, .{
                .acquire = state_mod.acquireTapLease,
                .release = state_mod.releaseTapLease,
            });
            errdefer console_tap.clear(instance_id);

            // Once start is entered, an implementation may have retained the callback even if it reports an error. This errdefer is later than every state cleanup, hence runs first and drains any task leases produced by its final session_closed callback.
            transport_started = true;
            errdefer rollbackStart(state);
            transport.start(state, dispatcher.transportEventHandler) catch {
                return StartError.TransportStartFailed;
            };

            if (!state_mod.activateReservedStart(instance_id, state)) return StartError.AlreadyStarted;
            reservation_active = false;

            if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
                if (engine.getContext(instance_id)) |ctx| backend.ActiveEngineModule.exception.ensureRejectionTracker(ctx);
            }

            return @ptrCast(state);
        }

        pub fn liveConsoleEntries() usize {
            if (comptime !Host.build_options.inspector) return 0;
            return state_mod.liveConsoleEntries();
        }

        // Stop the inspector, close sessions, join threads. A second call, or a call after `dropInstance`, does nothing.
        pub fn stop(handle: *Handle) void {
            if (comptime !Host.build_options.inspector) return;
            const state: *InspectorState = @ptrCast(@alignCast(handle));
            if (!state_mod.claimCloseByPtr(state)) return;
            releaseInspector(state);
        }

        fn releaseInspector(state: *InspectorState) void {
            debugger_cdp.stopInstance(state);
            await_promise.cancelState(state);
            console_tap.dropInstance(state.instance_id);
            dispatch.releaseTasksForOwner(state.instance_id, state);
            if (dispatch.isRunningTaskForOwner(state)) {
                // This can be a transport reader thread. Its final lease must resume normal owner/retire routing rather than calling the JS-thread-only finalizer directly.
                state_mod.deferFinalizationUntilLeasesReleased(state, resumeReleaseAfterCallback);
                return;
            }
            state_mod.waitForTasks(state);
            const running_owner = engine_thread.threadId(state.instance_id);
            const owner_thread_id = if (running_owner != 0) running_owner else state.engine_thread_id.load(.seq_cst);
            state.engine_thread_id.store(owner_thread_id, .seq_cst);
            if (owner_thread_id == @as(u64, @intCast(std.Thread.getCurrentId()))) {
                finalizeInspector(state);
                return;
            }
            closeNonJsResources(state);
            _ = state_mod.retireState(state);
            _ = dispatch.postTask(state.instance_id, .{
                .ctx = @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(state.instance_id)))) + 1),
                .run = drainRetiredTask,
            });
        }

        fn resumeReleaseAfterCallback(state: *InspectorState) void {
            releaseInspector(state);
        }

        /// A transport is permitted to synchronously report its final close while `deinit` runs. Reject task creation first, then release any leases that callback created before the start errdefers unlink and destroy the state.
        fn rollbackStart(state: *InspectorState) void {
            state_mod.beginClosing(state);
            state.transport.deinit();
            debugger_cdp.stopInstance(state);
            await_promise.cancelState(state);
            dispatch.releaseTasksForOwner(state.instance_id, state);
            state_mod.waitForTasks(state);
        }

        fn drainRetiredTask(ctx: ?*anyopaque) void {
            const packed_id = @intFromPtr(ctx.?) - 1;
            const instance_id: i32 = @bitCast(@as(u32, @truncate(packed_id)));
            drainRetired(instance_id);
        }

        fn finalizeInspector(state: *InspectorState) void {
            std.debug.assert(state.engine_thread_id.load(.seq_cst) == @as(u64, @intCast(std.Thread.getCurrentId())));
            const lease = engine_thread.beginExclusiveTeardown(state.instance_id);
            if (!lease.allowed) {
                requeueRetiredFinalization(state);
                return;
            }
            defer engine_thread.endEval(lease);
            // Finalization runs on the JS owner after all session/reader work has drained, so disarming here cannot race a new state with the same id.
            debugger_cdp.stopInstance(state);
            Host.debugger.coolDown(state.instance_id);
            if (engine.getRuntime(state.instance_id)) |runtime| {
                debugger_cdp.clearAsyncStackDepthOnOwner(state.instance_id, runtime);
            }
            closeNonJsResources(state);
            // The engine is still alive when `stop` runs. `dropInstance` runs at the start of `engine.destroy`, before the context is freed. A null context makes `deinit` skip `freeValue`.
            if (engine.getContext(state.instance_id)) |ctx| {
                exceptions.deinit(state, ctx);
                runtime_objects.releaseRuntimeIntrinsics(ctx, state);
            }
            state.object_table.deinit(engine.getContext(state.instance_id));
            _ = state_mod.removeStateByPtr(state);
            destroyInspectorState(state);
        }

        fn requeueRetiredFinalization(state: *InspectorState) void {
            const running_owner = engine_thread.threadId(state.instance_id);
            if (running_owner != 0) state.engine_thread_id.store(running_owner, .seq_cst);
            _ = state_mod.retireState(state);
            _ = dispatch.postTask(state.instance_id, .{
                .ctx = @ptrFromInt(@as(usize, @intCast(@as(u32, @bitCast(state.instance_id)))) + 1),
                .run = drainRetiredTask,
            });
        }

        fn closeNonJsResources(state: *InspectorState) void {
            if (!state.profiler_stopped) {
                profiler.stopInstance(state.instance_id);
                state.profiler_stopped = true;
            }
            if (!state.transport_closed) {
                state.transport.deinit();
                state.transport_closed = true;
            }
            if (!state.console_buffer_freed) {
                state_mod.deinitConsoleBuffer(state);
                state.console_buffer_freed = true;
            }
        }

        fn destroyInspectorState(state: *InspectorState) void {
            const alloc = state.allocator;
            state_mod.discardPendingAsyncDepthReconciliation(state);
            state.deinitSynchronization();
            alloc.free(state.title);
            alloc.free(state.url);
            alloc.free(state.target_id);
            state.sessions.deinit(alloc);
            alloc.destroy(state);
        }

        // Drain retired values from a caller that already holds the engine's JS-entry lease. The thread id recorded at the last Inspector task may be stale after threadStop or a legal yielded JSC entry.
        pub fn drainRetired(instance_id: i32) void {
            if (comptime !Host.build_options.inspector) return;
            const current_thread_id = @as(u64, @intCast(std.Thread.getCurrentId()));
            while (state_mod.takeRetiredState(instance_id, null)) |state| {
                state.engine_thread_id.store(current_thread_id, .seq_cst);
                finalizeInspector(state);
            }
        }

        pub fn boundPort(handle: *Handle) u16 {
            const state: *InspectorState = @ptrCast(@alignCast(handle));
            return state.transport.boundPort();
        }

        // Tear down any inspector attached to `instance_id`. `engine.destroy` calls this before the JS context is freed. Safe no-op if none registered or if `stop` already released it.
        pub fn dropInstance(instance_id: i32) void {
            if (comptime !Host.build_options.inspector) return;
            while (true) {
                switch (state_mod.claimDestroy(instance_id)) {
                    .none => return,
                    .wait => state_mod.waitForStateChange(instance_id),
                    .close => |state| {
                        json_writer.sendExecutionContextDestroyed(state);
                        releaseInspector(state);
                    },
                    .finalize => |state| {
                        // engine.destroy calls this after joining the engine thread; teardown now owns the still-live context.
                        state.engine_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
                        finalizeInspector(state);
                    },
                }
            }
        }
    };
}
