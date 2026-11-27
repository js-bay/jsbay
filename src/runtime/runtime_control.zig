//! Runtime control — interrupt handling, GC, memory introspection.
//!
//! Gives native code the ability to:
//! - cancel a long-running JS computation from another thread (requestInterrupt / clearInterrupt)
//!   - set an execution time limit that auto-interrupts expired scripts
//!   - force a synchronous GC pass and snapshot memory usage
//!
//! Lifecycle: Call `init(instance_id)` ONCE after `engine.create` to arm the backend-specific interrupt trampoline. `engine.destroy` removes it only after active JavaScript has unwound, while the runtime is still valid. Direct users may call `deinit` themselves before destroy when no evaluation is active.
//!
//! Thread-safety: `requestInterrupt` / `clearInterrupt` / `setExecutionTimeLimit` are safe to call from any thread (atomic loads/stores on the shared state). `runGc` / `getMemoryUsage` must be called on the engine's owning thread — they touch the JS runtime directly.
//!
//! Backend notes:
//! - QuickJS: full native support via `JS_SetInterruptHandler`. The JS VM throws an InternalError on the next interrupt check.
//! - JSC: uses the private `JSContextGroupSetExecutionTimeLimit` API exported by JavaScriptCore.framework. The callback explicitly re-arms its next 50ms check after returning false so interrupts and deadlines do not depend on framework-specific callback repetition. `runGc` requests collection through the public `JSGarbageCollect` API; completion timing is controlled by the framework. Memory usage is not queryable through JSC's public C API and is reported as zeros.
//! - Escargot: `runGc` → `Memory::gc`. Soft `getMemoryUsage` via `Memory::heapSize`/`totalSize`. No public heap cap (`setMemoryLimit` false). No mid-script interrupt in this pin.
//! - Hermes: `runGc` via `instrumentation().collectGarbage`. Soft `getMemoryUsage` via `getHeapInfo` (`hermes_allocatedBytes`/`hermes_heapSize`). `setMemoryLimit` false (use EngineConfig.max_heap_size / -Dhermes-max-heap at create; GCConfig.MaxHeapSize create-time only). User `requestInterrupt` sets a bit only (does **not** call `asyncTriggerTimeout` — sticky Timeout AsyncBreak would poison later evals); mid-script abort is via stop/destroy → `requestStopInterrupt` + softRearm/drain. Escargot: bit only, **no** mid-script abort.

const std = @import("std");
const io = @import("../platform/io.zig");
const sync = @import("zev");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("instance_map.zig");
const control_registry = @import("runtime_control_registry.zig");
const observation = @import("runtime_observation.zig");
const hermes_watchdog = @import("hermes_watchdog.zig");

pub const MemoryUsage = observation.MemoryUsage;
pub const ShutdownPhase = control_registry.ShutdownPhase;
pub const ShutdownStatus = control_registry.ShutdownStatus;
pub const InterruptState = control_registry.InterruptState;
pub const init = control_registry.init;
pub const initForInstance = control_registry.initForInstance;
pub const deinit = control_registry.deinit;
pub const deinitForInstance = control_registry.deinitForInstance;
const hermesTriggerTimeout = control_registry.hermesTriggerTimeout;
const hermesWatchTimeLimit = control_registry.hermesWatchTimeLimit;
const hermesDrainAsyncTimeout = control_registry.hermesDrainAsyncTimeout;
const registry = &control_registry.registry;
const registry_mutex = &control_registry.registry_mutex;
const registry_condition = &control_registry.registry_condition;
const HandlerStatus = control_registry.HandlerStatus;
const initForInstanceWithHooks = control_registry.initForInstanceWithHooks;
const deinitForInstanceWithWaitObserver = control_registry.deinitForInstanceWithWaitObserver;
const supportsMidScriptUserInterruptForBackend = control_registry.supportsMidScriptUserInterruptForBackend;
const supportsMidScriptUserInterruptForState = control_registry.supportsMidScriptUserInterruptForState;
const isHandlerReady = control_registry.isHandlerReady;
const takeState = control_registry.takeState;

