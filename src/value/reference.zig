//! Reference lifecycle — Local / Global(T) / Weak(T) / Scope / StackFrameScope.
//!
//! Hold JS values across scope boundaries with `Global(T)`; temporary in-scope values are the backend-native `Local` (aka `ActiveEngine.Value`).
//!
//! ## Lifetime summary
//!
//! - `Local` — backend Value. No retain; lifetime is whatever the backend rules say (e.g. QuickJS refcount held by caller, JSC GC root).
//! - `Global(T)` — retained across scopes. `init` duplicates the value; the retained value is released on `reset` (or when the owning engine is destroyed, see `engine.destroy` → bookkeeping walk).
//! - `Weak(T)` — **true weak** reference on JS objects. `get()` returns null once the target has been garbage collected. See "Weak semantics" below.
//! - `Rooted` — refcounted GC root. `root` calls the backend protect only on the 0→1 edge; `unroot` releases only when the count returns to 0. `Global` is unchanged and still protects exactly once.
//! - `Scope` — threadlocal stack that `currentInstanceId()` reads. Not yet required before every API call; exists so consumers can query the active engine id without passing it everywhere.
//! - `StackFrameScope` — thin wrapper around `dupValue` for values that need to escape a frame.
//!
//! ## Weak semantics
//!
//! `Weak(T)` is a true weak reference when the target value is a JS **object** (including arrays, functions, plain objects, typed arrays). `.get()` returns null after the underlying object has been garbage collected.
//!
//! - **QuickJS**: implemented via *Option C* — a finalizer watcher object (`WeakWatcher` class, registered once per runtime) is attached to the target as a hidden property (`__$jsbay_qjs_Weak$__`). Because the target strongly references the watcher (not the other way around), the watcher becomes unreachable exactly when the target does; its finalizer then clears a shared `WatcherData` struct. The Zig-side `Weak.get()` reads that struct to decide whether the target is still live.
//!
//! - **JSC**: implemented via `JSWeakCreate` / `JSWeakGetObject` — the JavaScriptCore private-but-ABI-stable weak-reference API. Symbols live in `JavaScriptCore.framework` but are not declared in the public headers; they are declared manually in `backend/jsc/weak.zig`.
//!
//! ### Primitives policy
//!
//! Non-object values (numbers, booleans, strings, null, undefined) are not subject to garbage collection in the same way — numbers/booleans are inlined in the tagged value, strings are refcounted (QJS) or interned (JSC). For these, `Weak.init` stores a retained copy and behaves like a tiny `Global` that never spontaneously clears. Callers that want strict "null after GC" semantics should wrap primitives in an object first.
//!
//! ## Implementation note: heap-allocated handle
//!
//! `Global` and `Weak` are value types that may be moved/copied (e.g. by return-by-value from `init`). To keep their bookkeeping stable across such moves, the actual state lives in a heap-allocated `Cell` and the Global/Weak holds a stable pointer to it. The Cell embeds the intrusive `RefEntry` so `engine.destroy` can walk all live references and force-reset them before tearing down the JS runtime — preventing use-after- free when consumers forget to call `reset()` themselves.

const std = @import("std");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

/// Convenience alias so consumers can write `reference.Local` instead of reaching into the backend module for the Value type.
pub const Local = ActiveEngine.Value;

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

    /// Promote a value out of the frame. Duplicates the refcount (QuickJS) or calls JSValueProtect (JSC). The caller then owns the returned value and must free it via `ActiveEngine.freeValue`.
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
    val: ActiveEngine.Value,
    /// True once the JS value has been released. Once released the Cell itself stays around (so the owning Global's pointer remains valid) until the Global is deinit'd; further `get`/`reset` are no-ops.
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *GlobalCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        if (ctxForInstance(cell.instance_id)) |ctx| {
            ActiveEngine.freeValue(ctx, cell.val);
        }
        cell.released = true;
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
/// For QuickJS, the watcher JS object holds a pointer to this via its opaque slot; on finalize it sets `target_collected = true`. Because either side can outlive the other, we reference-count the struct:
///   - `+1` for the WeakCell while it holds a pointer
///   - `+1` for the watcher while its finalizer has not fired yet.
///
/// For JSC, this struct just records the `JSWeakRef` in an opaque slot.
pub const WatcherData = struct {
    /// True once the backend's finalizer/weak-ref reports the target has been garbage collected. For JSC this is implicit (set by polling `JSWeakGetObject == NULL`) so we don't actually flip this bit on JSC; see `getLive`.
    target_collected: bool = false,
    /// Platform-opaque handle. On JSC this is the `JSWeakRef`; on QJS it's unused (the watcher JS object owns the lifetime).
    native_handle: ?*anyopaque = null,
    ref_count: u32 = 1,

    pub fn retain(self: *WatcherData) void {
        self.ref_count += 1;
    }

    pub fn release(self: *WatcherData) void {
        std.debug.assert(self.ref_count > 0);
        self.ref_count -= 1;
        if (self.ref_count == 0) std.heap.c_allocator.destroy(self);
    }

    pub fn create() ?*WatcherData {
        const p = std.heap.c_allocator.create(WatcherData) catch return null;
        p.* = .{};
        return p;
    }
};

