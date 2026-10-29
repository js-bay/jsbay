//! engine/native_handle/handle.zig — NativeHandle creation and per-instance state accessors.
//!
//! `create*` allocate HandleData in QuickJS-managed memory and stamp it onto the object via JS_SetOpaque. The class finalizer (see class.zig) frees the payload when the JS object is collected.

const types = @import("types.zig");
const c_api = @import("../../backend.zig").ActiveEngineModule.c_api;
const class = @import("class.zig");
const method = @import("method.zig");

const c = types.c;

/// Create a new NativeHandle JS object.
///
/// The returned `c.JSValue` is callable from JS if `config.call_fn` is set. The caller owns the returned value (must eventually be freed or returned to JS which will GC it).
pub fn create(ctx: ?*c.JSContext, config: types.HandleData) c.JSValue {
    const obj = c.JS_NewObjectClass(ctx, @intCast(class.classIdRaw()));
    if (c_api.jsIsException(obj)) return obj;

    // Allocate HandleData in QuickJS-managed memory so it is freed together with the runtime.
    const raw: ?*anyopaque = c.js_mallocz(ctx, @sizeOf(types.HandleData));
    if (raw) |p| {
        const data: *types.HandleData = @ptrCast(@alignCast(p));
        data.* = config;
        _ = c.JS_SetOpaque(obj, p);
    } else {
        c.JS_FreeValue(ctx, obj);
        return c.JS_ThrowOutOfMemory(ctx);
    }

    return obj;
}

/// Create a NativeHandle object with an explicit JavaScript prototype.
pub fn createWithProto(ctx: ?*c.JSContext, proto: c.JSValue, config: types.HandleData) c.JSValue {
    const obj = c.JS_NewObjectProtoClass(ctx, proto, @intCast(class.classIdRaw()));
    if (c_api.jsIsException(obj)) return obj;

    const raw: ?*anyopaque = c.js_mallocz(ctx, @sizeOf(types.HandleData));
    if (raw) |p| {
        const data: *types.HandleData = @ptrCast(@alignCast(p));
        data.* = config;
        _ = c.JS_SetOpaque(obj, p);
    } else {
        c.JS_FreeValue(ctx, obj);
        return c.JS_ThrowOutOfMemory(ctx);
    }

    return obj;
}

/// Convenience: create a handle and attach methods in one call.
pub fn createWithMethods(
    ctx: ?*c.JSContext,
    config: types.HandleData,
    methods: anytype,
) c.JSValue {
    const obj = create(ctx, config);
    if (c_api.jsIsException(obj)) return obj;

    for (methods) |m| {
        method.setMethod(ctx, obj, m.name, m.func, m.argc);
    }

    return obj;
}

/// Set a string property on a NativeHandle instance.
pub fn setStringProp(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [*:0]const u8,
    value: []const u8,
) void {
    const js_str = c.JS_NewStringLen(ctx, value.ptr, value.len);
    _ = c.JS_SetPropertyStr(ctx, obj, name, js_str);
}

/// Set an integer property on a NativeHandle instance.
pub fn setIntProp(
    ctx: ?*c.JSContext,
    obj: c.JSValue,
    name: [*:0]const u8,
    value: i64,
) void {
    _ = c.JS_SetPropertyStr(ctx, obj, name, c.JS_NewInt64(ctx, value));
}

/// Retrieve the `HandleData` from a NativeHandle JS value.
///
/// Returns `null` if `val` is not a NativeHandle or has no data. Use this in method implementations to access native state.
pub fn getOpaque(ctx: ?*c.JSContext, val: c.JSValue) ?*types.HandleData {
    const p = c.JS_GetOpaque2(ctx, val, class.classIdRaw()) orelse return null;
    return @ptrCast(@alignCast(p));
}