fn jscPollingControlsUnavailable(state: *const InterruptState) bool {
    if (comptime !backend.isPacked(.jsc)) return false;
    return state.backend_tag == .jsc and !@import("../backend/jsc/polling_config.zig").supportsInterrupt();
}

pub const softRearmHermesStopAfterHost = hermes_watchdog.softRearmHermesStopAfterHost;
const hermesTriggerTeardownTimeout = hermes_watchdog.hermesTriggerTeardownTimeout;

/// Request that the JS runtime interrupt execution on the next interrupt check. Thread-safe. Returns false if the instance was never init()'d or has been deinit()'d.
///
/// After the script throws, call `clearInterrupt` to reset the flag.
///
/// True when `requestInterrupt` can abort mid-script JS (QuickJS/NG via interrupt handler; JSC via time-limit callback).
///
/// Escargot/Hermes spikes: false — user interrupt must not be advertised as mid-script cancel.
pub fn supportsMidScriptUserInterrupt() bool {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => true,
        .jsc => @import("../backend/jsc/polling_config.zig").supportsInterrupt(),
        .escargot, .hermes => false,
    };
}

/// Request mid-script interrupt when the backend supports it. Returns true only when the instance exists **and** mid-script user interrupt is supported (bit armed). Escargot: always false (no Public hook). Hermes: always false for this API — mid-script abort is stop/destroy via `requestStopInterrupt` → `asyncTriggerTimeout` (sticky; softRearm/drain required).
pub fn requestInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    const polling_enabled = if (state.backend_tag == .jsc) blk: {
        if (comptime backend.isPacked(.jsc)) break :blk @import("../backend/jsc/polling_config.zig").supportsInterrupt();
        break :blk false;
    } else true;
    if (!supportsMidScriptUserInterruptForState(state, polling_enabled)) return false;
    const epoch_ptr: *std.atomic.Value(u64) = @ptrCast(&state.exec_epoch);
    const target_ptr: *std.atomic.Value(u64) = @ptrCast(&state.interrupt_target);
    const cur_epoch = epoch_ptr.load(.monotonic);
    const target_epoch = if (cur_epoch % 2 == 1) cur_epoch else cur_epoch + 1;
    _ = target_ptr.fetchMax(target_epoch, .monotonic);
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchOr(1, .monotonic);
    return true;
}

test "instance interrupt support follows the selected packed backend" {
    try std.testing.expect(supportsMidScriptUserInterruptForBackend(.quickjs_ng, false));
    try std.testing.expect(supportsMidScriptUserInterruptForBackend(.quickjs, false));
    try std.testing.expect(!supportsMidScriptUserInterruptForBackend(.jsc, false));
    try std.testing.expect(supportsMidScriptUserInterruptForBackend(.jsc, true));
    try std.testing.expect(!supportsMidScriptUserInterruptForBackend(.escargot, true));
    try std.testing.expect(!supportsMidScriptUserInterruptForBackend(.hermes, true));
}

test "reused instance ids use the backend saved with each interrupt state" {
    const reused_id = std.math.maxInt(i32) - 11;
    var old_state = InterruptState{ .instance_id = reused_id, .backend_tag = .jsc };
    var new_state = InterruptState{ .instance_id = reused_id, .backend_tag = .quickjs_ng };
    try std.testing.expect(!supportsMidScriptUserInterruptForState(&old_state, false));
    try std.testing.expect(supportsMidScriptUserInterruptForState(&new_state, false));
    try std.testing.expect(supportsMidScriptUserInterruptForState(
        &InterruptState{ .instance_id = reused_id, .backend_tag = .jsc },
        true,
    ));
}

