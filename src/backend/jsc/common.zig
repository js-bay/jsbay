//! Shared infrastructure for the JSC backend submodules.
//!
//! Exposes the shared `jsc` bindings, JSTypedArrayType constants, the per-context opaque side table, and string/JSON/exception helpers.
//!
//! Declarations used by the JSC backend are re-exported through `backend/jsc.zig`.

const std = @import("std");
const sync = @import("zev");

pub const jsc = @import("jsc_c.zig");

// ---- TypedArray kind constants mirroring JSTypedArrayType ----
// Re-export the typed-array kinds used by this backend as c_int constants.
pub const JSC_TA_INT8: c_int = @intCast(jsc.kJSTypedArrayTypeInt8Array);
pub const JSC_TA_INT16: c_int = @intCast(jsc.kJSTypedArrayTypeInt16Array);
pub const JSC_TA_INT32: c_int = @intCast(jsc.kJSTypedArrayTypeInt32Array);
pub const JSC_TA_UINT8: c_int = @intCast(jsc.kJSTypedArrayTypeUint8Array);
pub const JSC_TA_UINT8C: c_int = @intCast(jsc.kJSTypedArrayTypeUint8ClampedArray);
pub const JSC_TA_UINT16: c_int = @intCast(jsc.kJSTypedArrayTypeUint16Array);
pub const JSC_TA_UINT32: c_int = @intCast(jsc.kJSTypedArrayTypeUint32Array);
pub const JSC_TA_FLOAT32: c_int = @intCast(jsc.kJSTypedArrayTypeFloat32Array);
pub const JSC_TA_FLOAT64: c_int = @intCast(jsc.kJSTypedArrayTypeFloat64Array);
pub const JSC_TA_ARRAYBUFFER: c_int = @intCast(jsc.kJSTypedArrayTypeArrayBuffer);
pub const JSC_TA_NONE: c_int = @intCast(jsc.kJSTypedArrayTypeNone);

// BigInt64Array / BigUint64Array kind constants (declared after the original JSC_TA_* block in jsc.zig — kept here so all kind constants live in one place).
pub const JSC_TA_BIG_INT64: c_int = @intCast(jsc.kJSTypedArrayTypeBigInt64Array);
pub const JSC_TA_BIG_UINT64: c_int = @intCast(jsc.kJSTypedArrayTypeBigUint64Array);

// ---- Context-opaque side table ----
//
// JSCore doesn't have a built-in opaque slot on the context, so we use a side HashMap keyed by the context pointer address.

var context_opaque: std.AutoHashMap(usize, usize) = std.AutoHashMap(usize, usize).init(std.heap.c_allocator);
var opaque_mutex: sync.Mutex = .{};

pub fn setContextOpaque(ctx: jsc.JSGlobalContextRef, data: ?*anyopaque) void {
    opaque_mutex.lock();
    defer opaque_mutex.unlock();
    context_opaque.put(@intFromPtr(ctx), @intFromPtr(data)) catch {};
}

pub fn getContextOpaque(ctx: jsc.JSGlobalContextRef) ?*anyopaque {
    opaque_mutex.lock();
    defer opaque_mutex.unlock();
    const val = context_opaque.get(@intFromPtr(ctx)) orelse return null;
    return @ptrFromInt(val);
}

pub fn removeContextOpaque(ctx: jsc.JSGlobalContextRef) void {
    opaque_mutex.lock();
    defer opaque_mutex.unlock();
    _ = context_opaque.remove(@intFromPtr(ctx));
}

pub fn instanceIdFromCtx(ctx: jsc.JSGlobalContextRef) i32 {
    const ptr = getContextOpaque(ctx);
    return @bitCast(@as(u32, @truncate(@intFromPtr(ptr))));
}

// ---- String / JSON / exception helpers ----
//
// These are file-level helpers used by every other submodule. They are also re-exported via `JscBackend.{jsStringFromSlice, valueToString, jsonStringify, jsonParse, formatException}` so external call sites such as cjs.zig keep working unchanged.

