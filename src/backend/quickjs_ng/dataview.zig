//! DataView support (see ../value.zig).
//!
//! DataView identity and window metadata come from the patched native C API.

const c = @import("c_api.zig");
const qjs = c.qjs;

pub const QjsDataViewInfo = struct {
    bytes: []u8,
    byte_offset: usize,
    byte_length: usize,
};

fn qjsDataViewCtor(ctx: ?*qjs.JSContext) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    return qjs.JS_GetPropertyStr(ctx, global, "DataView");
}

/// True when `val` has QuickJS-NG's native DataView class.
pub fn qjsIsDataView(_: ?*qjs.JSContext, val: qjs.JSValue) bool {
    return c.JS_IsDataView(val);
}

/// Extract native DataView metadata. The returned slice covers the full backing ArrayBuffer.
pub fn qjsDataViewInfo(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?QjsDataViewInfo {
    var off: usize = 0;
    var len: usize = 0;
    const buffer = c.JS_GetDataViewBuffer(ctx, val, &off, &len);
    defer c.jsbay_qjs_JS_FreeValue(ctx, buffer);
    if (c.jsIsUndefined(buffer)) return null;

    var size: usize = 0;
    const base = c.JS_GetArrayBuffer(ctx, &size, buffer);
    if (base == null) return null;
    if (off > size or len > size - off) return null;

    return .{ .bytes = base[0..size], .byte_offset = off, .byte_length = len };
}

/// Construct `new DataView(ab, byte_offset, byte_length)`. Returns JS_EXCEPTION on failure (e.g. the buffer is smaller than requested).
pub fn qjsNewDataView(
    ctx: ?*qjs.JSContext,
    ab: qjs.JSValue,
    byte_offset: usize,
    byte_length: usize,
) qjs.JSValue {
    const ctor = qjsDataViewCtor(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) return c.JS_EXCEPTION;
    var argv = [_]qjs.JSValue{
        ab,
        c.jsbay_qjs_JS_NewFloat64(ctx, @floatFromInt(byte_offset)),
        c.jsbay_qjs_JS_NewFloat64(ctx, @floatFromInt(byte_length)),
    };
    return qjs.JS_CallConstructor(ctx, ctor, 3, &argv);
}