test "interrupt request observes a replacement state under the registry lock" {
    const id = std.math.maxInt(i32) - 12;
    const old_state = try std.testing.allocator.create(InterruptState);
    old_state.* = .{ .instance_id = id, .backend_tag = .jsc };
    defer std.testing.allocator.destroy(old_state);
    const replacement = try std.testing.allocator.create(InterruptState);
    replacement.* = .{ .instance_id = id, .backend_tag = .quickjs_ng };
    defer std.testing.allocator.destroy(replacement);

    const Probe = struct {
        instance_id: i32,
        accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            self.accepted.store(requestInterrupt(self.instance_id), .release);
        }
    };
    var probe = Probe{ .instance_id = id };

    registry_mutex.lock();
    registry.put(id, old_state) catch {
        registry_mutex.unlock();
        return error.OutOfMemory;
    };
    const thread = std.Thread.spawn(.{}, Probe.run, .{&probe}) catch {
        _ = registry.remove(id);
        registry_mutex.unlock();
        return error.ThreadSpawnFailed;
    };
    if (registry.fetchRemove(id) == null) {
        registry_mutex.unlock();
        thread.join();
        return error.MissingOriginalState;
    }
    registry.put(id, replacement) catch {
        registry_mutex.unlock();
        thread.join();
        _ = takeState(id);
        return error.OutOfMemory;
    };
    registry_mutex.unlock();
    thread.join();

    const current = takeState(id) orelse return error.MissingReplacementState;
    try std.testing.expect(current == replacement);
    try std.testing.expect(probe.accepted.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), old_state.interrupt_requested);
    try std.testing.expectEqual(@as(u8, 1), replacement.interrupt_requested);
}