pub fn jsStringFromSlice(s: []const u8) jsc.JSStringRef {
    // JSStringCreateWithUTF8CString stops at the first 0. UTF-16 with an explicit length keeps embedded 0x00. JSC copies the units, so the temporary buffer does not outlive this call.
    if (fail_next_typed_string_for_testing.swap(false, .acq_rel)) return null;
    const utf16 = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, s) catch return null;
    defer std.heap.c_allocator.free(utf16);
    if (utf16.len == 0) {
        const dummy = [_]jsc.JSChar{0};
        return jsc.JSStringCreateWithCharacters(&dummy, 0);
    }
    return jsc.JSStringCreateWithCharacters(utf16.ptr, utf16.len);
}

var fail_next_typed_string_for_testing = std.atomic.Value(bool).init(false);

pub fn failNextTypedStringForTesting() void {
    fail_next_typed_string_for_testing.store(true, .release);
}

pub fn jsStringToOwnedAlloc(allocator: std.mem.Allocator, js_str: jsc.JSStringRef) ?[]u8 {
    if (js_str == null) return null;
    // JSStringGetUTF8CString exposes an empty result for an unpaired UTF-16 surrogate on this JSC build. Encode the native UTF-16 units ourselves so public strings always use U+FFFD for each unpaired half.
    const len = jsc.JSStringGetLength(js_str);
    const chars = jsc.JSStringGetCharactersPtr(js_str);
    if (len != 0 and chars == null) return null;
    var out = std.ArrayList(u8).empty;
    out.ensureTotalCapacityPrecise(allocator, len * 3) catch return null;
    var i: usize = 0;
    while (i < len) {
        const unit = chars[i];
        var scalar: u21 = unit;
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            if (i + 1 < len and chars[i + 1] >= 0xDC00 and chars[i + 1] <= 0xDFFF) {
                scalar = 0x10000 + ((@as(u21, unit) - 0xD800) << 10) + (@as(u21, chars[i + 1]) - 0xDC00);
                i += 1;
            } else scalar = std.unicode.replacement_character;
        } else if (unit >= 0xDC00 and unit <= 0xDFFF) scalar = std.unicode.replacement_character;
        var encoded: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(scalar, &encoded) catch return null;
        out.appendSliceAssumeCapacity(encoded[0..written]);
        i += 1;
    }
    return out.toOwnedSlice(allocator) catch null;
}

pub fn jsStringToOwned(js_str: jsc.JSStringRef) ?[]const u8 {
    return jsStringToOwnedAlloc(std.heap.c_allocator, js_str);
}

pub fn valueToStringAlloc(allocator: std.mem.Allocator, ctx_ref: jsc.JSContextRef, val: jsc.JSValueRef) ?[]u8 {
    if (val == null) return null;
    var exc: jsc.JSValueRef = null;
    const js_str = jsc.JSValueToStringCopy(ctx_ref, val, &exc);
    if (js_str == null) return null;
    defer jsc.JSStringRelease(js_str);
    return jsStringToOwnedAlloc(allocator, js_str);
}

pub fn valueToString(ctx_ref: jsc.JSContextRef, val: jsc.JSValueRef) ?[]const u8 {
    return valueToStringAlloc(std.heap.c_allocator, ctx_ref, val);
}

fn shrinkOwned(allocator: std.mem.Allocator, buf: []u8, len: usize) ?[]u8 {
    if (len == buf.len) return buf;
    if (allocator.resize(buf, len)) {
        // resize(0) frees the allocation. The empty slice is not a second copy.
        return if (len == 0) buf[0..0] else buf[0..len];
    }
    return allocator.realloc(buf, len) catch {
        allocator.free(buf);
        return null;
    };
}

pub fn jsonStringify(ctx_ref: jsc.JSContextRef, val: jsc.JSValueRef) ?[]const u8 {
    if (val == null) return null;
    var exc: jsc.JSValueRef = null;
    const js_str = jsc.JSValueCreateJSONString(ctx_ref, val, 0, &exc);
    if (js_str == null) return null;
    defer jsc.JSStringRelease(js_str);
    return jsStringToOwned(js_str);
}

pub fn jsonParse(ctx_ref: jsc.JSContextRef, json: []const u8) jsc.JSValueRef {
    const js_str = jsStringFromSlice(json) orelse return null;
    defer jsc.JSStringRelease(js_str);
    return jsc.JSValueMakeFromJSONString(ctx_ref, js_str);
}

