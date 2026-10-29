//! Value operations for the JSC backend.
//!
//! Type predicates, value creation, type conversion, property/array access, function calls, ArrayBuffer / TypedArray helpers — everything the `value.zig` abstraction layer dispatches to via `ActiveEngine.xxx(...)`.
//!
//! Contract (cross-backend uniform): every `new*Val` returns a value with protect-count >= 1 so the caller's `freeValue` (JSValueUnprotect) lands on a non-zero count. For tagged primitives Protect/Unprotect are internally no-ops on JSC, but we call them uniformly so the contract stays unmuddled.

const std = @import("std");
const common = @import("common.zig");
const sync = @import("zev");

pub const jsc = common.jsc;

pub const Context = jsc.JSGlobalContextRef;
pub const Value = jsc.JSValueRef;

// Protected, context-owned copies of Function.prototype.apply, TypeError.prototype, DataView.prototype.byteLength's getter, and the TypedArray methods used by copyBuffer. Calling apply with the target function as its object receiver forwards the original JS value of `this`; the TypeError prototype classifies native JSC buffer errors and the DataView getter checks native view state without consulting mutable globals or instance properties.
const CapturedIntrinsics = struct {
    apply: jsc.JSObjectRef,
    type_error_prototype: jsc.JSValueRef,
    data_view_byte_length_getter: jsc.JSObjectRef,
    typed_array_set: jsc.JSObjectRef,
    typed_array_values: jsc.JSObjectRef,
    big_int: jsc.JSObjectRef,
    is_big_int: jsc.JSObjectRef,
};

var function_apply_by_context = std.AutoHashMap(usize, CapturedIntrinsics).init(std.heap.c_allocator);
var function_apply_mutex: sync.Mutex = .{};