test "instance control registration rejects stale state and serializes first registration" {
    const id = std.math.maxInt(i32) - 13;
    try std.testing.expect(engine.create(id, .{ .allocator = std.testing.allocator }));
    defer engine.destroy(id);

    const inst = instance_map.getInstance(id) orelse return error.MissingInstance;
    registry_mutex.lock();
    const state = registry.get(id) orelse {
        registry_mutex.unlock();
        return error.MissingInterruptState;
    };
    const generation = state.generation;
    const backend_tag = state.backend_tag;
    state.generation +%= 1;
    registry_mutex.unlock();
    try std.testing.expect(!initForInstance(id, inst));

    registry_mutex.lock();
    state.generation = generation;
    state.backend_tag = if (backend_tag == .jsc) .quickjs_ng else .jsc;
    registry_mutex.unlock();
    try std.testing.expect(!initForInstance(id, inst));

    registry_mutex.lock();
    state.backend_tag = backend_tag;
    state.handler_status = .removing;
    registry_mutex.unlock();
    try std.testing.expect(!initForInstance(id, inst));

    registry_mutex.lock();
    state.handler_status = .ready;
    registry_mutex.unlock();
    try std.testing.expect(deinit(id));

    const Probe = struct {
        id: i32,
        inst: *instance_map.EngineInstance,
        start: *std.atomic.Value(bool),
        succeeded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            self.succeeded.store(initForInstance(self.id, self.inst), .release);
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var first = Probe{ .id = id, .inst = inst, .start = &start };
    var second = Probe{ .id = id, .inst = inst, .start = &start };
    const first_thread = try std.Thread.spawn(.{}, Probe.run, .{&first});
    const second_thread = std.Thread.spawn(.{}, Probe.run, .{&second}) catch {
        start.store(true, .release);
        first_thread.join();
        return error.ThreadSpawnFailed;
    };
    start.store(true, .release);
    first_thread.join();
    second_thread.join();

    try std.testing.expect(first.succeeded.load(.acquire));
    try std.testing.expect(second.succeeded.load(.acquire));
    try std.testing.expect(initForInstance(id, inst));
}

test "public deinit lease serializes with engine destruction and id reuse" {
    const id = std.math.maxInt(i32) - 14;
    try std.testing.expect(engine.create(id, .{ .allocator = std.testing.allocator }));
    defer engine.destroy(id);

    const Probe = struct {
        id: i32,
        start: *std.atomic.Value(bool),

        fn runDeinit(self: *@This()) void {
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            _ = deinit(self.id);
        }

        fn destroy(self: *@This()) void {
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            engine.destroy(self.id);
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var probe = Probe{ .id = id, .start = &start };
    const deinit_thread = try std.Thread.spawn(.{}, Probe.runDeinit, .{&probe});
    const destroy_thread = std.Thread.spawn(.{}, Probe.destroy, .{&probe}) catch {
        start.store(true, .release);
        deinit_thread.join();
        engine.destroy(id);
        return error.ThreadSpawnFailed;
    };
    start.store(true, .release);
    deinit_thread.join();
    destroy_thread.join();

    try std.testing.expect(instance_map.getInstance(id) == null);
    try std.testing.expect(engine.create(id, .{ .allocator = std.testing.allocator }));
    try std.testing.expect(deinit(id));
}

test "failed registration cleanup owns state while deinit waits for init waiters" {
    const id = std.math.maxInt(i32) - 15;
    try std.testing.expect(engine.create(id, .{ .allocator = std.testing.allocator }));
    defer engine.destroy(id);
    try std.testing.expect(deinit(id));

    const inst = instance_map.getInstance(id) orelse return error.MissingInstance;
    const Gate = struct {
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .init,
        installer_entered: bool = false,
        release_installer: bool = false,
        failure_published: bool = false,
        release_cleanup: bool = false,
        deinit_waiting_install: bool = false,
        deinit_waits_after_failure: usize = 0,
        deinit_done: bool = false,
        installer_result: bool = true,
        init_result: bool = true,
        deinit_result: bool = true,

        fn failInstall(_: *instance_map.EngineInstance, _: *InterruptState, context: ?*anyopaque) bool {
            const gate: *@This() = @ptrCast(@alignCast(context.?));
            gate.mutex.lock();
            gate.installer_entered = true;
            gate.changed.broadcast();
            while (!gate.release_installer) gate.changed.wait(&gate.mutex);
            gate.mutex.unlock();
            return false;
        }

        fn pauseAfterFailure(context: ?*anyopaque) void {
            const gate: *@This() = @ptrCast(@alignCast(context.?));
            gate.mutex.lock();
            gate.failure_published = true;
            gate.changed.broadcast();
            while (!gate.release_cleanup) gate.changed.wait(&gate.mutex);
            gate.mutex.unlock();
        }
    };
    const WaitContext = struct { gate: *Gate, state: *InterruptState };
    const Probe = struct {
        id: i32,
        inst: *instance_map.EngineInstance,
        gate: *Gate,
        wait_context: WaitContext,

        fn observeDeinitWait(context: ?*anyopaque) void {
            const wait_context: *WaitContext = @ptrCast(@alignCast(context.?));
            const gate = wait_context.gate;
            gate.mutex.lock();
            if (wait_context.state.handler_status == .installing) gate.deinit_waiting_install = true;
            if (wait_context.state.handler_status == .failed and wait_context.state.registration_waiters == 0) {
                gate.deinit_waits_after_failure += 1;
            }
            gate.changed.broadcast();
            gate.mutex.unlock();
        }

        fn runInstaller(self: *@This()) void {
            const installed = initForInstanceWithHooks(
                self.id,
                self.inst,
                std.testing.allocator,
                @ptrCast(self.gate),
                Gate.failInstall,
                Gate.pauseAfterFailure,
            );
            self.gate.mutex.lock();
            self.gate.installer_result = installed;
            self.gate.changed.broadcast();
            self.gate.mutex.unlock();
        }

        fn runInitWaiter(self: *@This()) void {
            const initialized = initForInstance(self.id, self.inst);
            self.gate.mutex.lock();
            self.gate.init_result = initialized;
            self.gate.changed.broadcast();
            self.gate.mutex.unlock();
        }

        fn runDeinitWaiter(self: *@This()) void {
            const removed = deinitForInstanceWithWaitObserver(
                self.id,
                self.inst,
                std.testing.allocator,
                @ptrCast(&self.wait_context),
                observeDeinitWait,
            );
            self.gate.mutex.lock();
            self.gate.deinit_result = removed;
            self.gate.deinit_done = true;
            self.gate.changed.broadcast();
            self.gate.mutex.unlock();
        }
    };

    var gate = Gate{};
    var probe = Probe{ .id = id, .inst = inst, .gate = &gate, .wait_context = undefined };
    const installer_thread = try std.Thread.spawn(.{}, Probe.runInstaller, .{&probe});
    gate.mutex.lock();
    while (!gate.installer_entered) gate.changed.wait(&gate.mutex);
    gate.mutex.unlock();

    registry_mutex.lock();
    const state = registry.get(id) orelse {
        registry_mutex.unlock();
        gate.mutex.lock();
        gate.release_installer = true;
        gate.release_cleanup = true;
        gate.changed.broadcast();
        gate.mutex.unlock();
        installer_thread.join();
        return error.MissingInterruptState;
    };
    probe.wait_context = .{ .gate = &gate, .state = state };
    registry_mutex.unlock();

    const init_thread = std.Thread.spawn(.{}, Probe.runInitWaiter, .{&probe}) catch {
        gate.mutex.lock();
        gate.release_installer = true;
        gate.changed.broadcast();
        while (!gate.failure_published) gate.changed.wait(&gate.mutex);
        gate.release_cleanup = true;
        gate.changed.broadcast();
        gate.mutex.unlock();
        installer_thread.join();
        return error.ThreadSpawnFailed;
    };
    registry_mutex.lock();
    while (state.registration_waiters != 1) registry_condition.wait(registry_mutex);
    registry_mutex.unlock();

    const deinit_thread = std.Thread.spawn(.{}, Probe.runDeinitWaiter, .{&probe}) catch {
        gate.mutex.lock();
        gate.release_installer = true;
        gate.changed.broadcast();
        while (!gate.failure_published) gate.changed.wait(&gate.mutex);
        gate.release_cleanup = true;
        gate.changed.broadcast();
        gate.mutex.unlock();
        init_thread.join();
        installer_thread.join();
        return error.ThreadSpawnFailed;
    };
    gate.mutex.lock();
    while (!gate.deinit_waiting_install and !gate.deinit_done) gate.changed.wait(&gate.mutex);
    gate.release_installer = true;
    gate.changed.broadcast();
    while (!gate.failure_published) gate.changed.wait(&gate.mutex);
    while (gate.deinit_waits_after_failure == 0 and !gate.deinit_done) gate.changed.wait(&gate.mutex);
    const deinit_escaped_cleanup = gate.deinit_done;
    gate.release_cleanup = true;
    gate.changed.broadcast();
    gate.mutex.unlock();

    init_thread.join();
    deinit_thread.join();
    installer_thread.join();

    try std.testing.expect(!deinit_escaped_cleanup);
    try std.testing.expect(gate.deinit_waits_after_failure != 0);
    try std.testing.expect(!gate.installer_result);
    try std.testing.expect(!gate.init_result);
    try std.testing.expect(!gate.deinit_result);
    registry_mutex.lock();
    const still_registered = registry.get(id) != null;
    registry_mutex.unlock();
    try std.testing.expect(!still_registered);
}

/// Clear a pending user interrupt. Lifecycle shutdown owns a separate bit, so this cannot resume a script that is being stopped.
pub fn clearInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return false;
    }
    const target_ptr: *std.atomic.Value(u64) = @ptrCast(&state.interrupt_target);
    target_ptr.store(0, .monotonic);
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchAnd(~@as(u8, 1), .monotonic);
    registry_mutex.unlock();
    // Unwatch only — do not evaluate here (may race a live mid-script eval).
    // Sticky Timeout AsyncBreak from stop/destroy is drained in clearStopInterrupt after join.
    hermesWatchTimeLimit(instance_id, 0);
    return true;
}

/// Request an interrupt owned by lifecycle shutdown without clearing a caller's explicit interrupt request or a configured deadline.
pub fn requestStopInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return false;
    }
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchOr(2, .monotonic);
    registry_mutex.unlock();
    hermesTriggerTimeout(instance_id);
    return true;
}

