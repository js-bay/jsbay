const std = @import("std");
const io = @import("../platform/io.zig");
const sync = @import("zev");
const backend = @import("../backend.zig");
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

/// Force a GC pass on the runtime. Must be called on the engine's owning thread. Returns false if the instance was never created.
pub fn runGc(instance_id: i32) bool {
    const inst = instance_map.getInstance(instance_id) orelse return false;
    switch (inst.engine_handles) {
        .mono => |m| switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                qjs_mod.qjsRunGc(m.runtime);
            },
            .jsc => {
                const jsc_mod = @import("../backend/jsc.zig");
                jsc_mod.jscRunGc(@ptrCast(m.ctx));
            },
            .escargot => {
                if (comptime backend.isEscargotBackend(backend.active_backend)) {
                    @import("../backend/escargot.zig").EscargotBackend.runGc(m.runtime);
                }
            },
            .hermes => {
                if (comptime backend.isHermesBackend(backend.active_backend)) {
                    @import("../backend/hermes.zig").HermesBackend.runGc(m.runtime);
                }
            },
        },
        .packed_alt => |a| @import("../backend_dispatch.zig").runGcPacked(a.tag, .{
            .runtime_addr = a.runtime_addr,
            .ctx_addr = a.ctx_addr,
        }),
    }
    return true;
}

/// Cap the QuickJS-managed heap of this runtime at `bytes` (0 = unlimited). This does not cap allocations outside QuickJS, so it is not a process-RSS limit. Must be called on the engine's owning thread before the script it should bound runs. QuickJS: enforced via `JS_SetMemoryLimit` (GC is triggered on the next allocation past the cap). JSC: no public C API exists, so this operation is unsupported and returns false. Returns false when the instance was never created.
pub fn setMemoryLimit(instance_id: i32, bytes: u64) bool {
    const inst = instance_map.getInstance(instance_id) orelse return false;
    switch (inst.engine_handles) {
        // Comptime switch: do not call ActiveEngineModule.qjs* when primary is JSC (Zig still typechecks the dead runtime `if`).
        .mono => |m| switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                qjs_mod.qjsSetMemoryLimit(m.runtime, @intCast(bytes));
                return true;
            },
            .jsc, .escargot, .hermes => return false,
        },
        .packed_alt => |a| {
            if (!backend.isQuickJsApiBackend(a.tag)) return false;
            inline for (.{ .quickjs_ng, .quickjs }) |cand| {
                if (a.tag == cand) {
                    // Gate EngineModule imports on pack membership so mono-JSC builds do not pull qjs.
                    if (comptime backend.isPacked(cand) or cand == backend.active_backend) {
                        const E = backend.Engine(cand);
                        const Mod = backend.EngineModule(cand);
                        const rt = @as(E.Runtime, @ptrFromInt(a.runtime_addr));
                        Mod.qjsSetMemoryLimit(rt, @intCast(bytes));
                        return true;
                    }
                    return false;
                }
            }
            return false;
        },
    }
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
    switch (live.engine_handles) {
        .mono => |m| switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                qjs_mod.qjsRunGc(m.runtime);
            },
            .jsc => {
                const jsc_mod = @import("../backend/jsc.zig");
                jsc_mod.jscRunGc(@ptrCast(m.ctx));
            },
            .escargot => {
                if (comptime backend.isEscargotBackend(backend.active_backend)) {
                    @import("../backend/escargot.zig").EscargotBackend.runGc(m.runtime);
                }
            },
            .hermes => {
                if (comptime backend.isHermesBackend(backend.active_backend)) {
                    @import("../backend/hermes.zig").HermesBackend.runGc(m.runtime);
                }
            },
        },
        .packed_alt => |a| @import("../backend_dispatch.zig").runGcPacked(a.tag, .{
            .runtime_addr = a.runtime_addr,
            .ctx_addr = a.ctx_addr,
        }),
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
    switch (inst.engine_handles) {
        .mono => |m| switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs_mod = @import("../backend.zig").ActiveEngineModule;
                const snap = qjs_mod.qjsMemoryUsage(m.runtime);
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
            .jsc => return .{},
            .escargot => {
                if (comptime backend.isEscargotBackend(backend.active_backend)) {
                    const esc = @import("../backend/escargot/c_api.zig");
                    const heap: u64 = esc.escargot_runtime_heap_size(m.runtime);
                    const total: u64 = esc.escargot_runtime_total_size(m.runtime);
                    return .{
                        .malloc_size = total,
                        .memory_used_size = heap,
                    };
                }
                return .{};
            },
            .hermes => {
                if (comptime backend.isHermesBackend(backend.active_backend)) {
                    const hermes = @import("../backend/hermes/c_api.zig");
                    return .{
                        .malloc_size = hermes.hermes_runtime_allocated_bytes(m.runtime),
                        .memory_used_size = hermes.hermes_runtime_heap_size(m.runtime),
                    };
                }
                return .{};
            },
        },
        .packed_alt => |a| {
            if (!backend.isQuickJsApiBackend(a.tag)) return .{};
            inline for (.{ .quickjs_ng, .quickjs }) |cand| {
                if (a.tag == cand) {
                    if (comptime backend.isPacked(cand) or cand == backend.active_backend) {
                        const E = backend.Engine(cand);
                        const Mod = backend.EngineModule(cand);
                        const rt = @as(E.Runtime, @ptrFromInt(a.runtime_addr));
                        const snap = Mod.qjsMemoryUsage(rt);
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
                    }
                    return .{};
                }
            }
            return .{};
        },
    }
}
