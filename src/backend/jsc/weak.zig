//! True-weak references and per-object finalizer attachment for the JSC backend.
//!
//! JavaScriptCore ships an ABI-stable private weak-reference API in its framework binary; the symbols are not present in the public headers on macOS, so we declare the externs ourselves. They resolve at link time against JavaScriptCore.framework.

const std = @import("std");
const sync = @import("zev");
const reference_mod = @import("../../value/reference.zig");
const common = @import("common.zig");

const jsc = common.jsc;

// ---- Weak ref externs ----

/// JSWeakRef is an opaque handle to a weak reference. We don't rely on its concrete layout — everything goes through the extern functions.
const JSWeakRef = ?*anyopaque;

pub extern "c" fn JSWeakCreate(group: jsc.JSContextGroupRef, object: jsc.JSObjectRef) JSWeakRef;
pub extern "c" fn JSWeakRetain(group: jsc.JSContextGroupRef, weak: JSWeakRef) void;
pub extern "c" fn JSWeakRelease(group: jsc.JSContextGroupRef, weak: JSWeakRef) void;
pub extern "c" fn JSWeakGetObject(weak: JSWeakRef) jsc.JSObjectRef;

/// Aggressively kick the collector — used by tests to force determinism.
pub extern "c" fn JSSynchronousGarbageCollectForDebugging(ctx: jsc.JSContextRef) void;
/// Eden (young gen) variant; useful for flushing weak finalisation.
pub extern "c" fn JSSynchronousEdenCollectForDebugging(ctx: jsc.JSContextRef) void;

pub fn jsbay_qjsWeakAttach(ctx: jsc.JSGlobalContextRef, cell: *reference_mod.WeakCell, target: jsc.JSValueRef) bool {
    if (target == null) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(ctx_ref, target)) return false;

    const group = jsc.JSContextGetGroup(ctx_ref);
    if (group == null) return false;

    const obj: jsc.JSObjectRef = @constCast(target);
    const weak = JSWeakCreate(group, obj);
    if (weak == null) return false;

    const wd = reference_mod.WatcherData.create() orelse {
        JSWeakRelease(group, weak);
        return false;
    };
    // wd.ref_count = 1 (cell's reference). We store the JSWeakRef as the native handle so release() can free it.
    wd.native_handle = @ptrCast(weak);
    cell.watcher = wd;
    return true;
}

pub fn jsbay_qjsWeakGetLive(ctx: jsc.JSGlobalContextRef, cell: *reference_mod.WeakCell) ?jsc.JSValueRef {
    _ = ctx;
    const wd = cell.watcher orelse return null;
    const weak: JSWeakRef = @ptrCast(wd.native_handle);
    if (weak == null) return null;
    const obj = JSWeakGetObject(weak);
    if (obj == null) {
        // Target has been collected. Flip the flag for parity with QJS.
        wd.target_collected = true;
        return null;
    }
    // JSObjectRef → JSValueRef is an upcast; the ABI is identical but Zig treats them as distinct optional pointer types.
    const v: jsc.JSValueRef = @ptrCast(obj);
    return v;
}

/// `JSValueIsStrictEqual` is JavaScript `===`: `NaN` is not equal to `NaN`, `+0` equals `-0`.
extern fn JSValueIsStrictEqual(ctx: jsc.JSContextRef, a: jsc.JSValueRef, b: jsc.JSValueRef) bool;

/// Single `JSValueProtect`. `reference.Rooted` calls this only on 0→1. Sentinels are skipped so a later unprotect cannot unbalance them.
pub fn jsbay_qjsRootProtect(ctx: jsc.JSGlobalContextRef, val: jsc.JSValueRef) jsc.JSValueRef {
    if (common.isSentinel(val)) return val;
    if (val != null) jsc.JSValueProtect(@ptrCast(ctx), val);
    return val;
}

/// Drop the single protect taken by `jsbay_qjsRootProtect`.
pub fn jsbay_qjsRootUnprotect(ctx: jsc.JSGlobalContextRef, val: jsc.JSValueRef) void {
    if (common.isSentinel(val)) return;
    if (val != null) jsc.JSValueUnprotect(@ptrCast(ctx), val);
}

/// JavaScript `===` via JSC. No extra NaN case: a NaN is not equal to itself.
pub fn jsbay_qjsStrictEqual(ctx: jsc.JSContextRef, a: jsc.JSValueRef, b: jsc.JSValueRef) bool {
    return JSValueIsStrictEqual(ctx, a, b);
}

pub fn jsbay_qjsWeakRelease(ctx: ?jsc.JSGlobalContextRef, cell: *reference_mod.WeakCell) void {
    const wd = cell.watcher orelse return;
    cell.watcher = null;
    // Free the underlying JSWeakRef if still present. Needs the context group — if the engine has already been torn down we simply leak the JSWeakRef (the whole runtime is about to die anyway).
    if (ctx) |c| {
        if (wd.native_handle) |nh| {
            const group = jsc.JSContextGetGroup(@ptrCast(c));
            if (group != null) {
                const weak: JSWeakRef = @ptrCast(nh);
                JSWeakRelease(group, weak);
            }
            wd.native_handle = null;
        }
    }
    wd.release();
}

