//! Backend-typed facade for shared errors support.

const c = @import("c_api.zig");

fn nativeIsError(ctx: ?*c.qjs.JSContext, val: c.qjs.JSValue) bool {
    return c.qjs.JS_IsError(ctx, val) != 0;
}

const shared = @import("../quickjs_common/errors.zig").create(c, nativeIsError);

pub const QjsErrorKind = shared.QjsErrorKind;
pub const qjsNewTypedError = shared.qjsNewTypedError;
pub const qjsIsError = shared.qjsIsError;
pub const qjsThrowValue = shared.qjsThrowValue;
