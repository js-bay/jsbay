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

/// Explicit wrapper representing an owned JavaScript Value whose ownership is transferred to the callee.
pub const OwnedValue = struct {
    ctx: ActiveEngine.Context,
    raw: Local,

    pub fn init(ctx: ActiveEngine.Context, v: Local) OwnedValue {
        return .{ .ctx = ctx, .raw = v };
    }

    pub fn borrow(self: *const OwnedValue) Local {
        return self.raw;
    }

    pub fn release(self: *OwnedValue) Local {
        const val = self.raw;
        self.raw = ActiveEngine.undefinedValue();
        return val;
    }

    pub fn deinit(self: *OwnedValue) void {
        ActiveEngine.freeValue(self.ctx, self.raw);
        self.raw = ActiveEngine.undefinedValue();
    }
};

// ----------------------------------------------------------------------
// Scope
// ----------------------------------------------------------------------

pub const Scope = struct {
    instance_id: i32,
    prev: ?*Scope = null,

    /// Construct a Scope. To make it the active threadlocal scope, pass it to `activate`. Pattern: var s = Scope.enter(id); reference.activate(&s); defer s.exit();
    pub fn enter(instance_id: i32) Scope {
        return Scope{
            .instance_id = instance_id,
            .prev = current_scope,
        };
    }

    /// Pop the scope; asserts the caller is exiting the topmost scope.
    pub fn exit(self: *Scope) void {
        std.debug.assert(current_scope == self);
        current_scope = self.prev;
        self.prev = null;
    }

    /// Returns a pointer to the topmost Scope on this thread, or null.
    pub fn current() ?*Scope {
        return current_scope;
    }
};

/// Make `scope` the active threadlocal scope. The Scope value must be alive (e.g. a stack local in the same frame) until `exit` is called.
pub fn activate(scope: *Scope) void {
    current_scope = scope;
}

threadlocal var current_scope: ?*Scope = null;

/// Read the instance id of the topmost Scope on this thread, or null if no Scope is active.
pub fn currentInstanceId() ?i32 {
    const s = current_scope orelse return null;
    return s.instance_id;
}

// ----------------------------------------------------------------------
// StackFrameScope — escape mechanism for Local values leaving a block
// ----------------------------------------------------------------------

pub const StackFrameScope = struct {
    instance_id: i32,

    pub fn enter(instance_id: i32) StackFrameScope {
        return StackFrameScope{ .instance_id = instance_id };
    }

    pub fn exit(self: *StackFrameScope) void {
        _ = self;
    }

    /// Promote a value out of the frame via the backend retain path. The caller then owns the returned value and must free it via `ActiveEngine.freeValue`.
    pub fn returnValue(self: *StackFrameScope, v: Local) Local {
        const ctx = ctxForInstance(self.instance_id) orelse return v;
        return ActiveEngine.dupValue(ctx, v);
    }
};

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

const RefOperation = struct {
    instance_id: i32,
    lease: instance_map.RefLease,
    previous: ?*RefOperation = null,
    deferred_destroy: bool = false,
    active: bool = true,

    fn end(self: *RefOperation) void {
        std.debug.assert(ref_tls_top == self and self.active);
        _ = self.lease.end();
        ref_tls_top = self.previous;
        self.active = false;
        if (self.deferred_destroy) @import("../engine.zig").destroyForGeneration(self.instance_id, self.lease.generation);
    }
};

threadlocal var ref_tls_top: ?*RefOperation = null;

pub fn isRefOpActiveOnCurrentThread(instance_id: i32) bool {
    var current = ref_tls_top;
    while (current) |entry| : (current = entry.previous) if (entry.instance_id == instance_id) return true;
    return false;
}

pub fn requestDeferredDestroy(instance_id: i32) bool {
    var current = ref_tls_top;
    while (current) |entry| : (current = entry.previous) {
        if (entry.instance_id == instance_id) {
            entry.deferred_destroy = true;
            return true;
        }
    }
    return false;
}

fn beginRefOperation(operation: *RefOperation, instance_id: i32, generation: ?u64) bool {
    const lease = instance_map.beginRefOp(instance_id, generation) orelse return false;
    operation.* = .{ .instance_id = instance_id, .lease = lease, .previous = ref_tls_top };
    ref_tls_top = operation;
    return true;
}

