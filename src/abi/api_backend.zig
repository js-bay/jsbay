//! Raw Value operations for the public opaque-Value ABI.  Unlike the older convenience helpers, these preserve an arbitrary JavaScript throw value.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("../backend.zig");
const ActiveEngine = backend.ActiveEngine;

pub const Result = union(enum) {
    ok: ActiveEngine.Value,
    exception: ActiveEngine.Value,
    out_of_memory,
};

/// Predicate-style operations report their boolean separately from a thrown JavaScript value, so `false` is never confused with an exception.
pub const BoolResult = union(enum) {
    ok: bool,
    exception: ActiveEngine.Value,
    out_of_memory,
};

/// Conversion results deliberately keep a thrown JavaScript value separate from allocation failure.  The older convenience helpers flatten both to null and drain exceptions, which is unsuitable for the typed C ABI.
pub const BytesResult = union(enum) {
    ok: []u8,
    exception: ActiveEngine.Value,
    out_of_memory,
    invalid_argument,
};

pub fn toUtf8(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsToUtf8(allocator, ctx, value),
        .jsc => jscToUtf8(allocator, ctx, value),
        .escargot => spikeToUtf8(allocator, ctx, .escargot, value),
        .hermes => spikeToUtf8(allocator, ctx, .hermes, value),
    };
}

pub fn toJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    // JSON text has no top-level representation for these values.  JSC's native stringify currently yields "null" for undefined, so enforce the public cross-backend contract before invoking backend conversion.
    if (ActiveEngine.isUndefined(ctx, value) or ActiveEngine.isFunction(ctx, value)) return .invalid_argument;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsToJson(allocator, ctx, value),
        .jsc => jscToJson(allocator, ctx, value),
        .escargot => spikeToJson(allocator, ctx, value, .escargot),
        .hermes => spikeToJson(allocator, ctx, value, .hermes),
    };
}

pub fn get(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsGet(ctx, object, key),
        .jsc => jscGet(ctx, object, key[0..key.len]),
        // Exception-preserving property reads (getter throws must not collapse to OOM).
        .escargot => escargotOp(@import("../backend/escargot/c_api.zig").escargot_get_property_result(ctx, object, key.ptr)),
        .hermes => hermesOp(@import("../backend/hermes/c_api.zig").hermes_get_property_result(ctx, object, key.ptr)),
    };
}

pub fn call(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, function: ActiveEngine.Value, this_value: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsCall(ctx, function, this_value, args),
        .jsc => jscCall(allocator, ctx, function, this_value, args),
        .escargot => escargotCall(ctx, function, this_value, args),
        .hermes => hermesCall(ctx, function, this_value, args),
    };
}

/// `value` is consumed by the backend on both success and throw paths.
pub fn set(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8, value: ActiveEngine.Value) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsSet(ctx, object, key, value),
        .jsc => jscSet(ctx, object, key[0..key.len], value),
        .escargot => blk: {
            const c = @import("../backend/escargot/c_api.zig");
            const r = c.escargot_set_property_result(ctx, object, key.ptr, value);
            // Consume value like setPropertyStr (bridge copies into the engine).
            ActiveEngine.freeValue(ctx, value);
            break :blk escargotOp(r);
        },
        .hermes => blk: {
            const c = @import("../backend/hermes/c_api.zig");
            const r = c.hermes_set_property_result(ctx, object, key.ptr, value);
            ActiveEngine.freeValue(ctx, value);
            break :blk hermesOp(r);
        },
    };
}

/// `new function(...args)`. Non-constructors throw a TypeError.
pub fn construct(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, function: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsConstruct(ctx, function, args),
        .jsc => jscConstruct(allocator, ctx, function, args),
        .escargot => escargotConstruct(ctx, function, args),
        .hermes => hermesConstruct(ctx, function, args),
    };
}

/// `key in object`, including the prototype chain. A non-object throws a TypeError.
pub fn has(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsHas(ctx, object, key),
        .jsc => jscHas(ctx, object, key[0..key.len]),
        .escargot => escargotHas(ctx, object, key),
        .hermes => hermesHas(ctx, object, key),
    };
}

/// Non-strict `delete object[key]`: a non-configurable property yields false, not a throw. `object` goes through ToObject, so only undefined and null throw.
pub fn delete(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsDelete(ctx, object, key),
        .jsc => jscDelete(ctx, object, key[0..key.len]),
        .escargot => escargotDelete(ctx, object, key),
        .hermes => hermesDelete(ctx, object, key),
    };
}

/// Equivalent to `Object.keys(object)`, returned as a new array.
pub fn keys(ctx: ActiveEngine.Context, object: ActiveEngine.Value) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsKeys(ctx, object),
        .jsc => jscKeys(ctx, object),
        .escargot => escargotKeys(ctx, object),
        .hermes => hermesKeys(ctx, object),
    };
}

/// `value instanceof constructor`, honoring `Symbol.hasInstance`.
pub fn instanceOf(ctx: ActiveEngine.Context, value: ActiveEngine.Value, constructor: ActiveEngine.Value) BoolResult {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsInstanceOf(ctx, value, constructor),
        .jsc => jscInstanceOf(ctx, value, constructor),
        .escargot => escargotInstanceOf(ctx, value, constructor),
        .hermes => hermesInstanceOf(ctx, value, constructor),
    };
}

