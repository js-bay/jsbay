//! Date / BigInt support (see ../value.zig).
//!
//! QuickJS has direct C-API entries for both, so these are thin shims around `JS_NewDate` / `JS_IsDate` / `JS_NewBigInt64` / `JS_ToBigInt64`. The Date reverse-conversion routes through `val.getTime()` because QuickJS exposes no native millisecond getter on the C side.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

// ---- Date ----

pub fn qjsIsDate(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    return c.JS_IsDate(ctx, val);
}

pub fn qjsToDateMs(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?i64 {
    if (!c.JS_IsDate(ctx, val)) return null;
    // Call val.getTime() which returns an integer millisecond value.
    const atom = qjs.JS_NewAtom(ctx, "getTime");
    defer qjs.JS_FreeAtom(ctx, atom);
    const r = qjs.JS_Invoke(ctx, val, atom, 0, null);
    if (r.tag == qjs.JS_TAG_EXCEPTION) {
        c.jsbay_qjs_JS_FreeValue(ctx, r);
        return null;
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, r);
    var d: f64 = 0;
    if (qjs.JS_ToFloat64(ctx, &d, r) != 0) return null;
    if (!std.math.isFinite(d)) return null;
    return @intFromFloat(d);
}

pub fn qjsNewDate(ctx: ?*qjs.JSContext, ms: i64) qjs.JSValue {
    return c.JS_NewDate(ctx, @floatFromInt(ms));
}

// ---- BigInt ----

pub fn qjsIsBigInt(_: ?*qjs.JSContext, val: qjs.JSValue) bool {
    // Inline equivalent of static-inline JS_IsBigInt in quickjs.h.
    return val.tag == qjs.JS_TAG_BIG_INT or val.tag == qjs.JS_TAG_SHORT_BIG_INT;
}

pub fn qjsToBigIntI64(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?i64 {
    var out: i64 = 0;
    if (c.JS_ToBigInt64(ctx, &out, val) != 0) return null;
    return out;
}

pub fn qjsToBigIntU64(ctx: ?*qjs.JSContext, val: qjs.JSValue) ?u64 {
    var out: u64 = 0;
    if (c.JS_ToBigUint64(ctx, &out, val) != 0) return null;
    return out;
}

pub fn qjsNewBigIntI64(ctx: ?*qjs.JSContext, v: i64) qjs.JSValue {
    return c.JS_NewBigInt64(ctx, v);
}

pub fn qjsNewBigIntU64(ctx: ?*qjs.JSContext, v: u64) qjs.JSValue {
    return c.JS_NewBigUint64(ctx, v);
}