pub fn captureFunctionApply(ctx: Context) bool {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const source = common.jsStringFromSlice("[Function.prototype.apply, TypeError.prototype, Object.getOwnPropertyDescriptor(DataView.prototype,'byteLength').get, Uint8Array.prototype.set, Uint8Array.prototype.values, typeof BigInt === 'function' ? BigInt : null, typeof BigInt === 'function' ? function(value){ return typeof value === 'bigint'; } : null]") orelse return false;
    defer jsc.JSStringRelease(source);
    var exception: jsc.JSValueRef = null;
    const value = jsc.JSEvaluateScript(ctx_ref, source, null, null, 1, &exception);
    if (exception != null or value == null or !jsc.JSValueIsObject(ctx_ref, value)) return false;
    jsc.JSValueProtect(ctx_ref, value);
    defer jsc.JSValueUnprotect(ctx_ref, value);
    const array: jsc.JSObjectRef = @ptrCast(@constCast(value));
    const zero = common.jsStringFromSlice("0") orelse return false;
    defer jsc.JSStringRelease(zero);
    const one = common.jsStringFromSlice("1") orelse return false;
    defer jsc.JSStringRelease(one);
    const two = common.jsStringFromSlice("2") orelse return false;
    defer jsc.JSStringRelease(two);
    const three = common.jsStringFromSlice("3") orelse return false;
    defer jsc.JSStringRelease(three);
    const four = common.jsStringFromSlice("4") orelse return false;
    defer jsc.JSStringRelease(four);
    const five = common.jsStringFromSlice("5") orelse return false;
    defer jsc.JSStringRelease(five);
    const six = common.jsStringFromSlice("6") orelse return false;
    defer jsc.JSStringRelease(six);
    const apply_value = jsc.JSObjectGetProperty(ctx_ref, array, zero, &exception);
    if (exception != null or apply_value == null or !jsc.JSValueIsObject(ctx_ref, apply_value)) return false;
    const type_error_prototype = jsc.JSObjectGetProperty(ctx_ref, array, one, &exception);
    if (exception != null or type_error_prototype == null or !jsc.JSValueIsObject(ctx_ref, type_error_prototype)) return false;
    const data_view_byte_length_getter_value = jsc.JSObjectGetProperty(ctx_ref, array, two, &exception);
    if (exception != null or data_view_byte_length_getter_value == null or !jsc.JSValueIsObject(ctx_ref, data_view_byte_length_getter_value)) return false;
    const typed_array_set_value = jsc.JSObjectGetProperty(ctx_ref, array, three, &exception);
    if (exception != null or typed_array_set_value == null or !jsc.JSValueIsObject(ctx_ref, typed_array_set_value)) return false;
    const typed_array_values_value = jsc.JSObjectGetProperty(ctx_ref, array, four, &exception);
    if (exception != null or typed_array_values_value == null or !jsc.JSValueIsObject(ctx_ref, typed_array_values_value)) return false;
    const big_int_value = jsc.JSObjectGetProperty(ctx_ref, array, five, &exception);
    if (exception != null or big_int_value == null) return false;
    const is_big_int_value = jsc.JSObjectGetProperty(ctx_ref, array, six, &exception);
    if (exception != null or is_big_int_value == null) return false;
    const apply: jsc.JSObjectRef = @ptrCast(@constCast(apply_value));
    const data_view_byte_length_getter: jsc.JSObjectRef = @ptrCast(@constCast(data_view_byte_length_getter_value));
    const typed_array_set: jsc.JSObjectRef = @ptrCast(@constCast(typed_array_set_value));
    const typed_array_values: jsc.JSObjectRef = @ptrCast(@constCast(typed_array_values_value));
    const big_int: jsc.JSObjectRef = if (jsc.JSValueIsObject(ctx_ref, big_int_value)) @ptrCast(@constCast(big_int_value)) else null;
    const is_big_int: jsc.JSObjectRef = if (jsc.JSValueIsObject(ctx_ref, is_big_int_value)) @ptrCast(@constCast(is_big_int_value)) else null;
    if (!jsc.JSObjectIsFunction(ctx_ref, apply) or !jsc.JSObjectIsFunction(ctx_ref, data_view_byte_length_getter) or !jsc.JSObjectIsFunction(ctx_ref, typed_array_set) or !jsc.JSObjectIsFunction(ctx_ref, typed_array_values) or (big_int != null and !jsc.JSObjectIsFunction(ctx_ref, big_int.?)) or (is_big_int != null and !jsc.JSObjectIsFunction(ctx_ref, is_big_int.?))) return false;
    jsc.JSValueProtect(ctx_ref, apply_value);
    jsc.JSValueProtect(ctx_ref, type_error_prototype);
    jsc.JSValueProtect(ctx_ref, data_view_byte_length_getter_value);
    jsc.JSValueProtect(ctx_ref, typed_array_set_value);
    jsc.JSValueProtect(ctx_ref, typed_array_values_value);
    if (big_int != null) jsc.JSValueProtect(ctx_ref, big_int_value);
    if (is_big_int != null) jsc.JSValueProtect(ctx_ref, is_big_int_value);
    function_apply_mutex.lock();
    function_apply_by_context.put(@intFromPtr(ctx), .{
        .apply = apply,
        .type_error_prototype = type_error_prototype,
        .data_view_byte_length_getter = data_view_byte_length_getter,
        .typed_array_set = typed_array_set,
        .typed_array_values = typed_array_values,
        .big_int = big_int,
        .is_big_int = is_big_int,
    }) catch {
        function_apply_mutex.unlock();
        jsc.JSValueUnprotect(ctx_ref, apply_value);
        jsc.JSValueUnprotect(ctx_ref, type_error_prototype);
        jsc.JSValueUnprotect(ctx_ref, data_view_byte_length_getter_value);
        jsc.JSValueUnprotect(ctx_ref, typed_array_set_value);
        jsc.JSValueUnprotect(ctx_ref, typed_array_values_value);
        if (big_int != null) jsc.JSValueUnprotect(ctx_ref, big_int_value);
        if (is_big_int != null) jsc.JSValueUnprotect(ctx_ref, is_big_int_value);
        return false;
    };
    function_apply_mutex.unlock();
    return true;
}
pub fn releaseFunctionApply(ctx: Context) void {
    function_apply_mutex.lock();
    const apply = function_apply_by_context.fetchRemove(@intFromPtr(ctx));
    function_apply_mutex.unlock();
    if (apply) |entry| {
        jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.apply);
        jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.type_error_prototype);
        jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.data_view_byte_length_getter);
        jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.typed_array_set);
        jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.typed_array_values);
        if (entry.value.big_int != null) jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.big_int);
        if (entry.value.is_big_int != null) jsc.JSValueUnprotect(@ptrCast(ctx), entry.value.is_big_int);
    }
}

pub fn functionApply(ctx: Context) ?jsc.JSObjectRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    return if (function_apply_by_context.get(@intFromPtr(ctx))) |entry| entry.apply else null;
}

pub fn typeErrorPrototype(ctx: Context) ?jsc.JSValueRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    return if (function_apply_by_context.get(@intFromPtr(ctx))) |entry| entry.type_error_prototype else null;
}