pub fn parseJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, input: []const u8) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsParseJson(allocator, ctx, input),
        .jsc => jscParseJson(allocator, ctx, input),
        .escargot => escargotOp(blk: {
            const c = @import("../backend/escargot/c_api.zig");
            break :blk c.escargot_json_parse_result(ctx, input.ptr, input.len);
        }),
        .hermes => hermesOp(blk: {
            const c = @import("../backend/hermes/c_api.zig");
            break :blk c.hermes_json_parse_result(ctx, input.ptr, input.len);
        }),
    };
}

pub fn newError(ctx: ActiveEngine.Context, message: []const u8) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsNewError(ctx, message),
        .jsc => jscNewError(ctx, message),
        .escargot => escargotNewError(ctx, message),
        .hermes => hermesNewError(ctx, message),
    };
}

/// Typed string construction keeps JSC's UTF-16 allocation failure distinct from an empty JavaScript string.
var fail_next_constructor_for_testing = false;

/// Test-only allocation fault seam for the typed constructor status contract. It is deliberately not a C export.
pub fn failNextConstructorForTesting() void {
    if (builtin.is_test) fail_next_constructor_for_testing = true;
}

fn consumeConstructorFault() bool {
    if (!builtin.is_test or !fail_next_constructor_for_testing) return false;
    fail_next_constructor_for_testing = false;
    return true;
}

fn qjsConstructorResult(ctx: ActiveEngine.Context, value: ActiveEngine.Value) Result {
    const m = backend.ActiveEngineModule;
    if (m.c_api.jsIsException(value)) {
        // Constructors without an out_exception cannot expose a live throw value. Consume it so no pending exception poisons the next call.
        ActiveEngine.freeValue(ctx, value);
        const exception = m.qjs.JS_GetException(ctx);
        ActiveEngine.freeValue(ctx, exception);
        return .out_of_memory;
    }
    return .{ .ok = value };
}

/// Typed string construction keeps JSC's UTF-16 allocation failure distinct from an empty JavaScript string and never publishes a QJS exception tag.
pub fn newString(ctx: ActiveEngine.Context, input: []const u8) Result {
    if (consumeConstructorFault()) return .out_of_memory;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsConstructorResult(ctx, ActiveEngine.newStringVal(ctx, input)),
        .jsc => jscNewString(ctx, input),
        .escargot, .hermes => blk: {
            const v = ActiveEngine.newStringVal(ctx, input);
            break :blk if (v == null) .out_of_memory else .{ .ok = v };
        },
    };
}

/// Object construction follows the same no-pending-exception contract as strings. A constructor API has no exception output, so every backend-side allocation failure is reported as OUT_OF_MEMORY with a cleared output.
pub fn newObject(ctx: ActiveEngine.Context) Result {
    if (consumeConstructorFault()) return .out_of_memory;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsConstructorResult(ctx, ActiveEngine.newObject(ctx)),
        .jsc => if (ActiveEngine.newObject(ctx)) |value| .{ .ok = value } else .out_of_memory,
        .escargot, .hermes => if (ActiveEngine.newObject(ctx)) |value| .{ .ok = value } else .out_of_memory,
    };
}

/// `len` is already constrained to a valid native array length by the public caller. Backends which cannot allocate it return OUT_OF_MEMORY and retain no pending exception.
pub fn newArray(ctx: ActiveEngine.Context, len: u32) Result {
    if (consumeConstructorFault()) return .out_of_memory;
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => qjsConstructorResult(ctx, ActiveEngine.newArray(ctx, len) orelse return .out_of_memory),
        .jsc => if (ActiveEngine.newArray(ctx, len)) |value| .{ .ok = value } else .out_of_memory,
        .escargot, .hermes => if (ActiveEngine.newArray(ctx, len)) |value| .{ .ok = value } else .out_of_memory,
    };
}

pub fn newArrayBuffer(ctx: ActiveEngine.Context, bytes: []const u8) Result {
    const value = ActiveEngine.newArrayBufferCopyVal(ctx, bytes);
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => blk: {
            const m = backend.ActiveEngineModule;
            if (m.c_api.jsIsException(value)) break :blk .{ .exception = m.qjs.JS_GetException(ctx) };
            break :blk .{ .ok = value };
        },
        .jsc => if (value == null) .out_of_memory else .{ .ok = value },
        .escargot, .hermes => if (value == null) .out_of_memory else .{ .ok = value },
    };
}

pub fn copyBuffer(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    if (comptime backend.isJscApiBackend(backend.active_backend)) return jscCopyBuffer(allocator, ctx, value);

    const source: []const u8 = if (ActiveEngine.getArrayBufferSliceVal(ctx, value)) |bytes|
        bytes
    else if (ActiveEngine.getTypedArrayBytesVal(ctx, value)) |view|
        view.bytes
    else if (ActiveEngine.dataViewInfo(ctx, value)) |view|
        view.bytes[view.byte_offset .. view.byte_offset + view.byte_length]
    else
        return .invalid_argument;
    return .{ .ok = allocator.dupe(u8, source) catch return .out_of_memory };
}