pub fn requestTeardownInterrupt(instance_id: i32, generation: u64) bool {
    if (!requestStopInterrupt(instance_id)) return false;
    hermesTriggerTeardownTimeout(instance_id, generation);
    return true;
}

/// A generation-scoped host shutdown is terminal for this runtime generation. Engine-thread stop/restart paths may clear their bit, so this uses a separate bit that is cleared only when runtime-control state is destroyed.
pub fn requestShutdownCancel(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    cancelShutdownState(state);
    return true;
}

fn cancelShutdownState(state: *InterruptState) void {
    state.shutdown_phase = .cancelled;
    const flag: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = flag.fetchOr(4, .monotonic);
}

fn refreshShutdown(state: *InterruptState, now: u64) void {
    if (state.shutdown_phase != .closing and state.shutdown_phase != .sealed) return;
    const deadline: *std.atomic.Value(u64) = @ptrCast(&state.shutdown_deadline_ms);
    const at = deadline.load(.monotonic);
    if (at != 0 and now >= at) cancelShutdownState(state);
}

/// Arm the generation's graceful-shutdown deadline without discarding messages already in a host transport. Repeated begins never extend the first deadline; the host sends its final fence through that same transport before sealing core submission.
pub fn beginShutdown(instance_id: i32, millis: u64) bool {
    if (millis == 0) return false;
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    const now: u64 = @intCast(io.monotonicMilliseconds());
    refreshShutdown(state, now);
    if (state.shutdown_phase != .open) return state.shutdown_phase == .closing or state.shutdown_phase == .sealed;
    const deadline: *std.atomic.Value(u64) = @ptrCast(&state.shutdown_deadline_ms);
    deadline.store(std.math.add(u64, now, millis) catch std.math.maxInt(u64), .monotonic);
    state.shutdown_phase = .closing;
    return true;
}