fn unregisterEntry(inst: *instance_map.EngineInstance, entry: *instance_map.RefEntry) void {
    inst.ref_bookkeeping.mutex.lock();
    defer inst.ref_bookkeeping.mutex.unlock();
    if (entry.prev) |p| {
        p.next = entry.next;
    } else if (inst.ref_bookkeeping.head == entry) {
        inst.ref_bookkeeping.head = entry.next;
    }
    if (entry.next) |n| n.prev = entry.prev;
    entry.prev = null;
    entry.next = null;
}

fn abandonEntry(entry: *instance_map.RefEntry) void {
    while (true) {
        const old: instance_map.RefEntryState = @fromBackingInt(@intCast(entry.state.load(.acquire)));
        const next: ?instance_map.RefEntryState = switch (old) {
            .linked => .abandoned,
            .releasing => .releasing_abandoned,
            .released => .freed,
            .abandoned, .releasing_abandoned, .freed => null,
        };
        const target = next orelse return;
        if (entry.state.cmpxchgWeak(@backingInt(old), @backingInt(target), .acq_rel, .acquire) == null) {
            if (target == .freed) entry.free_fn(entry);
            return;
        }
    }
}

fn finishRefRelease(entry: *instance_map.RefEntry) void {
    while (true) {
        const state: instance_map.RefEntryState = @fromBackingInt(@intCast(entry.state.load(.acquire)));
        switch (state) {
            .releasing, .releasing_abandoned => {
                if (entry.state.cmpxchgWeak(@backingInt(state), @backingInt(instance_map.RefEntryState.freed), .acq_rel, .acquire) == null) {
                    entry.free_fn(entry);
                    return;
                }
            },
            .freed => return,
            .linked, .released, .abandoned => unreachable,
        }
    }
}

fn ctxForInstance(instance_id: i32) ?ActiveEngine.Context {
    const ptrs = instance_map.getPtrs(instance_id) orelse return null;
    return ptrs.ctx;
}

fn registerEntryDirect(inst: *instance_map.EngineInstance, entry: *instance_map.RefEntry) void {
    inst.ref_bookkeeping.mutex.lock();
    defer inst.ref_bookkeeping.mutex.unlock();
    entry.prev = null;
    entry.next = inst.ref_bookkeeping.head;
    if (inst.ref_bookkeeping.head) |h| h.prev = entry;
    inst.ref_bookkeeping.head = entry;
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

/// One native retain (refcount dup or GC protect). Callers (Rooted) must not invoke this on every `root()`. Hermes uses `cell.identity` (weak object / durable primitive) so re-root works after the protect-map wrapper is released.
fn rootBackendProtect(ctx: ActiveEngine.Context, cell: *RootCell) ?Local {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsRootProtect(ctx, cell.val),
        .jsc => @import("../backend/jsc/weak.zig").jsbay_qjsRootProtect(ctx, cell.val),
        .escargot => ActiveEngine.dupValue(ctx, cell.val),
        .hermes => blk: {
            const c = @import("../backend/hermes/c_api.zig");
            const id = cell.identity orelse break :blk null;
            const v = c.hermes_root_protect(ctx, @ptrCast(id));
            break :blk if (v == null) null else v;
        },
    };
}

/// Drop the single retain taken by `rootBackendProtect`.
fn rootBackendUnprotect(ctx: ActiveEngine.Context, v: Local) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsRootUnprotect(ctx, v),
        .jsc => @import("../backend/jsc/weak.zig").jsbay_qjsRootUnprotect(ctx, v),
        .escargot, .hermes => ActiveEngine.freeValue(ctx, v),
    }
}

fn rootBackendIdentityCreate(ctx: ActiveEngine.Context, v: Local) ?*anyopaque {
    return switch (backend.active_backend) {
        .hermes => blk: {
            const c = @import("../backend/hermes/c_api.zig");
            break :blk @ptrCast(c.hermes_root_identity_create(ctx, v));
        },
        else => null,
    };
}