fn jscCopyBuffer(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    const m = @import("../backend/jsc.zig");
    const intrinsics = @import("../backend/jsc/value.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const effective = @import("../backend/jsc/common.zig").liftValue(ctx_ref, value);
    if (!m.jsc.JSValueIsObject(ctx_ref, effective)) return .invalid_argument;

    var exception: m.jsc.JSValueRef = null;
    const kind = m.jsc.JSValueGetTypedArrayType(ctx_ref, effective, &exception);
    if (exception != null) return jscBufferException(ctx, exception);

    var buffer: m.jsc.JSObjectRef = undefined;
    var byte_offset: usize = 0;
    var byte_length: usize = 0;
    if (kind == m.jsc.kJSTypedArrayTypeArrayBuffer) {
        buffer = @constCast(effective);
        byte_length = m.jsc.JSObjectGetArrayBufferByteLength(ctx_ref, buffer, &exception);
        if (exception != null) return jscBufferException(ctx, exception);
    } else {
        buffer = m.jsc.JSObjectGetTypedArrayBuffer(ctx_ref, @constCast(effective), &exception);
        if (exception != null) return jscBufferException(ctx, exception);
        if (buffer == null) return .invalid_argument;

        const validator = if (kind == m.jsc.kJSTypedArrayTypeNone)
            intrinsics.dataViewByteLengthGetter(@ptrCast(ctx))
        else
            intrinsics.typedArrayValues(@ptrCast(ctx));
        const validate = validator orelse return .out_of_memory;
        const validation_result = m.jsc.JSObjectCallAsFunction(ctx_ref, validate, @constCast(effective), 0, null, &exception);
        if (exception != null) return jscBufferException(ctx, exception);
        if (validation_result == null) return .out_of_memory;

        byte_offset = m.jsc.JSObjectGetTypedArrayByteOffset(ctx_ref, @constCast(effective), &exception);
        if (exception != null) return jscBufferException(ctx, exception);
        byte_length = m.jsc.JSObjectGetTypedArrayByteLength(ctx_ref, @constCast(effective), &exception);
        if (exception != null) return jscBufferException(ctx, exception);
    }
    m.jsc.JSValueProtect(ctx_ref, buffer);
    defer m.jsc.JSValueUnprotect(ctx_ref, buffer);

    exception = null;
    const source = m.jsc.JSObjectMakeTypedArrayWithArrayBufferAndOffset(ctx_ref, @intCast(m.jsc.kJSTypedArrayTypeUint8Array), buffer, byte_offset, byte_length, &exception);
    if (source == null or exception != null) return jscBufferException(ctx, exception);
    m.jsc.JSValueProtect(ctx_ref, source);
    defer m.jsc.JSValueUnprotect(ctx_ref, source);

    exception = null;
    const destination = m.jsc.JSObjectMakeTypedArray(ctx_ref, @intCast(m.jsc.kJSTypedArrayTypeUint8Array), byte_length, &exception);
    if (destination == null or exception != null) return jscBufferException(ctx, exception);
    m.jsc.JSValueProtect(ctx_ref, destination);
    defer m.jsc.JSValueUnprotect(ctx_ref, destination);

    const set_fn = intrinsics.typedArraySet(@ptrCast(ctx)) orelse return .out_of_memory;
    const args = [_]m.jsc.JSValueRef{source};
    exception = null;
    const set_result = m.jsc.JSObjectCallAsFunction(ctx_ref, set_fn, destination, args.len, &args, &exception);
    if (exception != null) return jscBufferException(ctx, exception);
    if (set_result == null) return .out_of_memory;

    exception = null;
    const copied_len = m.jsc.JSObjectGetTypedArrayByteLength(ctx_ref, destination, &exception);
    if (exception != null) return jscBufferException(ctx, exception);
    if (copied_len != byte_length) return .out_of_memory;
    const ptr = m.jsc.JSObjectGetTypedArrayBytesPtr(ctx_ref, destination, &exception);
    if (exception != null) return jscBufferException(ctx, exception);
    if (ptr == null and copied_len != 0) return .out_of_memory;
    const source_bytes: []const u8 = if (copied_len == 0)
        &.{}
    else
        @as([*]const u8, @ptrCast(ptr.?))[0..copied_len];
    return .{ .ok = allocator.dupe(u8, source_bytes) catch return .out_of_memory };
}

fn jscBufferException(ctx: ActiveEngine.Context, exception: @import("../backend/jsc.zig").jsc.JSValueRef) BytesResult {
    const m = @import("../backend/jsc.zig");
    const thrown = exception orelse return .out_of_memory;
    if (m.jsc.JSValueIsObject(@ptrCast(ctx), thrown)) {
        const type_error_prototype = @import("../backend/jsc/value.zig").typeErrorPrototype(@ptrCast(ctx));
        if (type_error_prototype) |prototype| {
            if (m.jsc.JSValueIsStrictEqual(@ptrCast(ctx), m.jsc.JSObjectGetPrototype(@ptrCast(ctx), @constCast(thrown)), prototype)) return .invalid_argument;
        }
    }
    return .{ .exception = ActiveEngine.dupValue(ctx, thrown) };
}

fn qjsGet(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) Result {
    const m = backend.ActiveEngineModule;
    const value = m.qjs.JS_GetPropertyStr(ctx, object, key.ptr);
    if (m.c_api.jsIsException(value)) return .{ .exception = m.qjs.JS_GetException(ctx) };
    return .{ .ok = value };
}

fn qjsCall(ctx: ActiveEngine.Context, function: ActiveEngine.Value, this_value: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const m = backend.ActiveEngineModule;
    const value = m.qjs.JS_Call(ctx, function, this_value, @intCast(args.len), @constCast(args.ptr));
    if (m.c_api.jsIsException(value)) return .{ .exception = m.qjs.JS_GetException(ctx) };
    return .{ .ok = value };
}

fn qjsSet(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8, value: ActiveEngine.Value) Result {
    const m = backend.ActiveEngineModule;
    if (m.qjs.JS_SetPropertyStr(ctx, object, key.ptr, value) < 0) return .{ .exception = m.qjs.JS_GetException(ctx) };
    return .{ .ok = ActiveEngine.undefinedValue() };
}

fn qjsPendingException(ctx: ActiveEngine.Context) ActiveEngine.Value {
    return backend.ActiveEngineModule.qjs.JS_GetException(ctx);
}

fn qjsTypeError(ctx: ActiveEngine.Context, message: [*:0]const u8) ActiveEngine.Value {
    const m = backend.ActiveEngineModule;
    _ = m.qjs.JS_ThrowTypeError(ctx, "%s", message);
    return qjsPendingException(ctx);
}

/// Atom creation fails only on allocation failure. The engine leaves its out-of-memory error pending; consume it so the next call starts clean.
fn qjsKeyAtom(ctx: ActiveEngine.Context, key: [:0]const u8) ?u32 {
    const m = backend.ActiveEngineModule;
    const atom = m.qjs.JS_NewAtomLen(ctx, key.ptr, key.len);
    if (atom != 0) return atom;
    m.qjs.JS_FreeValue(ctx, qjsPendingException(ctx));
    return null;
}

fn qjsConstruct(ctx: ActiveEngine.Context, function: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const m = backend.ActiveEngineModule;
    const value = m.qjs.JS_CallConstructor(ctx, function, @intCast(args.len), @constCast(args.ptr));
    if (m.c_api.jsIsException(value)) return .{ .exception = qjsPendingException(ctx) };
    return .{ .ok = value };
}

fn qjsHas(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    const m = backend.ActiveEngineModule;
    // JS_HasProperty reports false for primitives; the `in` operator throws.
    if (m.c_api.jsbay_qjs_JS_IsObject(object) == 0) return .{ .exception = qjsTypeError(ctx, "cannot use 'in' operator to search for a key in a non-object") };
    const atom = qjsKeyAtom(ctx, key) orelse return .out_of_memory;
    defer m.qjs.JS_FreeAtom(ctx, atom);
    const found = m.qjs.JS_HasProperty(ctx, object, atom);
    if (found < 0) return .{ .exception = qjsPendingException(ctx) };
    return .{ .ok = found != 0 };
}

fn qjsDelete(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    const m = backend.ActiveEngineModule;
    const target = m.qjs.JS_ToObject(ctx, object);
    if (m.c_api.jsIsException(target)) return .{ .exception = qjsPendingException(ctx) };
    defer m.qjs.JS_FreeValue(ctx, target);
    const atom = qjsKeyAtom(ctx, key) orelse return .out_of_memory;
    defer m.qjs.JS_FreeAtom(ctx, atom);
    // Flags 0 selects non-strict semantics: refusal is false, not a TypeError.
    const deleted = m.qjs.JS_DeleteProperty(ctx, target, atom, 0);
    if (deleted < 0) return .{ .exception = qjsPendingException(ctx) };
    return .{ .ok = deleted != 0 };
}

fn qjsKeys(ctx: ActiveEngine.Context, object: ActiveEngine.Value) Result {
    const m = backend.ActiveEngineModule;
    const target = m.qjs.JS_ToObject(ctx, object);
    if (m.c_api.jsIsException(target)) return .{ .exception = qjsPendingException(ctx) };
    defer m.qjs.JS_FreeValue(ctx, target);
    var table: [*c]m.qjs.JSPropertyEnum = null;
    var count: u32 = 0;
    if (m.qjs.JS_GetOwnPropertyNames(ctx, &table, &count, target, m.qjs.JS_GPN_STRING_MASK | m.qjs.JS_GPN_ENUM_ONLY) < 0) {
        return .{ .exception = qjsPendingException(ctx) };
    }
    defer m.qjs.JS_FreePropertyEnum(ctx, table, count);
    const array = m.qjs.JS_NewArray(ctx);
    if (m.c_api.jsIsException(array)) return .{ .exception = qjsPendingException(ctx) };
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const name = m.qjs.JS_AtomToString(ctx, table[index].atom);
        if (m.c_api.jsIsException(name)) {
            m.qjs.JS_FreeValue(ctx, array);
            return .{ .exception = qjsPendingException(ctx) };
        }
        // Define rather than assign so Object.keys' CreateDataProperty is matched and a page-installed Array.prototype setter never runs. JS_DefinePropertyValueUint32 consumes `name` on success and failure.
        if (m.qjs.JS_DefinePropertyValueUint32(ctx, array, index, name, m.qjs.JS_PROP_C_W_E | m.qjs.JS_PROP_THROW) < 0) {
            m.qjs.JS_FreeValue(ctx, array);
            return .{ .exception = qjsPendingException(ctx) };
        }
    }
    return .{ .ok = array };
}

