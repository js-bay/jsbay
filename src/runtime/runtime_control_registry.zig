const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const instance_map = @import("instance_map.zig");

pub const ShutdownPhase = enum(c_int) { open = 0, closing = 1, sealed = 2, drained = 3, cancelled = 4 };
pub const ShutdownStatus = struct { phase: ShutdownPhase, remaining_ms: u64 };

pub const HandlerStatus = enum(u8) { installing, ready, removing, failed };

/// Per-instance state shared between public control calls and backend interrupt trampolines. Registry access is serialized; interrupt flags and deadlines use atomic access. Backend trampoline structs preserve their shared field prefix.
pub const InterruptState = extern struct {
    /// Non-zero when an interrupt has been requested. Read by the trampoline on every interrupt check.
    interrupt_requested: u8 = 0,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// Absolute monotonic deadline in ms (from io.monotonicMilliseconds). Zero means "no limit". Read atomically.
    deadline_ms: u64 = 0,
    /// Instance this state belongs to. -1 until init() fills it in.
    instance_id: i32 = -1,
    budget_millis: u64 = 0,
    budget_deadline_ms: u64 = 0,
    budget_depth: usize = 0,
    shutdown_deadline_ms: u64 = 0,
    shutdown_phase: ShutdownPhase = .open,
    /// Execution epoch: even = idle, odd = running.
    exec_epoch: u64 = 0,
    /// Monotonic target epoch for user interrupts (via fetchMax).
    interrupt_target: u64 = 0,
    /// Backend tag used by control-plane calls while holding registry_mutex.
    backend_tag: backend.BackendC = .primary,
    generation: u64 = 0,
    handler_status: HandlerStatus = .ready,
    registration_waiters: usize = 0,
    active_handler_users: usize = 0,
};

fn assertTrampolinePrefix(comptime Shadow: type) void {
    const fields = .{
        "interrupt_requested",
        "_pad",
        "deadline_ms",
        "instance_id",
        "budget_millis",
        "budget_deadline_ms",
        "budget_depth",
        "shutdown_deadline_ms",
        "shutdown_phase",
        "exec_epoch",
        "interrupt_target",
    };
    inline for (fields) |field| {
        if (@offsetOf(Shadow, field) != @offsetOf(InterruptState, field)) {
            @compileError("backend interrupt state field offsets must match InterruptState");
        }
    }
    if (@sizeOf(Shadow) != @offsetOf(InterruptState, "backend_tag")) {
        @compileError("backend interrupt state must end at the InterruptState shared prefix");
    }
}

comptime {
    if (backend.isPacked(.quickjs)) {
        assertTrampolinePrefix(@import("../backend/quickjs/runtime_control.zig").QjsInterruptState);
    }
    if (backend.isPacked(.quickjs_ng)) {
        assertTrampolinePrefix(@import("../backend/quickjs_ng/runtime_control.zig").QjsInterruptState);
    }
    if (backend.isPacked(.jsc)) {
        assertTrampolinePrefix(@import("../backend/jsc/runtime_control.zig").JscInterruptState);
    }
}

// ---- Module-global state registry --------------------------------------------

pub var registry: std.AutoHashMap(i32, *InterruptState) =
    std.AutoHashMap(i32, *InterruptState).init(std.heap.c_allocator);
// Lock order: instance_map.mutex may precede this mutex during engine publication; this mutex may precede polling_config.mutex. Never acquire instance_map.mutex or call JSC while holding this mutex.
pub var registry_mutex: sync.Mutex = .{};
pub var registry_condition: sync.Condition = .init;

pub fn takeState(instance_id: i32) ?*InterruptState {
    registry_mutex.lock();
    while (registry.get(instance_id)) |state| {
        if (state.handler_status != .installing and state.handler_status != .removing and state.handler_status != .failed and state.registration_waiters == 0) break;
        registry_condition.wait(&registry_mutex);
    }
    const kv = registry.fetchRemove(instance_id) orelse {
        registry_mutex.unlock();
        return null;
    };
    registry_mutex.unlock();
    return kv.value;
}

// ---- Public API --------------------------------------------------------------