fn rootBackendIdentityFree(ctx: ActiveEngine.Context, identity: ?*anyopaque) void {
    const id = identity orelse return;
    if (comptime backend.active_backend == .hermes) {
        const c = @import("../backend/hermes/c_api.zig");
        c.hermes_root_identity_free(ctx, @ptrCast(id));
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

// ----------------------------------------------------------------------
// Rooted — refcounted protect (0→1 retains, back to 0 releases)
// ----------------------------------------------------------------------

/// Heap cell for `Rooted`. The native retain is a single protect/dup held only while `root_count > 0`. Extra `root` calls bump the counter and do not call the backend again.
///
/// On Hermes, `identity` holds a reusable weak object reference (or durable primitive copy) separate from the protect-map wrapper in `val`. Unroot releases only the wrapper so a later `root` can protect the still-live object again.
const RootCell = struct {
    entry: instance_map.RefEntry,
    instance_id: i32,
    generation: u64,
    ctx: ActiveEngine.Context,
    allocator: std.mem.Allocator,
    val: ActiveEngine.Value,
    /// Hermes-only durable identity (`HermesRootIdentity`). Null on other backends.
    identity: ?*anyopaque = null,
    root_count: u32 = 0,
    /// True while the single native protect/dup from `rootBackendProtect` is outstanding.
    protected: bool = false,
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *RootCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        if (cell.protected) {
            rootBackendUnprotect(cell.ctx, cell.val);
            cell.protected = false;
        }
        if (cell.identity) |id| {
            rootBackendIdentityFree(cell.ctx, id);
            cell.identity = null;
        }
        cell.root_count = 0;
        cell.released = true;
    }

    fn freeCell(entry: *instance_map.RefEntry) void {
        const cell: *RootCell = @fieldParentPtr("entry", entry);
        cell.allocator.destroy(cell);
    }
};

/// Refcounted root of one JS value.
///
/// `root` twice then `unroot` once leaves the value protected. A further `unroot` that brings the count to 0 drops the native retain, after which a GC may collect the object. `unroot` at 0 is a no-op. This does not change `Global`, which still protects exactly once in `init`.
///
/// Hermes keeps a weak identity across unroot so re-rooting a still-live object creates a fresh protect-map wrapper; other backends reuse the durable value handle itself.
///
/// The cell is registered with engine bookkeeping so `engine.destroy` releases a leftover protect before the runtime is freed.
pub const Rooted = struct {
    instance_id: i32,
    cell: ?*RootCell = null,

    /// Store `v` with a root count of 0. Does not protect yet.
    pub fn init(instance_id: i32, v: Local) Rooted {
        var op: RefOperation = undefined;
        if (!beginRefOperation(&op, instance_id, null)) return Rooted{ .instance_id = instance_id, .cell = null };
        defer op.end();
        const inst = op.lease.inst;
        const ctx = inst.monoCtx() orelse {
            return Rooted{ .instance_id = instance_id, .cell = null };
        };
        const cell = inst.allocator.create(RootCell) catch {
            return Rooted{ .instance_id = instance_id, .cell = null };
        };
        const identity = rootBackendIdentityCreate(ctx, v);
        if (comptime backend.active_backend == .hermes) {
            if (identity == null) {
                inst.allocator.destroy(cell);
                return Rooted{ .instance_id = instance_id, .cell = null };
            }
        }
        cell.* = .{
            .entry = .{ .reset_fn = RootCell.releaseValue, .free_fn = RootCell.freeCell },
            .instance_id = instance_id,
            .generation = op.lease.generation,
            .ctx = ctx,
            .allocator = inst.allocator,
            .val = v,
            .identity = identity,
        };
        registerEntryDirect(inst, &cell.entry);
        return Rooted{ .instance_id = instance_id, .cell = cell };
    }

    pub fn isEmpty(self: Rooted) bool {
        const cell = self.cell orelse return true;
        var op: RefOperation = undefined;
        if (!beginRefOperation(&op, cell.instance_id, cell.generation)) return true;
        defer op.end();
        return cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked) or cell.root_count == 0;
    }

    /// Increment the root count. The backend protect runs only on 0→1.
    pub fn root(self: *Rooted) void {
        const cell = self.cell orelse return;
        var op: RefOperation = undefined;
        if (!beginRefOperation(&op, cell.instance_id, cell.generation)) return;
        defer op.end();
        if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return;
        if (cell.released) return;
        if (cell.root_count == 0) {
            const protected_val = rootBackendProtect(cell.ctx, cell) orelse return;
            cell.val = protected_val;
            cell.protected = true;
        }
        cell.root_count += 1;
    }

    /// Decrement the root count. The backend release runs only when the count returns to 0. Extra calls at 0 do nothing.
    pub fn unroot(self: *Rooted) void {
        const cell = self.cell orelse return;
        var op: RefOperation = undefined;
        if (!beginRefOperation(&op, cell.instance_id, cell.generation)) return;
        defer op.end();
        if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return;
        if (cell.released or cell.root_count == 0) return;
        cell.root_count -= 1;
        if (cell.root_count == 0 and cell.protected) {
            rootBackendUnprotect(cell.ctx, cell.val);
            cell.protected = false;
            // Hermes: drop the freed wrapper address; re-root rebuilds from `identity`.
            if (comptime backend.active_backend == .hermes) {
                cell.val = ActiveEngine.undefinedValue();
            }
        }
    }

    /// Unlink, drop a leftover protect, and free the cell.
    pub fn deinit(self: *Rooted) void {
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
            RootCell.releaseValue(&cell.entry);
            finishRefRelease(&cell.entry);
        } else {
            abandonEntry(&cell.entry);
        }
        self.cell = null;
    }
};

