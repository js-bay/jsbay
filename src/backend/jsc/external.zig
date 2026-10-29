//! External value support (napi_create_external / v8::External parity) for the JSC backend.
//!
//! Wraps a raw native pointer as an opaque JS object via a dedicated JSClassRef. JSValueIsObjectOfClass gives a clean isExternal predicate; JSObjectGetPrivate returns the wrapped pointer.

const std = @import("std");
const sync = @import("zev");
const common = @import("common.zig");

const jsc = common.jsc;

pub const JscExternalFinalizer = *const fn (*anyopaque) callconv(.c) void;

/// Heap-allocated box so we can attach a finalizer without paying for a HandleData-sized struct. The raw `ptr` is what getExternal returns.
const JscExternalBox = struct {
    ptr: ?*anyopaque,
    finalizer: ?JscExternalFinalizer,
};

var jsc_external_class_ref: ?jsc.JSClassRef = null;
var jsc_external_class_mutex: sync.Mutex = .{};

const jsc_external_class_name: [*:0]const u8 = "JsBayQjsExternal";

fn jscExternalFinalize(obj: jsc.JSObjectRef) callconv(.c) void {
    // JSC contract: must NOT call any JSC API that takes a JSContextRef here.
    const raw = jsc.JSObjectGetPrivate(obj);
    if (raw == null) return;
    const box: *JscExternalBox = @ptrCast(@alignCast(raw));
    if (box.finalizer) |fin| {
        if (box.ptr) |p| fin(p);
    }
    _ = jsc.JSObjectSetPrivate(obj, null);
    std.heap.c_allocator.destroy(box);
}

fn jscEnsureExternalClass() jsc.JSClassRef {
    jsc_external_class_mutex.lock();
    defer jsc_external_class_mutex.unlock();
    if (jsc_external_class_ref) |c| return c;
    var def = jsc.kJSClassDefinitionEmpty;
    def.className = jsc_external_class_name;
    def.finalize = jscExternalFinalize;
    jsc_external_class_ref = jsc.JSClassCreate(&def);
    return jsc_external_class_ref.?;
}

/// Wrap `ptr` as an External JSObjectRef. `finalizer`, if non-null, runs with `ptr` when the JS object is garbage-collected (or when the context is released).
pub fn jscNewExternal(
    ctx: jsc.JSContextRef,
    ptr: *anyopaque,
    finalizer: ?JscExternalFinalizer,
) jsc.JSObjectRef {
    const cls = jscEnsureExternalClass();
    const box = std.heap.c_allocator.create(JscExternalBox) catch {
        // Allocation failure — return an object with no private data so getExternal yields null downstream.
        return jsc.JSObjectMake(ctx, cls, null);
    };
    box.* = .{ .ptr = ptr, .finalizer = finalizer };
    return jsc.JSObjectMake(ctx, cls, @ptrCast(box));
}

/// Retrieve the wrapped pointer, or null if `val` is not an External.
pub fn jscGetExternal(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?*anyopaque {
    const cls = jscEnsureExternalClass();
    if (!jsc.JSValueIsObjectOfClass(ctx, val, cls)) return null;
    var exc: jsc.JSValueRef = null;
    const obj = jsc.JSValueToObject(ctx, val, &exc);
    if (exc != null or obj == null) return null;
    const raw = jsc.JSObjectGetPrivate(obj);
    if (raw == null) return null;
    const box: *JscExternalBox = @ptrCast(@alignCast(raw));
    return box.ptr;
}

/// True iff `val` is a JS object previously created by jscNewExternal.
pub fn jscIsExternal(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    const cls = jscEnsureExternalClass();
    return jsc.JSValueIsObjectOfClass(ctx, val, cls);
}