/// Arm interrupt + time-limit support for the given instance. Must be called after `engine.create` and before any other runtime_control operation on this instance. Idempotent for the same instance generation and backend.
///
/// Returns false if the instance does not exist.
pub fn init(instance_id: i32) bool {
    const lease = instance_map.beginControlPlane(instance_id) orelse return false;
    defer lease.end();
    return initForInstance(instance_id, lease.inst);
}

/// Install control state while an instance is being published under the instance-map lock. It must not look the instance up again: creation uses it before the instance becomes observable to normal readers.
pub fn initForInstance(instance_id: i32, inst: *instance_map.EngineInstance) bool {
    return initForInstanceWithHooks(instance_id, inst, std.heap.c_allocator, null, installInterruptHandlerAdapter, null);
}

pub const HandlerInstaller = *const fn (*instance_map.EngineInstance, *InterruptState, ?*anyopaque) bool;
pub const RegistrationFailureHook = *const fn (?*anyopaque) void;

fn installInterruptHandlerAdapter(inst: *instance_map.EngineInstance, state: *InterruptState, _: ?*anyopaque) bool {
    return installInterruptHandler(inst, state);
}

pub fn initForInstanceWithHooks(
    instance_id: i32,
    inst: *instance_map.EngineInstance,
    allocator: std.mem.Allocator,
    context: ?*anyopaque,
    installer: HandlerInstaller,
    failure_hook: ?RegistrationFailureHook,
) bool {
    const generation = inst.generation;
    const backend_tag = backend.backendToC(inst.backendTag());

    // Preserve allocation-free idempotence for an already installed handler.
    registry_mutex.lock();
    if (registry.get(instance_id)) |existing| {
        if (existing.generation != generation or existing.backend_tag != backend_tag) {
            registry_mutex.unlock();
            return false;
        }
        switch (existing.handler_status) {
            .ready => {
                registry_mutex.unlock();
                return true;
            },
            .failed, .removing => {
                registry_mutex.unlock();
                return false;
            },
            .installing => {
                existing.registration_waiters += 1;
                registry_condition.broadcast();
                while (existing.handler_status == .installing) registry_condition.wait(&registry_mutex);
                const ready = existing.handler_status == .ready;
                existing.registration_waiters -= 1;
                registry_condition.broadcast();
                registry_mutex.unlock();
                return ready;
            },
        }
    }
    registry_mutex.unlock();

    const state = allocator.create(InterruptState) catch return false;
    state.* = .{
        .interrupt_requested = 0,
        .deadline_ms = 0,
        .instance_id = instance_id,
        .budget_millis = 0,
        .budget_deadline_ms = 0,
        .budget_depth = 0,
        .exec_epoch = 0,
        .interrupt_target = 0,
        .backend_tag = backend_tag,
        .generation = generation,
        .handler_status = .installing,
    };

    registry_mutex.lock();
    while (registry.get(instance_id)) |existing| {
        if (existing.generation != state.generation or existing.backend_tag != state.backend_tag) {
            registry_mutex.unlock();
            allocator.destroy(state);
            return false;
        }
        switch (existing.handler_status) {
            .ready => {
                registry_mutex.unlock();
                allocator.destroy(state);
                return true;
            },
            .failed => {
                registry_mutex.unlock();
                allocator.destroy(state);
                return false;
            },
            .removing => {
                registry_mutex.unlock();
                allocator.destroy(state);
                return false;
            },
            .installing => {
                existing.registration_waiters += 1;
                registry_condition.broadcast();
                while (existing.handler_status == .installing) registry_condition.wait(&registry_mutex);
                const ready = existing.handler_status == .ready;
                existing.registration_waiters -= 1;
                registry_condition.broadcast();
                registry_mutex.unlock();
                allocator.destroy(state);
                return ready;
            },
        }
    }
    registry.put(instance_id, state) catch {
        registry_mutex.unlock();
        allocator.destroy(state);
        return false;
    };
    registry_mutex.unlock();

    const installed = installer(inst, state, context);

    registry_mutex.lock();
    if (installed) {
        state.handler_status = .ready;
        registry_condition.broadcast();
        registry_mutex.unlock();
        return true;
    }
    registry_mutex.unlock();
    markRegistrationFailed(instance_id, state, context, failure_hook);
    removeFailedRegistration(allocator, instance_id, state);
    return false;
}

