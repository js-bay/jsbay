//! Zero-copy buffer support — wrap a caller-owned byte slice as a JS ArrayBuffer (or Uint8Array view over it) without copying the payload.
//!
//! Backends expose this pattern natively:
//!
//!   * QuickJS: `JS_NewArrayBuffer(ctx, buf, len, 0, realloc_func, opaque, false)`
//!   * JSC:     `JSObjectMakeArrayBufferWithBytesNoCopy`
//!   * Escargot / Hermes: bridge helpers that attach a host finalizer to a buffer object
//!
//! The `finalizer` fires when the JS GC reclaims the ArrayBuffer wrapper; the caller is responsible for freeing the backing memory inside the finalizer (both backends will pass back the same pointer/length they received). Pass a `null` finalizer for memory that outlives the engine (static data) — nothing happens at collection time then.
//!
//! Contract: operations on a given `instance_id` MUST happen on the owning thread. The finalizer itself is called from the GC and MUST NOT re-enter JS.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

/// Called by the JS GC when the ArrayBuffer/TypedArray wrapping your bytes becomes unreachable. Free the backing memory here.
///
/// `user_data` is whatever was passed to `newArrayBufferFromBytes`. `bytes` and `len` match the original call — both backends hand back the same pointer and length they received.
pub const BufferFinalizer = *const fn (
    user_data: ?*anyopaque,
    bytes: [*]u8,
    len: usize,
) callconv(.c) void;

/// Read-only view into the underlying bytes of an ArrayBuffer or TypedArray. Valid while the JS value is reachable on the engine.
pub const BufferView = struct {
    ptr: [*]u8,
    len: usize,
};

/// Wrap a native byte slice as an ArrayBuffer without copying. The buffer remains alive while the ArrayBuffer is reachable from JS; when the GC reclaims the wrapper, `finalizer(user_data, bytes, len)` fires and the caller is expected to free the memory inside it.
///
/// Caller promises `bytes[0..len]` is valid until the finalizer fires. Returns `null` if the instance is gone or the backend refused the allocation. On refusal the finalizer will still have fired exactly once with the original `(user_data, bytes, len)` so the caller can free safely.
///
/// The returned value is owned by the caller — release it via `ActiveEngine.freeValue` once native-side ownership is dropped, or stash it in JS (e.g. via `setPropertyStr`) where the GC will take over.
pub fn newArrayBufferFromBytes(
    instance_id: i32,
    bytes: [*]u8,
    len: usize,
    finalizer: ?BufferFinalizer,
    user_data: ?*anyopaque,
) ?ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse {
        // Instance missing. The caller's memory is still owned by them; fire the finalizer so they can release it. Matches napi-rs "on failure the finalizer runs" convention.
        if (finalizer) |fin| fin(user_data, bytes, len);
        return null;
    };
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const val = qjs_mod.qjsNewArrayBufferFromBytes(ctx, bytes, len, finalizer, user_data);
            if (qjs_mod.Backend.jsIsException(val)) {
                // Drain any pending exception so we don't poison the next eval. The backend trampoline already ran the finalizer, so the caller's memory is accounted for.
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return null;
            }
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const obj = jsc_mod.jscNewArrayBufferFromBytes(@ptrCast(ctx), bytes, len, finalizer, user_data);
            if (obj == null) return null;
            // jscNewArrayBufferFromBytes already JSValueProtect'd the object so it balances with the caller's freeValue.
            const v: ActiveEngine.Value = @ptrCast(obj);
            return v;
        },
        .escargot => {
            const esc = @import("../backend/escargot.zig").EscargotBackend;
            const Pack = struct {
                fin: BufferFinalizer,
                bytes: [*]u8,
                len: usize,
                user_data: ?*anyopaque,
            };
            const deleter_cb = struct {
                fn call(ud: ?*anyopaque) callconv(.c) void {
                    const pack: *Pack = @ptrCast(@alignCast(ud orelse return));
                    pack.fin(pack.user_data, pack.bytes, pack.len);
                    std.heap.c_allocator.destroy(pack);
                }
            }.call;
            if (finalizer) |fin| {
                const pack = std.heap.c_allocator.create(Pack) catch {
                    fin(user_data, bytes, len);
                    return null;
                };
                pack.* = .{ .fin = fin, .bytes = bytes, .len = len, .user_data = user_data };
                const val = esc.newArrayBufferNoCopyVal(ctx, bytes[0..len], deleter_cb, pack);
                if (val == null) return null; // bridge already ran deleter on failure
                return val;
            } else {
                return esc.newArrayBufferNoCopyVal(ctx, bytes[0..len], null, null);
            }
        },
        .hermes => {
            const herm = @import("../backend/hermes.zig").HermesBackend;
            const Pack = struct {
                fin: BufferFinalizer,
                bytes: [*]u8,
                len: usize,
                user_data: ?*anyopaque,
            };
            const deleter_cb = struct {
                fn call(ud: ?*anyopaque) callconv(.c) void {
                    const pack: *Pack = @ptrCast(@alignCast(ud orelse return));
                    pack.fin(pack.user_data, pack.bytes, pack.len);
                    std.heap.c_allocator.destroy(pack);
                }
            }.call;
            if (finalizer) |fin| {
                const pack = std.heap.c_allocator.create(Pack) catch {
                    fin(user_data, bytes, len);
                    return null;
                };
                pack.* = .{ .fin = fin, .bytes = bytes, .len = len, .user_data = user_data };
                const val = herm.newArrayBufferNoCopyVal(ctx, bytes[0..len], deleter_cb, pack);
                if (val == null) return null;
                return val;
            } else {
                return herm.newArrayBufferNoCopyVal(ctx, bytes[0..len], null, null);
            }
        },
    }
}

