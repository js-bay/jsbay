//! Runtime control — interrupt handling, GC, memory introspection.
//!
//! Gives native code the ability to:
//! - cancel a long-running JS computation from another thread (requestInterrupt / clearInterrupt)
//!   - set an execution time limit that auto-interrupts expired scripts
//!   - force a synchronous GC pass and snapshot memory usage
//!
//! Lifecycle: Call `init(instance_id)` ONCE after `engine.create` to arm the backend-specific interrupt trampoline. `engine.destroy` calls `deinit(instance_id)` only after active JavaScript has unwound, while the runtime is still valid. Direct users may call `deinit` themselves before destroy when no evaluation is active.
//!
//! Thread-safety: `requestInterrupt` / `clearInterrupt` / `setExecutionTimeLimit` are safe to call from any thread (atomic loads/stores on the shared state). `runGc` / `getMemoryUsage` must be called on the engine's owning thread — they touch the JS runtime directly.
//!
//! Backend notes:
//! - QuickJS: full native support via `JS_SetInterruptHandler`. The JS VM throws an InternalError on the next interrupt check.
//! - JSC: uses the private `JSContextGroupSetExecutionTimeLimit` API (symbol ships in JavaScriptCore.framework, even though the public header hides it). The system JSC build exercised here needs the callback to explicitly re-arm its next 50ms check after it returns false, despite the upstream header documenting automatic continuation. This keeps `requestInterrupt` and execution deadlines responsive there. `runGc` uses the public `JSGarbageCollect` and is reliable on all JSC builds. Memory usage is not queryable through JSC's public C API and is reported as zeros.

const std = @import("std");
const io = @import("../platform/io.zig");
const sync = @import("zev");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("instance_map.zig");

/// Snapshot of runtime memory consumption. Fields not reported by a backend default to zero.
pub const MemoryUsage = extern struct {
    malloc_count: u64 = 0,
    malloc_size: u64 = 0,
    malloc_limit: u64 = 0,
    memory_used_count: u64 = 0,
    memory_used_size: u64 = 0,
    atom_count: u64 = 0,
    atom_size: u64 = 0,
    obj_count: u64 = 0,
    obj_size: u64 = 0,
    shape_count: u64 = 0,
};

/// Per-instance state shared between the public API (any thread) and the backend interrupt trampolines (JS thread). Fields are atomic; layout matches the `QjsInterruptState` / `JscInterruptState` extern structs declared in the backends so the trampolines can read this struct directly via a pointer cast.
pub const InterruptState = extern struct {
    /// Non-zero when an interrupt has been requested. Read by the trampoline on every interrupt check.
    interrupt_requested: u8 = 0,
    _pad: [7]u8 = .{ 0, 0, 0, 0, 0, 0, 0 },
    /// Absolute monotonic deadline in ms (from io.monotonicMilliseconds). Zero means "no limit". Read atomically.
    deadline_ms: u64 = 0,
    /// Instance this state belongs to. -1 until init() fills it in.
    instance_id: i32 = -1,
};

// ---- Module-global state registry --------------------------------------------

var registry: std.AutoHashMap(i32, *InterruptState) =
    std.AutoHashMap(i32, *InterruptState).init(std.heap.c_allocator);
var registry_mutex: sync.Mutex = .{};

fn takeState(instance_id: i32) ?*InterruptState {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const kv = registry.fetchRemove(instance_id) orelse return null;
    return kv.value;
}

// ---- Public API --------------------------------------------------------------

/// Arm interrupt + time-limit support for the given instance. Must be called after `engine.create` and before any other runtime_control operation on this instance. Idempotent — returns true if already initialized.
///
/// Returns false if the instance does not exist.
pub fn init(instance_id: i32) bool {
    const inst = instance_map.getInstance(instance_id) orelse return false;
    return initForInstance(instance_id, inst);
}

/// Install control state while an instance is being published under the instance-map lock. It must not look the instance up again: creation uses it before the instance becomes observable to normal readers.
pub fn initForInstance(instance_id: i32, inst: *instance_map.EngineInstance) bool {

    // Idempotency check.
    registry_mutex.lock();
    if (registry.get(instance_id) != null) {
        registry_mutex.unlock();
        return true;
    }
    registry_mutex.unlock();

    const state = std.heap.c_allocator.create(InterruptState) catch return false;
    state.* = .{
        .interrupt_requested = 0,
        .deadline_ms = 0,
        .instance_id = instance_id,
    };

    registry_mutex.lock();
    registry.put(instance_id, state) catch {
        registry_mutex.unlock();
        std.heap.c_allocator.destroy(state);
        return false;
    };
    registry_mutex.unlock();

    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            // Safe: the two extern structs have identical layout.
            const qjs_state: *qjs_mod.QjsInterruptState = @ptrCast(state);
            qjs_mod.qjsInstallInterruptHandler(inst.runtime, qjs_state);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const jsc_state: *jsc_mod.JscInterruptState = @ptrCast(state);
            // 50ms watchdog period — keeps requestInterrupt latency low without incurring meaningful overhead on normal scripts.
            const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(inst.ctx));
            jsc_mod.jscInstallInterruptHandler(group, jsc_state);
        },
    }

    return true;
}

