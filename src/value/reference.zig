//! Reference lifecycle — Local / Global(T) / Weak(T) / Scope / StackFrameScope.
//!
//! Users who need to hold a JS `Value` across scope boundaries (e.g. store a callback in a Zig data structure) should reach for `Global(T)`; temporary in-scope values are the backend-native `Local` (aka `ActiveEngine.Value`).
//!
//! ## Lifetime summary
//!
//! - `Local` — backend Value. No retain; lifetime follows the active backend's ownership rules (refcount or GC root).
//! - `Global(T)` — retained across scopes. `init` duplicates the value; the retained value is released on `reset` (or when the owning engine is destroyed, see `engine.destroy` → bookkeeping walk).
//! - `Weak(T)` — **true weak** reference on JS objects. `get()` returns null once the target has been garbage collected. See "Weak semantics" below.
//! - `Rooted` — refcounted GC root. `root` calls the backend protect only on the 0→1 edge; `unroot` releases only when the count returns to 0. On Hermes the protect-map wrapper is separate from a reusable weak identity so re-rooting a still-live object works after unroot. `Global` is unchanged and still protects exactly once.
//! - `Scope` — threadlocal stack that `currentInstanceId()` reads. Not yet required before every API call; exists so consumers can query the active engine id without passing it everywhere.
//! - `StackFrameScope` — thin wrapper around `dupValue` for values that need to escape a frame.
//!
//! ## Weak semantics
//!
//! `Weak(T)` is a true weak reference when the target value is a JS **object** (including arrays, functions, plain objects, typed arrays). `.get()` returns null after the underlying object has been garbage collected.
//!
//! - **Refcount backends**: a finalizer watcher object (`WeakWatcher` class, registered once per runtime) is attached to the target as a hidden property (`__$jsbay_qjs_Weak$__`). Because the target strongly references the watcher (not the other way around), the watcher becomes unreachable exactly when the target does; its finalizer then clears a shared `WatcherData` struct. The Zig-side `Weak.get()` reads that struct to decide whether the target is still live.
//!
//! - **GC backends with weak handles**: implemented via the backend weak-reference API declared in `backend/jsc/weak.zig` (`JSWeakCreate` / `JSWeakGetObject`).
//!
//! ### Primitives policy
//!
//! Non-object values (numbers, booleans, strings, null, undefined) are not subject to garbage collection in the same way — numbers/booleans are inlined in the tagged value; strings are refcounted or interned depending on the backend. For these, `Weak.init` stores a retained copy and behaves like a tiny `Global` that never spontaneously clears. Callers that want strict "null after GC" semantics should wrap primitives in an object first.
//!
//! ## Implementation note: heap-allocated handle
//!
//! `Global` and `Weak` are value types that may be moved/copied (e.g. by return-by-value from `init`). To keep their bookkeeping stable across such moves, the actual state lives in a heap-allocated `Cell` and the Global/Weak holds a stable pointer to it. The Cell embeds the intrusive `RefEntry` so `engine.destroy` can walk all live references and force-reset them before tearing down the JS runtime — preventing use-after-free when consumers forget to call `reset()` themselves.
//!
//! ## Thread affinity
//!
//! All Global, Weak, and Rooted operations (init, get, reset, deinit) must be performed on the owning engine thread. Engine teardown walks the intrusive bookkeeping list to reset dangling references before runtime destruction. OwnedValue represents local scoped ownership and must not outlive its owning context.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const ref_op = @import("reference_op.zig");
const rooted = @import("rooted.zig");

pub const Rooted = rooted.Rooted;
pub const isRefOpActiveOnCurrentThread = ref_op.isRefOpActiveOnCurrentThread;
pub const requestDeferredDestroy = ref_op.requestDeferredDestroy;
const RefOperation = ref_op.RefOperation;
const beginRefOperation = ref_op.beginRefOperation;
const unregisterEntry = ref_op.unregisterEntry;
const abandonEntry = ref_op.abandonEntry;
const finishRefRelease = ref_op.finishRefRelease;
const registerEntryDirect = ref_op.registerEntryDirect;

const ActiveEngine = backend.ActiveEngine;
var global_release_hook_for_testing: ?*const fn (?*anyopaque) void = null;
var global_release_hook_context_for_testing: ?*anyopaque = null;

pub fn setGlobalReleaseHookForTesting(hook: ?*const fn (?*anyopaque) void, ctx: ?*anyopaque) void {
    if (!builtin.is_test) return;
    global_release_hook_for_testing = hook;
    global_release_hook_context_for_testing = ctx;
}

/// Convenience alias so consumers can write `reference.Local` instead of reaching into the backend module for the Value type.
pub const Local = ActiveEngine.Value;

const scope = @import("scope.zig");