pub fn dataViewByteLengthGetter(ctx: Context) ?jsc.JSObjectRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    return if (function_apply_by_context.get(@intFromPtr(ctx))) |entry| entry.data_view_byte_length_getter else null;
}

pub fn typedArraySet(ctx: Context) ?jsc.JSObjectRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    return if (function_apply_by_context.get(@intFromPtr(ctx))) |entry| entry.typed_array_set else null;
}

pub fn typedArrayValues(ctx: Context) ?jsc.JSObjectRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    return if (function_apply_by_context.get(@intFromPtr(ctx))) |entry| entry.typed_array_values else null;
}

pub fn bigIntConstructor(ctx: Context) ?jsc.JSObjectRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    const entry = function_apply_by_context.get(@intFromPtr(ctx)) orelse return null;
    return entry.big_int orelse return null;
}

pub fn isBigIntFunction(ctx: Context) ?jsc.JSObjectRef {
    function_apply_mutex.lock();
    defer function_apply_mutex.unlock();
    const entry = function_apply_by_context.get(@intFromPtr(ctx)) orelse return null;
    return entry.is_big_int orelse return null;
}

test "JSC context intrinsics remain usable when BigInt is absent" {
    const testing = std.testing;
    const group = jsc.JSContextGroupCreate() orelse return error.OutOfMemory;
    defer jsc.JSContextGroupRelease(group);
    const ctx = jsc.JSGlobalContextCreateInGroup(group, null) orelse return error.OutOfMemory;
    defer jsc.JSGlobalContextRelease(ctx);
    const remove = common.jsStringFromSlice("delete globalThis.BigInt") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(remove);
    var exception: jsc.JSValueRef = null;
    _ = jsc.JSEvaluateScript(ctx, remove, null, null, 1, &exception);
    try testing.expect(exception == null);
    try testing.expect(captureFunctionApply(ctx));
    defer releaseFunctionApply(ctx);
    const ordinary = common.jsStringFromSlice("40 + 2") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(ordinary);
    exception = null;
    const result = jsc.JSEvaluateScript(ctx, ordinary, null, null, 1, &exception);
    try testing.expect(exception == null and result != null);
    try testing.expectEqual(@as(f64, 42), jsc.JSValueToNumber(ctx, result, &exception));
}

// ---- Top-level value singletons ----

pub fn undefinedValue() Value {
    // C-null doubles as the "default-init / unset slot" value on JSC, which JS-level predicates classify as `undefined`.
    return null;
}

pub fn nullValue() Value {
    // Distinct from `undefinedValue()` so callers can default-init a slot as JS `null` (not `undefined`) without a context. Lifted to a real ref by `common.liftSentinel` whenever it would cross into a JSC API.
    return common.NULL_SENTINEL;
}

pub fn dupValue(ctx: Context, val: Value) Value {
    if (common.isSentinel(val)) return val; // sentinel is constant; nothing to protect
    if (val != null) {
        jsc.JSValueProtect(@ptrCast(ctx), val);
    }
    return val;
}

pub fn freeValue(ctx: Context, val: Value) void {
    if (common.isSentinel(val)) return; // sentinel was never protected
    if (val != null) {
        jsc.JSValueUnprotect(@ptrCast(ctx), val);
    }
}

// ---- Function detection / no-arg call ----

pub fn isFunction(ctx: Context, val: Value) bool {
    if (val == null or common.isSentinel(val)) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    // JSObjectIsFunction asserts its argument is a JSObjectRef; calling it on a primitive value aborts the process under debug builds. Gate first.
    if (!jsc.JSValueIsObject(ctx_ref, val)) return false;
    return jsc.JSObjectIsFunction(ctx_ref, @constCast(val));
}

pub fn callFunctionNoArgs(ctx: Context, func: Value) ?[]const u8 {
    const jsc_ctx: jsc.JSContextRef = @ptrCast(ctx);
    const global = jsc.JSContextGetGlobalObject(jsc_ctx);
    var exception: jsc.JSValueRef = null;
    _ = jsc.JSObjectCallAsFunction(jsc_ctx, @constCast(func), global, 0, null, &exception);
    if (exception != null) {
        return common.formatException(jsc_ctx, exception);
    }
    return null;
}

// ---- Public helpers for consumers (bridge, etc.) ----