pub fn shutdownStatus(instance_id: i32) ?ShutdownStatus {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return null;
    if (!isHandlerReady(state)) return null;
    const now: u64 = @intCast(io.monotonicMilliseconds());
    refreshShutdown(state, now);
    const deadline: *std.atomic.Value(u64) = @ptrCast(&state.shutdown_deadline_ms);
    return .{ .phase = state.shutdown_phase, .remaining_ms = deadline.load(.monotonic) -| now };
}

/// User submissions remain admissible until the final transport marker seals the core FIFO. Internal dispatch and destruction retain their existing admission rules.
pub fn canSubmit(instance_id: i32) bool {
    const status = shutdownStatus(instance_id) orelse return false;
    return status.phase == .open or status.phase == .closing;
}

/// Sealed shutdown rejects fresh synchronous VM entry while allowing already-admitted queue turns and their nested host callbacks to finish.
pub fn canEnterExecution(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return true;
    if (!isHandlerReady(state)) return false;
    refreshShutdown(state, @intCast(io.monotonicMilliseconds()));
    return state.shutdown_phase == .open or state.shutdown_phase == .closing or state.budget_depth != 0;
}

/// Called in the same instance admission critical section, only after the final fence has successfully entered the FIFO.
pub fn sealShutdown(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    refreshShutdown(state, @intCast(io.monotonicMilliseconds()));
    if (state.shutdown_phase != .closing) return false;
    state.shutdown_phase = .sealed;
    return true;
}

/// A completed fence reports queue progress rather than script success. Its caller runs after the preceding task's microtask checkpoint.
pub fn completeShutdownDrain(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    refreshShutdown(state, @intCast(io.monotonicMilliseconds()));
    if (state.shutdown_phase != .sealed) return false;
    state.shutdown_phase = .drained;
    return true;
}

pub fn clearStopInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return false;
    }
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchAnd(~@as(u8, 2), .monotonic);
    registry_mutex.unlock();
    // threadStop → requestStopInterrupt → asyncTriggerTimeout is sticky on Hermes.
    hermesWatchTimeLimit(instance_id, 0);
    hermesDrainAsyncTimeout(instance_id);
    return true;
}

