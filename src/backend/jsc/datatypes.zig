//! Date / BigInt / Map / Set / DataView support for the JSC backend.
//!
//! These use JS-side constructors only where JSC has no public native API.

const std = @import("std");
const common = @import("common.zig");
const value_mod = @import("value.zig");
const sync = @import("zev");

const jsc = common.jsc;

// ---- Date ----

pub fn jscIsDate(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (val == null) return false;
    // Sentinel is JS null, never a Date.
    if (common.isSentinel(val)) return false;
    return jsc.JSValueIsDate(ctx, val);
}

pub fn jscToDateMs(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?i64 {
    if (!jscIsDate(ctx, val)) return null;
    // Invoke val.getTime(). In JSC we do this by looking up "getTime" on the object and calling it as a function.
    const name = jsc.JSStringCreateWithUTF8CString("getTime");
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const fn_val = jsc.JSObjectGetProperty(ctx, @constCast(val), name, &exc);
    if (exc != null or fn_val == null) return null;
    if (!jsc.JSValueIsObject(ctx, fn_val)) return null;
    const fn_obj: jsc.JSObjectRef = @constCast(fn_val);
    if (!jsc.JSObjectIsFunction(ctx, fn_obj)) return null;
    var exc2: jsc.JSValueRef = null;
    const res = jsc.JSObjectCallAsFunction(ctx, fn_obj, @constCast(val), 0, null, &exc2);
    if (exc2 != null or res == null) return null;
    var exc3: jsc.JSValueRef = null;
    const d = jsc.JSValueToNumber(ctx, res, &exc3);
    if (exc3 != null or !std.math.isFinite(d)) return null;
    return @intFromFloat(d);
}

pub fn jscNewDate(ctx: jsc.JSContextRef, ms: i64) jsc.JSValueRef {
    const ms_val = jsc.JSValueMakeNumber(ctx, @floatFromInt(ms));
    var args = [_]jsc.JSValueRef{ms_val};
    var exc: jsc.JSValueRef = null;
    const date_obj = jsc.JSObjectMakeDate(ctx, 1, &args, &exc);
    if (exc != null or date_obj == null) return jsc.JSValueMakeUndefined(ctx);
    const result: jsc.JSValueRef = @ptrCast(date_obj);
    jsc.JSValueProtect(ctx, result);
    return result;
}

// ---- BigInt ----

const IsBigIntFn = *const fn (jsc.JSContextRef, jsc.JSValueRef) callconv(.c) bool;
const ToBigIntI64Fn = *const fn (jsc.JSContextRef, jsc.JSValueRef, [*c]jsc.JSValueRef) callconv(.c) i64;
const ToBigIntU64Fn = *const fn (jsc.JSContextRef, jsc.JSValueRef, [*c]jsc.JSValueRef) callconv(.c) u64;
const NewBigIntI64Fn = *const fn (jsc.JSContextRef, i64, [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef;
const NewBigIntU64Fn = *const fn (jsc.JSContextRef, u64, [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef;

const NativeBigInt = struct {
    is_big_int: IsBigIntFn,
    to_i64: ToBigIntI64Fn,
    to_u64: ToBigIntU64Fn,
    new_i64: NewBigIntI64Fn,
    new_u64: NewBigIntU64Fn,
};

var native_bigint: ?NativeBigInt = null;
var native_bigint_checked = false;
var force_bigint_fallback_for_testing = false;
var native_bigint_mutex: sync.Mutex = .{};

fn lookupNativeBigInt() ?NativeBigInt {
    native_bigint_mutex.lock();
    defer native_bigint_mutex.unlock();
    if (force_bigint_fallback_for_testing) return null;
    if (native_bigint_checked) return native_bigint;
    native_bigint_checked = true;
    const path: [*:0]const u8 = "/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore";
    const handle = std.c.dlopen(path, .{ .LAZY = true }) orelse return null;
    const is_big_int = @as(?IsBigIntFn, @ptrCast(@alignCast(std.c.dlsym(handle, "JSValueIsBigInt") orelse return null))) orelse return null;
    const to_i64 = @as(?ToBigIntI64Fn, @ptrCast(@alignCast(std.c.dlsym(handle, "JSValueToInt64") orelse return null))) orelse return null;
    const to_u64 = @as(?ToBigIntU64Fn, @ptrCast(@alignCast(std.c.dlsym(handle, "JSValueToUInt64") orelse return null))) orelse return null;
    const new_i64 = @as(?NewBigIntI64Fn, @ptrCast(@alignCast(std.c.dlsym(handle, "JSBigIntCreateWithInt64") orelse return null))) orelse return null;
    const new_u64 = @as(?NewBigIntU64Fn, @ptrCast(@alignCast(std.c.dlsym(handle, "JSBigIntCreateWithUInt64") orelse return null))) orelse return null;
    native_bigint = .{ .is_big_int = is_big_int, .to_i64 = to_i64, .to_u64 = to_u64, .new_i64 = new_i64, .new_u64 = new_u64 };
    return native_bigint;
}

/// Internal test hook: force the old-system path without changing the public ABI.
pub fn setForceBigIntFallbackForTesting(enabled: bool) void {
    native_bigint_mutex.lock();
    defer native_bigint_mutex.unlock();
    force_bigint_fallback_for_testing = enabled;
}

fn fallbackIsBigInt(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    const predicate = value_mod.isBigIntFunction(@ptrCast(@constCast(ctx))) orelse return false;
    const global = jsc.JSContextGetGlobalObject(ctx);
    var args = [_]jsc.JSValueRef{val};
    var exception: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsFunction(ctx, predicate, global, 1, &args, &exception);
    return exception == null and result != null and jsc.JSValueToBoolean(ctx, result);
}

fn fallbackBigIntText(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?[]u8 {
    var exception: jsc.JSValueRef = null;
    const string = jsc.JSValueToStringCopy(ctx, val, &exception);
    if (exception != null or string == null) return null;
    defer jsc.JSStringRelease(string);
    return common.jsStringToOwnedAlloc(std.heap.c_allocator, string);
}

/// Mirrors JSC's integer conversion: accumulate modulo 2^64, then apply a decimal minus as two's complement. This intentionally accepts BigInts outside either target range.
fn fallbackBigIntBits(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var index: usize = 0;
    const negative = text[0] == '-';
    if (negative) index = 1;
    if (index == text.len) return null;
    var bits: u64 = 0;
    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (byte < '0' or byte > '9') return null;
        bits = bits *% 10 +% (byte - '0');
    }
    return if (negative) 0 -% bits else bits;
}

fn fallbackNewBigInt(ctx: jsc.JSContextRef, text: []const u8) jsc.JSValueRef {
    const constructor = value_mod.bigIntConstructor(@ptrCast(@constCast(ctx))) orelse return jsc.JSValueMakeUndefined(ctx);
    const argument = common.jsStringFromSlice(text) orelse return jsc.JSValueMakeUndefined(ctx);
    defer jsc.JSStringRelease(argument);
    const raw = jsc.JSValueMakeString(ctx, argument);
    var args = [_]jsc.JSValueRef{raw};
    var exception: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsFunction(ctx, constructor, jsc.JSContextGetGlobalObject(ctx), 1, &args, &exception);
    if (exception != null or result == null) return jsc.JSValueMakeUndefined(ctx);
    jsc.JSValueProtect(ctx, result);
    return result;
}

pub fn jscIsBigInt(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (val == null) return false;
    // Sentinel is JS null, never a BigInt.
    if (common.isSentinel(val)) return false;
    if (lookupNativeBigInt()) |native| return native.is_big_int(ctx, val);
    return fallbackIsBigInt(ctx, val);
}

pub fn jscToBigIntI64(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?i64 {
    if (!jscIsBigInt(ctx, val)) return null;
    if (lookupNativeBigInt()) |native| {
        var exc: jsc.JSValueRef = null;
        const r = native.to_i64(ctx, val, &exc);
        if (exc == null) return r;
        return null;
    }
    const text = fallbackBigIntText(ctx, val) orelse return null;
    defer std.heap.c_allocator.free(text);
    return @bitCast(fallbackBigIntBits(text) orelse return null);
}

pub fn jscToBigIntU64(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?u64 {
    if (!jscIsBigInt(ctx, val)) return null;
    if (lookupNativeBigInt()) |native| {
        var exc: jsc.JSValueRef = null;
        const r = native.to_u64(ctx, val, &exc);
        if (exc == null) return r;
        return null;
    }
    const text = fallbackBigIntText(ctx, val) orelse return null;
    defer std.heap.c_allocator.free(text);
    return fallbackBigIntBits(text);
}

pub fn jscNewBigIntI64(ctx: jsc.JSContextRef, v: i64) jsc.JSValueRef {
    if (lookupNativeBigInt()) |native| {
        var exc: jsc.JSValueRef = null;
        const result = native.new_i64(ctx, v, &exc);
        if (exc == null and result != null) {
            jsc.JSValueProtect(ctx, result);
            return result;
        }
        return jsc.JSValueMakeUndefined(ctx);
    }
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{v}) catch return jsc.JSValueMakeUndefined(ctx);
    return fallbackNewBigInt(ctx, text);
}

pub fn jscNewBigIntU64(ctx: jsc.JSContextRef, v: u64) jsc.JSValueRef {
    if (lookupNativeBigInt()) |native| {
        var exc: jsc.JSValueRef = null;
        const result = native.new_u64(ctx, v, &exc);
        if (exc == null and result != null) {
            jsc.JSValueProtect(ctx, result);
            return result;
        }
        return jsc.JSValueMakeUndefined(ctx);
    }
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{v}) catch return jsc.JSValueMakeUndefined(ctx);
    return fallbackNewBigInt(ctx, text);
}

test "JSC BigInt fallback survives global mutation, GC, and integer bounds" {
    const lifecycle = @import("lifecycle.zig");
    const testing = std.testing;
    const runtime = lifecycle.newRuntime() orelse return error.OutOfMemory;
    defer lifecycle.freeRuntime(runtime);
    const context = lifecycle.newContext(runtime) orelse return error.OutOfMemory;
    defer lifecycle.freeContext(context);
    const ctx: jsc.JSContextRef = @ptrCast(context);

    setForceBigIntFallbackForTesting(true);
    defer setForceBigIntFallbackForTesting(false);
    const mutation = common.jsStringFromSlice("globalThis.BigInt = () => 0") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(mutation);
    var exception: jsc.JSValueRef = null;
    _ = jsc.JSEvaluateScript(ctx, mutation, null, null, 1, &exception);
    try testing.expect(exception == null);
    jsc.JSGarbageCollect(ctx);

    const signed = jscNewBigIntI64(ctx, std.math.minInt(i64));
    defer jsc.JSValueUnprotect(ctx, signed);
    try testing.expect(jscIsBigInt(ctx, signed));
    try testing.expectEqual(std.math.minInt(i64), jscToBigIntI64(ctx, signed).?);
    const unsigned = jscNewBigIntU64(ctx, std.math.maxInt(u64));
    defer jsc.JSValueUnprotect(ctx, unsigned);
    try testing.expect(jscIsBigInt(ctx, unsigned));
    try testing.expectEqual(std.math.maxInt(u64), jscToBigIntU64(ctx, unsigned).?);
    try testing.expectEqual(@as(i64, -1), jscToBigIntI64(ctx, unsigned).?);
}

// ---- Map / Set detection via JSValueIsInstanceOfConstructor ----

fn jscGetGlobalCtor(ctx: jsc.JSContextRef, name_cstr: [*:0]const u8) jsc.JSObjectRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const js_name = jsc.JSStringCreateWithUTF8CString(name_cstr);
    defer jsc.JSStringRelease(js_name);
    var exc: jsc.JSValueRef = null;
    const ctor_val = jsc.JSObjectGetProperty(ctx, global, js_name, &exc);
    if (exc != null or ctor_val == null) return null;
    if (!jsc.JSValueIsObject(ctx, ctor_val)) return null;
    return @constCast(ctor_val);
}

pub fn jscIsMap(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (val == null) return false;
    // Sentinel is JS null, never a Map.
    if (common.isSentinel(val)) return false;
    if (!jsc.JSValueIsObject(ctx, val)) return false;
    const ctor = jscGetGlobalCtor(ctx, "Map") orelse return false;
    var exc: jsc.JSValueRef = null;
    const is = jsc.JSValueIsInstanceOfConstructor(ctx, val, ctor, &exc);
    if (exc != null) return false;
    return is;
}

pub fn jscIsSet(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (val == null) return false;
    // Sentinel is JS null, never a Set.
    if (common.isSentinel(val)) return false;
    if (!jsc.JSValueIsObject(ctx, val)) return false;
    const ctor = jscGetGlobalCtor(ctx, "Set") orelse return false;
    var exc: jsc.JSValueRef = null;
    const is = jsc.JSValueIsInstanceOfConstructor(ctx, val, ctor, &exc);
    if (exc != null) return false;
    return is;
}

/// Return `JSON.stringify(Array.from(val))` as an owned slice, or null on error.
pub fn jscMapSetToJson(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?[]const u8 {
    // Sentinel is JS null, not a Map/Set; `Array.from(null)` would TypeError and the unprotected sentinel would deref inside JSObjectCallAsFunction.
    if (common.isSentinel(val) or val == null) return null;
    const global = jsc.JSContextGetGlobalObject(ctx);
    // Array.from(val)
    const array_name = jsc.JSStringCreateWithUTF8CString("Array");
    defer jsc.JSStringRelease(array_name);
    var exc: jsc.JSValueRef = null;
    const array_val = jsc.JSObjectGetProperty(ctx, global, array_name, &exc);
    if (exc != null or array_val == null or !jsc.JSValueIsObject(ctx, array_val)) return null;
    const array_obj: jsc.JSObjectRef = @constCast(array_val);

    const from_name = jsc.JSStringCreateWithUTF8CString("from");
    defer jsc.JSStringRelease(from_name);
    const from_val = jsc.JSObjectGetProperty(ctx, array_obj, from_name, &exc);
    if (exc != null or from_val == null or !jsc.JSValueIsObject(ctx, from_val)) return null;
    const from_fn: jsc.JSObjectRef = @constCast(from_val);
    if (!jsc.JSObjectIsFunction(ctx, from_fn)) return null;

    var args = [_]jsc.JSValueRef{val};
    var exc2: jsc.JSValueRef = null;
    const arr = jsc.JSObjectCallAsFunction(ctx, from_fn, array_obj, 1, &args, &exc2);
    if (exc2 != null or arr == null) return null;

    return common.jsonStringify(ctx, arr);
}

/// Construct `new Map(JSON.parse(json))`. Returns null on error.
pub fn jscNewMapFromJson(ctx: jsc.JSContextRef, json: []const u8) jsc.JSValueRef {
    const parsed = common.jsonParse(ctx, json);
    if (parsed == null) return null;
    const ctor = jscGetGlobalCtor(ctx, "Map") orelse return null;
    var args = [_]jsc.JSValueRef{parsed};
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 1, &args, &exc);
    if (exc != null or result == null) return null;
    const v: jsc.JSValueRef = @ptrCast(result);
    jsc.JSValueProtect(ctx, v);
    return v;
}

/// Construct `new Set(JSON.parse(json))`. Returns null on error.
pub fn jscNewSetFromJson(ctx: jsc.JSContextRef, json: []const u8) jsc.JSValueRef {
    const parsed = common.jsonParse(ctx, json);
    if (parsed == null) return null;
    const ctor = jscGetGlobalCtor(ctx, "Set") orelse return null;
    var args = [_]jsc.JSValueRef{parsed};
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 1, &args, &exc);
    if (exc != null or result == null) return null;
    const v: jsc.JSValueRef = @ptrCast(result);
    jsc.JSValueProtect(ctx, v);
    return v;
}

// ============================================================================
// DataView support. JSC's public ArrayBufferView APIs expose a DataView's native backing store and window. DataView has the `None` typed-array type, while a native backing query distinguishes it from ordinary objects.
// ============================================================================

pub const JscDataViewInfo = struct {
    bytes: []u8,
    byte_offset: usize,
    byte_length: usize,
};

fn jscDataViewCtor(ctx: jsc.JSContextRef) jsc.JSObjectRef {
    const global = jsc.JSContextGetGlobalObject(ctx);
    const js_name = jsc.JSStringCreateWithUTF8CString("DataView");
    defer jsc.JSStringRelease(js_name);
    var exc: jsc.JSValueRef = null;
    const ctor_val = jsc.JSObjectGetProperty(ctx, global, js_name, &exc);
    if (exc != null or ctor_val == null) return null;
    if (!jsc.JSValueIsObject(ctx, ctor_val)) return null;
    return @constCast(ctor_val);
}

pub fn jscIsDataView(ctx: jsc.JSContextRef, val: jsc.JSValueRef) bool {
    if (val == null) return false;
    if (common.isSentinel(val)) return false;
    if (!jsc.JSValueIsObject(ctx, val)) return false;
    if (@as(c_int, @intCast(jsc.JSValueGetTypedArrayType(ctx, val, null))) != common.JSC_TA_NONE) return false;
    var exc: jsc.JSValueRef = null;
    return jsc.JSObjectGetTypedArrayBuffer(ctx, @constCast(val), &exc) != null and exc == null;
}

pub fn jscDataViewInfo(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?JscDataViewInfo {
    if (!jscIsDataView(ctx, val)) return null;
    const obj: jsc.JSObjectRef = @constCast(val);
    var exc: jsc.JSValueRef = null;
    const buffer = jsc.JSObjectGetTypedArrayBuffer(ctx, obj, &exc);
    if (exc != null or buffer == null) return null;
    jsc.JSValueProtect(ctx, buffer);
    defer jsc.JSValueUnprotect(ctx, buffer);
    exc = null;
    const size = jsc.JSObjectGetArrayBufferByteLength(ctx, buffer, &exc);
    if (exc != null) return null;
    exc = null;
    const ptr = jsc.JSObjectGetArrayBufferBytesPtr(ctx, buffer, &exc);
    if (exc != null) return null;
    if (ptr == null and size > 0) return null;
    exc = null;
    const off = jsc.JSObjectGetTypedArrayByteOffset(ctx, obj, &exc);
    if (exc != null) return null;
    exc = null;
    const len = jsc.JSObjectGetTypedArrayByteLength(ctx, obj, &exc);
    if (exc != null) return null;
    if (off > size or len > size - off) return null;
    if (off == 0 and len == 0) {
        const getter = @import("value.zig").dataViewByteLengthGetter(@ptrCast(@constCast(ctx))) orelse return null;
        exc = null;
        _ = jsc.JSObjectCallAsFunction(ctx, getter, obj, 0, null, &exc);
        if (exc != null) return null;
    }

    if (ptr == null) {
        return .{ .bytes = @as([*]u8, @ptrFromInt(@alignOf(u8)))[0..0], .byte_offset = off, .byte_length = len };
    }
    const byte_ptr: [*]u8 = @ptrCast(ptr);
    return .{ .bytes = byte_ptr[0..size], .byte_offset = off, .byte_length = len };
}

pub fn jscNewDataView(
    ctx: jsc.JSContextRef,
    ab: jsc.JSValueRef,
    byte_offset: usize,
    byte_length: usize,
) jsc.JSValueRef {
    const ctor = jscDataViewCtor(ctx) orelse return jsc.JSValueMakeUndefined(ctx);
    var args = [_]jsc.JSValueRef{
        ab,
        jsc.JSValueMakeNumber(ctx, @floatFromInt(byte_offset)),
        jsc.JSValueMakeNumber(ctx, @floatFromInt(byte_length)),
    };
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 3, &args, &exc);
    if (exc != null or result == null) return jsc.JSValueMakeUndefined(ctx);
    const v: jsc.JSValueRef = @ptrCast(result);
    jsc.JSValueProtect(ctx, v);
    return v;
}

// ============================================================================
// Native iteration + builder helpers for Map and Set (JSC side). Mirrors the QuickJS surface; see src/backend/quickjs.zig for contracts.
// ============================================================================

pub const JscMapForEachFn = fn (
    ctx: jsc.JSContextRef,
    cb_ctx: ?*anyopaque,
    key: jsc.JSValueRef,
    value: jsc.JSValueRef,
) callconv(.c) bool;

pub const JscSetForEachFn = fn (
    ctx: jsc.JSContextRef,
    cb_ctx: ?*anyopaque,
    value: jsc.JSValueRef,
) callconv(.c) bool;

/// Invoke `val[method]()` and return the iterator object, or null on exception / missing method.
fn jscObtainIter(ctx: jsc.JSContextRef, val: jsc.JSValueRef, method_cstr: [*:0]const u8) ?jsc.JSObjectRef {
    if (!jsc.JSValueIsObject(ctx, val)) return null;
    const obj: jsc.JSObjectRef = @constCast(val);

    const name = jsc.JSStringCreateWithUTF8CString(method_cstr);
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const method_val = jsc.JSObjectGetProperty(ctx, obj, name, &exc);
    if (exc != null or method_val == null or !jsc.JSValueIsObject(ctx, method_val)) return null;
    const method_fn: jsc.JSObjectRef = @constCast(method_val);
    if (!jsc.JSObjectIsFunction(ctx, method_fn)) return null;

    var exc2: jsc.JSValueRef = null;
    const iter_val = jsc.JSObjectCallAsFunction(ctx, method_fn, obj, 0, null, &exc2);
    if (exc2 != null or iter_val == null or !jsc.JSValueIsObject(ctx, iter_val)) return null;
    return @constCast(iter_val);
}

/// Call `iter.next()` once. On success returns the `.value` JSValueRef and sets `done_out=false`. On exhaustion returns null + done_out=true. On exception returns null + done_out=true (signals stop; caller can detect via returning false from driver if needed).
fn jscIterNextValue(ctx: jsc.JSContextRef, iter: jsc.JSObjectRef, done_out: *bool) ?jsc.JSValueRef {
    const next_name = jsc.JSStringCreateWithUTF8CString("next");
    defer jsc.JSStringRelease(next_name);
    var exc: jsc.JSValueRef = null;
    const next_val = jsc.JSObjectGetProperty(ctx, iter, next_name, &exc);
    if (exc != null or next_val == null or !jsc.JSValueIsObject(ctx, next_val)) {
        done_out.* = true;
        return null;
    }
    const next_fn: jsc.JSObjectRef = @constCast(next_val);
    if (!jsc.JSObjectIsFunction(ctx, next_fn)) {
        done_out.* = true;
        return null;
    }

    var exc2: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsFunction(ctx, next_fn, iter, 0, null, &exc2);
    if (exc2 != null or result == null or !jsc.JSValueIsObject(ctx, result)) {
        done_out.* = true;
        return null;
    }
    const result_obj: jsc.JSObjectRef = @constCast(result);

    const done_name = jsc.JSStringCreateWithUTF8CString("done");
    defer jsc.JSStringRelease(done_name);
    var exc3: jsc.JSValueRef = null;
    const done_val = jsc.JSObjectGetProperty(ctx, result_obj, done_name, &exc3);
    if (exc3 != null) {
        done_out.* = true;
        return null;
    }
    const is_done = jsc.JSValueToBoolean(ctx, done_val);
    done_out.* = is_done;
    if (is_done) return null;

    const value_name = jsc.JSStringCreateWithUTF8CString("value");
    defer jsc.JSStringRelease(value_name);
    var exc4: jsc.JSValueRef = null;
    const v = jsc.JSObjectGetProperty(ctx, result_obj, value_name, &exc4);
    if (exc4 != null) {
        done_out.* = true;
        return null;
    }
    return v;
}

pub fn jscMapForEach(
    ctx: jsc.JSContextRef,
    val: jsc.JSValueRef,
    cb_ctx: ?*anyopaque,
    cb: *const JscMapForEachFn,
) bool {
    if (!jscIsMap(ctx, val)) return false;
    const iter = jscObtainIter(ctx, val, "entries") orelse return false;

    while (true) {
        var done: bool = false;
        const entry = jscIterNextValue(ctx, iter, &done) orelse {
            return done;
        };
        if (!jsc.JSValueIsObject(ctx, entry)) return false;
        const entry_obj: jsc.JSObjectRef = @constCast(entry);

        var exc: jsc.JSValueRef = null;
        const key = jsc.JSObjectGetPropertyAtIndex(ctx, entry_obj, 0, &exc);
        if (exc != null) return false;
        var exc2: jsc.JSValueRef = null;
        const value = jsc.JSObjectGetPropertyAtIndex(ctx, entry_obj, 1, &exc2);
        if (exc2 != null) return false;

        const keep_going = cb(ctx, cb_ctx, key, value);
        if (!keep_going) return true;
    }
}

pub fn jscSetForEach(
    ctx: jsc.JSContextRef,
    val: jsc.JSValueRef,
    cb_ctx: ?*anyopaque,
    cb: *const JscSetForEachFn,
) bool {
    if (!jscIsSet(ctx, val)) return false;
    const iter = jscObtainIter(ctx, val, "values") orelse return false;

    while (true) {
        var done: bool = false;
        const item = jscIterNextValue(ctx, iter, &done) orelse {
            return done;
        };
        const keep_going = cb(ctx, cb_ctx, item);
        if (!keep_going) return true;
    }
}

pub fn jscMapSize(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?usize {
    if (!jscIsMap(ctx, val)) return null;
    const obj: jsc.JSObjectRef = @constCast(val);
    const name = jsc.JSStringCreateWithUTF8CString("size");
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const prop = jsc.JSObjectGetProperty(ctx, obj, name, &exc);
    if (exc != null or prop == null) return null;
    var exc2: jsc.JSValueRef = null;
    const d = jsc.JSValueToNumber(ctx, prop, &exc2);
    if (exc2 != null) return null;
    if (!std.math.isFinite(d) or d < 0) return null;
    return @intFromFloat(d);
}

pub fn jscSetSize(ctx: jsc.JSContextRef, val: jsc.JSValueRef) ?usize {
    if (!jscIsSet(ctx, val)) return null;
    const obj: jsc.JSObjectRef = @constCast(val);
    const name = jsc.JSStringCreateWithUTF8CString("size");
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const prop = jsc.JSObjectGetProperty(ctx, obj, name, &exc);
    if (exc != null or prop == null) return null;
    var exc2: jsc.JSValueRef = null;
    const d = jsc.JSValueToNumber(ctx, prop, &exc2);
    if (exc2 != null) return null;
    if (!std.math.isFinite(d) or d < 0) return null;
    return @intFromFloat(d);
}

pub fn jscNewMap(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const ctor = jscGetGlobalCtor(ctx, "Map") orelse return null;
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 0, null, &exc);
    if (exc != null or result == null) return null;
    const v: jsc.JSValueRef = @ptrCast(result);
    jsc.JSValueProtect(ctx, v);
    return v;
}

pub fn jscNewSet(ctx: jsc.JSContextRef) jsc.JSValueRef {
    const ctor = jscGetGlobalCtor(ctx, "Set") orelse return null;
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectCallAsConstructor(ctx, ctor, 0, null, &exc);
    if (exc != null or result == null) return null;
    const v: jsc.JSValueRef = @ptrCast(result);
    jsc.JSValueProtect(ctx, v);
    return v;
}

/// Invoke `map.set(key, value)`. Returns true on success.
pub fn jscMapSet(ctx: jsc.JSContextRef, map: jsc.JSValueRef, key: jsc.JSValueRef, value: jsc.JSValueRef) bool {
    // Sentinel is JS null, not a Map; refuse before JSValueIsObject derefs it.
    if (common.isSentinel(map) or map == null) return false;
    if (!jsc.JSValueIsObject(ctx, map)) return false;
    const map_obj: jsc.JSObjectRef = @constCast(map);

    const name = jsc.JSStringCreateWithUTF8CString("set");
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const method_val = jsc.JSObjectGetProperty(ctx, map_obj, name, &exc);
    if (exc != null or method_val == null or !jsc.JSValueIsObject(ctx, method_val)) return false;
    const method_fn: jsc.JSObjectRef = @constCast(method_val);
    if (!jsc.JSObjectIsFunction(ctx, method_fn)) return false;

    var args = [_]jsc.JSValueRef{ key, value };
    var exc2: jsc.JSValueRef = null;
    _ = jsc.JSObjectCallAsFunction(ctx, method_fn, map_obj, 2, &args, &exc2);
    return exc2 == null;
}

/// Invoke `set.add(value)`. Returns true on success.
pub fn jscSetAdd(ctx: jsc.JSContextRef, set: jsc.JSValueRef, value: jsc.JSValueRef) bool {
    // Sentinel is JS null, not a Set; refuse before JSValueIsObject derefs it.
    if (common.isSentinel(set) or set == null) return false;
    if (!jsc.JSValueIsObject(ctx, set)) return false;
    const set_obj: jsc.JSObjectRef = @constCast(set);

    const name = jsc.JSStringCreateWithUTF8CString("add");
    defer jsc.JSStringRelease(name);
    var exc: jsc.JSValueRef = null;
    const method_val = jsc.JSObjectGetProperty(ctx, set_obj, name, &exc);
    if (exc != null or method_val == null or !jsc.JSValueIsObject(ctx, method_val)) return false;
    const method_fn: jsc.JSObjectRef = @constCast(method_val);
    if (!jsc.JSObjectIsFunction(ctx, method_fn)) return false;

    var args = [_]jsc.JSValueRef{value};
    var exc2: jsc.JSValueRef = null;
    _ = jsc.JSObjectCallAsFunction(ctx, method_fn, set_obj, 1, &args, &exc2);
    return exc2 == null;
}