pub fn getGlobalObject(ctx: Context) jsc.JSObjectRef {
    const global = jsc.JSContextGetGlobalObject(@ptrCast(ctx));
    if (global != null) {
        jsc.JSValueProtect(@ptrCast(ctx), global);
    }
    return global;
}

pub fn newObject(ctx: Context) jsc.JSObjectRef {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const obj = jsc.JSObjectMake(ctx_ref, null, null);
    // Symmetric with QJS's "+1 refcount on return" contract: the caller pairs `newObject` with `freeValue` (JSValueUnprotect). Without this protect, an unprotected JSObjectMake result has protection count 0 and is vulnerable to GC between creation and graph insertion.
    if (obj != null) jsc.JSValueProtect(ctx_ref, obj);
    return obj;
}

/// Parity alias matching the QuickJS backend: set a property keyed by a NUL-terminated name string.
///
/// Ownership contract (cross-backend uniform): this function CONSUMES `val`. After the call the caller must NOT use `val` again, and must NOT `freeValue` it — the property slot now owns the (JSC: protected / QJS: +1 refcount) reference. Consumption happens even on failure, so callers never need an error-path free. If the caller needs to retain a usable handle after the set, pass `dupValue(ctx, val)` instead.
pub fn setPropertyStr(ctx_ref: Context, obj: Value, name: [*:0]const u8, val: Value) void {
    const ctx_typed: jsc.JSContextRef = @ptrCast(ctx_ref);
    // Lift the no-ctx null sentinel to a real `JSValueMakeNull(ctx)` ref before forwarding to JSC. The lifted ref is unprotected — JSC's null/undefined singletons live for the lifetime of the group, so there's no balance to maintain.
    const lifted = common.liftSentinel(ctx_typed, val);
    // Null obj: JSC would assert/crash inside JSObjectSetProperty. Skip the set but still consume val so the contract holds on the error path — matches QJS, which reports failure and still steals the ref.
    if (obj != null) {
        const slice = std.mem.span(name);
        const obj_typed: jsc.JSObjectRef = @ptrCast(@constCast(obj));
        common.setProperty(ctx_typed, obj_typed, slice, lifted);
    }
    // Only the original `val` (not the lifted form) was protected by the caller's `new*Val`; only it needs unprotect. The sentinel is a constant and was never protected.
    if (!common.isSentinel(val) and val != null) jsc.JSValueUnprotect(ctx_typed, val);
}

// ---- Type predicates ----

pub fn isUndefined(ctx: Context, val: Value) bool {
    if (common.isSentinel(val)) return false; // null sentinel is JS null, not undefined
    if (val == null) return true;
    return jsc.JSValueIsUndefined(@ptrCast(ctx), val);
}

pub fn isNull(ctx: Context, val: Value) bool {
    if (common.isSentinel(val)) return true;
    if (val == null) return false;
    return jsc.JSValueIsNull(@ptrCast(ctx), val);
}

pub fn isBool(ctx: Context, val: Value) bool {
    if (common.isSentinel(val) or val == null) return false;
    return jsc.JSValueIsBoolean(@ptrCast(ctx), val);
}

pub fn isNumber(ctx: Context, val: Value) bool {
    if (common.isSentinel(val) or val == null) return false;
    return jsc.JSValueIsNumber(@ptrCast(ctx), val);
}

pub fn isString(ctx: Context, val: Value) bool {
    if (common.isSentinel(val) or val == null) return false;
    return jsc.JSValueIsString(@ptrCast(ctx), val);
}

pub fn isSymbol(ctx: Context, val: Value) bool {
    if (common.isSentinel(val) or val == null) return false;
    return jsc.JSValueIsSymbol(@ptrCast(ctx), val);
}

pub fn isObjectVal(ctx: Context, val: Value) bool {
    if (common.isSentinel(val) or val == null) return false;
    return jsc.JSValueIsObject(@ptrCast(ctx), val);
}

pub fn isArray(ctx: Context, val: Value) bool {
    if (common.isSentinel(val) or val == null) return false;
    return jsc.JSValueIsArray(@ptrCast(ctx), val);
}

pub fn sameValue(ctx: Context, a: Value, b: Value) bool {
    return jsc.JSValueIsStrictEqual(@ptrCast(ctx), a, b);
}

// ---- Type extraction ----

pub fn toBool(ctx: Context, val: Value) ?bool {
    if (val == null) return null;
    // `Boolean(null) === false`. Sentinel represents JS null without a ctx.
    if (common.isSentinel(val)) return false;
    return jsc.JSValueToBoolean(@ptrCast(ctx), val);
}

