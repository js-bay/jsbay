//! Zero-copy buffer support.
//!
//! Wrap a caller-owned byte slice as an ArrayBuffer (or Uint8Array view over it) without copying the payload. QuickJS calls our realloc trampoline with size 0 when the ArrayBuffer is released. A non-zero size is a resize, which these fixed buffers refuse.
//!
//! Ownership:
//! * buffers.zig allocates a `QjsBufferBox` on the Zig heap carrying { len, user_finalizer, user_data } and passes its pointer as `opaque`.
//! * On a successful buffer, QuickJS calls the trampoline once with size 0 at detach or finalization. If JS_NewArrayBuffer fails before the object exists, QuickJS does not call the trampoline, so this function runs the user finalizer and frees the box itself.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

pub const QjsBufferFinalizer = *const fn (
    user_data: ?*anyopaque,
    bytes: [*]u8,
    len: usize,
) callconv(.c) void;

const QjsBufferBox = struct {
    len: usize,
    user_finalizer: ?QjsBufferFinalizer,
    user_data: ?*anyopaque,
};

fn qjsBufferReallocTrampoline(
    _rt: ?*qjs.JSRuntime,
    opaque_ptr: ?*anyopaque,
    ptr: ?*anyopaque,
    size: usize,
) callconv(.c) ?*anyopaque {
    _ = _rt;
    if (size != 0) return null;
    const raw = opaque_ptr orelse return null;
    const box: *QjsBufferBox = @ptrCast(@alignCast(raw));
    if (box.user_finalizer) |fin| {
        if (ptr) |p| {
            const byte_ptr: [*]u8 = @ptrCast(p);
            fin(box.user_data, byte_ptr, box.len);
        }
    }
    std.heap.c_allocator.destroy(box);
    return null;
}

/// Wrap `bytes[0..len]` as an ArrayBuffer without copying. `finalizer`, if non-null, fires with `(user_data, bytes, len)` when the ArrayBuffer is GC'd (or immediately if QuickJS refuses the allocation). Returns JS_EXCEPTION on failure.
pub fn qjsNewArrayBufferFromBytes(
    ctx: ?*qjs.JSContext,
    bytes: [*]u8,
    len: usize,
    finalizer: ?QjsBufferFinalizer,
    user_data: ?*anyopaque,
) qjs.JSValue {
    const box = std.heap.c_allocator.create(QjsBufferBox) catch {
        // Out-of-memory on the Zig heap. Fire the user finalizer eagerly so the caller's memory isn't leaked, then return JS_EXCEPTION.
        if (finalizer) |fin| fin(user_data, bytes, len);
        return qjs.JS_ThrowOutOfMemory(ctx);
    };
    box.* = .{ .len = len, .user_finalizer = finalizer, .user_data = user_data };
    const val = c.JS_NewArrayBuffer(
        ctx,
        bytes,
        len,
        0,
        qjsBufferReallocTrampoline,
        @ptrCast(box),
        false,
    );
    if (c.jsIsException(val)) {
        if (finalizer) |fin| fin(user_data, bytes, len);
        std.heap.c_allocator.destroy(box);
    }
    return val;
}

/// Wrap `bytes[0..len]` as a Uint8Array without copying. Internally creates an ArrayBuffer and then a Uint8Array view spanning the whole buffer. Returns JS_EXCEPTION on failure.
pub fn qjsNewUint8ArrayFromBytes(
    ctx: ?*qjs.JSContext,
    bytes: [*]u8,
    len: usize,
    finalizer: ?QjsBufferFinalizer,
    user_data: ?*anyopaque,
) qjs.JSValue {
    const ab = qjsNewArrayBufferFromBytes(ctx, bytes, len, finalizer, user_data);
    if (c.jsIsException(ab)) return ab;
    defer c.jsbay_qjs_JS_FreeValue(ctx, ab);
    var argv = [_]qjs.JSValue{ ab, c.JS_UNDEFINED, c.JS_UNDEFINED };
    return c.JS_NewTypedArray(ctx, 3, &argv, c.QJS_TYPED_ARRAY_UINT8);
}

/// Read-only view over an ArrayBuffer or TypedArray's underlying bytes. Returns null for other value shapes. The pointer is live while the JS value is reachable.
pub fn qjsGetBufferView(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?struct { ptr: [*]u8, len: usize } {
    if (c.JS_IsArrayBuffer(ctx, val)) {
        var size: usize = 0;
        const p = c.JS_GetArrayBuffer(ctx, &size, val);
        if (p == null) {
            if (size == 0) return .{ .ptr = @ptrFromInt(@alignOf(u8)), .len = 0 };
            return null;
        }
        return .{ .ptr = p, .len = size };
    }
    const kind = c.JS_GetTypedArrayType(ctx, val);
    if (kind < 0) return null;
    var offset: usize = 0;
    var byte_len: usize = 0;
    var bpe: usize = 0;
    const ab = c.JS_GetTypedArrayBuffer(ctx, val, &offset, &byte_len, &bpe);
    if (c.jsIsException(ab)) {
        c.jsbay_qjs_JS_FreeValue(ctx, ab);
        return null;
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, ab);
    var size: usize = 0;
    const base = c.JS_GetArrayBuffer(ctx, &size, ab);
    if (base == null) return null;
    if (offset + byte_len > size) return null;
    return .{ .ptr = base + offset, .len = byte_len };
}
