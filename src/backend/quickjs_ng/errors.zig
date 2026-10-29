//! Structured error API helpers (see ../errors.zig).
//!
//! These thin wrappers around QuickJS's JS_New*Error / JS_IsError APIs let the backend-neutral `errors.zig` module build and introspect typed Error instances without exposing cImport internals to its callers.

const c = @import("c_api.zig");
const qjs = c.qjs;

/// Tags enumerated by errors.JsErrorKind. Mirrors QuickJS's built-in error constructors (plus a "generic Error" + "AggregateError" slot — QJS has no dedicated helpers for those, so we fall back to JS_NewError / global constructor lookup).
pub const QjsErrorKind = enum(u8) {
    generic,
    type_error,
    range_error,
    reference_error,
    syntax_error,
    uri_error,
    eval_error,
    internal_error,
    aggregate_error,
};

/// Frames inside `qjsNewTypedError` on this thread. Past one frame we build a native Error and do not call the global constructor again.
threadlocal var qjs_error_depth: u8 = 0;

/// Plain Error via `JS_NewError`, which does not invoke global `Error`. Used when the global constructor is missing, threw, or we are already inside error construction.
fn newMessage(ctx: ?*qjs.JSContext, message: []const u8) qjs.JSValue {
    return qjs.JS_NewStringLen(ctx, message.ptr, message.len);
}

fn qjsNativePlainError(ctx: ?*qjs.JSContext, message: []const u8) qjs.JSValue {
    const err = qjs.JS_NewError(ctx);
    if (c.jsIsException(err)) return err;
    const msg_val = newMessage(ctx, message);
    if (c.jsIsException(msg_val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, err);
        return msg_val;
    }
    // JS_DefinePropertyValueStr takes ownership of msg_val.
    _ = qjs.JS_DefinePropertyValueStr(
        ctx,
        err,
        "message",
        msg_val,
        qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE,
    );
    return err;
}

fn drainQjsException(ctx: ?*qjs.JSContext) void {
    const pending = qjs.JS_GetException(ctx);
    if (!c.jsIsNull(pending)) c.jsbay_qjs_JS_FreeValue(ctx, pending);
}

/// `new ctor(message)`. On throw or a missing ctor, return a native Error and leave no pending exception. Does not call `qjsNewTypedError`.
fn qjsErrorViaGlobalOrNative(
    ctx: ?*qjs.JSContext,
    ctor_name: [*:0]const u8,
    message: []const u8,
) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, ctor_name);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor) or c.jsbay_qjs_JS_IsFunction(ctx, ctor) == 0) {
        if (!c.jsIsUndefined(ctor)) c.jsbay_qjs_JS_FreeValue(ctx, ctor);
        if (c.jsIsException(ctor)) drainQjsException(ctx);
        return qjsNativePlainError(ctx, message);
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);

    const msg_val = newMessage(ctx, message);
    if (c.jsIsException(msg_val)) return msg_val;
    var argv = [_]qjs.JSValue{msg_val};
    const result = qjs.JS_CallConstructor(ctx, ctor, 1, &argv);
    c.jsbay_qjs_JS_FreeValue(ctx, msg_val);
    if (c.jsIsException(result)) {
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        drainQjsException(ctx);
        return qjsNativePlainError(ctx, message);
    }
    return result;
}

/// Create a new Error instance of the requested kind with `message` as the `.message` property. Returns `JS_EXCEPTION` on allocation failure; callers MUST check with `jsIsException` before using the result.
///
/// The returned value is owned by the caller — free via `jsbay_qjs_JS_FreeValue`, or hand off to JS (e.g. `JS_SetPropertyStr`, `JS_Throw`), which transfers ownership.
pub fn qjsNewTypedError(
    ctx: ?*qjs.JSContext,
    kind: QjsErrorKind,
    message: []const u8,
) qjs.JSValue {
    // Already building an Error. Do not call a user constructor again.
    if (qjs_error_depth >= 1) return qjsNativePlainError(ctx, message);
    qjs_error_depth += 1;
    defer qjs_error_depth -= 1;

    return switch (kind) {
        // Global Error constructor. A throwing replacement is caught once; the native fallback does not call Error again.
        .generic => qjsErrorViaGlobalOrNative(ctx, "Error", message),
        .type_error, .range_error, .reference_error, .syntax_error, .internal_error => qjsNativeFormattedError(ctx, kind, message),
        // QuickJS has no dedicated JS_NewEvalError / JS_NewURIError / JS_NewAggregateError — pull the constructor off globalThis and invoke it with the message. Falls back to a plain Error if the global is missing (hardened runtimes).
        .uri_error => qjsNewErrorViaGlobal(ctx, "URIError", message),
        .eval_error => qjsNewErrorViaGlobal(ctx, "EvalError", message),
        .aggregate_error => qjsNewAggregateError(ctx, message),
    };
}