pub fn toInt32(ctx: Context, val: Value) ?i32 {
    if (val == null) return null;
    // `Number(null) | 0 === 0`.
    if (common.isSentinel(val)) return 0;
    var exc: jsc.JSValueRef = null;
    const d = jsc.JSValueToNumber(@ptrCast(ctx), val, &exc);
    if (exc != null) return null;
    if (!std.math.isFinite(d)) return null;
    return @intFromFloat(d);
}

pub fn toFloat64(ctx: Context, val: Value) ?f64 {
    if (val == null) return null;
    // `Number(null) === 0`.
    if (common.isSentinel(val)) return 0.0;
    var exc: jsc.JSValueRef = null;
    const d = jsc.JSValueToNumber(@ptrCast(ctx), val, &exc);
    if (exc != null) return null;
    return d;
}

// ---- Value creation ----
//
// Contract (symmetric with QJS): every `new*Val` hands back a value the caller is responsible for balancing with `freeValue`. On JSC that means `JSValueProtect` on the way out so `JSValueUnprotect` in `freeValue` lands on a non-zero protection count. For tagged primitives (boolean/number) Protect/Unprotect are internally no-ops, but we call them uniformly to keep the cross-backend contract unmuddled.

pub fn newBoolVal(ctx: Context, val: bool) Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const result = jsc.JSValueMakeBoolean(ctx_ref, val);
    if (result != null) jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn newInt32Val(ctx: Context, val: i32) Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const result = jsc.JSValueMakeNumber(ctx_ref, @floatFromInt(val));
    if (result != null) jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn newFloat64Val(ctx: Context, val: f64) Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const result = jsc.JSValueMakeNumber(ctx_ref, val);
    if (result != null) jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn newStringVal(ctx: Context, str: []const u8) Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const js_str = common.jsStringFromSlice(str) orelse return null;
    defer jsc.JSStringRelease(js_str);
    const result = jsc.JSValueMakeString(ctx_ref, js_str);
    // Protect so freeValue (JSValueUnprotect) is safe
    jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn newNullVal(ctx: Context) Value {
    const result = jsc.JSValueMakeNull(@ptrCast(ctx));
    jsc.JSValueProtect(@ptrCast(ctx), result);
    return result;
}

pub fn newUndefinedVal(ctx: Context) Value {
    const result = jsc.JSValueMakeUndefined(@ptrCast(ctx));
    jsc.JSValueProtect(@ptrCast(ctx), result);
    return result;
}

// ---- Property access ----

pub fn getPropertyVal(ctx: Context, obj: Value, key: [*:0]const u8) ?Value {
    if (obj == null) return null;
    // `null.foo` would TypeError in JS; surface as "no value" without dereferencing the sentinel.
    if (common.isSentinel(obj)) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const js_key = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(js_key);
    var exc: jsc.JSValueRef = null;
    const val = jsc.JSObjectGetProperty(ctx_ref, @constCast(obj), js_key, &exc);
    if (exc != null) return null;
    if (val == null or jsc.JSValueIsUndefined(ctx_ref, val)) return null;
    // Protect so freeValue is safe
    jsc.JSValueProtect(ctx_ref, val);
    return val;
}

pub fn hasProperty(ctx: Context, obj: Value, key: [*:0]const u8) bool {
    if (obj == null) return false;
    // `"foo" in null` is a TypeError; treat sentinel as "no property".
    if (common.isSentinel(obj)) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const js_key = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(js_key);
    return jsc.JSObjectHasProperty(ctx_ref, @constCast(obj), js_key);
}

// ---- Array access ----

pub fn getIndex(ctx: Context, arr: Value, idx: u32) ?Value {
    if (arr == null) return null;
    // `null[0]` is a TypeError; surface as "no value".
    if (common.isSentinel(arr)) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    var exc: jsc.JSValueRef = null;
    const val = jsc.JSObjectGetPropertyAtIndex(ctx_ref, @constCast(arr), idx, &exc);
    if (exc != null) return null;
    if (val == null or jsc.JSValueIsUndefined(ctx_ref, val)) return null;
    jsc.JSValueProtect(ctx_ref, val);
    return val;
}