fn qjsInstanceOf(ctx: ActiveEngine.Context, value: ActiveEngine.Value, constructor: ActiveEngine.Value) BoolResult {
    const m = backend.ActiveEngineModule;
    const result = m.JS_IsInstanceOf(ctx, value, constructor);
    if (result < 0) return .{ .exception = qjsPendingException(ctx) };
    return .{ .ok = result != 0 };
}

fn qjsParseJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, input: []const u8) Result {
    const m = backend.ActiveEngineModule;
    const bytes = allocator.dupeSentinel(u8, input, 0) catch return .out_of_memory;
    defer allocator.free(bytes);
    const value = m.qjs.JS_ParseJSON(ctx, bytes.ptr, bytes.len, "<json>");
    if (m.c_api.jsIsException(value)) return .{ .exception = m.qjs.JS_GetException(ctx) };
    return .{ .ok = value };
}

fn qjsNewError(ctx: ActiveEngine.Context, message: []const u8) Result {
    const m = backend.ActiveEngineModule;
    const error_value = m.qjs.JS_NewError(ctx);
    if (m.c_api.jsIsException(error_value)) return .{ .exception = m.qjs.JS_GetException(ctx) };
    const text = m.qjs.JS_NewStringLen(ctx, message.ptr, message.len);
    if (m.c_api.jsIsException(text)) {
        m.qjs.JS_FreeValue(ctx, error_value);
        return .{ .exception = m.qjs.JS_GetException(ctx) };
    }
    // Define an own data property: assignment may invoke a poisoned Error.prototype.message setter and leave a pending exception behind.
    const flags = m.qjs.JS_PROP_WRITABLE | m.qjs.JS_PROP_CONFIGURABLE;
    if (m.qjs.JS_DefinePropertyValueStr(ctx, error_value, "message", text, flags) < 0) {
        m.qjs.JS_FreeValue(ctx, error_value);
        return .{ .exception = m.qjs.JS_GetException(ctx) };
    }
    return .{ .ok = error_value };
}