/// Same as `newArrayBufferFromBytes` but returns a `Uint8Array` view over the underlying buffer. Convenience wrapper when the JS consumer wants typed access. Semantics and ownership match `newArrayBufferFromBytes`.
pub fn newUint8ArrayFromBytes(
    instance_id: i32,
    bytes: [*]u8,
    len: usize,
    finalizer: ?BufferFinalizer,
    user_data: ?*anyopaque,
) ?ActiveEngine.Value {
    const ctx = engine.getContext(instance_id) orelse {
        if (finalizer) |fin| fin(user_data, bytes, len);
        return null;
    };
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const val = qjs_mod.qjsNewUint8ArrayFromBytes(ctx, bytes, len, finalizer, user_data);
            if (qjs_mod.Backend.jsIsException(val)) {
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return null;
            }
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const obj = jsc_mod.jscNewUint8ArrayFromBytes(@ptrCast(ctx), bytes, len, finalizer, user_data);
            if (obj == null) return null;
            const v: ActiveEngine.Value = @ptrCast(obj);
            return v;
        },
        .escargot => {
            const esc = @import("../backend/escargot.zig").EscargotBackend;
            // Build ArrayBuffer then Uint8Array view; finalizer owns the AB backing store.
            const Pack = struct {
                fin: BufferFinalizer,
                bytes: [*]u8,
                len: usize,
                user_data: ?*anyopaque,
            };
            const deleter_cb = struct {
                fn call(ud: ?*anyopaque) callconv(.c) void {
                    const pack: *Pack = @ptrCast(@alignCast(ud orelse return));
                    pack.fin(pack.user_data, pack.bytes, pack.len);
                    std.heap.c_allocator.destroy(pack);
                }
            }.call;
            const ab = blk: {
                if (finalizer) |fin| {
                    const pack = std.heap.c_allocator.create(Pack) catch {
                        fin(user_data, bytes, len);
                        return null;
                    };
                    pack.* = .{ .fin = fin, .bytes = bytes, .len = len, .user_data = user_data };
                    break :blk esc.newArrayBufferNoCopyVal(ctx, bytes[0..len], deleter_cb, pack);
                } else {
                    break :blk esc.newArrayBufferNoCopyVal(ctx, bytes[0..len], null, null);
                }
            };
            if (ab == null) return null;
            defer esc.freeValue(ctx, ab);
            // kind 1 = Uint8Array; length is element count
            return esc.newTypedArrayFromBufferVal(ctx, ab, 1, 0, len);
        },
        .hermes => {
            const herm = @import("../backend/hermes.zig").HermesBackend;
            const Pack = struct {
                fin: BufferFinalizer,
                bytes: [*]u8,
                len: usize,
                user_data: ?*anyopaque,
            };
            const deleter_cb = struct {
                fn call(ud: ?*anyopaque) callconv(.c) void {
                    const pack: *Pack = @ptrCast(@alignCast(ud orelse return));
                    pack.fin(pack.user_data, pack.bytes, pack.len);
                    std.heap.c_allocator.destroy(pack);
                }
            }.call;
            const ab = blk: {
                if (finalizer) |fin| {
                    const pack = std.heap.c_allocator.create(Pack) catch {
                        fin(user_data, bytes, len);
                        return null;
                    };
                    pack.* = .{ .fin = fin, .bytes = bytes, .len = len, .user_data = user_data };
                    break :blk herm.newArrayBufferNoCopyVal(ctx, bytes[0..len], deleter_cb, pack);
                } else {
                    break :blk herm.newArrayBufferNoCopyVal(ctx, bytes[0..len], null, null);
                }
            };
            if (ab == null) return null;
            defer herm.freeValue(ctx, ab);
            return herm.newTypedArrayFromBufferVal(ctx, ab, 1, 0, len);
        },
    }
}