pub fn getLength(ctx: Context, obj: Value) ?u32 {
    if (obj == null) return null;
    // `null.length` is a TypeError; surface as "no length".
    if (common.isSentinel(obj)) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    // JSObjectGetProperty requires the receiver to actually be an object. Coerce via JSValueToObject so string/number inputs yield a proper wrapper (String → String object with .length) instead of crashing.
    var coerce_exc: jsc.JSValueRef = null;
    const as_obj = jsc.JSValueToObject(ctx_ref, obj, &coerce_exc);
    if (coerce_exc != null or as_obj == null) return null;
    const len_name = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(len_name);
    var exc: jsc.JSValueRef = null;
    const len_val = jsc.JSObjectGetProperty(ctx_ref, as_obj, len_name, &exc);
    if (exc != null or len_val == null) return null;
    var exc2: jsc.JSValueRef = null;
    const d = jsc.JSValueToNumber(ctx_ref, len_val, &exc2);
    if (exc2 != null) return null;
    if (!std.math.isFinite(d) or d < 0) return null;
    return @intFromFloat(d);
}

// ---- Function call ----

pub fn callFunction(ctx: Context, func: Value, this: Value, args: []const Value) ?Value {
    if (func == null) return null;
    // `null(...)` is a TypeError; surface as "no result" without dereferencing the sentinel inside JSObjectCallAsFunction.
    if (common.isSentinel(func)) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    var exc: jsc.JSValueRef = null;
    // `this` may legitimately be the no-ctx null sentinel — lift it to a real `JSValueMakeNull(ctx)` ref before forwarding so JSC sees a sound `this` argument. C-null falls through unchanged (means "global").
    const this_lifted = common.liftSentinel(ctx_ref, this);
    const this_obj: jsc.JSObjectRef = if (this_lifted != null) @constCast(this_lifted) else null;
    const result = jsc.JSObjectCallAsFunction(ctx_ref, @constCast(func), this_obj, args.len, @ptrCast(args.ptr), &exc);
    if (exc != null) return null;
    if (result != null) {
        jsc.JSValueProtect(ctx_ref, result);
    }
    return result;
}

// ---- JSON ----

pub fn jsonParseVal(ctx: Context, json: []const u8) ?Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const result = common.jsonParse(ctx_ref, json);
    if (result == null) return null;
    jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn jsonStringifyVal(ctx: Context, val: Value) ?[]const u8 {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    return common.jsonStringify(ctx_ref, common.liftSentinel(ctx_ref, val));
}

pub fn valueToStringAlloc(allocator: std.mem.Allocator, ctx: Context, val: Value) ?[]u8 {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    return common.valueToStringAlloc(allocator, ctx_ref, common.liftSentinel(ctx_ref, val));
}

pub fn valueToStringVal(ctx: Context, val: Value) ?[]const u8 {
    return valueToStringAlloc(std.heap.c_allocator, ctx, val);
}

// ---- ArrayBuffer / TypedArray (used by value.zig) ----

pub fn isArrayBufferVal(ctx: Context, val: Value) bool {
    if (val == null) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const t: c_int = @intCast(jsc.JSValueGetTypedArrayType(ctx_ref, val, null));
    return t == common.JSC_TA_ARRAYBUFFER;
}

pub fn isTypedArrayVal(ctx: Context, val: Value) bool {
    if (val == null) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const t: c_int = @intCast(jsc.JSValueGetTypedArrayType(ctx_ref, val, null));
    return t != common.JSC_TA_NONE and t != common.JSC_TA_ARRAYBUFFER;
}

pub fn getArrayBufferSliceVal(ctx: Context, val: Value) ?[]u8 {
    if (val == null) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const t: c_int = @intCast(jsc.JSValueGetTypedArrayType(ctx_ref, val, null));
    if (t != common.JSC_TA_ARRAYBUFFER) return null;
    const obj: jsc.JSObjectRef = @constCast(val);
    var exc: jsc.JSValueRef = null;
    const size = jsc.JSObjectGetArrayBufferByteLength(ctx_ref, obj, &exc);
    if (exc != null) return null;
    const ptr = jsc.JSObjectGetArrayBufferBytesPtr(ctx_ref, obj, &exc);
    if (exc != null) return null;
    if (ptr == null) return if (size == 0) @as([*]u8, @ptrFromInt(@alignOf(u8)))[0..0] else null;
    const byte_ptr: [*]u8 = @ptrCast(ptr);
    return byte_ptr[0..size];
}

pub const TypedArrayBytes = struct { bytes: []u8, element_size: usize, kind: c_int };