pub const OwnedValue = scope.OwnedValue;
pub const Scope = scope.Scope;
pub const activate = scope.activate;
pub const currentInstanceId = scope.currentInstanceId;
pub const StackFrameScope = scope.StackFrameScope;

// ----------------------------------------------------------------------
// Bookkeeping cells (heap-allocated, pointed at by Global/Weak)
// ----------------------------------------------------------------------

/// State for a Global. The entry is pre-unlinked by `engine.forceResetBookkeeping` before `reset_fn` is invoked, so the release callback below only needs to release the JS value and mark the cell as released. `Global.reset()` unlinks explicitly (see `unregisterEntry`) before running the same release logic.
const GlobalCell = struct {
    entry: instance_map.RefEntry,
    instance_id: i32,
    generation: u64,
    ctx: ActiveEngine.Context,
    allocator: std.mem.Allocator,
    val: ActiveEngine.Value,
    /// True once the JS value has been released. Once released the Cell itself stays around (so the owning Global's pointer remains valid) until the Global is deinit'd; further `get`/`reset` are no-ops.
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *GlobalCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        if (builtin.is_test) if (global_release_hook_for_testing) |hook| hook(global_release_hook_context_for_testing);
        ActiveEngine.freeValue(cell.ctx, cell.val);
        cell.released = true;
    }

    fn freeCell(entry: *instance_map.RefEntry) void {
        const cell: *GlobalCell = @fieldParentPtr("entry", entry);
        cell.allocator.destroy(cell);
    }
};

/// Kinds of values a WeakCell can hold.
const WeakKind = enum {
    /// True weak reference on a JS object. `.val` is meaningful only when the backend-specific handle reports the target is still alive.
    object,
    /// Non-object primitive that is stored with a retained copy; behaves like a lightweight Global that never clears spontaneously.
    primitive,
};

/// Shared between a `Weak` cell and the backend-specific watcher.
///
/// On refcount backends, the watcher JS object holds a pointer to this via its opaque slot; on finalize it sets `target_collected = true`. Because either side can outlive the other, we reference-count the struct:
///   - `+1` for the WeakCell while it holds a pointer
///   - `+1` for the watcher while its finalizer has not fired yet.
///
/// On weak-handle backends, this struct records the weak ref in an opaque slot.
pub const WatcherData = struct {
    /// True once the backend's finalizer/weak-ref reports the target has been garbage collected. On weak-handle backends this may be implicit (polled null); see `getLive`.
    target_collected: bool = false,
    /// Platform-opaque handle. On weak-handle backends this is the weak ref; on refcount backends it's unused (the watcher JS object owns the lifetime).
    native_handle: ?*anyopaque = null,
    ref_count: u32 = 1,
    allocator: std.mem.Allocator,

    pub fn retain(self: *WatcherData) void {
        self.ref_count += 1;
    }

    pub fn release(self: *WatcherData) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) self.allocator.destroy(self);
    }

    pub fn create(allocator: std.mem.Allocator) ?*WatcherData {
        const p = allocator.create(WatcherData) catch return null;
        p.* = .{ .allocator = allocator };
        return p;
    }
};

pub const WeakCell = struct {
    entry: instance_map.RefEntry,
    instance_id: i32,
    generation: u64,
    ctx: ActiveEngine.Context,
    allocator: std.mem.Allocator,
    kind: WeakKind,
    /// For primitives: the retained value. For objects: a snapshot of the initial Value used as a fast-path return when the backend says the target is still live.
    val: ActiveEngine.Value,
    /// Non-null for object-kind cells with a successfully-attached watcher.
    watcher: ?*WatcherData = null,
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *WeakCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        switch (cell.kind) {
            .primitive => {
                ActiveEngine.freeValue(cell.ctx, cell.val);
            },
            .object => {
                weakBackendRelease(cell.ctx, cell);
            },
        }
        cell.released = true;
    }

    fn freeCell(entry: *instance_map.RefEntry) void {
        const cell: *WeakCell = @fieldParentPtr("entry", entry);
        cell.allocator.destroy(cell);
    }
};

fn ctxForInstance(instance_id: i32) ?ActiveEngine.Context {
    const ptrs = instance_map.getPtrs(instance_id) orelse return null;
    return ptrs.ctx;
}

// ----------------------------------------------------------------------
// Backend dispatch for weak machinery.
//
// reference.zig owns the WatcherData lifetime; each backend provides a thin attach/get/release adapter declared as `jsbay_qjsWeakAttach`, `jsbay_qjsWeakGetLive`, `jsbay_qjsWeakRelease` (append-only additions at the end of each backend file).
// ----------------------------------------------------------------------

