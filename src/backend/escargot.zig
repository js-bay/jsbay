//! Escargot backend — EscargotPublic C bridge (native, not a JSC shim).
const std = @import("std");
const lifecycle = @import("escargot/lifecycle.zig");
const value_mod = @import("escargot/value.zig");
const c_api = @import("escargot/c_api.zig");
const console_mod = @import("escargot/console.zig");
const timers_mod = @import("escargot/timers.zig");

pub const c_api_mod = c_api;

pub const EscargotBackend = struct {
    pub const Runtime = lifecycle.Runtime;
    pub const Context = lifecycle.Context;
    pub const Value = value_mod.Value;

    pub const newRuntime = lifecycle.newRuntime;
    pub const setMaxStackSize = lifecycle.setMaxStackSize;
    pub const newContext = lifecycle.newContext;
    pub const freeContext = lifecycle.freeContext;
    pub const freeRuntime = lifecycle.freeRuntime;
    pub const runGc = lifecycle.runGc;
    pub const eval = lifecycle.eval;
    pub const processPendingJobs = lifecycle.processPendingJobs;
    pub const threadEnter = lifecycle.threadEnter;
    pub const threadLeave = lifecycle.threadLeave;

    pub fn setContextOpaque(ctx: Context, ptr: ?*anyopaque) void {
        c_api.escargot_context_set_opaque(ctx, ptr);
    }
    pub fn getContextOpaque(ctx: Context) ?*anyopaque {
        return c_api.escargot_context_get_opaque(ctx);
    }
    pub fn instanceIdFromCtx(ctx: Context) i32 {
        const p = getContextOpaque(ctx) orelse return 0;
        return @bitCast(@as(u32, @truncate(@intFromPtr(p))));
    }

    pub const registerConsole = console_mod.registerConsole;
    pub const registerTimers = timers_mod.registerTimers;

    pub const undefinedValue = value_mod.undefinedValue;
    pub const nullValue = value_mod.nullValue;
    pub const dupValue = value_mod.dupValue;
    pub const freeValue = value_mod.freeValue;
    pub const isFunction = value_mod.isFunction;
    pub const isConstructor = value_mod.isConstructor;
    pub const callFunctionNoArgs = value_mod.callFunctionNoArgs;
    pub const getGlobalObject = value_mod.getGlobalObject;
    pub const newObject = value_mod.newObject;
    pub fn setProperty(ctx: Context, obj: Value, key: []const u8, val: Value) bool {
        // C bridge keys are NUL-terminated; reject embedded NUL rather than silently truncate.
        if (std.mem.indexOfScalar(u8, key, 0) != null) return false;
        var buf: [512]u8 = undefined;
        if (key.len >= buf.len) return false;
        @memcpy(buf[0..key.len], key);
        buf[key.len] = 0;
        return c_api.escargot_set_property(ctx, obj, @ptrCast(&buf), val);
    }
    pub const setPropertyStr = value_mod.setPropertyStr;
    pub fn makeFunction(ctx: Context, name: anytype, callback: anytype) Value {
        // JSC-shaped API used by registry: name is []const u8 or [*:0]const u8; callback is *const fn...
        // Escargot registry uses escargot_make_function directly via EscargotWrapper.
        _ = ctx;
        _ = name;
        _ = callback;
        return null;
    }
    pub const makeNativeFunction = value_mod.makeFunction;
    pub const evalValue = value_mod.evalValue;
    pub fn makeStringValue(ctx: Context, s: []const u8) Value {
        return value_mod.newStringVal(ctx, s);
    }
    pub fn throwError(ctx: Context, message: []const u8) Value {
        // Sets pending_throw for the native trampoline (see escargot_throw).
        var buf: [1024]u8 = undefined;
        if (message.len >= buf.len) return null;
        @memcpy(buf[0..message.len], message);
        buf[message.len] = 0;
        c_api.escargot_throw(ctx, @ptrCast(&buf));
        return null;
    }
    pub fn jsStringFromSlice(_: []const u8) ?*anyopaque {
        return null;
    }
    pub fn jsStringToOwned(_: ?*anyopaque) ?[]u8 {
        return null;
    }
    pub fn valueToString(ctx: Context, v: Value) ?[]u8 {
        return value_mod.valueToStringAlloc(std.heap.c_allocator, ctx, v);
    }
    pub fn jsonStringify(ctx: Context, v: Value) ?[]u8 {
        return value_mod.jsonStringifyVal(ctx, v);
    }
    pub fn jsonParse(ctx: Context, s: []const u8) ?Value {
        return value_mod.jsonParseVal(ctx, s);
    }
    pub fn formatException(ctx: Context, v: Value) ?[]u8 {
        return value_mod.valueToStringAlloc(std.heap.c_allocator, ctx, v);
    }

    pub const isUndefined = value_mod.isUndefined;
    pub const isNull = value_mod.isNull;
    pub const isBool = value_mod.isBool;
    pub const isNumber = value_mod.isNumber;
    pub const isString = value_mod.isString;
    pub const isSymbol = value_mod.isSymbol;
    pub const isObjectVal = value_mod.isObjectVal;
    pub const isArray = value_mod.isArray;
    pub const sameValue = value_mod.sameValue;
    pub const strictEqual = value_mod.strictEqual;
    pub const toBool = value_mod.toBool;
    pub const toInt32 = value_mod.toInt32;
    pub const toFloat64 = value_mod.toFloat64;
    pub const newBoolVal = value_mod.newBoolVal;
    pub const newInt32Val = value_mod.newInt32Val;
    pub const newFloat64Val = value_mod.newFloat64Val;
    pub const newStringVal = value_mod.newStringVal;
    pub const newNullVal = value_mod.newNullVal;
    pub const newUndefinedVal = value_mod.newUndefinedVal;
    pub const newArray = value_mod.newArray;
    pub const getPropertyVal = value_mod.getPropertyVal;
    pub const hasProperty = value_mod.hasProperty;
    pub const getIndex = value_mod.getIndex;
    pub const getIndexKeepUndefined = value_mod.getIndexKeepUndefined;
    pub const setIndex = value_mod.setIndex;
    pub const setLength = value_mod.setLength;
    pub const defineDataProperty = value_mod.defineDataProperty;
    pub const newSymbol = value_mod.newSymbol;
    pub const symbolFor = value_mod.symbolFor;
    pub const getLength = value_mod.getLength;
    pub const callFunction = value_mod.callFunction;
    pub const jsonParseVal = value_mod.jsonParseVal;
    pub const jsonStringifyVal = value_mod.jsonStringifyVal;
    pub const valueToStringAlloc = value_mod.valueToStringAlloc;
    pub const valueToStringVal = value_mod.valueToStringVal;
    pub const isArrayBufferVal = value_mod.isArrayBufferVal;
    pub const isTypedArrayVal = value_mod.isTypedArrayVal;
    pub const getArrayBufferSliceVal = value_mod.getArrayBufferSliceVal;
    pub const getTypedArrayBytesVal = value_mod.getTypedArrayBytesVal;
    pub const newArrayBufferCopyVal = value_mod.newArrayBufferCopyVal;
    pub const newArrayBufferNoCopyVal = value_mod.newArrayBufferNoCopyVal;
    pub const newTypedArrayFromBufferVal = value_mod.newTypedArrayFromBufferVal;

    pub fn isDate(ctx: Context, v: Value) bool {
        return c_api.escargot_is_date(ctx, v);
    }
    pub fn toDateMs(ctx: Context, v: Value) ?i64 {
        if (!isDate(ctx, v)) return null;
        return c_api.escargot_date_to_ms(ctx, v);
    }
    pub fn newDate(ctx: Context, ms: i64) Value {
        return c_api.escargot_new_date(ctx, ms);
    }
    pub fn isBigInt(_: Context, v: Value) bool {
        return c_api.escargot_is_bigint(v);
    }
    pub fn toBigIntI64(_: Context, v: Value) ?i64 {
        var out: i64 = 0;
        if (!c_api.escargot_bigint_to_i64(v, &out)) return null;
        return out;
    }
    pub fn toBigIntU64(_: Context, v: Value) ?u64 {
        var out: u64 = 0;
        if (!c_api.escargot_bigint_to_u64(v, &out)) return null;
        return out;
    }
    pub fn newBigIntI64(_: Context, v: i64) Value {
        return c_api.escargot_new_bigint_i64(v);
    }
    pub fn newBigIntU64(_: Context, v: u64) Value {
        return c_api.escargot_new_bigint_u64(v);
    }
    pub fn isMap(_: Context, v: Value) bool {
        return c_api.escargot_is_map(v);
    }
    pub fn isSet(_: Context, v: Value) bool {
        return c_api.escargot_is_set(v);
    }
    pub fn mapSetToJson(ctx: Context, v: Value) ?[]const u8 {
        const p = blk: {
            if (isSet(ctx, v)) break :blk c_api.escargot_set_to_json(ctx, v);
            if (isMap(ctx, v)) break :blk c_api.escargot_map_to_json(ctx, v);
            break :blk null;
        } orelse return null;
        const s = std.mem.span(p);
        const owned = std.heap.c_allocator.dupe(u8, s) catch {
            _ = std.c.free(p);
            return null;
        };
        _ = std.c.free(p);
        return owned;
    }
    pub fn newMapFromJson(ctx: Context, json: []const u8) Value {
        return c_api.escargot_new_map_from_json(ctx, json.ptr, json.len);
    }
    pub fn newSetFromJson(ctx: Context, json: []const u8) Value {
        return c_api.escargot_new_set_from_json(ctx, json.ptr, json.len);
    }
    pub fn mapSize(ctx: Context, v: Value) ?usize {
        if (!isMap(ctx, v)) return null;
        return c_api.escargot_map_size(ctx, v);
    }
    pub fn setSize(ctx: Context, v: Value) ?usize {
        if (!isSet(ctx, v)) return null;
        return c_api.escargot_set_size(ctx, v);
    }
    pub fn newMap(ctx: Context) Value {
        return c_api.escargot_new_map(ctx);
    }
    pub fn newSet(ctx: Context) Value {
        return c_api.escargot_new_set(ctx);
    }
    pub fn mapSet(ctx: Context, map: Value, key: Value, value: Value) bool {
        return c_api.escargot_map_set(ctx, map, key, value);
    }
    pub fn setAdd(ctx: Context, set: Value, value: Value) bool {
        return c_api.escargot_set_add(ctx, set, value);
    }
    pub fn isDataView(_: Context, v: Value) bool {
        return c_api.escargot_is_data_view(v);
    }
    pub fn dataViewInfo(ctx: Context, v: Value) ?struct { bytes: []u8, byte_offset: usize, byte_length: usize } {
        var off: usize = 0;
        var len: usize = 0;
        const ptr = c_api.escargot_data_view_data(ctx, v, &off, &len) orelse return null;
        // Escargot ArrayBufferViewRef::rawBuffer() is already advanced by byteOffset
        // (NAPI parity). NativeArgs.getDataView re-applies byte_offset onto buffer.bytes,
        // so report a view-relative window with offset 0 (off captured only for the C ABI).
        return .{ .bytes = ptr[0..len], .byte_offset = 0, .byte_length = len };
    }
    pub fn newDataViewFromBuffer(ctx: Context, ab: Value, byte_offset: usize, byte_length: usize) Value {
        return c_api.escargot_new_data_view(ctx, ab, byte_offset, byte_length);
    }
    pub const MapForEachFn = fn (
        ctx: Context,
        cb_ctx: ?*anyopaque,
        key: Value,
        value: Value,
    ) callconv(.c) bool;

    pub const SetForEachFn = fn (
        ctx: Context,
        cb_ctx: ?*anyopaque,
        value: Value,
    ) callconv(.c) bool;

    pub fn mapForEach(ctx: Context, map: Value, cb_ctx: ?*anyopaque, cb: *const MapForEachFn) bool {
        return c_api.escargot_map_foreach(ctx, map, cb_ctx, @ptrCast(cb));
    }
    pub fn setForEach(ctx: Context, set: Value, cb_ctx: ?*anyopaque, cb: *const SetForEachFn) bool {
        return c_api.escargot_set_foreach(ctx, set, cb_ctx, @ptrCast(cb));
    }
};

const module_mod = @import("escargot/module.zig");
pub const installModuleLoader = module_mod.installModuleLoader;
pub const uninstallModuleLoader = module_mod.uninstallModuleLoader;
pub const escargotEvalModule = module_mod.escargotEvalModule;
pub const escargotImportModule = module_mod.escargotImportModule;
