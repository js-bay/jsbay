//! Backend-typed facade for shared errors support.

const c = @import("c_api.zig");

fn nativeIsError(ctx: ?*c.qjs.JSContext, val: c.qjs.JSValue) bool {
    _ = ctx;
    return c.qjs.JS_IsError(val);
}

const shared = @import("../quickjs_common/errors.zig").create(c, nativeIsError);

pub const QjsErrorKind = shared.QjsErrorKind;
pub const qjsNewTypedError = shared.qjsNewTypedError;
pub const qjsIsError = shared.qjsIsError;
pub const qjsThrowValue = shared.qjsThrowValue;
