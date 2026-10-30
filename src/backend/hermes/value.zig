//! Hermes value helpers via native C bridge. Signatures match ActiveEngine / JscBackend.
const std = @import("std");
const c_api = @import("c_api.zig");
const lifecycle = @import("lifecycle.zig");

pub const Context = lifecycle.Context;
pub const Value = c_api.Value;

pub fn undefinedValue() Value {
    // Match JSC: C-null is the no-ctx undefined sentinel (safe as comptime default).
    return null;
}
pub fn nullValue() Value {
    return c_api.hermes_null();
}
pub fn dupValue(ctx: Context, v: Value) Value {
    if (v == null) return null;
    return c_api.hermes_dup(ctx, v);
}
pub fn freeValue(ctx: Context, v: Value) void {
    if (v == null) return;
    c_api.hermes_free_value(ctx, v);
}
pub fn isUndefined(_: Context, v: Value) bool {
    if (v == null) return true;
    return c_api.hermes_is_undefined(v);
}
pub fn isNull(_: Context, v: Value) bool {
    return c_api.hermes_is_null(v);
}
pub fn isBool(_: Context, v: Value) bool {
    return c_api.hermes_is_bool(v);
}
pub fn isNumber(_: Context, v: Value) bool {
    return c_api.hermes_is_number(v);
}
pub fn isString(_: Context, v: Value) bool {
    return c_api.hermes_is_string(v);
}
pub fn isSymbol(_: Context, _: Value) bool {
    return false;
}
pub fn isObjectVal(_: Context, v: Value) bool {
    return c_api.hermes_is_object(v);
}
pub fn isArray(ctx: Context, v: Value) bool {
    return c_api.hermes_is_array(ctx, v);
}
pub fn isFunction(ctx: Context, v: Value) bool {
    return c_api.hermes_is_function(ctx, v);
}
pub fn isConstructor(ctx: Context, v: Value) bool {
    return c_api.hermes_is_constructor(ctx, v);
}
pub fn sameValue(ctx: Context, a: Value, b: Value) bool {
    return c_api.hermes_strict_equal(ctx, a, b);
}
pub fn strictEqual(ctx: Context, a: Value, b: Value) bool {
    return c_api.hermes_strict_equal(ctx, a, b);
}
pub fn toBool(_: Context, v: Value) ?bool {
    if (v == null) return null;
    return c_api.hermes_to_bool(v);
}
pub fn toInt32(_: Context, v: Value) ?i32 {
    if (v == null) return null;
    return c_api.hermes_to_int32(v);
}
pub fn toFloat64(_: Context, v: Value) ?f64 {
    if (v == null) return null;
    return c_api.hermes_to_float64(v);
}
pub fn newBoolVal(ctx: Context, v: bool) Value {
    return c_api.hermes_new_bool(ctx, v);
}
pub fn newInt32Val(ctx: Context, v: i32) Value {
    return c_api.hermes_new_int32(ctx, v);
}
pub fn newFloat64Val(ctx: Context, v: f64) Value {
    return c_api.hermes_new_float64(ctx, v);
}
pub fn newStringVal(ctx: Context, s: []const u8) Value {
    return c_api.hermes_new_string(ctx, s.ptr, s.len);
}
pub fn newNullVal(_: Context) Value {
    return c_api.hermes_null();
}
pub fn newUndefinedVal(_: Context) Value {
    return c_api.hermes_undefined();
}
pub fn newObject(ctx: Context) Value {
    return c_api.hermes_new_object(ctx);
}
pub fn newArray(ctx: Context, len: u32) ?Value {
    const v = c_api.hermes_new_array(ctx, len);
    return if (v == null) null else v;
}
pub fn getGlobalObject(ctx: Context) Value {
    return c_api.hermes_get_global(ctx);
}
pub fn getPropertyVal(ctx: Context, obj: Value, key: [*:0]const u8) ?Value {
    const v = c_api.hermes_get_property(ctx, obj, key);
    if (v == null) return null;
    if (c_api.hermes_is_undefined(v)) {
        c_api.hermes_free_value(ctx, v);
        return null;
    }
    return v;
}
pub fn hasProperty(ctx: Context, obj: Value, key: [*:0]const u8) bool {
    return c_api.hermes_has_property(ctx, obj, key);
}
pub fn setPropertyStr(ctx: Context, obj: Value, key: [*:0]const u8, val: Value) void {
    _ = c_api.hermes_set_property(ctx, obj, key, val);
    // Ownership: consume val like JSC/QJS contract
    c_api.hermes_free_value(ctx, val);
}
pub fn getIndex(ctx: Context, obj: Value, index: u32) ?Value {
    const v = c_api.hermes_get_index(ctx, obj, index);
    if (v == null) return null;
    if (c_api.hermes_is_undefined(v)) {
        c_api.hermes_free_value(ctx, v);
        return null;
    }
    return v;
}
/// Like getIndex but preserves JS undefined for array holes (caller owns the value).
pub fn getIndexKeepUndefined(ctx: Context, obj: Value, index: u32) ?Value {
    const v = c_api.hermes_get_index(ctx, obj, index);
    if (v == null) return null;
    return v;
}
pub fn setIndex(ctx: Context, obj: Value, index: u32, val: Value) bool {
    return c_api.hermes_set_index(ctx, obj, index, val);
}
pub fn setLength(ctx: Context, obj: Value, length: u32) bool {
    return c_api.hermes_set_length(ctx, obj, length);
}
pub fn defineDataProperty(ctx: Context, obj: Value, key: [*:0]const u8, val: Value, writable: bool) bool {
    return c_api.hermes_define_data_property(ctx, obj, key, val, writable);
}
pub fn newSymbol(ctx: Context, desc: []const u8) ?Value {
    const v = c_api.hermes_new_symbol(ctx, if (desc.len > 0) desc.ptr else null, desc.len);
    return if (v == null) null else v;
}
pub fn symbolFor(ctx: Context, key: []const u8) ?Value {
    const v = c_api.hermes_symbol_for(ctx, if (key.len > 0) key.ptr else null, key.len);
    return if (v == null) null else v;
}
pub fn getLength(ctx: Context, obj: Value) ?u32 {
    if (obj == null) return null;
    if (c_api.hermes_is_null(obj) or c_api.hermes_is_undefined(obj)) return null;
    // Non-objects (except strings, which have .length) have no length — match JSC/QJS "no length" null.
    if (!c_api.hermes_is_object(obj) and !c_api.hermes_is_string(obj)) return null;
    return c_api.hermes_get_length(ctx, obj);
}
pub fn callFunction(ctx: Context, fn_val: Value, this_val: Value, args: []const Value) ?Value {
    var err: ?[*:0]u8 = null;
    const v = c_api.hermes_call(ctx, fn_val, this_val, if (args.len > 0) args.ptr else null, args.len, &err);
    if (err) |e| {
        _ = std.c.free(e);
        return null;
    }
    return v;
}
/// Call with no args; returns owned error text if the call threw, else null.
pub fn callFunctionNoArgs(ctx: Context, fn_val: Value) ?[]const u8 {
    var err: ?[*:0]u8 = null;
    const this_val = c_api.hermes_get_global(ctx);
    defer c_api.hermes_free_value(ctx, this_val);
    _ = c_api.hermes_call(ctx, fn_val, this_val, null, 0, &err);
    if (err) |e| {
        const s = std.mem.span(e);
        const owned = std.heap.c_allocator.dupe(u8, s) catch {
            _ = std.c.free(e);
            return "JavaScript error";
        };
        _ = std.c.free(e);
        return owned;
    }
    return null;
}
pub fn jsonParseVal(ctx: Context, input: []const u8) ?Value {
    const v = c_api.hermes_json_parse(ctx, input.ptr, input.len);
    return if (v == null) null else v;
}
pub fn jsonStringifyVal(ctx: Context, v: Value) ?[]u8 {
    const p = c_api.hermes_json_stringify(ctx, v) orelse return null;
    const s = std.mem.span(p);
    const owned = std.heap.c_allocator.dupe(u8, s) catch {
        _ = std.c.free(p);
        return null;
    };
    _ = std.c.free(p);
    return owned;
}
pub fn valueToStringAlloc(allocator: std.mem.Allocator, ctx: Context, v: Value) ?[]u8 {
    var len: usize = 0;
    const p = c_api.hermes_value_to_utf8_n(ctx, v, &len) orelse return null;
    const owned = allocator.dupe(u8, p[0..len]) catch {
        _ = std.c.free(p);
        return null;
    };
    _ = std.c.free(p);
    return owned;
}
pub fn valueToStringVal(ctx: Context, v: Value) ?[]const u8 {
    return valueToStringAlloc(std.heap.c_allocator, ctx, v);
}
pub fn isArrayBufferVal(ctx: Context, v: Value) bool {
    return c_api.hermes_is_array_buffer(ctx, v);
}
pub fn isTypedArrayVal(ctx: Context, v: Value) bool {
    return c_api.hermes_is_typed_array(ctx, v);
}
pub fn getArrayBufferSliceVal(ctx: Context, v: Value) ?[]u8 {
    var len: usize = 0;
    const ptr = c_api.hermes_array_buffer_data(ctx, v, &len) orelse return null;
    return ptr[0..len];
}
pub fn getTypedArrayBytesVal(ctx: Context, v: Value) ?struct { bytes: []u8, byte_offset: usize, byte_length: usize, kind: c_int } {
    var off: usize = 0;
    var len: usize = 0;
    var kind: c_int = -1;
    const ptr = c_api.hermes_typed_array_data(ctx, v, &off, &len, &kind) orelse return null;
    return .{ .bytes = ptr[0..len], .byte_offset = off, .byte_length = len, .kind = kind };
}
pub fn newArrayBufferCopyVal(ctx: Context, bytes: []const u8) Value {
    return c_api.hermes_new_array_buffer_copy(ctx, bytes.ptr, bytes.len);
}
pub fn newArrayBufferNoCopyVal(ctx: Context, bytes: []u8, finalizer: ?*const fn (?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) Value {
    return c_api.hermes_new_array_buffer_no_copy(ctx, bytes.ptr, bytes.len, finalizer, user_data);
}
pub fn newTypedArrayFromBufferVal(ctx: Context, ab: Value, kind: c_int, byte_offset: usize, length: usize) Value {
    return c_api.hermes_new_typed_array(ctx, ab, kind, byte_offset, length);
}

pub fn evalValue(ctx: Context, source: []const u8, filename: []const u8) struct { value: Value, exception: Value, err_text: ?[]u8 } {
    const r = c_api.hermes_eval_value(ctx, source.ptr, source.len, filename.ptr, filename.len);
    var err_text: ?[]u8 = null;
    if (r.err) |e| {
        const s = std.mem.span(e);
        err_text = std.heap.c_allocator.dupe(u8, s) catch null;
        c_api.hermes_value_result_free_err(r);
    }
    // On throw, bridge retains exception in value and sets err.
    if (err_text != null) {
        return .{ .value = null, .exception = r.value, .err_text = err_text };
    }
    return .{ .value = r.value, .exception = null, .err_text = null };
}

pub fn makeFunction(ctx: Context, name: []const u8, fn_ptr: c_api.NativeFn, user_data: ?*anyopaque) Value {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    return c_api.hermes_make_function(ctx, @ptrCast(&buf), fn_ptr, user_data);
}
