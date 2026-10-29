//! backend/jsc/native_handle.zig — JSC counterpart of native_handle.zig.
//!
//! Provides NativeHandle: a JSC class whose instances are directly callable from JavaScript and carry a native opaque pointer with automatic cleanup.
//!
//! Mirrors the public API of src/value/native_handle.zig so cross-backend consumer code can `@import("native_handle")` and get the right backend.
//!
//! Implementation notes:
//!   - Uses a single process-wide JSClassRef cached on first init().
//! - finalize: invoked by JSC GC; we run user finalize_fn then destroy the heap-allocated HandleData. Must NOT touch any JSC API that takes a JSContextRef (per JSObjectFinalizeCallback contract).
//!   - callAsFunction: dispatches to user call_fn or throws TypeError.
//! - Methods installed via JSObjectMakeFunctionWithCallback. Each method receives `this` as a JSObjectRef; we look up the HandleData via getOpaque(ctx, this).
//! - getOpaque verifies the value is an instance of our class via JSValueIsObjectOfClass before reading the private slot.
//! - No gc_mark_fn — JSC GC is internal. The field is preserved on the HandleData struct (set to null) for source-level parity with QuickJS.

const std = @import("std");
const sync = @import("zev");
const common = @import("common.zig");

/// Reuse the JavaScriptCore declarations shared with the backend facade.
pub const jsc = common.jsc;

// ── Per-instance data ─────────────────────────────────────────────────────