pub const WeakCell = struct {
    entry: instance_map.RefEntry,
    instance_id: i32,
    kind: WeakKind,
    /// For primitives: the retained value. For objects: a snapshot of the initial Value used as a fast-path return when the backend says the target is still live.
    val: ActiveEngine.Value,
    /// Non-null for object-kind cells with a successfully-attached watcher.
    watcher: ?*WatcherData = null,
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *WeakCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        const ctx_opt = ctxForInstance(cell.instance_id);
        switch (cell.kind) {
            .primitive => {
                if (ctx_opt) |c| ActiveEngine.freeValue(c, cell.val);
            },
            .object => {
                // `Context` is already an optional pointer type on both backends; pass a null Context when the engine is gone so the backend can decide whether it can still release native handles.
                const ctx: ActiveEngine.Context = ctx_opt orelse null;
                weakBackendRelease(ctx, cell);
            },
        }
        cell.released = true;
    }
};

fn ctxForInstance(instance_id: i32) ?ActiveEngine.Context {
    const ptrs = instance_map.getPtrs(instance_id) orelse return null;
    return ptrs.ctx;
}

/// Insert `entry` at the head of the engine's bookkeeping list. `entry` must already have its `reset_fn` set.
fn registerEntry(instance_id: i32, entry: *instance_map.RefEntry) void {
    const inst = instance_map.getInstance(instance_id) orelse return;
    inst.ref_bookkeeping.mutex.lock();
    defer inst.ref_bookkeeping.mutex.unlock();
    entry.prev = null;
    entry.next = inst.ref_bookkeeping.head;
    if (inst.ref_bookkeeping.head) |h| h.prev = entry;
    inst.ref_bookkeeping.head = entry;
}

/// Unlink `entry` from the engine's bookkeeping list. Safe to call even if the engine has been torn down or the entry was already unlinked.
fn unregisterEntry(instance_id: i32, entry: *instance_map.RefEntry) void {
    const inst = instance_map.getInstance(instance_id) orelse {
        entry.prev = null;
        entry.next = null;
        return;
    };
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

// ----------------------------------------------------------------------
// Backend dispatch for weak machinery.
//
// reference.zig owns the WatcherData lifetime; each backend provides a thin attach/get/release adapter declared as `jsbay_qjsWeakAttach`, `jsbay_qjsWeakGetLive`, `jsbay_qjsWeakRelease` (append-only additions at the end of each backend file).
// ----------------------------------------------------------------------

/// Called by a backend finalizer when it detects that the target of a Weak has been collected. Must be `callconv(.c)` so we can hand it to QuickJS as a class finalizer. Flips `target_collected` and releases the backend's reference on the `WatcherData`; safe to invoke even after the owning `Weak` was `reset()` (the WatcherData is refcounted).
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
    };
}

/// Attempt to install a backend-specific watcher on `v`. On success, populates `cell.watcher` and returns true. On failure (e.g. target frozen on QuickJS, or JSC alloc failure), returns false and the caller should fall back to strong retention.
fn weakBackendAttach(ctx: ActiveEngine.Context, cell: *WeakCell, v: Local) bool {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.jsbay_qjsWeakAttach(ctx, cell, v),
        .jsc => @import("../backend/jsc.zig").jsbay_qjsWeakAttach(ctx, cell, v),
    };
}

/// Return a non-retained Value for the target if it is still live, or null if it has been collected / the engine is gone.
fn weakBackendGetLive(ctx: ActiveEngine.Context, cell: *WeakCell) ?Local {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.jsbay_qjsWeakGetLive(ctx, cell),
        .jsc => @import("../backend/jsc.zig").jsbay_qjsWeakGetLive(ctx, cell),
    };
}

