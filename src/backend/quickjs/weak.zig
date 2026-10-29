//! True-weak support for `reference.Weak(T)`.
//!
//! Approach (Option C): attach a per-runtime "WeakWatcher" JS class to the target object as a hidden property. The target strongly references the watcher, not the other way around, so the watcher is GC'd exactly when the target is. The watcher's finalizer flips a flag on a refcounted `WatcherData` struct owned by reference.zig.

const std = @import("std");
const sync = @import("zev");
const c = @import("c_api.zig");
const qjs = c.qjs;

const reference_mod = @import("../../value/reference.zig");

/// QuickJS class id for `WeakWatcher`. Allocated lazily on the first `jsbay_qjsWeakAttach` call and shared by all weak watchers.
var qjs_weak_watcher_class_id: qjs.JSClassID = 0;
var qjs_weak_watcher_class_mutex: sync.Mutex = .{};

fn qjsWeakWatcherFinalizer(rt: ?*qjs.JSRuntime, val: qjs.JSValue) callconv(.c) void {
    _ = rt;
    const p = qjs.JS_GetOpaque(val, qjs_weak_watcher_class_id) orelse return;
    reference_mod.weakFinalizerCallback(p);
}

const qjs_weak_watcher_class_def = qjs.JSClassDef{
    .class_name = "JsBayQjsWeakWatcher",
    .finalizer = qjsWeakWatcherFinalizer,
    .gc_mark = null,
    .call = null,
    .exotic = null,
};

fn qjsEnsureWeakWatcherClass(rt: ?*qjs.JSRuntime) void {
    qjs_weak_watcher_class_mutex.lock();
    defer qjs_weak_watcher_class_mutex.unlock();
    // JS_NewClassID only allocates a fresh id the first time it sees a zero-initialised cell; subsequent calls are idempotent. JS_NewClass tolerates re-registration when the id is the same, so we unconditionally register to cover per-runtime registration across tests that recycle JSRuntime pointers.
    _ = c.JS_NewClassID(rt, &qjs_weak_watcher_class_id);
    _ = qjs.JS_NewClass(rt, qjs_weak_watcher_class_id, &qjs_weak_watcher_class_def);
}

/// Hidden-property name used to park the watcher on the target. A plain string key is simpler than a Symbol and sufficient in practice — user code should not be iterating `__$jsbay_qjs_Weak$__` keys on arbitrary objects.
const qjs_weak_hidden_prop: [*:0]const u8 = "__$jsbay_qjs_Weak$__";

/// Install a weak watcher on `target`. Returns false if the target refuses the hidden property (e.g. frozen). On success, bumps the WatcherData refcount to 2 (one for the WeakCell, one for the watcher's finalizer).
pub fn jsbay_qjsWeakAttach(ctx: ?*qjs.JSContext, cell: *reference_mod.WeakCell, target: qjs.JSValue) bool {
    if (!c.jsIsObject(target)) return false;

    const rt = qjs.JS_GetRuntime(ctx);
    qjsEnsureWeakWatcherClass(rt);

    // If the target already carries a watcher (installed by a previous Weak pointing at the same object), share its WatcherData. This lets multiple Weaks coexist without having to bump the property slot, and ensures they all flip to "collected" together.
    const existing = qjs.JS_GetPropertyStr(ctx, target, qjs_weak_hidden_prop);
    if (!c.jsIsException(existing) and !c.jsIsUndefined(existing)) {
        defer c.jsbay_qjs_JS_FreeValue(ctx, existing);
        const op = qjs.JS_GetOpaque(existing, qjs_weak_watcher_class_id);
        if (op != null) {
            const wd: *reference_mod.WatcherData = @ptrCast(@alignCast(op.?));
            wd.retain();
            cell.watcher = wd;
            return true;
        }
        // The hidden property exists but isn't our class — someone else owns it. Fall back to strong retention.
        return false;
    } else if (c.jsIsException(existing)) {
        c.jsbay_qjs_JS_FreeValue(ctx, existing);
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
    } else {
        // undefined — clean slate; release and proceed to install.
        c.jsbay_qjs_JS_FreeValue(ctx, existing);
    }

    const wd = reference_mod.WatcherData.create() orelse return false;
    // wd.ref_count = 1 (ours). We'll +1 before handing to the watcher.

    // Create the watcher object with our class.
    const watcher = qjs.JS_NewObjectClass(ctx, @intCast(qjs_weak_watcher_class_id));
    if (c.jsIsException(watcher)) {
        wd.release();
        return false;
    }
    // Transfer ownership of one refcount to the watcher object. Its finalizer calls reference.weakFinalizerCallback, which releases.
    wd.retain();
    _ = qjs.JS_SetOpaque(watcher, @ptrCast(wd));

    // Stash the watcher on the target as a hidden property. If the target refuses the property (frozen / non-extensible), back out. JS_DefinePropertyValueStr with flags=0 means non-enumerable, non-configurable, non-writable which is what we want for a parking slot.
    const ok = qjs.JS_DefinePropertyValueStr(ctx, target, qjs_weak_hidden_prop, watcher, 0);
    if (ok < 0) {
        // JS_DefinePropertyValueStr consumes `watcher` even on failure, which will eventually invoke our finalizer and release wd's second refcount. We still need to drop our own. Drop pending exception to avoid poisoning the caller.
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        wd.release();
        return false;
    }
    // Ownership of `watcher` now belongs to the target's property slot.

    cell.watcher = wd;
    return true;
}

/// Return a non-retained JSValue for the target if it is still live; null if it has been collected or the cell has no watcher.
pub fn jsbay_qjsWeakGetLive(ctx: ?*qjs.JSContext, cell: *reference_mod.WeakCell) ?qjs.JSValue {
    _ = ctx;
    const wd = cell.watcher orelse return null;
    if (wd.target_collected) return null;
    return cell.val;
}

/// Called from `WeakCell.releaseValue` when the owning Weak is being reset. Simply drops our refcount on the WatcherData; if the watcher object has not yet been finalised it will still fire later and drop its own reference, at which point the struct is freed.
pub fn jsbay_qjsWeakRelease(ctx: ?*qjs.JSContext, cell: *reference_mod.WeakCell) void {
    _ = ctx;
    const wd = cell.watcher orelse return;
    cell.watcher = null;
    wd.release();
}

/// Single retain used by `reference.Rooted` on the 0→1 edge. Not refcounted here — the caller pairs one protect with one unprotect.
pub fn jsbay_qjsRootProtect(ctx: ?*qjs.JSContext, val: qjs.JSValue) qjs.JSValue {
    return c.jsbay_qjs_JS_DupValue(ctx, val);
}

/// Drop the retain taken by `jsbay_qjsRootProtect`.
pub fn jsbay_qjsRootUnprotect(ctx: ?*qjs.JSContext, val: qjs.JSValue) void {
    c.jsbay_qjs_JS_FreeValue(ctx, val);
}

/// Host strict equality: JavaScript `===` (`NaN` is not equal to `NaN`, `+0` equals `-0`). Delegates to QuickJS `JS_IsStrictEqual`.
pub fn jsbay_qjsStrictEqual(ctx: ?*qjs.JSContext, a: qjs.JSValue, b: qjs.JSValue) bool {
    return qjs.JS_StrictEq(ctx, a, b) != 0;
}