fn armJscWatchdogShortLimit(instance_id: i32, millis: u64) void {
    if (comptime !(backend.active_backend == .jsc or backend.isPacked(.jsc))) return;
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const inst = lease.inst;
    const jsc_mod = @import("../backend/jsc.zig");

    registry_mutex.lock();
    const state = registry.get(instance_id);
    const interrupt_state = state orelse {
        registry_mutex.unlock();
        return;
    };
    if (!isHandlerReady(interrupt_state) or
        interrupt_state.instance_id != instance_id or
        interrupt_state.generation != inst.generation or
        interrupt_state.backend_tag != backend.backendToC(inst.backendTag()))
    {
        registry_mutex.unlock();
        return;
    }
    interrupt_state.active_handler_users += 1;
    registry_mutex.unlock();
    defer {
        registry_mutex.lock();
        std.debug.assert(interrupt_state.active_handler_users != 0);
        interrupt_state.active_handler_users -= 1;
        registry_condition.broadcast();
        registry_mutex.unlock();
    }

    const period_sec = @as(f64, @floatFromInt(millis)) / 1000.0;
    switch (inst.engine_handles) {
        .mono => |m| if (backend.active_backend == .jsc) {
            const jsc_state: *jsc_mod.JscInterruptState = @ptrCast(interrupt_state);
            const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(m.ctx));
            jsc_mod.jscArmWatchdogPeriod(group, jsc_state, period_sec);
        },
        .packed_alt => |a| if (a.tag == .jsc) {
            const jsc_state: *jsc_mod.JscInterruptState = @ptrCast(interrupt_state);
            const ctx: jsc_mod.jsc.JSGlobalContextRef = @ptrFromInt(a.ctx_addr);
            const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(ctx));
            jsc_mod.jscArmWatchdogPeriod(group, jsc_state, period_sec);
        },
    }
}

/// Set an execution time limit in milliseconds. Passing 0 disables the limit. Thread-safe. Returns false if not initialized.
///
/// Deadlines expire automatically when monotonic time passes `now + millis` and do not leave a sticky interrupt flag. Setting a non-zero time limit establishes a new execution window and automatically clears any stale user interrupt flag.
///
/// Enforcement precision varies by backend: QuickJS checks interrupts at bytecode safe points (every ~10,000 opcode ticks, sub-millisecond in compute loops); JavaScriptCore (JSC) relies on a watchdog timer checking thread CPU time at min(remaining, 50ms) intervals (clamped to >= 5ms).
pub fn setExecutionTimeLimit(instance_id: i32, millis: u64) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    if (millis != 0 and jscPollingControlsUnavailable(state)) return false;
    const p: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    if (millis == 0) {
        p.store(0, .monotonic);
        return true;
    }
    const now: u64 = @intCast(io.monotonicMilliseconds());
    // Saturate instead of wrapping: an absurdly large `millis` must mean "effectively no deadline", never wrap to an already-expired one.
    const deadline = std.math.add(u64, now, millis) catch std.math.maxInt(u64);
    p.store(deadline, .monotonic);
    // Setting a fresh execution time limit establishes a new execution window; clear any stale user interrupt flag so the upcoming execution is not prematurely aborted.
    const target_ptr: *std.atomic.Value(u64) = @ptrCast(&state.interrupt_target);
    target_ptr.store(0, .monotonic);
    const req_ptr: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = req_ptr.fetchAnd(~@as(u8, 1), .monotonic);
    return true;
}

/// Configure a deadline applied to each outer VM entry. Zero disables it; idle time never consumes this budget.
pub fn setExecutionBudget(instance_id: i32, millis: u64) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    if (!isHandlerReady(state)) return false;
    if (millis != 0 and jscPollingControlsUnavailable(state)) return false;
    state.budget_millis = millis;
    if (millis != 0) {
        const target_ptr: *std.atomic.Value(u64) = @ptrCast(&state.interrupt_target);
        target_ptr.store(0, .monotonic);
        const req_ptr: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
        _ = req_ptr.fetchAnd(~@as(u8, 1), .monotonic);
    }
    return true;
}

/// Nested VM entries retain the first deadline so a callback cannot extend its caller's budget.
pub fn beginExecutionBudget(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return false;
    }
    var short_budget_millis: u64 = 0;
    if (state.budget_depth == 0) {
        const epoch_ptr: *std.atomic.Value(u64) = @ptrCast(&state.exec_epoch);
        const cur = epoch_ptr.load(.monotonic);
        const next_odd = if (cur % 2 == 0) cur + 1 else cur + 2;
        epoch_ptr.store(next_odd, .monotonic);

        if (state.budget_millis != 0) {
            const now: u64 = @intCast(io.monotonicMilliseconds());
            const deadline: u64 = std.math.add(u64, now, state.budget_millis) catch std.math.maxInt(u64);
            const deadline_ptr: *std.atomic.Value(u64) = @ptrCast(&state.budget_deadline_ms);
            deadline_ptr.store(deadline, .monotonic);
            if (state.budget_millis < 50) short_budget_millis = state.budget_millis;
        }
    }
    state.budget_depth += 1;
    registry_mutex.unlock();

    if (short_budget_millis != 0) {
        armJscWatchdogShortLimit(instance_id, short_budget_millis);
    }
    return true;
}