fn qjsNativeFormattedError(ctx: ?*qjs.JSContext, kind: QjsErrorKind, message: []const u8) qjs.JSValue {
    // The printf constructors stop at the first 0. Build the typed error with an empty message, then store the original bytes with a length.
    const err = switch (kind) {
        .type_error => qjs.JS_NewTypeError(ctx, "%s", ""),
        .range_error => qjs.JS_NewRangeError(ctx, "%s", ""),
        .reference_error => qjs.JS_NewReferenceError(ctx, "%s", ""),
        .syntax_error => qjs.JS_NewSyntaxError(ctx, "%s", ""),
        .internal_error => qjs.JS_NewInternalError(ctx, "%s", ""),
        else => return qjsNativePlainError(ctx, message),
    };
    if (c.jsIsException(err)) return err;
    const msg_val = newMessage(ctx, message);
    if (c.jsIsException(msg_val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, err);
        return msg_val;
    }
    _ = qjs.JS_DefinePropertyValueStr(
        ctx,
        err,
        "message",
        msg_val,
        qjs.JS_PROP_WRITABLE | qjs.JS_PROP_CONFIGURABLE,
    );
    return err;
}

fn qjsNewErrorViaGlobal(
    ctx: ?*qjs.JSContext,
    ctor_name: [*:0]const u8,
    message: []const u8,
) qjs.JSValue {
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, ctor_name);
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) {
        c.jsbay_qjs_JS_FreeValue(ctx, ctor);
        // Fallback: plain Error with the message attached. Native, so a broken global constructor cannot re-enter this function.
        return qjsNativePlainError(ctx, message);
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);

    const msg_val = newMessage(ctx, message);
    if (c.jsIsException(msg_val)) return msg_val;
    var argv = [_]qjs.JSValue{msg_val};
    // JS_CallConstructor dups its arguments internally — free the local msg_val after the call regardless of outcome.
    const result = qjs.JS_CallConstructor(ctx, ctor, 1, &argv);
    c.jsbay_qjs_JS_FreeValue(ctx, msg_val);
    return result;
}

fn qjsNewAggregateError(ctx: ?*qjs.JSContext, message: []const u8) qjs.JSValue {
    // AggregateError(errors, message) requires an iterable `errors` arg.
    const global = qjs.JS_GetGlobalObject(ctx);
    defer c.jsbay_qjs_JS_FreeValue(ctx, global);
    const ctor = qjs.JS_GetPropertyStr(ctx, global, "AggregateError");
    if (c.jsIsException(ctor) or c.jsIsUndefined(ctor)) {
        c.jsbay_qjs_JS_FreeValue(ctx, ctor);
        return qjsNativePlainError(ctx, message);
    }
    defer c.jsbay_qjs_JS_FreeValue(ctx, ctor);

    const errors_arr = qjs.JS_NewArray(ctx);
    if (c.jsIsException(errors_arr)) return errors_arr;
    const msg_val = newMessage(ctx, message);
    if (c.jsIsException(msg_val)) {
        c.jsbay_qjs_JS_FreeValue(ctx, errors_arr);
        return msg_val;
    }
    var argv = [_]qjs.JSValue{ errors_arr, msg_val };
    const result = qjs.JS_CallConstructor(ctx, ctor, 2, &argv);
    c.jsbay_qjs_JS_FreeValue(ctx, errors_arr);
    c.jsbay_qjs_JS_FreeValue(ctx, msg_val);
    return result;
}

/// True iff `val` is a JS Error instance (by JS_IsError — matches `val instanceof Error` for values produced by QuickJS's own error path).
pub fn qjsIsError(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    _ = ctx;
    return qjs.JS_IsError(val);
}

/// Throw `val` as the current pending exception. Takes ownership of `val` (JS_Throw consumes its reference count). Returns true on success.
pub fn qjsThrowValue(ctx: ?*qjs.JSContext, val: qjs.JSValue) bool {
    if (c.jsIsException(val)) return false;
    _ = qjs.JS_Throw(ctx, val);
    return true;
}
