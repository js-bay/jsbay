//! Zero-copy buffer support for the JSC backend.
//!
//! Wrap a caller-owned byte slice as an ArrayBuffer (or Uint8Array view over it) without copying. JSC calls our trampoline deallocator when the ArrayBuffer is collected; we bridge its (bytes, deallocatorContext) signature to the public `(user_data, bytes, len)` signature.
//!
//! Ownership:
//! * buffers.zig allocates a `JscBufferBox` on the Zig heap carrying { len, user_finalizer, user_data } and passes its pointer as `deallocatorContext`.
//! * JSC guarantees the deallocator runs even if JSObjectMakeArrayBufferWithBytesNoCopy itself throws (documented in the header). So the trampoline is always called exactly once.
//! * The returned ArrayBuffer is JSValueProtect'd so the caller can pair with `freeValue` (which unprotects) like any other backend Value.

const std = @import("std");
const common = @import("common.zig");

const jsc = common.jsc;

pub const JscBufferFinalizer = *const fn (
    user_data: ?*anyopaque,
    bytes: [*]u8,
    len: usize,
) callconv(.c) void;

const JscBufferBox = struct {
    len: usize,
    user_finalizer: ?JscBufferFinalizer,
    user_data: ?*anyopaque,
};

fn jscBufferDeallocatorTrampoline(
    bytes: ?*anyopaque,
    deallocator_ctx: ?*anyopaque,
) callconv(.c) void {
    const raw = deallocator_ctx orelse return;
    const box: *JscBufferBox = @ptrCast(@alignCast(raw));
    if (box.user_finalizer) |fin| {
        if (bytes) |b| {
            const byte_ptr: [*]u8 = @ptrCast(b);
            fin(box.user_data, byte_ptr, box.len);
        }
    }
    std.heap.c_allocator.destroy(box);
}

/// Wrap `bytes[0..len]` as an ArrayBuffer without copying. `finalizer`, if non-null, fires with `(user_data, bytes, len)` when the ArrayBuffer is collected (or immediately if JSC refuses the allocation). Returns null on failure. The returned object has been JSValueProtect'd.
pub fn jscNewArrayBufferFromBytes(
    ctx: jsc.JSContextRef,
    bytes: [*]u8,
    len: usize,
    finalizer: ?JscBufferFinalizer,
    user_data: ?*anyopaque,
) jsc.JSObjectRef {
    const box = std.heap.c_allocator.create(JscBufferBox) catch {
        if (finalizer) |fin| fin(user_data, bytes, len);
        return null;
    };
    box.* = .{ .len = len, .user_finalizer = finalizer, .user_data = user_data };

    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectMakeArrayBufferWithBytesNoCopy(
        ctx,
        bytes,
        len,
        jscBufferDeallocatorTrampoline,
        @ptrCast(box),
        &exc,
    );
    // Header contract: deallocator is guaranteed to have run on exception, so the box is already gone — no extra cleanup required here.
    if (exc != null or result == null) return null;
    jsc.JSValueProtect(ctx, result);
    return result;
}

/// Wrap `bytes[0..len]` as a Uint8Array without copying. Internally creates an ArrayBuffer and then a Uint8Array view over it. Returns null on failure. The returned object has been JSValueProtect'd.
pub fn jscNewUint8ArrayFromBytes(
    ctx: jsc.JSContextRef,
    bytes: [*]u8,
    len: usize,
    finalizer: ?JscBufferFinalizer,
    user_data: ?*anyopaque,
) jsc.JSObjectRef {
    const ab = jscNewArrayBufferFromBytes(ctx, bytes, len, finalizer, user_data);
    if (ab == null) return null;
    var exc: jsc.JSValueRef = null;
    const view = jsc.JSObjectMakeTypedArrayWithArrayBuffer(
        ctx,
        @intCast(jsc.kJSTypedArrayTypeUint8Array),
        ab,
        &exc,
    );
    // Release our protect on `ab`; the Uint8Array view owns a reference to the underlying buffer while it is alive, keeping the ArrayBuffer (and therefore the backing bytes) reachable.
    jsc.JSValueUnprotect(ctx, ab);
    if (exc != null or view == null) return null;
    jsc.JSValueProtect(ctx, view);
    return view;
}

/// Read-only view over an ArrayBuffer or TypedArray's underlying bytes. Returns null for other value shapes.
pub fn jscGetBufferView(
    ctx: jsc.JSContextRef,
    val: jsc.JSValueRef,
) ?struct { ptr: [*]u8, len: usize } {
    if (val == null) return null;
    const kind: c_int = @intCast(jsc.JSValueGetTypedArrayType(ctx, val, null));
    if (kind == common.JSC_TA_NONE) return null;
    const obj: jsc.JSObjectRef = @constCast(val);

    if (kind == common.JSC_TA_ARRAYBUFFER) {
        var exc: jsc.JSValueRef = null;
        const size = jsc.JSObjectGetArrayBufferByteLength(ctx, obj, &exc);
        if (exc != null) return null;
        const p = jsc.JSObjectGetArrayBufferBytesPtr(ctx, obj, &exc);
        if (exc != null) return null;
        if (p == null) {
            if (size == 0) return .{ .ptr = @ptrFromInt(@alignOf(u8)), .len = 0 };
            return null;
        }
        const byte_ptr: [*]u8 = @ptrCast(p);
        return .{ .ptr = byte_ptr, .len = size };
    }

    // TypedArray
    var exc: jsc.JSValueRef = null;
    const byte_len = jsc.JSObjectGetTypedArrayByteLength(ctx, obj, &exc);
    if (exc != null) return null;
    const byte_offset = jsc.JSObjectGetTypedArrayByteOffset(ctx, obj, &exc);
    if (exc != null) return null;
    const p = jsc.JSObjectGetTypedArrayBytesPtr(ctx, obj, &exc);
    if (exc != null) return null;
    if (p == null) {
        if (byte_len == 0) return .{ .ptr = @ptrFromInt(@alignOf(u8)), .len = 0 };
        return null;
    }
    const byte_ptr: [*]u8 = @ptrCast(p);
    return .{ .ptr = byte_ptr + byte_offset, .len = byte_len };
}
