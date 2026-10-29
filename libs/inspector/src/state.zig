pub fn Module(comptime Host: type) type {
    // InspectorState + the global instance-id → state map, plus per-session bookkeeping helpers.
    //
    // The state table follows the same pattern as `tsfn.zig` / `console_tap.zig`: a global `AutoHashMap(i32, *InspectorState)` guarded by `inspector_mutex`. Every entry-point that wants to look up state for an `instance_id` goes through here.
    //
    // Per-session bookkeeping (`addSession` / `removeSession` / `setSessionRuntimeEnabled` / `snapshotEnabledSessions`) lives on the `InspectorState.sessions` list and is guarded by the per-state mutex.
    //
    // `console_entries` stores recent `Runtime.consoleAPICalled` payloads collected while Runtime is enabled so later sessions can replay them. `removeStateByPtr` only unlinks the state. `inspector.stop` and `inspector.dropInstance` both free the buffer from `releaseInspector`.

    return struct {
        const std = @import("std");
        const backend = Host.backend;
        const dispatch = Host.dispatch;
        const io = Host.io;
        const sync = Host.sync;
        const transport_mod = @import("transport.zig");
        const object_table_mod = @import("object_table.zig").Module(Host);
        const test_faults = Host.test_faults;

        pub const ObjectTable = object_table_mod.ObjectTable;

        pub const ReportedRejection = struct {
            identity: usize,
            promise: backend.ActiveEngine.Value,
            exception_id: u32,
        };

        pub const Session = struct {
            id: transport_mod.SessionId,
            runtime_enabled: bool = false,
            debugger_enabled: bool = false,
            /// Requested by this CDP session through Debugger.setAsyncCallStackDepth. The owner thread applies the maximum request across live sessions.
            async_stack_depth: u32 = 0,
            performance_enabled: bool = false,
            performance_time_domain: PerformanceTimeDomain = .time_ticks,
        };

        // CDP's declared Performance time domains. Command handling rejects `thread_ticks` until this process has a portable thread-CPU clock.
        pub const PerformanceTimeDomain = enum { time_ticks, thread_ticks };

        pub const PerformanceSession = struct {
            enabled: bool,
            time_domain: PerformanceTimeDomain,
        };

        // Oldest entries are dropped once the console buffer reaches this size.
        pub const console_buffer_cap: usize = 100;

        // Id written by executionContextCreated, scriptParsed, and consoleAPICalled.
        pub const default_execution_context_id = 1;

        // Copied console events for one `Runtime.enable` replay. `owned` is false when `entries` is an empty static slice.
        pub const BufferedConsole = struct {
            entries: [][]u8 = &.{},
            owned: bool = false,
        };

        // One buffered console event. `group` names exactly the ObjectTable entries retained while serializing this event; it is never exposed through CDP.
        pub const ConsoleEntry = struct {
            json: []u8,
            group: ?[]u8 = null,
        };

        // Test-only observation of whether a live Inspector owns a clean realm for Runtime reflection. It observes the registered state and creates nothing.
        pub fn hasPristineRuntimeIntrinsicsForTesting(instance_id: i32) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            const state = if (states) |*map| map.get(instance_id) else null;
            return if (state) |value| value.runtime_intrinsics_ctx != null else false;
        }

        pub const InspectorState = struct {
            pub fn deinitSynchronization(self: *InspectorState) void {
                self.task_wake.deinit();
                self.task_mutex.deinit();
                self.mutex.deinit();
            }

            instance_id: i32,
            allocator: std.mem.Allocator,
            transport: *transport_mod.Transport,
            title: []u8,
            url: []u8,
            target_id: []u8,

            /// Per-session bookkeeping. Protected by `mutex`.
            mutex: sync.Mutex = .{},
            /// Protects task admission and the lifetime of tasks holding this state.
            task_mutex: sync.Mutex = .{},
            task_wake: sync.Condition = .init,
            /// Every in-flight borrow of this state, including synchronous callbacks.
            task_refs: usize = 0,
            /// Inspector work admitted through `postInspectorTask`, whether queued or currently executing on the owner thread.
            inspector_task_refs: usize = 0,
            closing: bool = false,
            deferred_finalizer: ?*const fn (*InspectorState) void = null,
            engine_thread_id: std.atomic.Value(u64) = .init(0),
            profiler_stopped: bool = false,
            transport_closed: bool = false,
            console_buffer_freed: bool = false,
            retired_next: ?*InspectorState = null,
            lifecycle: Lifecycle = .starting,
            sessions: std.ArrayList(Session),
            /// Set on the transport thread whenever a session changes its async-stack request or disappears. The owner clears it only after applying the aggregate to the backend.
            async_depth_reconcile_pending: bool = false,
            /// Set only when the final Debugger session disappeared or Inspector is stopping. Async-depth requests alone must not detach a host-attached debugger.
            debugger_cooldown_pending: bool = false,
            next_exception_id: u32 = 1,
            /// Owner-thread-only, bounded by exceptions.zig, released before context teardown.
            reported_rejections: std.ArrayList(ReportedRejection) = .empty,
            reported_rejections_head: usize = 0,
            /// Bounded exception object handles; entries themselves belong to ObjectTable.
            exception_object_ids: std.ArrayList(u64) = .empty,
            exception_object_ids_head: usize = 0,

            /// Full `Runtime.consoleAPICalled` JSON texts, oldest first. A group owns only the ObjectTable entries created for that event. Protected by `mutex`.
            console_entries: std.ArrayList(ConsoleEntry) = .empty,
            console_entries_head: usize = 0,

            /// Retained remote objects. Entries live until explicitly released or inspector shutdown. Allocated with `allocator`.
            object_table: ObjectTable,

            /// Intrinsics retained before page code can replace the global methods used by Runtime.getProperties. These values are owned by this state.
            runtime_object_ctor: ?backend.ActiveEngine.Value = null,
            runtime_reflect: ?backend.ActiveEngine.Value = null,
            runtime_object_keys: ?backend.ActiveEngine.Value = null,
            runtime_own_keys: ?backend.ActiveEngine.Value = null,
            runtime_reflect_get: ?backend.ActiveEngine.Value = null,
            runtime_has_own: ?backend.ActiveEngine.Value = null,
            runtime_get_own_descriptor: ?backend.ActiveEngine.Value = null,
            runtime_get_prototype_of: ?backend.ActiveEngine.Value = null,
            /// A fresh realm in the engine's runtime that owns the reflection methods. It remains alive only while this InspectorState does.
            runtime_intrinsics_ctx: ?backend.ActiveEngine.Context = null,
        };

        pub const Lifecycle = enum { starting, active, closing, retired };

        pub fn releaseStateLease(ctx: ?*anyopaque) void {
            const state: *InspectorState = @ptrCast(@alignCast(ctx.?));
            state.task_mutex.lock();
            std.debug.assert(state.task_refs != 0);
            state.task_refs -= 1;
            const finalizer = if (state.task_refs == 0) state.deferred_finalizer else null;
            if (finalizer != null) state.deferred_finalizer = null;
            state.task_wake.broadcast();
            state.task_mutex.unlock();
            if (finalizer) |finish| finish(state);
        }

        fn completeInspectorTask(ctx: ?*anyopaque) void {
            const state: *InspectorState = @ptrCast(@alignCast(ctx.?));
            state.task_mutex.lock();
            std.debug.assert(state.inspector_task_refs != 0);
            state.inspector_task_refs -= 1;
            state.task_mutex.unlock();
            releaseStateLease(ctx);
        }

        // Acquire a lease before using an InspectorState outside its registry lock.
        pub fn tryAcquireStateLease(state: *InspectorState) bool {
            state.task_mutex.lock();
            defer state.task_mutex.unlock();
            if (state.closing) return false;
            state.task_refs += 1;
            return true;
        }

        pub fn acquireStateLeaseByInstance(instance_id: i32) ?*InspectorState {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            const state = if (states) |*map| map.get(instance_id) else null;
            if (state) |value| {
                if (tryAcquireStateLease(value)) return value;
            }
            return null;
        }

        pub fn acquireTapLease(ctx: ?*anyopaque) bool {
            const state: *InspectorState = @ptrCast(@alignCast(ctx.?));
            if (!tryAcquireStateLease(state)) return false;
            state.mutex.lock();
            const enabled = hasEnabledRuntimeSessionLocked(state);
            state.mutex.unlock();
            if (enabled) return true;
            releaseStateLease(ctx);
            return false;
        }

        fn hasEnabledRuntimeSessionLocked(state: *InspectorState) bool {
            for (state.sessions.items) |session| if (session.runtime_enabled) return true;
            return false;
        }

        pub fn releaseTapLease(ctx: ?*anyopaque) void {
            releaseStateLease(ctx);
        }

        // Queue work that borrows `state`. Admission and queue insertion share the lifecycle lock so shutdown cannot remove a queue just before a new task recreates it. The task's completion callback clears the task marker before releasing the state lease.
        pub fn postInspectorTask(state: *InspectorState, task: dispatch.NativeTask) bool {
            state.task_mutex.lock();
            defer state.task_mutex.unlock();
            if (state.closing) return false;
            state.task_refs += 1;
            state.inspector_task_refs += 1;
            var leased = task;
            leased.complete = completeInspectorTask;
            leased.completion_ctx = state;
            leased.owner = state;
            leased.thread_id_slot = &state.engine_thread_id;
            if (dispatch.postTask(state.instance_id, leased)) return true;
            state.task_refs -= 1;
            state.inspector_task_refs -= 1;
            state.task_wake.broadcast();
            return false;
        }

        // Reject new tasks before transport shutdown and queue cancellation begins.
        pub fn beginClosing(state: *InspectorState) void {
            state.task_mutex.lock();
            state.closing = true;
            state.task_mutex.unlock();
        }

        pub fn isClosing(state: *InspectorState) bool {
            state.task_mutex.lock();
            defer state.task_mutex.unlock();
            return state.closing;
        }

        // Wait for tasks that were already taken out of the queue to finish before freeing the state they borrow.
        pub fn waitForTasks(state: *InspectorState) void {
            state.task_mutex.lock();
            while (state.task_refs != 0) {
                state.task_wake.wait(&state.task_mutex);
            }
            state.task_mutex.unlock();
        }

        // Defer state destruction until a reentrant task releases its final lease. The callback runs after dropping `task_mutex`, on the thread releasing the last lease.
        pub fn deferFinalizationUntilLeasesReleased(
            state: *InspectorState,
            finalizer: *const fn (*InspectorState) void,
        ) void {
            state.task_mutex.lock();
            std.debug.assert(state.closing);
            std.debug.assert(state.deferred_finalizer == null);
            state.deferred_finalizer = finalizer;
            const finalize_now = state.task_refs == 0;
            if (finalize_now) state.deferred_finalizer = null;
            state.task_mutex.unlock();
            if (finalize_now) finalizer(state);
        }

        pub var inspector_mutex: sync.Mutex = .{};
        pub var states: ?std.AutoHashMap(i32, *InspectorState) = null;
        // Number of InspectorStates that have an async-depth transition awaiting an owner-thread application. The zero fast path keeps normal JS admission from taking the inspector registry mutex.
        var pending_async_depth_reconciliations = std.atomic.Value(usize).init(0);
        var starting_ids: ?std.AutoHashMap(i32, void) = null;
        var destroying_ids: ?std.AutoHashMap(i32, void) = null;
        var retired_states: ?*InspectorState = null;
        var state_changed: sync.Condition = .init;

        // Reserve an instance id before start performs context capture or opens a transport. The reservation is serialized with state registration.
        pub fn reserveStart(instance_id: i32) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (destroying_ids) |*destroying| if (destroying.contains(instance_id)) return false;
            if (states) |*map| if (map.contains(instance_id)) return false;
            if (starting_ids == null) starting_ids = std.AutoHashMap(i32, void).init(std.heap.c_allocator);
            const reservations = &starting_ids.?;
            if (reservations.contains(instance_id)) return false;
            reservations.put(instance_id, {}) catch return false;
            return true;
        }

        pub fn cancelStartReservation(instance_id: i32) void {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (starting_ids) |*reservations| _ = reservations.remove(instance_id);
            state_changed.broadcast();
        }

        // Close Inspector startup admission for the full engine runtime teardown. The caller holds this gate until the engine context has left instance_map.
        pub fn beginEngineDestroy(instance_id: i32) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (destroying_ids == null) destroying_ids = std.AutoHashMap(i32, void).init(std.heap.c_allocator);
            const destroying = &destroying_ids.?;
            if (destroying.contains(instance_id)) return false;
            destroying.put(instance_id, {}) catch return false;
            return true;
        }

        pub fn endEngineDestroy(instance_id: i32) void {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (destroying_ids) |*destroying| _ = destroying.remove(instance_id);
            state_changed.broadcast();
        }

        pub fn registerReservedStart(instance_id: i32, state: *InspectorState) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            const reservations = if (starting_ids) |*map| map else return false;
            if (!reservations.contains(instance_id)) return false;
            if (states) |*map| if (map.contains(instance_id)) return false;
            const table = ensureStates();
            table.put(instance_id, state) catch return false;
            state.lifecycle = .starting;
            return true;
        }

        // Complete startup only after transport startup and callback installation have returned. Destroy waits on a registered starting state rather than tearing down resources while `start` still owns them.
        pub fn activateReservedStart(instance_id: i32, state: *InspectorState) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            const reservations = if (starting_ids) |*map| map else return false;
            if (!reservations.contains(instance_id)) return false;
            const table = if (states) |*map| map else return false;
            if (table.get(instance_id) != state or state.lifecycle != .starting) return false;
            state.lifecycle = .active;
            _ = reservations.remove(instance_id);
            state_changed.broadcast();
            return true;
        }

        // Claim the transition to closing while the state is still registered. The registry lock makes the pointer check safe for stale opaque handles.
        pub fn claimCloseByPtr(state: *InspectorState) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (states) |*map| {
                var it = map.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != state) continue;
                    if (state.lifecycle != .active) return false;
                    state.lifecycle = .closing;
                    beginClosing(state);
                    return true;
                }
            }
            return false;
        }

        pub const DestroyAction = union(enum) {
            none,
            close: *InspectorState,
            finalize: *InspectorState,
            wait,
        };

        // Choose exactly one teardown action for engine.destroy. Closing states stay registered until their owner finishes; retired states are atomically removed from the retired queue before destroy takes finalization ownership.
        pub fn claimDestroy(instance_id: i32) DestroyAction {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (starting_ids) |*reservations| {
                if (reservations.contains(instance_id)) return .wait;
            }
            const state = if (states) |*map| map.get(instance_id) else null;
            const value = state orelse return .none;
            switch (value.lifecycle) {
                .starting => return .wait,
                .active => {
                    value.lifecycle = .closing;
                    beginClosing(value);
                    return .{ .close = value };
                },
                .closing => return .wait,
                .retired => {
                    _ = unlinkRetiredLocked(value);
                    value.lifecycle = .closing;
                    return .{ .finalize = value };
                },
            }
        }

        pub fn waitForStateChange(instance_id: i32) void {
            inspector_mutex.lock();
            while (true) {
                const reservation_pending = if (starting_ids) |*reservations| reservations.contains(instance_id) else false;
                const state_pending = if (states) |*map| blk: {
                    const state = map.get(instance_id) orelse break :blk false;
                    break :blk state.lifecycle == .closing or state.lifecycle == .starting;
                } else false;
                if (!reservation_pending and !state_pending) break;
                state_changed.wait(&inspector_mutex);
            }
            inspector_mutex.unlock();
        }

        // Keep JS-valued Inspector state alive until its recorded JS owner can free retained values safely, or until engine teardown reclaims the context.
        pub fn retireState(state: *InspectorState) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            state.lifecycle = .retired;
            state.retired_next = retired_states;
            retired_states = state;
            state_changed.broadcast();
            return true;
        }

        fn unlinkRetiredLocked(target: *InspectorState) bool {
            var previous: ?*InspectorState = null;
            var current = retired_states;
            while (current) |state| : (current = state.retired_next) {
                if (state != target) {
                    previous = state;
                    continue;
                }
                if (previous) |parent| {
                    parent.retired_next = state.retired_next;
                } else {
                    retired_states = state.retired_next;
                }
                state.retired_next = null;
                return true;
            }
            return false;
        }

        pub fn takeRetiredState(instance_id: i32, owner_thread_id: ?u64) ?*InspectorState {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            var previous: ?*InspectorState = null;
            var current = retired_states;
            while (current) |state| {
                const next = state.retired_next;
                const owner_matches = if (owner_thread_id) |owner|
                    state.engine_thread_id.load(.seq_cst) == owner
                else
                    true;
                if (state.instance_id != instance_id or !owner_matches) {
                    previous = state;
                    current = next;
                    continue;
                }
                _ = unlinkRetiredLocked(state);
                state.lifecycle = .closing;
                return state;
            }
            return null;
        }

        pub fn retiredStateCount(instance_id: i32) usize {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            var count: usize = 0;
            var current = retired_states;
            while (current) |state| : (current = state.retired_next) {
                if (state.instance_id == instance_id) count += 1;
            }
            return count;
        }

        pub fn ensureStates() *std.AutoHashMap(i32, *InspectorState) {
            if (states == null) {
                states = std.AutoHashMap(i32, *InspectorState).init(std.heap.c_allocator);
            }
            return &states.?;
        }

        pub fn removeStateByPtr(state: *InspectorState) bool {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (states) |*m| {
                var it = m.iterator();
                while (it.next()) |kv| {
                    if (kv.value_ptr.* == state) {
                        _ = m.remove(kv.key_ptr.*);
                        state_changed.broadcast();
                        return true;
                    }
                }
            }
            return false;
        }

        pub fn takeState(instance_id: i32) ?*InspectorState {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            if (states) |*m| {
                const kv = m.fetchRemove(instance_id) orelse return null;
                return kv.value;
            }
            return null;
        }

        var console_entry_live: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        pub fn liveConsoleEntries() usize {
            return console_entry_live.load(.monotonic);
        }

        // Generate a target id that is stable for the lifetime of an inspector handle but unique across handles. Chrome doesn't require RFC-4122 UUIDs; a hex string derived from monotonic counter + instance id suffices.
        var target_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

        pub fn generateTargetId(alloc: std.mem.Allocator, instance_id: i32) ![]u8 {
            const n = target_counter.fetchAdd(1, .seq_cst);
            const now_ms: u64 = @intCast(io.milliTimestamp());
            return try std.fmt.allocPrint(alloc, "js-bay-{d}-{x}-{x}", .{ instance_id, now_ms, n });
        }

        // ---------------------------------------------------------------------------
        // Session bookkeeping helpers
        // ---------------------------------------------------------------------------

        pub fn addSession(state: *InspectorState, session_id: transport_mod.SessionId) bool {
            state.mutex.lock();
            defer state.mutex.unlock();
            if (test_faults.take(state.instance_id, .session_registration)) return false;
            state.sessions.append(state.allocator, .{ .id = session_id }) catch return false;
            return true;
        }

        pub fn removeSession(state: *InspectorState, session_id: transport_mod.SessionId) bool {
            state.mutex.lock();
            defer state.mutex.unlock();
            var i: usize = 0;
            while (i < state.sessions.items.len) : (i += 1) {
                if (state.sessions.items[i].id == session_id) {
                    _ = state.sessions.swapRemove(i);
                    return true;
                }
            }
            return false;
        }

        pub const RemovedSessionReconciliation = struct {
            removed: bool,
            debugger_cooldown: bool,
        };

        // Remove a transport session and publish all owner-thread reconciliation state under one mutex. In particular, a caller that observes sessionCount reaching zero cannot race an owner admission before the final Debugger session's cooldown request is visible.
        pub fn removeSessionAndMarkReconciliation(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
        ) RemovedSessionReconciliation {
            state.mutex.lock();
            defer state.mutex.unlock();
            var i: usize = 0;
            while (i < state.sessions.items.len) : (i += 1) {
                if (state.sessions.items[i].id != session_id) continue;
                const removed_debugger = state.sessions.items[i].debugger_enabled;
                _ = state.sessions.swapRemove(i);
                var has_debugger = false;
                for (state.sessions.items) |session| {
                    if (session.debugger_enabled) {
                        has_debugger = true;
                        break;
                    }
                }
                const debugger_cooldown = removed_debugger and !has_debugger;
                if (debugger_cooldown) state.debugger_cooldown_pending = true;
                markAsyncDepthReconcilePendingLocked(state);
                return .{ .removed = true, .debugger_cooldown = debugger_cooldown };
            }
            return .{ .removed = false, .debugger_cooldown = false };
        }

        pub fn hasSession(state: *InspectorState, session_id: transport_mod.SessionId) bool {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |session| {
                if (session.id == session_id) return true;
            }
            return false;
        }

        pub fn sessionCount(state: *InspectorState) usize {
            state.mutex.lock();
            defer state.mutex.unlock();
            return state.sessions.items.len;
        }

        pub fn stateByInstance(instance_id: i32) ?*InspectorState {
            inspector_mutex.lock();
            defer inspector_mutex.unlock();
            const map = states orelse return null;
            return map.get(instance_id);
        }

        pub fn setSessionDebuggerEnabled(state: *InspectorState, session_id: transport_mod.SessionId, enabled: bool) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |*s| {
                if (s.id == session_id) {
                    s.debugger_enabled = enabled;
                    return;
                }
            }
        }

        // Replace one live session's requested async parent-stack depth.  The caller must subsequently arrange an owner-thread reconciliation.
        pub fn setSessionAsyncStackDepth(state: *InspectorState, session_id: transport_mod.SessionId, depth: u32) bool {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |*session| {
                if (session.id != session_id) continue;
                session.async_stack_depth = depth;
                markAsyncDepthReconcilePendingLocked(state);
                return true;
            }
            return false;
        }

        // Withdraw one session's async request as part of Debugger.disable. This is intentionally independent of Debugger.enable: CDP permits a depth request before enable, and disable must always remove that request.
        pub fn clearSessionAsyncStackDepth(state: *InspectorState, session_id: transport_mod.SessionId) bool {
            return setSessionAsyncStackDepth(state, session_id, 0);
        }

        // Owner-thread only. Returns the newest aggregate request if a transport thread changed it since the prior reconciliation.
        pub const PendingAsyncDepthReconciliation = struct {
            depth: u32,
            debugger_cooldown: bool,
        };

        pub fn takePendingAsyncStackDepth(state: *InspectorState) ?PendingAsyncDepthReconciliation {
            state.mutex.lock();
            defer state.mutex.unlock();
            if (!state.async_depth_reconcile_pending) return null;
            var depth: u32 = 0;
            for (state.sessions.items) |session| depth = @max(depth, session.async_stack_depth);
            const debugger_cooldown = state.debugger_cooldown_pending;
            state.async_depth_reconcile_pending = false;
            state.debugger_cooldown_pending = false;
            _ = pending_async_depth_reconciliations.fetchSub(1, .acq_rel);
            return .{ .depth = depth, .debugger_cooldown = debugger_cooldown };
        }

        pub fn hasPendingAsyncDepthReconciliation() bool {
            return pending_async_depth_reconciliations.load(.acquire) != 0;
        }

        // True when this InspectorState still needs an owner-thread async-depth reconciliation. Reader-thread Debugger.disable uses this to keep its protocol reply ordered after a pending depth transition.
        pub fn hasPendingAsyncDepthReconciliationForState(state: *InspectorState) bool {
            state.mutex.lock();
            defer state.mutex.unlock();
            return state.async_depth_reconcile_pending;
        }

        // Includes queued and currently executing inspector tasks. A subsequent owner operation must not acknowledge ahead of an earlier CDP task.
        pub fn hasInspectorTasks(state: *InspectorState) bool {
            state.task_mutex.lock();
            defer state.task_mutex.unlock();
            return state.inspector_task_refs != 0;
        }

        // Drop an unapplied request when its InspectorState is being destroyed. The backend teardown has already forced depth zero, so it must not leave the global cold-path fast check permanently nonzero.
        pub fn discardPendingAsyncDepthReconciliation(state: *InspectorState) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            if (!state.async_depth_reconcile_pending) return;
            state.async_depth_reconcile_pending = false;
            state.debugger_cooldown_pending = false;
            _ = pending_async_depth_reconciliations.fetchSub(1, .acq_rel);
        }

        // Requires `state.mutex`.
        pub fn markAsyncDepthReconcilePendingLocked(state: *InspectorState) void {
            if (state.async_depth_reconcile_pending) return;
            state.async_depth_reconcile_pending = true;
            _ = pending_async_depth_reconciliations.fetchAdd(1, .release);
        }

        pub fn hasEnabledDebuggerSession(state: *InspectorState) bool {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |session| {
                if (session.debugger_enabled) return true;
            }
            return false;
        }

        pub fn snapshotDebuggerSessions(state: *InspectorState, out: *std.ArrayList(transport_mod.SessionId)) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |s| {
                if (s.debugger_enabled) {
                    out.append(state.allocator, s.id) catch {};
                }
            }
        }

        pub fn setSessionRuntimeEnabled(state: *InspectorState, session_id: transport_mod.SessionId, enabled: bool) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |*s| {
                if (s.id == session_id) {
                    s.runtime_enabled = enabled;
                    return;
                }
            }
        }

        pub fn configureSessionPerformance(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            enable: bool,
            requested_time_domain: ?PerformanceTimeDomain,
        ) enum { ok, active_time_domain_conflict, unknown_session } {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |*session| {
                if (session.id != session_id) continue;
                if (enable) {
                    const domain = requested_time_domain orelse session.performance_time_domain;
                    if (session.performance_enabled and domain != session.performance_time_domain) return .active_time_domain_conflict;
                    session.performance_time_domain = domain;
                    session.performance_enabled = true;
                } else {
                    session.performance_enabled = false;
                }
                return .ok;
            }
            return .unknown_session;
        }

        // Set the domain while disabled, as required by `Performance.setTimeDomain`.
        pub fn setSessionPerformanceTimeDomain(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
            time_domain: PerformanceTimeDomain,
        ) enum { ok, enabled, unknown_session } {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |*session| {
                if (session.id != session_id) continue;
                if (session.performance_enabled) return .enabled;
                session.performance_time_domain = time_domain;
                return .ok;
            }
            return .unknown_session;
        }

        pub fn sessionPerformance(state: *InspectorState, session_id: transport_mod.SessionId) ?PerformanceSession {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |session| {
                if (session.id == session_id) return .{
                    .enabled = session.performance_enabled,
                    .time_domain = session.performance_time_domain,
                };
            }
            return null;
        }

        // Snapshot of session ids whose Runtime domain is currently enabled.
        pub fn snapshotEnabledSessions(state: *InspectorState, out: *std.ArrayList(transport_mod.SessionId)) void {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |s| {
                if (s.runtime_enabled) {
                    out.append(state.allocator, s.id) catch {};
                }
            }
        }

        // Append one console event and collect sessions that should receive it now. The append and the session snapshot share the state mutex so `Runtime.enable` cannot replay an event that is also sent live, or miss one that is not.
        pub fn bufferConsoleEvent(
            state: *InspectorState,
            json: []const u8,
            ctx: ?backend.ActiveEngine.Context,
            group: ?[]const u8,
            enabled_out: *std.ArrayList(transport_mod.SessionId),
        ) !void {
            const copy = try state.allocator.dupe(u8, json);
            const group_copy = if (group) |name| state.allocator.dupe(u8, name) catch {
                state.allocator.free(copy);
                return error.OutOfMemory;
            } else null;

            state.mutex.lock();
            state.console_entries.ensureTotalCapacity(state.allocator, state.console_entries.items.len + 1) catch {
                state.mutex.unlock();
                state.allocator.free(copy);
                if (group_copy) |name| state.allocator.free(name);
                return error.OutOfMemory;
            };

            var evicted: ?ConsoleEntry = null;
            const console_pending = state.console_entries.items.len - state.console_entries_head;
            if (console_pending >= console_buffer_cap) {
                evicted = state.console_entries.items[state.console_entries_head];
                state.console_entries_head += 1;
                if (state.console_entries_head == state.console_entries.items.len) {
                    state.console_entries.clearRetainingCapacity();
                    state.console_entries_head = 0;
                }
            }
            state.console_entries.appendAssumeCapacity(.{ .json = copy, .group = group_copy });
            if (state.console_entries_head >= 32) {
                const pend = state.console_entries.items[state.console_entries_head..];
                var write: usize = 0;
                while (write < pend.len) : (write += 1) {
                    state.console_entries.items[write] = pend[write];
                }
                state.console_entries.shrinkRetainingCapacity(pend.len);
                state.console_entries_head = 0;
            }
            _ = console_entry_live.fetchAdd(1, .monotonic);
            for (state.sessions.items) |s| {
                if (s.runtime_enabled) {
                    enabled_out.append(state.allocator, s.id) catch {};
                }
            }
            state.mutex.unlock();
            if (evicted) |old| {
                freeConsoleEntry(state, old, ctx);
                _ = console_entry_live.fetchSub(1, .monotonic);
            }
        }

        fn freeConsoleEntry(state: *InspectorState, entry: ConsoleEntry, ctx: ?backend.ActiveEngine.Context) void {
            state.allocator.free(entry.json);
            if (entry.group) |name| {
                defer state.allocator.free(name);
                if (ctx) |js_ctx| {
                    _ = state.object_table.releaseConsoleGroup(js_ctx, name);
                } else {
                    // Real QuickJS console callbacks always supply ArgView.ctx. A synthetic callback must not discard a group it cannot release.
                    std.debug.assert(false);
                }
            }
        }

        fn exerciseBufferConsoleEventAllocationFailure(allocator: std.mem.Allocator) !void {
            var state = InspectorState{
                .instance_id = -1,
                .allocator = allocator,
                .transport = undefined,
                .title = &.{},
                .url = &.{},
                .target_id = &.{},
                .sessions = .empty,
                .object_table = ObjectTable.init(allocator),
            };
            defer state.sessions.deinit(allocator);
            defer state.deinitSynchronization();
            defer state.object_table.deinit(null);
            defer deinitConsoleBuffer(&state);
            var enabled: std.ArrayList(transport_mod.SessionId) = .empty;
            defer enabled.deinit(allocator);
            try bufferConsoleEvent(&state, "console-json", null, "console-group", &enabled);
        }

        pub const TestCases = if (@import("builtin").is_test) struct {
            pub fn consoleBufferReleasesEveryPartialAllocationFailure() !void {
                const testing = std.testing;
                try testing.checkAllAllocationFailures(testing.allocator, exerciseBufferConsoleEventAllocationFailure, .{});
            }

            const lifecycle_test = struct {
                var task_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
                var release_task: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
                var waiter_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
                var waiter_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

                fn heldTask(ctx: ?*anyopaque) void {
                    const state: *InspectorState = @ptrCast(@alignCast(ctx.?));
                    task_started.store(true, .seq_cst);
                    while (!release_task.load(.seq_cst)) std.Thread.yield() catch {};
                    std.mem.doNotOptimizeAway(state.instance_id);
                }

                fn tick(instance_id: i32) void {
                    _ = dispatch.tickInstance(instance_id);
                }

                fn wait(state: *InspectorState) void {
                    waiter_started.store(true, .seq_cst);
                    waitForTasks(state);
                    waiter_done.store(true, .seq_cst);
                }
            };

            pub fn destroyWaitsWhileTransportStartupOwnsRegisteredState() !void {
                const testing = std.testing;
                const instance_id: i32 = 61_772;
                var state = InspectorState{
                    .instance_id = instance_id,
                    .allocator = testing.allocator,
                    .transport = undefined,
                    .title = &.{},
                    .url = &.{},
                    .target_id = &.{},
                    .sessions = .empty,
                    .object_table = ObjectTable.init(testing.allocator),
                };
                defer state.sessions.deinit(testing.allocator);
                defer state.deinitSynchronization();
                defer state.object_table.deinit(null);
                try testing.expect(reserveStart(instance_id));
                try testing.expect(registerReservedStart(instance_id, &state));
                defer {
                    _ = removeStateByPtr(&state);
                    cancelStartReservation(instance_id);
                }

                switch (claimDestroy(instance_id)) {
                    .wait => {},
                    else => return error.DestroyClaimedStateBeforeTransportStartupFinished,
                }
                try testing.expect(activateReservedStart(instance_id, &state));
                switch (claimDestroy(instance_id)) {
                    .close => |claimed| try testing.expect(claimed == &state),
                    else => return error.DestroyDidNotClaimInspectorAfterStartupFinished,
                }
            }

            pub fn destroyWaitsForStartReservationBeforeRegistration() !void {
                const testing = std.testing;
                const instance_id: i32 = 61_771;
                try testing.expect(reserveStart(instance_id));
                defer cancelStartReservation(instance_id);
                switch (claimDestroy(instance_id)) {
                    .wait => {},
                    else => return error.DestroyMissedInspectorStartReservation,
                }
            }

            pub fn startAdmissionStaysClosedDuringEngineRuntimeTeardown() !void {
                const testing = std.testing;
                const instance_id: i32 = 61_770;
                try testing.expect(beginEngineDestroy(instance_id));
                defer endEngineDestroy(instance_id);
                try testing.expect(!reserveStart(instance_id));
                endEngineDestroy(instance_id);
                try testing.expect(reserveStart(instance_id));
                cancelStartReservation(instance_id);
            }

            pub fn stateShutdownWaitsForInFlightCallbackLease() !void {
                const testing = std.testing;
                const engine = Host.engine;
                const instance_id: i32 = 61_774;
                try testing.expect(engine.create(instance_id, .{}));
                defer engine.destroy(instance_id);
                var state = InspectorState{
                    .instance_id = instance_id,
                    .allocator = testing.allocator,
                    .transport = undefined,
                    .title = &.{},
                    .url = &.{},
                    .target_id = &.{},
                    .sessions = .empty,
                    .object_table = ObjectTable.init(testing.allocator),
                };
                defer state.sessions.deinit(testing.allocator);
                defer state.deinitSynchronization();
                defer state.object_table.deinit(null);

                try testing.expect(tryAcquireStateLease(&state));
                try testing.expect(!hasInspectorTasks(&state));
                beginClosing(&state);
                lifecycle_test.waiter_started.store(false, .seq_cst);
                lifecycle_test.waiter_done.store(false, .seq_cst);
                const waiter = try std.Thread.spawn(.{}, lifecycle_test.wait, .{&state});
                try testing.expect(lifecycle_test.waiter_started.load(.seq_cst) or spinLifecycleUntil(&lifecycle_test.waiter_started));
                try testing.expect(!spinLifecycleUntil(&lifecycle_test.waiter_done));
                releaseStateLease(&state);
                waiter.join();
                try testing.expect(lifecycle_test.waiter_done.load(.seq_cst));
            }

            fn spinLifecycleUntil(flag: *const std.atomic.Value(bool)) bool {
                for (0..1_000_000) |_| {
                    if (flag.load(.seq_cst)) return true;
                    std.Thread.yield() catch {};
                }
                return flag.load(.seq_cst);
            }

            pub fn stateShutdownWaitsForTaskAlreadyRemovedFromQueue() !void {
                const testing = std.testing;
                const engine = Host.engine;
                const instance_id: i32 = 61_773;
                try testing.expect(engine.create(instance_id, .{}));
                defer engine.destroy(instance_id);
                defer dispatch.releaseAllTasksForInstance(instance_id);

                var state = InspectorState{
                    .instance_id = instance_id,
                    .allocator = testing.allocator,
                    .transport = undefined,
                    .title = &.{},
                    .url = &.{},
                    .target_id = &.{},
                    .sessions = .empty,
                    .object_table = ObjectTable.init(testing.allocator),
                };
                defer state.sessions.deinit(testing.allocator);
                defer state.deinitSynchronization();
                defer state.object_table.deinit(null);
                lifecycle_test.task_started.store(false, .seq_cst);
                lifecycle_test.release_task.store(false, .seq_cst);
                lifecycle_test.waiter_started.store(false, .seq_cst);
                lifecycle_test.waiter_done.store(false, .seq_cst);

                try testing.expect(postInspectorTask(&state, .{
                    .ctx = &state,
                    .run = lifecycle_test.heldTask,
                }));
                try testing.expect(hasInspectorTasks(&state));
                const tick_thread = try std.Thread.spawn(.{}, lifecycle_test.tick, .{instance_id});
                var tick_joined = false;
                var waiter: ?std.Thread = null;
                defer {
                    lifecycle_test.release_task.store(true, .seq_cst);
                    if (!tick_joined) tick_thread.join();
                    if (waiter) |thread| thread.join();
                }
                while (!lifecycle_test.task_started.load(.seq_cst)) std.Thread.yield() catch {};
                try testing.expect(hasInspectorTasks(&state));

                beginClosing(&state);
                dispatch.releaseAllTasksForInstance(instance_id);
                waiter = try std.Thread.spawn(.{}, lifecycle_test.wait, .{&state});
                while (!lifecycle_test.waiter_started.load(.seq_cst)) std.Thread.yield() catch {};
                try testing.expect(!lifecycle_test.waiter_done.load(.seq_cst));

                lifecycle_test.release_task.store(true, .seq_cst);
                tick_thread.join();
                tick_joined = true;
                waiter.?.join();
                waiter = null;
                try testing.expect(lifecycle_test.waiter_done.load(.seq_cst));
                try testing.expectEqual(@as(usize, 0), state.task_refs);
                try testing.expect(!hasInspectorTasks(&state));
            }

            pub fn taskCountRollsBackFailedPostsAndCanceledTasks() !void {
                const testing = std.testing;
                const engine = Host.engine;
                const instance_id: i32 = 61_775;
                try testing.expect(engine.create(instance_id, .{}));
                defer engine.destroy(instance_id);
                defer dispatch.releaseAllTasksForInstance(instance_id);

                var state = InspectorState{
                    .instance_id = instance_id,
                    .allocator = testing.allocator,
                    .transport = undefined,
                    .title = &.{},
                    .url = &.{},
                    .target_id = &.{},
                    .sessions = .empty,
                    .object_table = ObjectTable.init(testing.allocator),
                };
                defer state.sessions.deinit(testing.allocator);
                defer state.deinitSynchronization();
                defer state.object_table.deinit(null);

                dispatch.failNextQueueAllocationForTesting();
                try testing.expect(!postInspectorTask(&state, .{
                    .ctx = &state,
                    .run = lifecycle_test.heldTask,
                }));
                try testing.expectEqual(@as(usize, 0), state.task_refs);
                try testing.expect(!hasInspectorTasks(&state));

                try testing.expect(postInspectorTask(&state, .{
                    .ctx = &state,
                    .run = lifecycle_test.heldTask,
                }));
                try testing.expect(hasInspectorTasks(&state));
                dispatch.releaseAllTasksForInstance(instance_id);
                try testing.expectEqual(@as(usize, 0), state.task_refs);
                try testing.expect(!hasInspectorTasks(&state));
            }
        } else struct {};

        // Mark `session_id` Runtime-enabled and copy the current console buffer. Copying happens under the same lock as the flag update.
        pub fn enableRuntimeAndCopyConsole(
            state: *InspectorState,
            session_id: transport_mod.SessionId,
        ) BufferedConsole {
            state.mutex.lock();
            defer state.mutex.unlock();
            for (state.sessions.items) |*s| {
                if (s.id == session_id) {
                    s.runtime_enabled = true;
                    break;
                }
            }
            const pending = state.console_entries.items[state.console_entries_head..];
            const n = pending.len;
            if (n == 0) return .{};
            const out = state.allocator.alloc([]u8, n) catch return .{};
            var filled: usize = 0;
            for (pending) |entry| {
                const dup = state.allocator.dupe(u8, entry.json) catch {
                    for (out[0..filled]) |e| state.allocator.free(e);
                    state.allocator.free(out);
                    return .{};
                };
                out[filled] = dup;
                filled += 1;
            }
            return .{ .entries = out, .owned = true };
        }

        pub fn freeBufferedConsole(state: *InspectorState, buffered: BufferedConsole) void {
            if (!buffered.owned) return;
            for (buffered.entries) |entry| state.allocator.free(entry);
            state.allocator.free(buffered.entries);
        }

        // Drop every buffered console event. `Runtime.discardConsoleEntries` calls this.
        pub fn clearConsoleEntries(state: *InspectorState, ctx: backend.ActiveEngine.Context) void {
            state.mutex.lock();
            var entries = state.console_entries;
            const head = state.console_entries_head;
            state.console_entries = .empty;
            state.console_entries_head = 0;
            state.mutex.unlock();
            const pending = entries.items[head..];
            const n = pending.len;
            for (pending) |entry| freeConsoleEntry(state, entry, ctx);
            entries.deinit(state.allocator);
            if (n != 0) _ = console_entry_live.fetchSub(n, .monotonic);
        }

        pub fn deinitConsoleBuffer(state: *InspectorState) void {
            state.mutex.lock();
            var entries = state.console_entries;
            const head = state.console_entries_head;
            state.console_entries = .empty;
            state.console_entries_head = 0;
            state.mutex.unlock();
            const pending = entries.items[head..];
            const n = pending.len;
            for (pending) |entry| {
                state.allocator.free(entry.json);
                if (entry.group) |name| state.allocator.free(name);
            }
            entries.deinit(state.allocator);
            if (n != 0) _ = console_entry_live.fetchSub(n, .monotonic);
        }
    };
}