pub const CallFn = *const fn (
    ctx: jsc.JSContextRef,
    ptr: ?*anyopaque,
    argc: usize,
    argv: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef;

pub const FinalizeFn = *const fn (ptr: ?*anyopaque) void;

/// Configuration for a new NativeHandle.  Passed to `create()`.
pub const HandleData = struct {
    /// Arbitrary native pointer carried by this handle.
    ptr: ?*anyopaque = null,

    /// Called when JS invokes the object directly: `handle(args…)`.
    call_fn: ?CallFn = null,

    /// Called when JSC garbage-collects the object.
    finalize_fn: ?FinalizeFn = null,

    /// Unused on JSC — kept for source-level parity with the QuickJS HandleData struct so cross-backend consumer code can use the same struct literal. JSC GC is opaque to user code.
    gc_mark_fn: ?*anyopaque = null,
};

/// Method function type. `this` is always a NativeHandle JSObjectRef. Use `getOpaque(ctx, this)` to access HandleData.
pub const MethodFn = *const fn (
    ctx: jsc.JSContextRef,
    function: jsc.JSObjectRef,
    this_obj: jsc.JSObjectRef,
    argc: usize,
    argv: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef;

/// Convenience entry for `createWithMethods`.
pub const MethodEntry = struct {
    name: [*:0]const u8,
    func: MethodFn,
};

// ── Class id (process-wide) ───────────────────────────────────────────────

var class_ref: ?jsc.JSClassRef = null;
var class_init_mutex: sync.Mutex = .{};

const class_name_cstr: [*:0]const u8 = "NativeHandle";

/// Register the NativeHandle class. Idempotent — caches the JSClassRef the first time it's called.
pub fn init() void {
    class_init_mutex.lock();
    defer class_init_mutex.unlock();
    if (class_ref != null) return;

    var def = jsc.kJSClassDefinitionEmpty;
    def.className = class_name_cstr;
    def.finalize = classFinalize;
    def.callAsFunction = classCallAsFunction;
    class_ref = jsc.JSClassCreate(&def);
}

/// Get (and lazily create) the cached JSClassRef.
pub fn getClassRef() jsc.JSClassRef {
    if (class_ref == null) init();
    return class_ref.?;
}

// ── Class callbacks ───────────────────────────────────────────────────────

fn classFinalize(obj: jsc.JSObjectRef) callconv(.c) void {
    // JSObjectFinalizeCallback contract: do NOT call any JSC API that takes a JSContextRef from here. Just free our private state.
    const raw = jsc.JSObjectGetPrivate(obj);
    if (raw == null) return;
    const data: *HandleData = @ptrCast(@alignCast(raw));
    if (data.finalize_fn) |fin| fin(data.ptr);
    // Clear the private slot so any subsequent GC pass sees null.
    _ = jsc.JSObjectSetPrivate(obj, null);
    std.heap.c_allocator.destroy(data);
}

fn classCallAsFunction(
    ctx: jsc.JSContextRef,
    function: jsc.JSObjectRef,
    _: jsc.JSObjectRef, // thisObject (unused — we always dispatch through `function`)
    argc: usize,
    argv: [*c]const jsc.JSValueRef,
    exception: [*c]jsc.JSValueRef,
) callconv(.c) jsc.JSValueRef {
    const raw = jsc.JSObjectGetPrivate(function);
    if (raw == null) {
        return throwTypeError(ctx, exception, "NativeHandle: invalid object");
    }
    const data: *HandleData = @ptrCast(@alignCast(raw));
    if (data.call_fn) |call_fn| {
        return call_fn(ctx, data.ptr, argc, argv, exception);
    }
    return throwTypeError(ctx, exception, "NativeHandle is not callable");
}

// ── Helpers ───────────────────────────────────────────────────────────────

fn throwTypeError(
    ctx: jsc.JSContextRef,
    exception: [*c]jsc.JSValueRef,
    msg: [*:0]const u8,
) jsc.JSValueRef {
    const js_msg = jsc.JSStringCreateWithUTF8CString(msg);
    defer jsc.JSStringRelease(js_msg);
    const msg_val = jsc.JSValueMakeString(ctx, js_msg);
    var args = [_]jsc.JSValueRef{msg_val};
    var inner_exc: jsc.JSValueRef = null;
    const err_obj = jsc.JSObjectMakeError(ctx, 1, &args, &inner_exc);
    if (exception != null) {
        exception[0] = if (err_obj != null) @as(jsc.JSValueRef, err_obj) else msg_val;
    }
    return jsc.JSValueMakeUndefined(ctx);
}

// ── Public API ────────────────────────────────────────────────────────────

/// Create a new NativeHandle JS object. The returned object is callable from JS if `config.call_fn` is set.
pub fn create(
    ctx: jsc.JSContextRef,
    config: struct {
        ptr: ?*anyopaque = null,
        call_fn: ?CallFn = null,
        finalize_fn: ?FinalizeFn = null,
    },
) jsc.JSObjectRef {
    const cls = getClassRef();
    const data = std.heap.c_allocator.create(HandleData) catch {
        // If allocation fails we still return an object (empty private), so callAsFunction will throw "invalid object" to JS.
        return jsc.JSObjectMake(ctx, cls, null);
    };
    data.* = .{
        .ptr = config.ptr,
        .call_fn = config.call_fn,
        .finalize_fn = config.finalize_fn,
    };
    return jsc.JSObjectMake(ctx, cls, @ptrCast(data));
}

/// Convenience: create a handle and attach methods in one call.
pub fn createWithMethods(
    ctx: jsc.JSContextRef,
    config: struct {
        ptr: ?*anyopaque = null,
        call_fn: ?CallFn = null,
        finalize_fn: ?FinalizeFn = null,
    },
    methods: []const MethodEntry,
) jsc.JSObjectRef {
    const obj = create(ctx, .{
        .ptr = config.ptr,
        .call_fn = config.call_fn,
        .finalize_fn = config.finalize_fn,
    });
    for (methods) |m| setMethod(ctx, obj, m.name, m.func);
    return obj;
}

/// Add a named method to a NativeHandle instance.
///
/// Methods receive `this` as the parent NativeHandle JSObjectRef when invoked via `handle.method()`. Detached invocation (`var f = h.m; f()`) will call the method with `globalThis` as `this`, so the method can no longer locate its handle — JSC has no native equivalent of QuickJS's bound-method trampoline. Consumers that need detach-safe methods should keep a Zig closure that captures the pointer.
pub fn setMethod(
    ctx: jsc.JSContextRef,
    obj: jsc.JSObjectRef,
    name: [*:0]const u8,
    func: MethodFn,
) void {
    const js_name = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(js_name);
    const fn_obj = jsc.JSObjectMakeFunctionWithCallback(ctx, js_name, func);
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx, obj, js_name, fn_obj, 0, &exc);
}

/// Set a string property on a NativeHandle instance.
pub fn setStringProp(
    ctx: jsc.JSContextRef,
    obj: jsc.JSObjectRef,
    name: [*:0]const u8,
    value: []const u8,
) void {
    const js_name = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(js_name);

    const z = std.heap.c_allocator.dupeSentinel(u8, value, 0) catch return;
    defer std.heap.c_allocator.free(z);
    const js_val_str = jsc.JSStringCreateWithUTF8CString(z.ptr);
    defer jsc.JSStringRelease(js_val_str);

    const val = jsc.JSValueMakeString(ctx, js_val_str);
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx, obj, js_name, val, 0, &exc);
}

/// Set an integer property on a NativeHandle instance.
pub fn setIntProp(
    ctx: jsc.JSContextRef,
    obj: jsc.JSObjectRef,
    name: [*:0]const u8,
    value: i64,
) void {
    const js_name = jsc.JSStringCreateWithUTF8CString(name);
    defer jsc.JSStringRelease(js_name);
    const val = jsc.JSValueMakeNumber(ctx, @floatFromInt(value));
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx, obj, js_name, val, 0, &exc);
}

/// Retrieve the `HandleData` from a NativeHandle JS value.
///
/// Returns `null` if `val` is not a NativeHandle object (i.e. not created from our cached JSClassRef) or has no private data.
pub fn getOpaque(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?*HandleData {
    const cls = getClassRef();
    if (!jsc.JSValueIsObjectOfClass(ctx, val, cls)) return null;
    // val is verified to be an object of our class — safe to coerce.
    var exc: jsc.JSValueRef = null;
    const obj = jsc.JSValueToObject(ctx, val, &exc);
    if (obj == null) return null;
    const raw = jsc.JSObjectGetPrivate(obj);
    if (raw == null) return null;
    return @ptrCast(@alignCast(raw));
}

/// Get the cached JSClassRef (for advanced interop).
pub fn getClassId() jsc.JSClassRef {
    return getClassRef();
}