// ============================================================================
// User-supplied finalizer callbacks attached to arbitrary JS objects. Implements the N-API `napi_wrap` + finalize shape (see src/value/weakcb.zig).
//
// Strategy mirrors the QuickJS side: a dedicated JSClassRef ("JsBayQjsWeakCb") with a finalize callback. Each attach() allocates a holder object of that class whose private slot carries (user_data, on_finalize), then parks the holder as a hidden property (DontEnum|DontDelete|ReadOnly) on the target under a unique key. Nothing else references the holder, so it finalizes exactly when the target does.
// ============================================================================

pub const JscWeakFinalizeCallback = *const fn (user_data: ?*anyopaque) callconv(.c) void;

const JscWeakBox = struct {
    user_data: ?*anyopaque,
    on_finalize: ?JscWeakFinalizeCallback,
    /// 0 idle, 1 running. Cleared private data is the primary reentry guard.
    state: u8 = 0,
};

var jsc_weak_cb_class_ref: ?jsc.JSClassRef = null;
var jsc_weak_cb_class_mutex: sync.Mutex = .{};
var jsc_weak_cb_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

const jsc_weak_cb_class_name: [*:0]const u8 = "JsBayQjsWeakCb";

fn jscWeakCbFinalize(obj: jsc.JSObjectRef) callconv(.c) void {
    // JSC contract: must NOT call any JSC API that takes a JSContextRef here.
    const raw = jsc.JSObjectGetPrivate(obj);
    if (raw == null) return;
    // Drop private data before the callback so engine.destroy, or a nested sweep of this same holder, cannot enter this callback again.
    _ = jsc.JSObjectSetPrivate(obj, null);
    const box: *JscWeakBox = @ptrCast(@alignCast(raw));
    if (box.state != 0) return;
    box.state = 1;
    const cb = box.on_finalize;
    box.on_finalize = null;
    if (cb) |f| f(box.user_data);
    std.heap.c_allocator.destroy(box);
}

fn jscWeakEnsureClass() jsc.JSClassRef {
    jsc_weak_cb_class_mutex.lock();
    defer jsc_weak_cb_class_mutex.unlock();
    if (jsc_weak_cb_class_ref) |c| return c;
    var def = jsc.kJSClassDefinitionEmpty;
    def.className = jsc_weak_cb_class_name;
    def.finalize = jscWeakCbFinalize;
    jsc_weak_cb_class_ref = jsc.JSClassCreate(&def);
    return jsc_weak_cb_class_ref.?;
}

/// Attach `(user_data, on_finalize)` to `target` so that when `target` is garbage collected, `on_finalize(user_data)` runs. Returns false if `target` is not a JS object or the holder cannot be attached.
pub fn jscWeakAttachFinalizer(
    ctx: jsc.JSContextRef,
    target: jsc.JSValueRef,
    user_data: ?*anyopaque,
    on_finalize: JscWeakFinalizeCallback,
) bool {
    if (target == null) return false;
    if (!jsc.JSValueIsObject(ctx, target)) return false;

    const cls = jscWeakEnsureClass();

    const box = std.heap.c_allocator.create(JscWeakBox) catch return false;
    box.* = .{ .user_data = user_data, .on_finalize = on_finalize };

    const holder = jsc.JSObjectMake(ctx, cls, @ptrCast(box));
    if (holder == null) {
        std.heap.c_allocator.destroy(box);
        return false;
    }
    jsc.JSValueProtect(ctx, @ptrCast(holder));
    defer jsc.JSValueUnprotect(ctx, @ptrCast(holder));

    var exc: jsc.JSValueRef = null;
    const target_obj = jsc.JSValueToObject(ctx, target, &exc);
    if (exc != null or target_obj == null) {
        discardWeakHolder(holder, box);
        return false;
    }

    // Unique key per attach.
    const n = jsc_weak_cb_counter.fetchAdd(1, .monotonic);
    var key_buf: [48]u8 = undefined;
    const key_slice = std.fmt.bufPrintSentinel(&key_buf, "__$jsbay_qjs_Finalizer${d}$__", .{n}, 0) catch {
        discardWeakHolder(holder, box);
        return false;
    };
    const js_name = jsc.JSStringCreateWithUTF8CString(key_slice.ptr);
    if (js_name == null) {
        discardWeakHolder(holder, box);
        return false;
    }
    defer jsc.JSStringRelease(js_name);

    const attrs: c_uint = jsc.kJSPropertyAttributeDontEnum |
        jsc.kJSPropertyAttributeDontDelete |
        jsc.kJSPropertyAttributeReadOnly;
    exc = null;
    jsc.JSObjectSetProperty(ctx, target_obj, js_name, holder, attrs, &exc);
    if (exc != null) {
        discardWeakHolder(holder, box);
        return false;
    }
    exc = null;
    const attached = jsc.JSObjectGetProperty(ctx, target_obj, js_name, &exc);
    if (exc != null or !JSValueIsStrictEqual(ctx, attached, @ptrCast(holder))) {
        discardWeakHolder(holder, box);
        return false;
    }
    return true;
}

fn discardWeakHolder(holder: jsc.JSObjectRef, box: *JscWeakBox) void {
    _ = jsc.JSObjectSetPrivate(holder, null);
    std.heap.c_allocator.destroy(box);
}