fn qjsBytes(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    const m = backend.ActiveEngineModule;
    var len: usize = 0;
    const text = m.qjs.JS_ToCStringLen(ctx, &len, value) orelse return .{ .exception = m.qjs.JS_GetException(ctx) };
    defer m.qjs.JS_FreeCString(ctx, text);
    const bytes = allocator.dupe(u8, text[0..len]) catch return .out_of_memory;
    return .{ .ok = bytes };
}

fn qjsToUtf8(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    return qjsBytes(allocator, ctx, value);
}

fn qjsToJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    const m = backend.ActiveEngineModule;
    const json = m.qjs.JS_JSONStringify(ctx, value, m.c_api.JS_UNDEFINED, m.c_api.JS_UNDEFINED);
    if (m.c_api.jsIsException(json)) return .{ .exception = m.qjs.JS_GetException(ctx) };
    defer m.qjs.JS_FreeValue(ctx, json);
    if (m.c_api.jsIsUndefined(json)) return .invalid_argument;
    return qjsBytes(allocator, ctx, json);
}

fn jscGet(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: []const u8) Result {
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    var exception: m.jsc.JSValueRef = null;
    const target = m.jsc.JSValueToObject(ctx_ref, common.liftValue(ctx_ref, object), &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (target == null) return .out_of_memory;
    const name = @import("../backend/jsc/common.zig").jsStringFromSlice(key) orelse return .out_of_memory;
    defer m.jsc.JSStringRelease(name);
    const value = m.jsc.JSObjectGetProperty(ctx_ref, target, name, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (value == null) return .out_of_memory;
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscCall(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, function: ActiveEngine.Value, this_value: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const m = @import("../backend/jsc.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const common = @import("../backend/jsc/common.zig");
    const lifted_function = common.liftValue(ctx_ref, function);
    if (!m.jsc.JSValueIsObject(ctx_ref, lifted_function)) {
        // Ask JSC itself for the ECMAScript TypeError.  Boxing first keeps undefined/null valid JSC values and avoids passing a primitive to JSObjectCallAsFunction, which requires an object pointer.
        var type_error: m.jsc.JSValueRef = null;
        const boxed = m.jsc.JSValueToObject(ctx_ref, lifted_function, &type_error);
        if (type_error != null) {
            m.jsc.JSValueProtect(ctx_ref, type_error);
            return .{ .exception = type_error };
        }
        if (boxed == null) return .out_of_memory;
        _ = m.jsc.JSObjectCallAsFunction(ctx_ref, boxed, m.jsc.JSContextGetGlobalObject(ctx_ref), 0, null, &type_error);
        if (type_error != null) {
            m.jsc.JSValueProtect(ctx_ref, type_error);
            return .{ .exception = type_error };
        }
        // A boxed primitive cannot be callable, but keep an owned fallback for an implementation that does not populate `type_error`.
        const error_result = jscNewError(ctx, "value is not callable");
        return switch (error_result) {
            .ok => |value| .{ .exception = value },
            .exception => |e| .{ .exception = e },
            .out_of_memory => .out_of_memory,
        };
    }
    const target: m.jsc.JSObjectRef = @ptrCast(@constCast(lifted_function));
    const apply = @import("../backend/jsc/value.zig").functionApply(ctx) orelse return .out_of_memory;
    var exception: m.jsc.JSValueRef = null;
    var lifted_args = std.ArrayList(m.jsc.JSValueRef).empty;
    defer lifted_args.deinit(allocator);
    lifted_args.ensureTotalCapacityPrecise(allocator, args.len) catch return .out_of_memory;
    for (args) |arg| lifted_args.appendAssumeCapacity(@import("../backend/jsc/common.zig").liftValue(ctx_ref, arg));
    const arg_array = m.jsc.JSObjectMakeArray(ctx_ref, lifted_args.items.len, lifted_args.items.ptr, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (arg_array == null) return .out_of_memory;
    const lifted_this = @import("../backend/jsc/common.zig").liftValue(ctx_ref, this_value);
    const apply_args = [_]m.jsc.JSValueRef{ lifted_this, arg_array };
    // `apply` is the pristine Function.prototype.apply captured at context creation. Its object receiver is the target function, preserving the exact primitive/null/undefined `this` argument under strict mode.
    const value = m.jsc.JSObjectCallAsFunction(ctx_ref, apply, target, apply_args.len, &apply_args, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (value == null) return .out_of_memory;
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscSet(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: []const u8, value: ActiveEngine.Value) Result {
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    // `set` consumes its value on every path, including a non-object target.
    defer ActiveEngine.freeValue(ctx, value);
    var exception: m.jsc.JSValueRef = null;
    const target = m.jsc.JSValueToObject(ctx_ref, common.liftValue(ctx_ref, object), &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (target == null) return .out_of_memory;
    const name = @import("../backend/jsc/common.zig").jsStringFromSlice(key) orelse return .out_of_memory;
    defer m.jsc.JSStringRelease(name);
    m.jsc.JSObjectSetProperty(ctx_ref, target, name, common.liftValue(ctx_ref, value), 0, &exception);
    // `set` consumes the duplicate supplied by the public API.  JSC property assignment does not consume a JSValueProtect reference itself.
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    return .{ .ok = ActiveEngine.undefinedValue() };
}

fn jscTypeError(ctx: ActiveEngine.Context, message: []const u8) Result {
    const m = @import("../backend/jsc.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const made = jscNewError(ctx, message);
    const error_value = switch (made) {
        .ok => |value| value,
        .exception => |e| return .{ .exception = e },
        .out_of_memory => return .out_of_memory,
    };
    // The pristine TypeError.prototype keeps `name` and `instanceof` correct even when page code has replaced the global TypeError.
    if (@import("../backend/jsc/value.zig").typeErrorPrototype(@ptrCast(ctx))) |prototype| {
        m.jsc.JSObjectSetPrototype(ctx_ref, @ptrCast(@constCast(error_value)), prototype);
    }
    return .{ .exception = error_value };
}

fn jscObjectIntrinsics(ctx: ActiveEngine.Context) ?@import("../backend/jsc/object_intrinsics.zig").Intrinsics {
    return @import("../backend/jsc/object_intrinsics.zig").get(@ptrCast(ctx));
}

/// Invoke a captured helper. Every helper is a plain function, so `this` is unused.
fn jscCallIntrinsic(ctx: ActiveEngine.Context, function: @import("../backend/jsc.zig").jsc.JSObjectRef, args: []const @import("../backend/jsc.zig").jsc.JSValueRef) Result {
    const m = @import("../backend/jsc.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    var exception: m.jsc.JSValueRef = null;
    const value = m.jsc.JSObjectCallAsFunction(ctx_ref, function, null, args.len, args.ptr, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (value == null) return .out_of_memory;
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscBoolResult(ctx: ActiveEngine.Context, result: Result) BoolResult {
    const m = @import("../backend/jsc.zig");
    switch (result) {
        .exception => |exception| return .{ .exception = exception },
        .ok => |value| {
            defer ActiveEngine.freeValue(ctx, value);
            return .{ .ok = m.jsc.JSValueToBoolean(@ptrCast(ctx), value) };
        },
        .out_of_memory => return .out_of_memory,
    }
}

fn jscKeyValue(ctx: ActiveEngine.Context, key: []const u8) ?@import("../backend/jsc.zig").jsc.JSValueRef {
    const m = @import("../backend/jsc.zig");
    const text = @import("../backend/jsc/common.zig").jsStringFromSlice(key) orelse return null;
    defer m.jsc.JSStringRelease(text);
    return m.jsc.JSValueMakeString(@ptrCast(ctx), text);
}

fn jscConstruct(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, function: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const lifted_function = common.liftValue(ctx_ref, function);
    // JSObjectCallAsConstructor returns null without an exception for a non-constructor, and requires an object pointer.
    if (!m.jsc.JSValueIsObject(ctx_ref, lifted_function) or !m.jsc.JSObjectIsConstructor(ctx_ref, @ptrCast(@constCast(lifted_function)))) {
        return jscTypeError(ctx, "value is not a constructor");
    }
    var lifted_args = std.ArrayList(m.jsc.JSValueRef).empty;
    defer lifted_args.deinit(allocator);
    lifted_args.ensureTotalCapacityPrecise(allocator, args.len) catch return .out_of_memory;
    for (args) |arg| lifted_args.appendAssumeCapacity(common.liftValue(ctx_ref, arg));
    var exception: m.jsc.JSValueRef = null;
    const value = m.jsc.JSObjectCallAsConstructor(ctx_ref, @ptrCast(@constCast(lifted_function)), lifted_args.items.len, lifted_args.items.ptr, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (value == null) return .out_of_memory;
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscHas(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: []const u8) BoolResult {
    const common = @import("../backend/jsc/common.zig");
    const intrinsics = jscObjectIntrinsics(ctx) orelse return .out_of_memory;
    const key_value = jscKeyValue(ctx, key) orelse return .out_of_memory;
    const args = [_]@import("../backend/jsc.zig").jsc.JSValueRef{ common.liftValue(@ptrCast(ctx), object), key_value };
    return jscBoolResult(ctx, jscCallIntrinsic(ctx, intrinsics.has, &args));
}

fn jscDelete(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: []const u8) BoolResult {
    const common = @import("../backend/jsc/common.zig");
    const intrinsics = jscObjectIntrinsics(ctx) orelse return .out_of_memory;
    const key_value = jscKeyValue(ctx, key) orelse return .out_of_memory;
    const args = [_]@import("../backend/jsc.zig").jsc.JSValueRef{ common.liftValue(@ptrCast(ctx), object), key_value };
    return jscBoolResult(ctx, jscCallIntrinsic(ctx, intrinsics.delete, &args));
}

fn jscKeys(ctx: ActiveEngine.Context, object: ActiveEngine.Value) Result {
    const common = @import("../backend/jsc/common.zig");
    const intrinsics = jscObjectIntrinsics(ctx) orelse return .out_of_memory;
    const args = [_]@import("../backend/jsc.zig").jsc.JSValueRef{common.liftValue(@ptrCast(ctx), object)};
    return jscCallIntrinsic(ctx, intrinsics.keys, &args);
}

fn jscInstanceOf(ctx: ActiveEngine.Context, value: ActiveEngine.Value, constructor: ActiveEngine.Value) BoolResult {
    const common = @import("../backend/jsc/common.zig");
    const intrinsics = jscObjectIntrinsics(ctx) orelse return .out_of_memory;
    const args = [_]@import("../backend/jsc.zig").jsc.JSValueRef{ common.liftValue(@ptrCast(ctx), value), common.liftValue(@ptrCast(ctx), constructor) };
    return jscBoolResult(ctx, jscCallIntrinsic(ctx, intrinsics.instance_of, &args));
}

fn jscParseJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, input: []const u8) Result {
    _ = allocator;
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const text = common.jsStringFromSlice(input) orelse return .out_of_memory;
    defer m.jsc.JSStringRelease(text);
    const value = m.jsc.JSValueMakeFromJSONString(ctx_ref, text);
    if (value == null) {
        const error_result = jscNewError(ctx, "invalid JSON");
        return switch (error_result) {
            .ok => |exception| .{ .exception = exception },
            .exception => |e| .{ .exception = e },
            .out_of_memory => .out_of_memory,
        };
    }
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscNewError(ctx: ActiveEngine.Context, message: []const u8) Result {
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const text = common.jsStringFromSlice(message) orelse return .out_of_memory;
    defer m.jsc.JSStringRelease(text);
    const argument = m.jsc.JSValueMakeString(ctx_ref, text);
    var exception: m.jsc.JSValueRef = null;
    const value = m.jsc.JSObjectMakeError(ctx_ref, 1, &argument, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (value == null) return .out_of_memory;
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscNewString(ctx: ActiveEngine.Context, input: []const u8) Result {
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const text = common.jsStringFromSlice(input) orelse return .out_of_memory;
    defer m.jsc.JSStringRelease(text);
    const value = m.jsc.JSValueMakeString(ctx_ref, text);
    if (value == null) return .out_of_memory;
    m.jsc.JSValueProtect(ctx_ref, value);
    return .{ .ok = value };
}

fn jscToUtf8(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    const m = @import("../backend/jsc.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    var exception: m.jsc.JSValueRef = null;
    const string = m.jsc.JSValueToStringCopy(ctx_ref, @import("../backend/jsc/common.zig").liftValue(ctx_ref, value), &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    const text = string orelse return .out_of_memory;
    defer m.jsc.JSStringRelease(text);
    return .{ .ok = @import("../backend/jsc/common.zig").jsStringToOwnedAlloc(allocator, text) orelse return .out_of_memory };
}

fn jscToJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value) BytesResult {
    const m = @import("../backend/jsc.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    var exception: m.jsc.JSValueRef = null;
    const result = m.jsc.JSValueCreateJSONString(ctx_ref, @import("../backend/jsc/common.zig").liftValue(ctx_ref, value), 0, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    const text = result orelse return .invalid_argument;
    defer m.jsc.JSStringRelease(text);
    return .{ .ok = @import("../backend/jsc/common.zig").jsStringToOwnedAlloc(allocator, text) orelse return .out_of_memory };
}

fn escargotOp(result: @import("../backend/escargot/c_api.zig").OpResult) Result {
    if (result.exception != null) return .{ .exception = result.exception };
    if (result.value != null) return .{ .ok = result.value };
    return .out_of_memory;
}

fn escargotBoolOp(result: @import("../backend/escargot/c_api.zig").BoolOpResult) BoolResult {
    if (result.exception != null) return .{ .exception = result.exception };
    return .{ .ok = result.value };
}

fn escargotConstruct(ctx: ActiveEngine.Context, function: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const c = @import("../backend/escargot/c_api.zig");
    const r = c.escargot_construct(ctx, function, if (args.len == 0) null else args.ptr, args.len);
    return escargotOp(r);
}

fn escargotHas(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    const c = @import("../backend/escargot/c_api.zig");
    return escargotBoolOp(c.escargot_has_in(ctx, object, key.ptr));
}

fn escargotDelete(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    const c = @import("../backend/escargot/c_api.zig");
    return escargotBoolOp(c.escargot_delete_property(ctx, object, key.ptr));
}

fn escargotKeys(ctx: ActiveEngine.Context, object: ActiveEngine.Value) Result {
    const c = @import("../backend/escargot/c_api.zig");
    return escargotOp(c.escargot_own_keys(ctx, object));
}

fn escargotInstanceOf(ctx: ActiveEngine.Context, value: ActiveEngine.Value, constructor: ActiveEngine.Value) BoolResult {
    const c = @import("../backend/escargot/c_api.zig");
    return escargotBoolOp(c.escargot_instance_of(ctx, value, constructor));
}

fn hermesCall(ctx: ActiveEngine.Context, function: ActiveEngine.Value, this_value: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const c = @import("../backend/hermes/c_api.zig");
    return hermesOp(c.hermes_call_result(ctx, function, this_value, if (args.len > 0) args.ptr else null, args.len));
}

fn escargotCall(ctx: ActiveEngine.Context, function: ActiveEngine.Value, this_value: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const c = @import("../backend/escargot/c_api.zig");
    return escargotOp(c.escargot_call_result(ctx, function, this_value, if (args.len > 0) args.ptr else null, args.len));
}

fn hermesNewError(ctx: ActiveEngine.Context, message: []const u8) Result {
    const c = @import("../backend/hermes/c_api.zig");
    const v = c.hermes_new_error(ctx, 0, message.ptr, message.len);
    return if (v == null) .out_of_memory else .{ .ok = v };
}

fn escargotNewError(ctx: ActiveEngine.Context, message: []const u8) Result {
    const c = @import("../backend/escargot/c_api.zig");
    const v = c.escargot_new_error(ctx, 0, message.ptr, message.len);
    return if (v == null) .out_of_memory else .{ .ok = v };
}

fn spikeToUtf8(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, comptime which: enum { escargot, hermes }, value: ActiveEngine.Value) BytesResult {
    const op = switch (which) {
        .escargot => escargotOp(@import("../backend/escargot/c_api.zig").escargot_value_to_string_result(ctx, value)),
        .hermes => hermesOp(@import("../backend/hermes/c_api.zig").hermes_value_to_string_result(ctx, value)),
    };
    switch (op) {
        .exception => |exception| return .{ .exception = exception },
        .out_of_memory => return .out_of_memory,
        .ok => |str_val| {
            defer ActiveEngine.freeValue(ctx, str_val);
            const bytes = ActiveEngine.valueToStringAlloc(allocator, ctx, str_val) orelse return .out_of_memory;
            return .{ .ok = bytes };
        },
    }
}

fn spikeToJson(allocator: std.mem.Allocator, ctx: ActiveEngine.Context, value: ActiveEngine.Value, comptime which: enum { escargot, hermes }) BytesResult {
    const op = switch (which) {
        .escargot => escargotOp(@import("../backend/escargot/c_api.zig").escargot_json_stringify_result(ctx, value)),
        .hermes => hermesOp(@import("../backend/hermes/c_api.zig").hermes_json_stringify_result(ctx, value)),
    };
    const json_val = switch (op) {
        .exception => |exception| return .{ .exception = exception },
        .out_of_memory => return .out_of_memory,
        .ok => |val| val,
    };
    defer ActiveEngine.freeValue(ctx, json_val);
    if (ActiveEngine.isUndefined(ctx, json_val)) return .invalid_argument;
    // Convert the JSON string Value to owned UTF-8 bytes.
    return toUtf8(allocator, ctx, json_val);
}

fn hermesOp(result: @import("../backend/hermes/c_api.zig").OpResult) Result {
    if (result.exception != null) return .{ .exception = result.exception };
    if (result.value != null) return .{ .ok = result.value };
    return .out_of_memory;
}
fn hermesBoolOp(result: @import("../backend/hermes/c_api.zig").BoolOpResult) BoolResult {
    if (result.exception != null) return .{ .exception = result.exception };
    return .{ .ok = result.value };
}
fn hermesConstruct(ctx: ActiveEngine.Context, function: ActiveEngine.Value, args: []const ActiveEngine.Value) Result {
    const c = @import("../backend/hermes/c_api.zig");
    return hermesOp(c.hermes_construct(ctx, function, if (args.len == 0) null else args.ptr, args.len));
}
fn hermesHas(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    const c = @import("../backend/hermes/c_api.zig");
    return hermesBoolOp(c.hermes_has_in(ctx, object, key.ptr));
}
fn hermesDelete(ctx: ActiveEngine.Context, object: ActiveEngine.Value, key: [:0]const u8) BoolResult {
    const c = @import("../backend/hermes/c_api.zig");
    return hermesBoolOp(c.hermes_delete_property(ctx, object, key.ptr));
}
fn hermesKeys(ctx: ActiveEngine.Context, object: ActiveEngine.Value) Result {
    const c = @import("../backend/hermes/c_api.zig");
    return hermesOp(c.hermes_own_keys(ctx, object));
}
fn hermesInstanceOf(ctx: ActiveEngine.Context, value: ActiveEngine.Value, constructor: ActiveEngine.Value) BoolResult {
    const c = @import("../backend/hermes/c_api.zig");
    return hermesBoolOp(c.hermes_instance_of(ctx, value, constructor));
}