/// Publish installation failure while leaving cleanup ownership with the installer.
fn markRegistrationFailed(
    instance_id: i32,
    state: *InterruptState,
    context: ?*anyopaque,
    failure_hook: ?RegistrationFailureHook,
) void {
    registry_mutex.lock();
    if (registry.get(instance_id) == state) state.handler_status = .failed;
    registry_condition.broadcast();
    registry_mutex.unlock();
    if (failure_hook) |hook| hook(context);
}

/// The installer exclusively removes failed state after registered init waiters have left.
fn removeFailedRegistration(allocator: std.mem.Allocator, instance_id: i32, state: *InterruptState) void {
    registry_mutex.lock();
    while (true) {
        if (registry.get(instance_id) != state) {
            registry_mutex.unlock();
            return;
        }
        if (state.registration_waiters == 0) break;
        registry_condition.wait(&registry_mutex);
    }
    const owns_state = if (registry.get(instance_id) == state)
        registry.fetchRemove(instance_id) != null
    else
        false;
    registry_condition.broadcast();
    registry_mutex.unlock();
    if (owns_state) allocator.destroy(state);
}

fn installInterruptHandler(inst: *instance_map.EngineInstance, state: *InterruptState) bool {
    switch (inst.engine_handles) {
        .mono => |m| switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                // Safe: the two extern structs have identical layout.
                const qjs_state: *qjs_mod.QjsInterruptState = @ptrCast(state);
                qjs_mod.qjsInstallInterruptHandler(m.runtime, qjs_state);
            },
            .jsc => {
                const jsc_mod = @import("../backend/jsc.zig");
                const jsc_state: *jsc_mod.JscInterruptState = @ptrCast(state);
                // 50ms watchdog period — keeps requestInterrupt latency low without incurring meaningful overhead on normal scripts.
                const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(m.ctx));
                jsc_mod.jscInstallInterruptHandler(group, jsc_state);
            },
            .escargot, .hermes => {},
        },
        .packed_alt => |a| {
            // Dispatch by the instance backend so non-primary packs get interrupt/time-limit handlers too.
            inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
                if (a.tag == cand) {
                    if (comptime !(backend.isPacked(cand) or cand == backend.active_backend)) return false;
                    if (comptime backend.isQuickJsApiBackend(cand)) {
                        const E = backend.Engine(cand);
                        const Mod = backend.EngineModule(cand);
                        const qjs_state: *Mod.QjsInterruptState = @ptrCast(state);
                        const rt: E.Runtime = @ptrFromInt(a.runtime_addr);
                        Mod.qjsInstallInterruptHandler(rt, qjs_state);
                    } else {
                        const jsc_mod = @import("../backend/jsc.zig");
                        const jsc_state: *jsc_mod.JscInterruptState = @ptrCast(state);
                        const ctx: jsc_mod.jsc.JSGlobalContextRef = @ptrFromInt(a.ctx_addr);
                        const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(ctx));
                        jsc_mod.jscInstallInterruptHandler(group, jsc_state);
                    }
                    break;
                }
            } else return false;
        },
    }

    return true;
}

/// Remove the interrupt trampoline and free the state. Call before `engine.destroy`. Idempotent — returns false if the instance was never initialized (or already torn down).
pub fn deinit(instance_id: i32) bool {
    const lease = instance_map.beginControlPlane(instance_id) orelse return false;
    defer lease.end();
    return deinitForInstance(instance_id, lease.inst);
}

/// Remove handler state while the caller owns the instance lifetime, either through a control-plane lease or teardown ownership.
pub fn deinitForInstance(instance_id: i32, inst: *instance_map.EngineInstance) bool {
    return deinitForInstanceWithWaitObserver(instance_id, inst, std.heap.c_allocator, null, null);
}

const DeinitWaitObserver = *const fn (?*anyopaque) void;