/// Remove the interrupt trampoline and free the state. Call before `engine.destroy`. Idempotent — returns false if the instance was never initialized (or already torn down).
pub fn deinit(instance_id: i32) bool {
    const inst_opt = instance_map.getInstance(instance_id);

    const state = takeState(instance_id) orelse return false;

    // Uninstall from the backend BEFORE freeing the state — otherwise the JS thread could read freed memory if it fires a check between takeState and here.
    if (inst_opt) |inst| {
        switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                qjs_mod.qjsUninstallInterruptHandler(inst.runtime);
            },
            .jsc => {
                const jsc_mod = @import("../backend/jsc.zig");
                const group = jsc_mod.jsc.JSContextGetGroup(@ptrCast(inst.ctx));
                jsc_mod.jscUninstallInterruptHandler(group);
            },
        }
    }

    std.heap.c_allocator.destroy(state);
    return true;
}

/// Request that the JS runtime interrupt execution on the next interrupt check. Thread-safe. Returns false if the instance was never init()'d or has been deinit()'d.
///
/// After the script throws, call `clearInterrupt` to reset the flag.
pub fn requestInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchOr(1, .monotonic);
    return true;
}

/// Clear a pending user interrupt. Lifecycle shutdown owns a separate bit, so this cannot resume a script that is being stopped.
pub fn clearInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchAnd(~@as(u8, 1), .monotonic);
    return true;
}

/// Request an interrupt owned by lifecycle shutdown without clearing a caller's explicit interrupt request or a configured deadline.
pub fn requestStopInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchOr(2, .monotonic);
    return true;
}

pub fn clearStopInterrupt(instance_id: i32) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    _ = p.fetchAnd(~@as(u8, 2), .monotonic);
    return true;
}

/// Set an execution time limit in milliseconds. Passing 0 disables the limit. Thread-safe. Returns false if not initialized.
///
/// The deadline is computed at call time — any script that finishes before `now + millis` elapses is unaffected. Scripts still running after the deadline are interrupted on the next interrupt check (QJS: typically within a few hundred bytecode instructions; JSC: within ~50ms).
pub fn setExecutionTimeLimit(instance_id: i32, millis: u64) bool {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    const state = registry.get(instance_id) orelse return false;
    const p: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    if (millis == 0) {
        p.store(0, .monotonic);
        return true;
    }
    const now: u64 = @intCast(io.monotonicMilliseconds());
    // Saturate instead of wrapping: an absurdly large `millis` must mean "effectively no deadline", never wrap to an already-expired one.
    const deadline = std.math.add(u64, now, millis) catch std.math.maxInt(u64);
    p.store(deadline, .monotonic);
    return true;
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
    const p: *std.atomic.Value(u64) = @ptrCast(&state.deadline_ms);
    const deadline = p.load(.monotonic);
    registry_mutex.unlock();
    return if (deadline == 0) null else deadline;
}

pub fn isInterruptRequested(instance_id: i32) bool {
    registry_mutex.lock();
    const state = registry.get(instance_id) orelse {
        registry_mutex.unlock();
        return false;
    };
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    const requested = p.load(.monotonic) != 0;
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
    const p: *std.atomic.Value(u8) = @ptrCast(&state.interrupt_requested);
    const requested = (p.load(.monotonic) & 2) != 0;
    registry_mutex.unlock();
    return requested;
}

/// Force a GC pass on the runtime. Must be called on the engine's owning thread. Returns false if the instance was never created.
pub fn runGc(instance_id: i32) bool {
    const inst = instance_map.getInstance(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            qjs_mod.qjsRunGc(inst.runtime);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            jsc_mod.jscRunGc(inst.ctx);
        },
    }
    return true;
}

/// Cap the QuickJS-managed heap of this runtime at `bytes` (0 = unlimited). This does not cap allocations outside QuickJS, so it is not a process-RSS limit. Must be called on the engine's owning thread before the script it should bound runs. QuickJS: enforced via `JS_SetMemoryLimit` (GC is triggered on the next allocation past the cap). JSC: no public C API exists, so this operation is unsupported and returns false. Returns false when the instance was never created.
pub fn setMemoryLimit(instance_id: i32, bytes: u64) bool {
    const inst = instance_map.getInstance(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            qjs_mod.qjsSetMemoryLimit(inst.runtime, @intCast(bytes));
        },
        .jsc => {
            // No public JSC heap-cap API. Do not claim an unenforced cap.
            return false;
        },
    }
    return true;
}