fn weakBackendRelease(ctx: ActiveEngine.Context, cell: *WeakCell) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.jsbay_qjsWeakRelease(ctx, cell),
        .jsc => @import("../backend/jsc.zig").jsbay_qjsWeakRelease(ctx, cell),
    }
}

/// One native retain. QuickJS dups the refcount; JSC calls `JSValueProtect` once. Callers (Rooted) must not invoke this on every `root()`.
fn rootBackendProtect(ctx: ActiveEngine.Context, v: Local) Local {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsRootProtect(ctx, v),
        .jsc => @import("../backend/jsc/weak.zig").jsbay_qjsRootProtect(ctx, v),
    };
}

/// Drop the single retain taken by `rootBackendProtect`.
fn rootBackendUnprotect(ctx: ActiveEngine.Context, v: Local) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsRootUnprotect(ctx, v),
        .jsc => @import("../backend/jsc/weak.zig").jsbay_qjsRootUnprotect(ctx, v),
    }
}

// ----------------------------------------------------------------------
// Global(T)
// ----------------------------------------------------------------------

/// Retained reference to a JS value, safe to hold across scope boundaries. `T` is a phantom marker (e.g. Value vs Function) for clarity at the type site; the Zig implementation does not currently distinguish on T at runtime.
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
            const ctx = ctxForInstance(instance_id) orelse {
                return Self{ .instance_id = instance_id, .cell = null };
            };
            const cell = std.heap.c_allocator.create(GlobalCell) catch {
                return Self{ .instance_id = instance_id, .cell = null };
            };
            cell.* = .{
                .entry = .{ .reset_fn = GlobalCell.releaseValue },
                .instance_id = instance_id,
                .val = ActiveEngine.dupValue(ctx, v),
            };
            registerEntry(instance_id, &cell.entry);
            return Self{ .instance_id = instance_id, .cell = cell };
        }

        /// Create an empty Global. `isEmpty()` returns true; `get()` returns null. Useful when a Global needs to be initialised before a value is ready.
        pub fn initEmpty(instance_id: i32) Self {
            return Self{ .instance_id = instance_id, .cell = null };
        }

        pub fn isEmpty(self: Self) bool {
            const cell = self.cell orelse return true;
            return cell.released;
        }

        /// Return a freshly-duplicated Value. Caller owns the result and must free it with `ActiveEngine.freeValue`.
        pub fn get(self: Self) ?Local {
            const cell = self.cell orelse return null;
            if (cell.released) return null;
            const ctx = ctxForInstance(self.instance_id) orelse return null;
            return ActiveEngine.dupValue(ctx, cell.val);
        }

        /// Release the retained value and free the underlying cell. Safe to call multiple times.
        pub fn reset(self: *Self) void {
            const cell = self.cell orelse return;
            if (!cell.released) {
                // Unlink from bookkeeping first, then release value.
                unregisterEntry(cell.instance_id, &cell.entry);
                GlobalCell.releaseValue(&cell.entry);
            }
            // Now that the cell is no longer linked into bookkeeping and its JS value has been released, free the cell itself.
            std.heap.c_allocator.destroy(cell);
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
            const ctx = ctxForInstance(instance_id) orelse {
                return Self{ .instance_id = instance_id, .cell = null };
            };
            const cell = std.heap.c_allocator.create(WeakCell) catch {
                return Self{ .instance_id = instance_id, .cell = null };
            };

            const is_obj = weakBackendIsObject(ctx, v);
            if (is_obj) {
                cell.* = .{
                    .entry = .{ .reset_fn = WeakCell.releaseValue },
                    .instance_id = instance_id,
                    .kind = .object,
                    .val = v,
                };
                if (!weakBackendAttach(ctx, cell, v)) {
                    // Fallback: the backend couldn't install a weak watcher (e.g. frozen target on QuickJS). Degrade to strong retention so the Weak is still usable.
                    cell.kind = .primitive;
                    cell.val = ActiveEngine.dupValue(ctx, v);
                }
            } else {
                cell.* = .{
                    .entry = .{ .reset_fn = WeakCell.releaseValue },
                    .instance_id = instance_id,
                    .kind = .primitive,
                    .val = ActiveEngine.dupValue(ctx, v),
                };
            }

            registerEntry(instance_id, &cell.entry);
            return Self{ .instance_id = instance_id, .cell = cell };
        }

        pub fn initEmpty(instance_id: i32) Self {
            return Self{ .instance_id = instance_id, .cell = null };
        }

        /// True when the Weak is unbacked, has been reset, or (for object-kind cells) the target has been collected.
        pub fn isEmpty(self: Self) bool {
            const cell = self.cell orelse return true;
            if (cell.released) return true;
            if (cell.kind == .object) {
                const ctx = ctxForInstance(self.instance_id) orelse return true;
                return weakBackendGetLive(ctx, cell) == null;
            }
            return false;
        }

        /// Returns the stored value without duplicating the caller's refcount. The returned `Local` is borrowed — its lifetime matches the underlying JS value (which, by definition of Weak, could be collected after this call).
        pub fn get(self: Self) ?Local {
            const cell = self.cell orelse return null;
            if (cell.released) return null;
            switch (cell.kind) {
                .primitive => return cell.val,
                .object => {
                    const ctx = ctxForInstance(self.instance_id) orelse return null;
                    return weakBackendGetLive(ctx, cell);
                },
            }
        }

        pub fn reset(self: *Self) void {
            const cell = self.cell orelse return;
            if (!cell.released) {
                unregisterEntry(cell.instance_id, &cell.entry);
                WeakCell.releaseValue(&cell.entry);
            }
            std.heap.c_allocator.destroy(cell);
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
const RootCell = struct {
    entry: instance_map.RefEntry,
    instance_id: i32,
    val: ActiveEngine.Value,
    root_count: u32 = 0,
    /// True while the single native protect/dup from `rootBackendProtect` is outstanding.
    protected: bool = false,
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *RootCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        if (cell.protected) {
            if (ctxForInstance(cell.instance_id)) |ctx| {
                rootBackendUnprotect(ctx, cell.val);
            }
            cell.protected = false;
            cell.val = ActiveEngine.nullValue();
        }
        cell.root_count = 0;
        cell.released = true;
    }
};