test "rootBackendIdentityFree takes the same Context as RootCell, not a nested optional" {
    const param_types = @typeInfo(@TypeOf(rootBackendIdentityFree)).@"fn".param_types;
    try std.testing.expectEqual(ActiveEngine.Context, param_types[0].?);
}

test "reference cell ownership transfers to teardown without a double free" {
    const Probe = struct {
        entry: instance_map.RefEntry,
        allocator: std.mem.Allocator,
        freed: *std.atomic.Value(u32),

        fn release(_: *instance_map.RefEntry) void {}

        fn free(entry: *instance_map.RefEntry) void {
            const self: *@This() = @fieldParentPtr("entry", entry);
            _ = self.freed.fetchAdd(1, .seq_cst);
            self.allocator.destroy(self);
        }
    };

    var freed = std.atomic.Value(u32).init(0);
    const p = try std.testing.allocator.create(Probe);
    p.* = .{
        .entry = .{ .reset_fn = Probe.release, .free_fn = Probe.free },
        .allocator = std.testing.allocator,
        .freed = &freed,
    };

    abandonEntry(&p.entry);
    try std.testing.expectEqual(@backingInt(instance_map.RefEntryState.abandoned), p.entry.state.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 0), freed.load(.seq_cst));
    try std.testing.expect(p.entry.state.cmpxchgStrong(@backingInt(instance_map.RefEntryState.abandoned), @backingInt(instance_map.RefEntryState.releasing_abandoned), .acq_rel, .acquire) == null);
    finishRefRelease(&p.entry);
    try std.testing.expectEqual(@as(u32, 1), freed.load(.seq_cst));
}

test "late reference deinit frees an already released cell exactly once" {
    const Probe = struct {
        entry: instance_map.RefEntry,
        allocator: std.mem.Allocator,
        freed: *std.atomic.Value(u32),

        fn release(_: *instance_map.RefEntry) void {}

        fn free(entry: *instance_map.RefEntry) void {
            const self: *@This() = @fieldParentPtr("entry", entry);
            _ = self.freed.fetchAdd(1, .seq_cst);
            self.allocator.destroy(self);
        }
    };

    var freed = std.atomic.Value(u32).init(0);
    const p = try std.testing.allocator.create(Probe);
    p.* = .{
        .entry = .{ .reset_fn = Probe.release, .free_fn = Probe.free },
        .allocator = std.testing.allocator,
        .freed = &freed,
    };
    p.entry.state.store(@backingInt(instance_map.RefEntryState.released), .seq_cst);

    abandonEntry(&p.entry);
    try std.testing.expectEqual(@as(u32, 1), freed.load(.seq_cst));
}