/// Ask for one idle collection. Does not collect now and does not retain the JS runtime — `engine.destroy` can still free it while the request is queued. Extra requests before the next idle collection collapse into a single pending collection (one idle pass drains the whole queue). Returns false if the instance does not exist.
pub fn requestIdleGc(instance_id: i32) bool {
    const inst = instance_map.getInstance(instance_id) orelse return false;
    idle_mutex.lock();
    defer idle_mutex.unlock();
    const slot = idleSlot(instance_id) orelse return false;
    adoptSlot(slot, @intFromPtr(inst));
    slot.pending +|= 1;
    return true;
}

/// Host is idle. If a collection was requested and the cooldown has elapsed, run GC once, clear every queued request, and start the cooldown. Further `noteIdle` calls during the cooldown do not collect, even if `requestIdleGc` is called again.
///
/// Returns false when `instance_id` is not a live engine, including after `engine.destroy`. Returns true when the instance is alive. Whether a collection ran is `idleCollectionCount`, not this boolean.
pub fn noteIdle(instance_id: i32) bool {
    const inst = instance_map.getInstance(instance_id) orelse {
        // Drop the queued request. It stores no runtime pointer, so this only forgets bookkeeping; destroy has already freed the engine.
        idle_mutex.lock();
        _ = idle_map.fetchRemove(instance_id);
        idle_mutex.unlock();
        return false;
    };
    const owner = @intFromPtr(inst);

    var should_collect = false;
    idle_mutex.lock();
    if (idle_map.getPtr(instance_id)) |slot| {
        // A slot left behind by a destroyed engine must not collect for a new engine that reused the id. The stored address is not dereferenced.
        if (slot.owner != owner) {
            slot.* = .{ .owner = owner };
        } else if (slot.pending != 0) {
            const now = monotonicMs();
            if (now >= slot.cooldown_until_ms) {
                slot.pending = 0;
                slot.collections += 1;
                slot.cooldown_until_ms = std.math.add(u64, now, idle_cooldown_ms) catch std.math.maxInt(u64);
                should_collect = true;
            }
        }
    }
    idle_mutex.unlock();

    if (!should_collect) return true;

    // Resolve the runtime again after the lock. A destroy that won the race must not be followed by a GC on a freed runtime.
    const live = instance_map.getInstance(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            qjs_mod.qjsRunGc(live.runtime);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            jsc_mod.jscRunGc(live.ctx);
        },
    }
    return true;
}

/// How many times `noteIdle` has actually run GC for this instance. Zero if the instance was never requested, or after its idle slot was dropped by `noteIdle` following `engine.destroy`.
pub fn idleCollectionCount(instance_id: i32) u64 {
    idle_mutex.lock();
    defer idle_mutex.unlock();
    const slot = idle_map.get(instance_id) orelse return 0;
    return slot.collections;
}

/// Wall-clock gap after an idle collection during which `noteIdle` will not collect again. Long enough that back-to-back test calls stay inside it.
const idle_cooldown_ms: u64 = 5_000;

const IdleSlot = struct {
    /// Address of the EngineInstance that owns this slot. Not dereferenced.
    owner: usize = 0,
    pending: u32 = 0,
    cooldown_until_ms: u64 = 0,
    collections: u64 = 0,
};

fn adoptSlot(slot: *IdleSlot, owner: usize) void {
    if (slot.owner != owner) slot.* = .{ .owner = owner };
}

var idle_map: std.AutoHashMap(i32, IdleSlot) = std.AutoHashMap(i32, IdleSlot).init(std.heap.c_allocator);
var idle_mutex: sync.Mutex = .{};

fn monotonicMs() u64 {
    const now = io.monotonicMilliseconds();
    if (now <= 0) return 0;
    return @intCast(now);
}

fn idleSlot(instance_id: i32) ?*IdleSlot {
    if (idle_map.getPtr(instance_id)) |slot| return slot;
    idle_map.put(instance_id, .{}) catch return null;
    return idle_map.getPtr(instance_id);
}

/// Snapshot memory usage. Returns null if the instance was never created. Backends that don't expose memory stats populate zeros.
pub fn getMemoryUsage(instance_id: i32) ?MemoryUsage {
    const inst = instance_map.getInstance(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const snap = qjs_mod.qjsMemoryUsage(inst.runtime);
            return .{
                .malloc_count = snap.malloc_count,
                .malloc_size = snap.malloc_size,
                .malloc_limit = snap.malloc_limit,
                .memory_used_count = snap.memory_used_count,
                .memory_used_size = snap.memory_used_size,
                .atom_count = snap.atom_count,
                .atom_size = snap.atom_size,
                .obj_count = snap.obj_count,
                .obj_size = snap.obj_size,
                .shape_count = snap.shape_count,
            };
        },
        .jsc => {
            // JSC's public C API does not expose heap introspection. Returning all-zeros keeps the API shape consistent.
            return .{};
        },
    }
}