/// Refcounted root of one JS value.
///
/// `root` twice then `unroot` once leaves the value protected. A further `unroot` that brings the count to 0 drops the native retain, after which a GC may collect the object. `unroot` at 0 is a no-op. This does not change `Global`, which still protects exactly once in `init`.
///
/// The cell is registered with engine bookkeeping so `engine.destroy` releases a leftover protect before the runtime is freed.
pub const Rooted = struct {
    instance_id: i32,
    cell: ?*RootCell = null,

    /// Store `v` with a root count of 0. Does not protect yet.
    pub fn init(instance_id: i32, v: Local) Rooted {
        const ctx = ctxForInstance(instance_id) orelse {
            return Rooted{ .instance_id = instance_id, .cell = null };
        };
        _ = ctx;
        const cell = std.heap.c_allocator.create(RootCell) catch {
            return Rooted{ .instance_id = instance_id, .cell = null };
        };
        cell.* = .{
            .entry = .{ .reset_fn = RootCell.releaseValue },
            .instance_id = instance_id,
            .val = v,
        };
        registerEntry(instance_id, &cell.entry);
        return Rooted{ .instance_id = instance_id, .cell = cell };
    }

    pub fn isEmpty(self: Rooted) bool {
        const cell = self.cell orelse return true;
        return cell.released or cell.root_count == 0;
    }

    /// Increment the root count. The backend protect runs only on 0→1.
    pub fn root(self: *Rooted) void {
        const cell = self.cell orelse return;
        if (cell.released) return;
        if (cell.root_count == 0) {
            const ctx = ctxForInstance(self.instance_id) orelse return;
            cell.val = rootBackendProtect(ctx, cell.val);
            cell.protected = true;
        }
        cell.root_count += 1;
    }

    /// Decrement the root count. The backend release runs only when the count returns to 0. Extra calls at 0 do nothing.
    pub fn unroot(self: *Rooted) void {
        const cell = self.cell orelse return;
        if (cell.released or cell.root_count == 0) return;
        cell.root_count -= 1;
        if (cell.root_count == 0 and cell.protected) {
            if (ctxForInstance(self.instance_id)) |ctx| {
                rootBackendUnprotect(ctx, cell.val);
            }
            cell.protected = false;
            // Keep cell.val so a later root() on a still-live object can re-protect it.
            // (Clearing to nullValue here made isEmpty false after re-root while protecting
            // only the sentinel — see "Rooted: re-root after count returns to zero".)
        }
    }

    /// Unlink, drop a leftover protect, and free the cell.
    pub fn deinit(self: *Rooted) void {
        const cell = self.cell orelse return;
        if (!cell.released) {
            unregisterEntry(cell.instance_id, &cell.entry);
            RootCell.releaseValue(&cell.entry);
        }
        std.heap.c_allocator.destroy(cell);
        self.cell = null;
    }
};