/// Return a pointer + length view into an ArrayBuffer or TypedArray's backing bytes. `len` is the buffer's real byte length from creation (the backend store), not a JavaScript `byteLength` own property that later shadows the prototype getter. Returns `null` for non-buffer values, a detached buffer, or if the instance is gone. The pointer is only valid while the value is reachable on the engine — callers must not retain it past the next GC.
pub fn getBufferView(instance_id: i32, value: ActiveEngine.Value) ?BufferView {
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const v = qjs_mod.qjsGetBufferView(ctx, value) orelse return null;
            return .{ .ptr = v.ptr, .len = v.len };
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const v = jsc_mod.jscGetBufferView(@ptrCast(ctx), value) orelse return null;
            return .{ .ptr = v.ptr, .len = v.len };
        },
        .escargot => {
            const esc = @import("../backend/escargot.zig").EscargotBackend;
            if (esc.isArrayBufferVal(ctx, value)) {
                const slice = esc.getArrayBufferSliceVal(ctx, value) orelse return null;
                return .{ .ptr = slice.ptr, .len = slice.len };
            }
            if (esc.isTypedArrayVal(ctx, value)) {
                const info = esc.getTypedArrayBytesVal(ctx, value) orelse return null;
                return .{ .ptr = info.bytes.ptr, .len = info.byte_length };
            }
            // DataView
            const c_api = @import("../backend/escargot/c_api.zig");
            if (c_api.escargot_is_data_view(value)) {
                var off: usize = 0;
                var len: usize = 0;
                const ptr = c_api.escargot_data_view_data(ctx, value, &off, &len) orelse return null;
                return .{ .ptr = ptr, .len = len };
            }
            return null;
        },
        .hermes => {
            const herm = @import("../backend/hermes.zig").HermesBackend;
            if (herm.isArrayBufferVal(ctx, value)) {
                const slice = herm.getArrayBufferSliceVal(ctx, value) orelse return null;
                return .{ .ptr = slice.ptr, .len = slice.len };
            }
            if (herm.isTypedArrayVal(ctx, value)) {
                const info = herm.getTypedArrayBytesVal(ctx, value) orelse return null;
                return .{ .ptr = info.bytes.ptr, .len = info.byte_length };
            }
            const c_api = @import("../backend/hermes/c_api.zig");
            if (c_api.hermes_is_data_view(ctx, value)) {
                var off: usize = 0;
                var len: usize = 0;
                const ptr = c_api.hermes_data_view_data(ctx, value, &off, &len) orelse return null;
                return .{ .ptr = ptr, .len = len };
            }
            return null;
        },
    }
}

// ---- Pin / unpin -----------------------------------------------------------
//
// Pins are a host-side refcount keyed by JS object identity. They do not retain the runtime, so engine.destroy is unaffected.

var pin_counts: std.AutoHashMap(usize, u32) = std.AutoHashMap(usize, u32).init(std.heap.c_allocator);
var pin_mutex: @import("zev").Mutex = .{};

fn bufferObjectKey(ctx: ActiveEngine.Context, value: ActiveEngine.Value) ?usize {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            if (value.tag != qjs_mod.qjs.JS_TAG_OBJECT) return null;
            return @intFromPtr(value.u.ptr);
        },
        .jsc => {
            const ptr = value orelse return null;
            return @intFromPtr(ptr);
        },
        .escargot => {
            // Escargot retained handles are ValueRef* identity for the live object.
            const ptr = value orelse return null;
            return @intFromPtr(ptr);
        },
        .hermes => {
            // Distinct retained jsi::Value wrappers must share one key for the same JS object.
            const c = @import("../backend/hermes/c_api.zig");
            const id = c.hermes_object_identity(ctx, value);
            if (id == 0) return null;
            return @intCast(id);
        },
    }
}

/// Hold an ArrayBuffer for host-side lifecycle coordination. Returns false if the instance is gone or `value` is not an ArrayBuffer. Pins nest: each `pin` needs a matching `unpin`.
pub fn pin(instance_id: i32, value: ActiveEngine.Value) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    if (!ActiveEngine.isArrayBufferVal(ctx, value)) return false;
    const key = bufferObjectKey(ctx, value) orelse return false;
    pin_mutex.lock();
    defer pin_mutex.unlock();
    const entry = pin_counts.getPtr(key);
    if (entry) |count| {
        count.* +|= 1;
        return true;
    }
    pin_counts.put(key, 1) catch return false;
    return true;
}

/// Drop one pin taken by `pin`. Returns false if it was not pinned.
pub fn unpin(instance_id: i32, value: ActiveEngine.Value) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    const key = bufferObjectKey(ctx, value) orelse return false;
    pin_mutex.lock();
    defer pin_mutex.unlock();
    const count = pin_counts.getPtr(key) orelse return false;
    if (count.* <= 1) {
        _ = pin_counts.fetchRemove(key);
        return true;
    }
    count.* -= 1;
    return true;
}

/// True while at least one `pin` is outstanding for this ArrayBuffer.
pub fn isPinned(instance_id: i32, value: ActiveEngine.Value) bool {
    const ctx = engine.getContext(instance_id) orelse return false;
    const key = bufferObjectKey(ctx, value) orelse return false;
    pin_mutex.lock();
    defer pin_mutex.unlock();
    const count = pin_counts.get(key) orelse return false;
    return count > 0;
}