pub fn getTypedArrayBytesVal(ctx: Context, val: Value) ?TypedArrayBytes {
    if (val == null) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const kind: c_int = @intCast(jsc.JSValueGetTypedArrayType(ctx_ref, val, null));
    if (kind == common.JSC_TA_NONE or kind == common.JSC_TA_ARRAYBUFFER) return null;

    const obj: jsc.JSObjectRef = @constCast(val);
    var exc: jsc.JSValueRef = null;
    const byte_len = jsc.JSObjectGetTypedArrayByteLength(ctx_ref, obj, &exc);
    if (exc != null) return null;
    // Empirically JSObjectGetTypedArrayBytesPtr returns the backing-store pointer of the owning ArrayBuffer (not the view start) for sub-views, so we explicitly add the view's byteOffset to obtain a pointer to the start of the visible region.
    const byte_offset = jsc.JSObjectGetTypedArrayByteOffset(ctx_ref, obj, &exc);
    if (exc != null) return null;
    const ptr = jsc.JSObjectGetTypedArrayBytesPtr(ctx_ref, obj, &exc);
    if (exc != null) return null;

    const elem_size: usize = switch (kind) {
        common.JSC_TA_INT8, common.JSC_TA_UINT8, common.JSC_TA_UINT8C => 1,
        common.JSC_TA_INT16, common.JSC_TA_UINT16 => 2,
        common.JSC_TA_INT32, common.JSC_TA_UINT32, common.JSC_TA_FLOAT32 => 4,
        common.JSC_TA_FLOAT64 => 8,
        else => 0,
    };
    if (ptr == null) return .{ .bytes = @as([*]u8, @ptrFromInt(@alignOf(u8)))[0..0], .element_size = elem_size, .kind = kind };
    const byte_ptr: [*]u8 = @ptrCast(ptr);
    return .{ .bytes = (byte_ptr + byte_offset)[0..byte_len], .element_size = elem_size, .kind = kind };
}

pub fn newArrayBufferCopyVal(ctx: Context, data: []const u8) Value {
    // JSC has no direct AB-copy API; copy into C-allocator and use NoCopy with a deallocator that c_allocator-frees on GC.
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (data.len == 0) {
        var exc: jsc.JSValueRef = null;
        const view = jsc.JSObjectMakeTypedArray(ctx_ref, @intCast(jsc.kJSTypedArrayTypeUint8Array), 0, &exc);
        if (exc != null or view == null) return null;
        jsc.JSValueProtect(ctx_ref, view);
        defer jsc.JSValueUnprotect(ctx_ref, view);
        exc = null;
        const result = jsc.JSObjectGetTypedArrayBuffer(ctx_ref, view, &exc);
        if (exc != null or result == null) return null;
        jsc.JSValueProtect(ctx_ref, result);
        return result;
    }
    // Use raw malloc so the deallocator can call free() directly. The documented contract of JSObjectMakeArrayBufferWithBytesNoCopy guarantees the deallocator runs even on exception.
    const raw = std.c.malloc(data.len) orelse return null;
    const owned_ptr: [*]u8 = @ptrCast(raw);
    @memcpy(owned_ptr[0..data.len], data);
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectMakeArrayBufferWithBytesNoCopy(
        ctx_ref,
        owned_ptr,
        data.len,
        &jscDefaultDeallocator,
        null,
        &exc,
    );
    if (exc != null or result == null) {
        // deallocator is guaranteed to have been called on exception, per header docs.
        return null;
    }
    jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn newArrayBufferNoCopyVal(
    ctx: Context,
    data: []u8,
    deallocator: ?jsc.JSTypedArrayBytesDeallocator,
    deallocator_ctx: ?*anyopaque,
) Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    var exc: jsc.JSValueRef = null;
    const result = jsc.JSObjectMakeArrayBufferWithBytesNoCopy(
        ctx_ref,
        data.ptr,
        data.len,
        deallocator,
        deallocator_ctx,
        &exc,
    );
    if (exc != null or result == null) return null;
    jsc.JSValueProtect(ctx_ref, result);
    return result;
}

pub fn newTypedArrayFromBufferVal(ctx: Context, kind: c_int, ab: Value) Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    var exc: jsc.JSValueRef = null;
    const ab_obj: jsc.JSObjectRef = @constCast(ab);
    const result = jsc.JSObjectMakeTypedArrayWithArrayBuffer(ctx_ref, @intCast(kind), ab_obj, &exc);
    if (exc != null or result == null) return null;
    jsc.JSValueProtect(ctx_ref, result);
    return result;
}