pub fn deinitForInstanceWithWaitObserver(
    instance_id: i32,
    inst: *instance_map.EngineInstance,
    allocator: std.mem.Allocator,
    observer_context: ?*anyopaque,
    observer: ?DeinitWaitObserver,
) bool {
    registry_mutex.lock();
    while (registry.get(instance_id)) |pending| {
        if (pending.handler_status != .installing and pending.handler_status != .removing and pending.handler_status != .failed and pending.registration_waiters == 0) break;
        if (observer) |notify| notify(observer_context);
        registry_condition.wait(&registry_mutex);
    }
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    if (state.generation != inst.generation or state.backend_tag != backend.backendToC(inst.backendTag())) {
        registry_mutex.unlock();
        return false;
    }
    state.handler_status = .removing;
    while (state.active_handler_users != 0) registry_condition.wait(&registry_mutex);
    registry_mutex.unlock();

    // Uninstall from the backend BEFORE freeing the state — otherwise the JS thread could read freed memory if it fires a check between takeState and here.
    {
        switch (inst.engine_handles) {
            .mono => |m| switch (backend.active_backend) {
                .quickjs, .quickjs_ng => {
                    const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                    qjs_mod.qjsUninstallInterruptHandler(m.runtime);
                },
                .jsc => {
                    const jsc_mod = @import("../backend/jsc.zig");
                    const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(m.ctx));
                    jsc_mod.jscUninstallInterruptHandler(group);
                },
                .escargot, .hermes => {},
            },
            .packed_alt => |a| {
                inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
                    if (a.tag == cand) {
                        if (comptime !(backend.isPacked(cand) or cand == backend.active_backend)) break;
                        if (comptime backend.isQuickJsApiBackend(cand)) {
                            const E = backend.Engine(cand);
                            const Mod = backend.EngineModule(cand);
                            const rt: E.Runtime = @ptrFromInt(a.runtime_addr);
                            Mod.qjsUninstallInterruptHandler(rt);
                        } else {
                            const jsc_mod = @import("../backend/jsc.zig");
                            const ctx: jsc_mod.jsc.JSGlobalContextRef = @ptrFromInt(a.ctx_addr);
                            const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(ctx));
                            jsc_mod.jscUninstallInterruptHandler(group);
                        }
                        break;
                    }
                }
            },
        }
    }

    registry_mutex.lock();
    const owns_state = if (registry.get(instance_id) == state)
        registry.fetchRemove(instance_id) != null
    else
        false;
    registry_condition.broadcast();
    registry_mutex.unlock();
    if (owns_state) allocator.destroy(state);
    return owns_state;
}

pub fn hermesTriggerTimeout(instance_id: i32) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    // Control-plane lease: refuse teardown_pending and keep destroyRuntime waiting so asyncTriggerTimeout cannot touch a freed Hermes runtime.
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    const her = @import("../backend/hermes.zig");
    her.c_api_mod.hermes_runtime_async_trigger_timeout(rt);
}

pub fn hermesWatchTimeLimit(instance_id: i32, millis: u64) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    // Lease across watch/unwatch so clear_interrupt cannot race destroyRuntime freeing the Hermes runtime while the map entry still exists.
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    const her = @import("../backend/hermes.zig");
    if (millis == 0) {
        her.c_api_mod.hermes_runtime_unwatch_time_limit(rt);
        return;
    }
    const capped: u32 = if (millis > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(millis);
    her.c_api_mod.hermes_runtime_watch_time_limit(rt, capped);
}

pub fn hermesDrainAsyncTimeout(instance_id: i32) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    // Same lease as watch/trigger: drain touches native Hermes timeout state that destroyRuntime frees.
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    const her = @import("../backend/hermes.zig");
    her.c_api_mod.hermes_runtime_drain_async_timeout(rt);
}

pub fn supportsMidScriptUserInterruptForBackend(tag: backend.BackendType, jsc_polling_enabled: bool) bool {
    return switch (tag) {
        .quickjs, .quickjs_ng => true,
        .jsc => jsc_polling_enabled,
        .escargot, .hermes => false,
    };
}

pub fn supportsMidScriptUserInterruptForState(state: *const InterruptState, jsc_polling_enabled: bool) bool {
    const tag = backend.backendFromC(@backingInt(state.backend_tag)) orelse return false;
    return supportsMidScriptUserInterruptForBackend(tag, jsc_polling_enabled);
}

pub fn isHandlerReady(state: *const InterruptState) bool {
    return state.handler_status == .ready;
}