/// Called by a backend finalizer when it detects that the target of a Weak has been collected. Must be `callconv(.c)` for class-finalizer trampolines. Flips `target_collected` and releases the backend's reference on the `WatcherData`; safe to invoke even after the owning `Weak` was `reset()` (the WatcherData is refcounted).
pub fn weakFinalizerCallback(opaque_ptr: ?*anyopaque) callconv(.c) void {
    const wd_ptr = opaque_ptr orelse return;
    const wd: *WatcherData = @ptrCast(@alignCast(wd_ptr));
    wd.target_collected = true;
    wd.release();
}

fn weakBackendIsObject(ctx: ActiveEngine.Context, v: Local) bool {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.Backend.jsIsObject(v),
        .jsc => @import("../backend/jsc.zig").JscBackend.isObjectVal(ctx, v),
        .escargot, .hermes => ActiveEngine.isObjectVal(ctx, v),
    };
}

/// Attempt to install a backend-specific watcher on `v`. On success, populates `cell.watcher` and returns true. On failure (non-extensible target, or alloc failure), returns false and the caller should fall back to strong retention.
fn weakBackendAttach(ctx: ActiveEngine.Context, cell: *WeakCell, v: Local) bool {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.jsbay_qjsWeakAttach(ctx, cell, v),
        .jsc => @import("../backend/jsc.zig").jsbay_qjsWeakAttach(ctx, cell, v),
        .escargot, .hermes => false,
    };
}

/// Return a non-retained Value for the target if it is still live, or null if it has been collected / the engine is gone.
fn weakBackendGetLive(ctx: ActiveEngine.Context, cell: *WeakCell) ?Local {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.jsbay_qjsWeakGetLive(ctx, cell),
        .jsc => @import("../backend/jsc.zig").jsbay_qjsWeakGetLive(ctx, cell),
        .escargot, .hermes => null,
    };
}

fn weakBackendRelease(ctx: ActiveEngine.Context, cell: *WeakCell) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.jsbay_qjsWeakRelease(ctx, cell),
        .jsc => @import("../backend/jsc.zig").jsbay_qjsWeakRelease(ctx, cell),
        .escargot, .hermes => {},
    }
}

// ----------------------------------------------------------------------
// Global(T)
// ----------------------------------------------------------------------

/// Retained reference to a JS value, safe to hold across scope boundaries. `T` is a phantom type marker (e.g. Global(Value), Global(Function)); the Zig implementation does not currently distinguish on T at runtime; consumers may still use it for clarity at the type site.
///
/// Ownership: a Global is a unique handle to the underlying heap cell. Copying the struct aliases the cell; deinit'ing one copy leaves any other copies with a dangling pointer. Pass Globals by pointer, or move them (do not use the source after assignment).
pub fn Global(comptime T: type) type {
    _ = T; // phantom
    return struct {
        const Self = @This();

        instance_id: i32,
        cell: ?*GlobalCell = null,

        /// Create a Global that retains `v`. Duplicates the refcount / calls `JSValueProtect` so the value outlives any scope it was created in.
        pub fn init(instance_id: i32, v: Local) Self {
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, instance_id, null)) return Self{ .instance_id = instance_id, .cell = null };
            defer op.end();
            const inst = op.lease.inst;
            const ctx = inst.monoCtx() orelse {
                return Self{ .instance_id = instance_id, .cell = null };
            };
            const cell = inst.allocator.create(GlobalCell) catch {
                return Self{ .instance_id = instance_id, .cell = null };
            };
            cell.* = .{
                .entry = .{ .reset_fn = GlobalCell.releaseValue, .free_fn = GlobalCell.freeCell },
                .instance_id = instance_id,
                .generation = op.lease.generation,
                .ctx = ctx,
                .allocator = inst.allocator,
                .val = ActiveEngine.dupValue(ctx, v),
            };
            registerEntryDirect(inst, &cell.entry);
            return Self{ .instance_id = instance_id, .cell = cell };
        }

        /// Create an empty Global. `isEmpty()` returns true; `get()` returns null. Useful when a Global needs to be initialised before a value is ready.
        pub fn initEmpty(instance_id: i32) Self {
            return Self{ .instance_id = instance_id, .cell = null };
        }

        pub fn isEmpty(self: Self) bool {
            const cell = self.cell orelse return true;
            return cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked);
        }

        /// Return a freshly-duplicated Value. Caller owns the result and must free it with `ActiveEngine.freeValue`.
        pub fn get(self: Self) ?Local {
            const cell = self.cell orelse return null;
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, cell.instance_id, cell.generation)) return null;
            defer op.end();
            if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return null;
            return ActiveEngine.dupValue(cell.ctx, cell.val);
        }

        /// Release the retained value and free the underlying cell. Safe to call multiple times.
        pub fn reset(self: *Self) void {
            const cell = self.cell orelse return;
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, cell.instance_id, cell.generation)) {
                abandonEntry(&cell.entry);
                self.cell = null;
                return;
            }
            defer op.end();
            if (cell.entry.state.cmpxchgStrong(@backingInt(instance_map.RefEntryState.linked), @backingInt(instance_map.RefEntryState.releasing), .acq_rel, .acquire) == null) {
                unregisterEntry(op.lease.inst, &cell.entry);
                GlobalCell.releaseValue(&cell.entry);
                finishRefRelease(&cell.entry);
            } else {
                abandonEntry(&cell.entry);
            }
            self.cell = null;
        }

        /// Alias for `reset` — provided for symmetry with other types that offer `deinit`.
        pub fn deinit(self: *Self) void {
            self.reset();
        }
    };
}