fn jscDefaultDeallocator(bytes: ?*anyopaque, _ctx: ?*anyopaque) callconv(.c) void {
    _ = _ctx;
    if (bytes) |b| {
        // We allocated with c_allocator as a u8 buffer; free it here. Without length info we free via std.c.free (c_allocator uses malloc).
        std.c.free(b);
    }
}

/// Public JSC C API not wrapped in `jsc_c.zig`.
extern fn JSObjectIsConstructor(ctx: jsc.JSContextRef, object: jsc.JSObjectRef) bool;

/// ES IsConstructor via `JSObjectIsConstructor`. Non-objects are false. Does not attempt `new` and does not inspect a thrown exception.
pub fn isConstructor(ctx: Context, val: Value) bool {
    if (val == null or common.isSentinel(val)) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(ctx_ref, val)) return false;
    return JSObjectIsConstructor(ctx_ref, @constCast(val));
}

/// `new Array(len)`. A single numeric argument is the length, so the slots are holes and read back as `undefined`. Caller owns the protected value.
pub fn newArray(ctx: Context, len: u32) ?Value {
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    var exc: jsc.JSValueRef = null;
    const arr = jsc.JSObjectMakeArray(ctx_ref, 0, null, &exc);
    if (exc != null or arr == null) return null;
    if (len != 0) {
        const name = common.jsStringFromSlice("length") orelse return null;
        defer jsc.JSStringRelease(name);
        jsc.JSObjectSetProperty(ctx_ref, arr, name, jsc.JSValueMakeNumber(ctx_ref, @floatFromInt(len)), 0, &exc);
        if (exc != null) return null;
    }
    jsc.JSValueProtect(ctx_ref, arr);
    // JSObjectRef coerces to JSValueRef. The extra optional is the "constructor failed" null, not a JS null.
    const out: Value = arr;
    return out;
}

/// Own element, or real JS `undefined` for a hole. Never returns the null sentinel and never reports a hole as `null`. Caller owns the value.
pub fn arrayGet(ctx: Context, arr: Value, index: u32) ?Value {
    if (arr == null or common.isSentinel(arr)) return null;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(ctx_ref, arr)) return null;
    var exc: jsc.JSValueRef = null;
    const got = jsc.JSObjectGetPropertyAtIndex(ctx_ref, @constCast(arr), index, &exc);
    if (exc != null) return null;
    // A C null here is "no JS value", not a hole. Holes are real undefined.
    const val: jsc.JSValueRef = if (got != null) got else jsc.JSValueMakeUndefined(ctx_ref);
    if (val == null) return null;
    jsc.JSValueProtect(ctx_ref, val);
    return val;
}

/// Set `arr[index] = val`. Does not consume `val`.
pub fn arraySet(ctx: Context, arr: Value, index: u32, val: Value) bool {
    if (arr == null or common.isSentinel(arr)) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(ctx_ref, arr)) return false;
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetPropertyAtIndex(ctx_ref, @constCast(arr), index, common.liftSentinel(ctx_ref, val), &exc);
    return exc == null;
}

/// `arr.length = 0`, which drops every element.
pub fn arrayClear(ctx: Context, arr: Value) bool {
    if (arr == null or common.isSentinel(arr)) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(ctx_ref, arr)) return false;
    const name = jsc.JSStringCreateWithUTF8CString("length");
    defer jsc.JSStringRelease(name);
    const zero = jsc.JSValueMakeNumber(ctx_ref, 0);
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx_ref, @constCast(arr), name, zero, 0, &exc);
    return exc == null;
}

/// Data descriptor. `writable == false` sets `kJSPropertyAttributeReadOnly` on a new property, which JSC defines as [[Writable]]: false (a data property, not an accessor). Does not consume `val`.
pub fn defineDataProperty(ctx: Context, obj: Value, key: [*:0]const u8, val: Value, writable: bool) bool {
    if (obj == null or common.isSentinel(obj)) return false;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    if (!jsc.JSValueIsObject(ctx_ref, obj)) return false;
    const js_key = jsc.JSStringCreateWithUTF8CString(key);
    defer jsc.JSStringRelease(js_key);
    const attrs: jsc.JSPropertyAttributes = if (writable)
        0
    else
        @intCast(jsc.kJSPropertyAttributeReadOnly);
    var exc: jsc.JSValueRef = null;
    jsc.JSObjectSetProperty(ctx_ref, @constCast(obj), js_key, common.liftSentinel(ctx_ref, val), attrs, &exc);
    return exc == null;
}
