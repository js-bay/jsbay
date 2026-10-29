//! User-supplied finalizer callbacks attached to arbitrary JS objects. Implements the N-API `napi_wrap` + finalize shape (see src/value/weakcb.zig).
//!
//! Strategy: reuse the existing `native_handle` class for holders. Every engine instance already registers native_handle exactly once per runtime, and the class's finalizer dispatches through `HandleData.finalize_fn` — so we can piggyback without adding another class id to the global static-id pool. This sidesteps QJS class-id-collision bugs that arise when multiple modules register their own classes across recycled runtimes.
//!
//! Each `attachFinalizer` creates a fresh NativeHandle with finalize_fn set to a trampoline that runs the user callback, then parks the holder as a writable property on `target` under a unique key. Because nothing else references the holder, it becomes unreachable exactly when the target does; the NativeHandle class finalizer then invokes our trampoline.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const native_handle_mod = @import("../../value/native_handle.zig");

pub const QjsWeakFinalizeCallback = *const fn (user_data: ?*anyopaque) callconv(.c) void;

/// Heap-allocated payload. The NativeHandle's `ptr` field holds a pointer to this box, and the class finalizer hands that pointer to our trampoline.
const QjsWeakBox = struct {
    user_data: ?*anyopaque,
    on_finalize: ?QjsWeakFinalizeCallback,
    /// 0 idle, 1 running, 2 finished. A second entry is a no-op.
    state: u8 = 0,
    /// Holder object, so a nested finalizer can drop its opaque pointer.
    holder: qjs.JSValue = undefined,
};

var qjs_weak_cb_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn nextWeakFinalizerKeyForTesting() u64 {
    return qjs_weak_cb_counter.load(.seq_cst);
}

/// Finalize trampoline wired via `native_handle.HandleData.finalize_fn`. Runs during GC / runtime teardown; must NOT re-enter JS.
///
/// The callback is cleared and the holder opaque is dropped before the user runs, so the same registration cannot run again from a nested sweep or from a later `engine.destroy`.
fn qjsWeakNativeHandleTrampoline(ptr: ?*anyopaque) void {
    const raw = ptr orelse return;
    const box: *QjsWeakBox = @ptrCast(@alignCast(raw));
    if (box.state != 0) return;
    box.state = 1;
    const cb = box.on_finalize;
    box.on_finalize = null;
    _ = qjs.JS_SetOpaque(box.holder, null);
    if (cb) |f| f(box.user_data);
    box.state = 2;
    std.heap.c_allocator.destroy(box);
}

/// Attach `(user_data, on_finalize)` to `target` so that when `target` is garbage collected, `on_finalize(user_data)` runs. Returns false if `target` is not a JS object or the holder cannot be attached.
pub fn qjsWeakAttachFinalizer(
    ctx: ?*qjs.JSContext,
    target: qjs.JSValue,
    user_data: ?*anyopaque,
    on_finalize: QjsWeakFinalizeCallback,
) bool {
    if (!c.jsIsObject(target) or c.JS_IsProxy(ctx, target)) return false;

    // Ensure the shared NativeHandle class is registered in this runtime. init is idempotent on recycled runtimes (see its doc comment).
    const rt = qjs.JS_GetRuntime(ctx);
    native_handle_mod.init(rt);

    const box = std.heap.c_allocator.create(QjsWeakBox) catch return false;
    box.* = .{ .user_data = user_data, .on_finalize = on_finalize };

    // Build the holder via native_handle. The class's finalizer runs our trampoline with `ptr` (our box) once the holder becomes unreachable.
    const holder = native_handle_mod.create(ctx, .{
        .ptr = @ptrCast(box),
        .finalize_fn = qjsWeakNativeHandleTrampoline,
    });
    if (c.jsIsException(holder)) {
        std.heap.c_allocator.destroy(box);
        const pending = qjs.JS_GetException(ctx);
        if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        return false;
    }
    box.holder = holder;

    // Unique key per attach so multiple finalizers can coexist on one object without overwriting each other's holder.
    const n = qjs_weak_cb_counter.fetchAdd(1, .monotonic);
    var key_buf: [48]u8 = undefined;
    const key_slice = std.fmt.bufPrintSentinel(&key_buf, "__$jsbay_qjs_Finalizer${d}$__", .{n}, 0) catch {
        discardHolder(ctx, holder, box);
        return false;
    };

    // Define an own property instead of assigning: assignment can traverse the prototype chain and be swallowed by an inherited setter or Proxy `set` trap. JS_DefinePropertyValueStr consumes the holder value and, on success, stores that reference directly on the target.
    const failure_guard = c.jsbay_qjs_JS_DupValue(ctx, holder);
    const rc = qjs.JS_DefinePropertyValueStr(ctx, target, key_slice.ptr, holder, 0);
    if (rc != 1) {
        if (rc < 0) {
            const pending = qjs.JS_GetException(ctx);
            if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
        }
        discardHolder(ctx, failure_guard, box);
        return false;
    }
    c.jsbay_qjs_JS_FreeValue(ctx, failure_guard);
    return true;
}

fn discardHolder(ctx: ?*qjs.JSContext, holder: qjs.JSValue, box: *QjsWeakBox) void {
    if (native_handle_mod.getOpaque(ctx, holder)) |handle| {
        handle.finalize_fn = null;
        handle.ptr = null;
    }
    c.jsbay_qjs_JS_FreeValue(ctx, holder);
    std.heap.c_allocator.destroy(box);
}