// ----------------------------------------------------------------------
// Weak(T)
// ----------------------------------------------------------------------

/// True weak reference to a JS value. For JS objects, `.get()` returns null once the target has been garbage collected. For primitives (numbers, strings, booleans, null, undefined), the weak retains a strong copy — see the module-level "Weak semantics" note.
pub fn Weak(comptime T: type) type {
    _ = T;
    return struct {
        const Self = @This();

        instance_id: i32,
        cell: ?*WeakCell = null,

        pub fn init(instance_id: i32, v: Local) Self {
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, instance_id, null)) return Self{ .instance_id = instance_id, .cell = null };
            defer op.end();
            const inst = op.lease.inst;
            const ctx = inst.monoCtx() orelse {
                return Self{ .instance_id = instance_id, .cell = null };
            };
            const cell = inst.allocator.create(WeakCell) catch {
                return Self{ .instance_id = instance_id, .cell = null };
            };

            const is_obj = weakBackendIsObject(ctx, v);
            if (is_obj) {
                cell.* = .{
                    .entry = .{ .reset_fn = WeakCell.releaseValue, .free_fn = WeakCell.freeCell },
                    .instance_id = instance_id,
                    .generation = op.lease.generation,
                    .ctx = ctx,
                    .allocator = inst.allocator,
                    .kind = .object,
                    .val = v,
                };
                if (!weakBackendAttach(ctx, cell, v)) {
                    // Fallback: the backend couldn't install a weak watcher (e.g. non-extensible target). Degrade to strong retention so the Weak is still usable.
                    cell.kind = .primitive;
                    cell.val = ActiveEngine.dupValue(ctx, v);
                }
            } else {
                cell.* = .{
                    .entry = .{ .reset_fn = WeakCell.releaseValue, .free_fn = WeakCell.freeCell },
                    .instance_id = instance_id,
                    .generation = op.lease.generation,
                    .ctx = ctx,
                    .allocator = inst.allocator,
                    .kind = .primitive,
                    .val = ActiveEngine.dupValue(ctx, v),
                };
            }

            registerEntryDirect(inst, &cell.entry);
            return Self{ .instance_id = instance_id, .cell = cell };
        }

        pub fn initEmpty(instance_id: i32) Self {
            return Self{ .instance_id = instance_id, .cell = null };
        }

        /// True when the Weak is unbacked, has been reset, or (for object-kind cells) the target has been collected.
        pub fn isEmpty(self: Self) bool {
            const cell = self.cell orelse return true;
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, cell.instance_id, cell.generation)) return true;
            defer op.end();
            if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return true;
            if (cell.kind == .object) {
                return weakBackendGetLive(cell.ctx, cell) == null;
            }
            return false;
        }

        /// Returns the stored value without duplicating the caller's refcount. The returned `Local` is borrowed — its lifetime matches the underlying JS value (which, by definition of Weak, could be collected after this call).
        pub fn get(self: Self) ?Local {
            const cell = self.cell orelse return null;
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, cell.instance_id, cell.generation)) return null;
            defer op.end();
            if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return null;
            switch (cell.kind) {
                .primitive => return cell.val,
                .object => {
                    return weakBackendGetLive(cell.ctx, cell);
                },
            }
        }

        pub fn reset(self: *Self) void {
            const cell = self.cell orelse return;
            var op: RefOperation = undefined;
            if (!beginRefOperation(&op, cell.instance_id, cell.generation)) {
                abandonEntry(&cell.entry);
                self.cell = null;
                return;
            }
            defer op.end();
            if (cell.entry.state.cmpxchgStrong(@backingInt(instance_map.RefEntryState.linked), @backingInt(instance_map.RefEntryState.releasing), .acq_rel, .acquire) == null) {
                unregisterEntry(op.lease.inst, &cell.entry);
                WeakCell.releaseValue(&cell.entry);
                finishRefRelease(&cell.entry);
            } else {
                abandonEntry(&cell.entry);
            }
            self.cell = null;
        }

        pub fn deinit(self: *Self) void {
            self.reset();
        }
    };
}