pub fn formatException(ctx_ref: jsc.JSContextRef, exc: jsc.JSValueRef) ?[]const u8 {
    if (exc == null) return std.heap.c_allocator.dupe(u8, "JavaScript error") catch null;
    return valueToString(ctx_ref, exc) orelse (std.heap.c_allocator.dupe(u8, "JavaScript error") catch null);
}

pub fn makeStringValue(ctx_ref: jsc.JSContextRef, s: []const u8) jsc.JSValueRef {
    const js_str = jsStringFromSlice(s) orelse return null;
    defer jsc.JSStringRelease(js_str);
    return jsc.JSValueMakeString(ctx_ref, js_str);
}

pub fn setProperty(ctx_ref: jsc.JSContextRef, obj: jsc.JSObjectRef, name: []const u8, val: jsc.JSValueRef) void {
    const js_name = jsStringFromSlice(name) orelse return;
    defer jsc.JSStringRelease(js_name);
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx_ref, obj, js_name, val, 0, &exc);
}

pub fn makeFunction(ctx_ref: jsc.JSContextRef, name: []const u8, callback: jsc.JSObjectCallAsFunctionCallback) jsc.JSObjectRef {
    const js_name = jsStringFromSlice(name) orelse return null;
    defer jsc.JSStringRelease(js_name);
    return jsc.JSObjectMakeFunctionWithCallback(ctx_ref, js_name, callback);
}

pub fn throwError(ctx_ref: jsc.JSContextRef, exception: [*c]jsc.JSValueRef, msg: []const u8) jsc.JSValueRef {
    // Construct a proper Error object so JS catch handlers can read `e.message`. `new Error(msg)` takes a single string argument.
    const msg_val = makeStringValue(ctx_ref, msg) orelse return jsc.JSValueMakeUndefined(ctx_ref);
    var args = [_]jsc.JSValueRef{msg_val};
    var inner_exc: jsc.JSValueRef = null;
    const err_obj = jsc.JSObjectMakeError(ctx_ref, 1, &args, &inner_exc);
    exception[0] = if (err_obj != null) err_obj else msg_val;
    return jsc.JSValueMakeUndefined(ctx_ref);
}

// ---- No-ctx JS-null sentinel ----
//
// JSC has no compile-time JS-null constant — every real `JSValueRef` representing JS `null` comes from `JSValueMakeNull(ctx)`, which needs a context. To preserve the JS-level distinction between `null` and `undefined` at the `ActiveEngine.Value` layer even when callers default-init a slot without a context, `nullValue()` hands back this non-null, non-aligned pointer. Real JSC values are always aligned to at least 8 bytes, so `0x1` can never collide. The sentinel is recognised by `isNull` / `isUndefined` / `dupValue` / `freeValue` and **must be lifted** to a real `JSValueMakeNull(ctx)` ref before being handed to any raw JSC API (see `liftSentinel`).
pub const NULL_SENTINEL: jsc.JSValueRef = @ptrFromInt(0x1);

pub fn isSentinel(val: jsc.JSValueRef) bool {
    return val == NULL_SENTINEL;
}

/// Replace the no-ctx null sentinel with a real `JSValueMakeNull(ctx)` ref before forwarding into a JSC API that would otherwise dereference it. Pass-through for every other value (including C `null`, which JSC API callers handle directly).
pub fn liftSentinel(ctx_ref: jsc.JSContextRef, val: jsc.JSValueRef) jsc.JSValueRef {
    if (val == NULL_SENTINEL) return jsc.JSValueMakeNull(ctx_ref);
    return val;
}

/// The typed layer represents undefined as a C-null handle until it crosses a JavaScriptCore API boundary.  JSC APIs need a real JSValueRef there; null itself is represented by NULL_SENTINEL and is handled by liftSentinel.
pub fn liftValue(ctx_ref: jsc.JSContextRef, val: jsc.JSValueRef) jsc.JSValueRef {
    if (val == null) return jsc.JSValueMakeUndefined(ctx_ref);
    return liftSentinel(ctx_ref, val);
}