pub fn endExecutionBudget(instance_id: i32) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return;
    if (!isHandlerReady(state)) return;
    std.debug.assert(state.budget_depth != 0);
    state.budget_depth -= 1;
    if (state.budget_depth == 0) {
        const epoch_ptr: *std.atomic.Value(u64) = @ptrCast(&state.exec_epoch);
        const cur = epoch_ptr.load(.monotonic);
        const next_even = if (cur % 2 == 1) cur + 1 else cur + 2;
        epoch_ptr.store(next_even, .monotonic);

        const deadline_ptr: *std.atomic.Value(u64) = @ptrCast(&state.budget_deadline_ms);
        deadline_ptr.store(0, .monotonic);
    }
}

/// Snapshot the remaining engine execution budget without entering the VM. Null means no configured deadline; zero means it has already elapsed.
pub fn remainingExecutionLimitMillis(instance_id: i32) ?u64 {
    const deadline = executionDeadlineMillis(instance_id) orelse return null;
    const now: u64 = @intCast(io.monotonicMilliseconds());
    return if (now >= deadline) 0 else deadline - now;
}

/// Absolute monotonic deadline snapshot. Null means no configured limit.
pub fn executionDeadlineMillis(instance_id: i32) ?u64 {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return null;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return null;
    }
    const p: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    const deadline = p.load(.monotonic);
    registry_mutex.unlock();
    return if (deadline == 0) null else deadline;
}

/// Earliest deadline across the absolute time limit, active VM-entry budget, and shutdown grace period. This leaves executionDeadlineMillis as the absolute-limit query for existing callers.
pub fn effectiveExecutionDeadlineMillis(instance_id: i32) ?u64 {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return null;
    if (!isHandlerReady(state)) return null;
    const manual_ptr: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    const budget_ptr: *std.atomic.Value(u64) = @ptrCast(&state.budget_deadline_ms);
    const manual = manual_ptr.load(.monotonic);
    const budget = budget_ptr.load(.monotonic);
    const shutdown_ptr: *std.atomic.Value(u64) = @ptrCast(&state.shutdown_deadline_ms);
    const shutdown = shutdown_ptr.load(.monotonic);
    var earliest: u64 = 0;
    for ([_]u64{ manual, budget, shutdown }) |deadline| {
        if (deadline != 0 and (earliest == 0 or deadline < earliest)) earliest = deadline;
    }
    return if (earliest == 0) null else earliest;
}

pub fn remainingEffectiveExecutionLimitMillis(instance_id: i32) ?u64 {
    const deadline = effectiveExecutionDeadlineMillis(instance_id) orelse return null;
    const now: u64 = @intCast(io.monotonicMilliseconds());
    return if (now >= deadline) 0 else deadline - now;
}

/// True when a caller-requested interrupt bit is set. Lifecycle stop uses a separate bit (`isStopRequested`); do not treat stop as a user interrupt — waiters must report teardown as instance-gone.
pub fn isInterruptRequested(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return false;
    }
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    const requested = (p.load(.monotonic) & 1) != 0;
    registry_mutex.unlock();
    return requested;
}

/// True when lifecycle shutdown has requested an interrupt. This is separate from a caller-requested interrupt so waiters can report instance teardown rather than treating a stopped runtime as a user cancellation.
pub fn isStopRequested(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (!isHandlerReady(state)) {
        registry_mutex.unlock();
        return false;
    }
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    const requested = (p.load(.monotonic) & 2) != 0;
    registry_mutex.unlock();
    return requested;
}

pub const runGc = observation.runGc;
pub const setMemoryLimit = observation.setMemoryLimit;
pub const requestIdleGc = observation.requestIdleGc;
pub const noteIdle = observation.noteIdle;
pub const idleCollectionCount = observation.idleCollectionCount;
pub const getMemoryUsage = observation.getMemoryUsage;
