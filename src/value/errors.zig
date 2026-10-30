//! Structured JS error construction and introspection.
//!
//! JS has a small family of built-in Error subclasses (TypeError, RangeError, SyntaxError, ...). The raw backend APIs expose these as loose global constructors or ad-hoc C helpers; this module normalises them behind a single enum-tagged surface so consumers can:
//!
//!   - Create a typed Error from Zig code (`newError`)
//! - Throw a typed Error into the current context (`throwError`, for use inside native function callbacks)
//!   - Classify + decode an arbitrary JS value back into Zig (`inspectError`)
//!
//! Design notes
//! ============
//!
//! * `JsErrorKind` is the single source of truth for "which flavour of Error." Both backends translate this to their native error constructor in `src/backend/{quickjs,jsc}.zig`.
//! * `JsErrorInfo` stores OWNED copies of the error's `name`, `message`, and (optionally) `stack` strings. Use `freeJsErrorInfo` with the SAME allocator you passed to `inspectError` to release them.
//! * `throwError` requires being invoked while executing a JS callback — on both backends "throw" is modeled as populating a per-call exception slot. Outside a callback this is a no-op returning false.
//!
//! Safety contract: every call here is dispatched through `instance_id`; operations on a given instance MUST occur on that instance's owning thread (same rule as the rest of the public API).

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");

const ActiveEngine = backend.ActiveEngine;

/// Tagged kind of a JS Error. The `unknown` variant is returned by `inspectError` when the value is not an Error instance — `newError` / `throwError` callers should not pass it in (behaviour falls back to a plain Error).
pub const JsErrorKind = enum(u8) {
    generic,
    type_error,
    range_error,
    reference_error,
    syntax_error,
    uri_error,
    eval_error,
    internal_error,
    aggregate_error,
    unknown,
};

/// Decoded payload of a JS Error instance. All slice fields are owned copies; release with `freeJsErrorInfo`.
pub const JsErrorInfo = struct {
    kind: JsErrorKind,
    name: []u8,
    message: []u8,
    /// `null` when the engine did not attach a stack (Error objects built manually without `Error.captureStackTrace` may omit it).
    stack: ?[]u8,
};

/// Map the public enum to the QuickJS backend enum.
fn toQjsKind(kind: JsErrorKind) @import("../backend.zig").ActiveEngineModule.QjsErrorKind {
    return switch (kind) {
        .generic, .unknown => .generic,
        .type_error => .type_error,
        .range_error => .range_error,
        .reference_error => .reference_error,
        .syntax_error => .syntax_error,
        .uri_error => .uri_error,
        .eval_error => .eval_error,
        .internal_error => .internal_error,
        .aggregate_error => .aggregate_error,
    };
}

/// Map the public enum to the JSC backend enum.
fn toJscKind(kind: JsErrorKind) @import("../backend/jsc.zig").JscErrorKind {
    return switch (kind) {
        .generic, .unknown => .generic,
        .type_error => .type_error,
        .range_error => .range_error,
        .reference_error => .reference_error,
        .syntax_error => .syntax_error,
        .uri_error => .uri_error,
        .eval_error => .eval_error,
        .internal_error => .internal_error,
        .aggregate_error => .aggregate_error,
    };
}

/// Classify an Error `name` property back into its enum tag. Anything outside the known set maps to `.generic` (the caller has already confirmed the value is-an Error — we just can't place it more specifically).
fn kindFromName(name: []const u8) JsErrorKind {
    if (std.mem.eql(u8, name, "TypeError")) return .type_error;
    if (std.mem.eql(u8, name, "RangeError")) return .range_error;
    if (std.mem.eql(u8, name, "ReferenceError")) return .reference_error;
    if (std.mem.eql(u8, name, "SyntaxError")) return .syntax_error;
    if (std.mem.eql(u8, name, "URIError")) return .uri_error;
    if (std.mem.eql(u8, name, "EvalError")) return .eval_error;
    if (std.mem.eql(u8, name, "InternalError")) return .internal_error;
    if (std.mem.eql(u8, name, "AggregateError")) return .aggregate_error;
    if (std.mem.eql(u8, name, "Error")) return .generic;
    return .generic;
}

/// How many `newError` / `throwError` frames are on this thread. A second entry means Error construction re-entered itself (the global Error constructor called back into us). Stop there — do not build another Error. One level is the call that is allowed to touch JS.
threadlocal var error_build_depth: u8 = 0;

fn enterErrorBuild() bool {
    if (error_build_depth >= 1) return false;
    error_build_depth += 1;
    return true;
}

fn leaveErrorBuild() void {
    if (error_build_depth > 0) error_build_depth -= 1;
}

/// Build a new Error of the requested kind with `.message = message`. Returns `null` if the instance is dead or the backend failed to allocate. The caller owns the returned value and must eventually either hand it off to JS (e.g. via `throwError` / `setPropertyStr`) or release it with `ActiveEngine.freeValue`.
pub fn newError(
    instance_id: i32,
    kind: JsErrorKind,
    message: []const u8,
) ?ActiveEngine.Value {
    // Re-entered while an Error is already being built. Stop.
    if (!enterErrorBuild()) return null;
    defer leaveErrorBuild();
    const ctx = engine.getContext(instance_id) orelse return null;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const v = qjs_mod.qjsNewTypedError(ctx, toQjsKind(kind), message);
            if (qjs_mod.Backend.jsIsException(v)) {
                // Drain the pending exception so we don't poison the next eval.
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return null;
            }
            return v;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const obj = jsc_mod.jscNewTypedError(ctx_ref, toJscKind(kind), message);
            if (obj == null) return null;
            // Protect so freeValue is symmetric with other Values (matches the external.zig pattern exactly).
            const v: ActiveEngine.Value = @ptrCast(obj);
            _ = jsc_mod.jsc.JSValueProtect(ctx_ref, v);
            return v;
        },
        .escargot => {
            const c_api = @import("../backend/escargot/c_api.zig");
            // Must match escargot_new_error switch (not ErrorObjectRef::Code ordinal).
            const kind_i: c_int = switch (kind) {
                .type_error => 1,
                .range_error => 2,
                .reference_error => 3,
                .syntax_error => 4,
                .uri_error => 5,
                .eval_error => 6,
                .aggregate_error => 8,
                .generic, .internal_error, .unknown => 0,
            };
            var buf: [1024]u8 = undefined;
            if (message.len >= buf.len) return null;
            @memcpy(buf[0..message.len], message);
            buf[message.len] = 0;
            return c_api.escargot_new_error(ctx, kind_i, @ptrCast(&buf));
        },
        .hermes => {
            const c_api = @import("../backend/hermes/c_api.zig");
            const kind_i: c_int = switch (kind) {
                .type_error => 1,
                .range_error => 2,
                .reference_error => 3,
                .syntax_error => 4,
                .uri_error => 5,
                .eval_error => 6,
                .aggregate_error => 8,
                .generic, .internal_error, .unknown => 0,
            };
            var buf: [1024]u8 = undefined;
            if (message.len >= buf.len) return null;
            @memcpy(buf[0..message.len], message);
            buf[message.len] = 0;
            return c_api.hermes_new_error(ctx, kind_i, @ptrCast(&buf));
        },
    }
}

/// Inspect an arbitrary JS value. Returns `null` when the value is not an Error instance. When non-null, the returned `JsErrorInfo` carries owned copies of `.name`, `.message`, and (optionally) `.stack` — release via `freeJsErrorInfo` using the SAME allocator passed here.
pub fn inspectError(
    allocator: std.mem.Allocator,
    instance_id: i32,
    value: ActiveEngine.Value,
) ?JsErrorInfo {
    const ctx = engine.getContext(instance_id) orelse return null;

    // Gate on isError first so we don't invoke property accessors on primitives (both backends handle this fine but returning early is clearer and skips a few allocations).
    const is_err = switch (backend.active_backend) {
        .quickjs, .quickjs_ng => blk: {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            break :blk qjs_mod.qjsIsError(ctx, value);
        },
        .jsc => blk: {
            const jsc_mod = @import("../backend/jsc.zig");
            break :blk jsc_mod.jscIsError(@ptrCast(ctx), value);
        },
        .escargot => blk: {
            const c_api = @import("../backend/escargot/c_api.zig");
            break :blk c_api.escargot_is_error(value);
        },
        .hermes => blk: {
            const c_api = @import("../backend/hermes/c_api.zig");
            break :blk c_api.hermes_is_error(ctx, value);
        },
    };
    if (!is_err) return null;

    const name_buf = readStringProp(allocator, ctx, value, "name") orelse
        allocator.dupe(u8, "Error") catch return null;
    const msg_buf = readStringProp(allocator, ctx, value, "message") orelse
        allocator.dupe(u8, "") catch {
        allocator.free(name_buf);
        return null;
    };
    const stack_buf = readStringProp(allocator, ctx, value, "stack");

    return JsErrorInfo{
        .kind = kindFromName(name_buf),
        .name = name_buf,
        .message = msg_buf,
        .stack = stack_buf,
    };
}

/// Release an info struct previously returned by `inspectError`. Must be called with the same allocator.
pub fn freeJsErrorInfo(allocator: std.mem.Allocator, info: JsErrorInfo) void {
    allocator.free(info.name);
    allocator.free(info.message);
    if (info.stack) |s| allocator.free(s);
}

/// Thread-local JSC callback exception out-parameter, set by `bindCallbackException` for the duration of a native callback. QuickJS does not consult this: `JS_Throw` already fills the context slot.
threadlocal var callback_exception_slot: ?*anyopaque = null;

/// Bind the JSC native-callback exception out-parameter for this thread. `throwError` writes the new Error into `slot` (a `[*c]JSValueRef`). Pass `null` when the callback returns. QuickJS ignores the slot; the callback still has to return `JS_EXCEPTION` after a successful `throwError`. Outside a bound callback, JSC `throwError` returns false because JavaScriptCore has no runtime-wide exception slot.
pub fn bindCallbackException(slot: ?*anyopaque) void {
    callback_exception_slot = slot;
}

/// Throw a typed Error as the current pending exception. Returns `true` on success, `false` if the instance is dead or the backend could not materialise the Error.
///
/// **Usage**: call this from a native function callback that wants JS `try/catch` to observe the Error.
///
/// * QuickJS: the Error is stored in the context exception slot. The callback must return `JS_EXCEPTION` so the engine propagates it. `JS_Throw` consumes the Error value.
/// * JSC: bind the callback's exception out-parameter with `bindCallbackException` first. `throwError` writes the Error there and returns true. With no slot bound this returns false and does not retain the Error (there is nowhere for it to go).
pub fn throwError(instance_id: i32, kind: JsErrorKind, message: []const u8) bool {
    // Re-entered from a throwing or re-calling Error constructor. Stop before touching JS again so this cannot recurse without bound.
    if (!enterErrorBuild()) return false;
    defer leaveErrorBuild();
    const ctx = engine.getContext(instance_id) orelse return false;
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const v = qjs_mod.qjsNewTypedError(ctx, toQjsKind(kind), message);
            if (qjs_mod.Backend.jsIsException(v)) {
                // Drain so no stale exception leaks; the typed error itself could not be built.
                const pending = qjs_mod.qjs.JS_GetException(ctx);
                if (!qjs_mod.Backend.jsIsNull(pending)) {
                    qjs_mod.jsbay_qjs_JS_FreeValue(ctx, pending);
                }
                return false;
            }
            // JS_Throw takes ownership of `v`; do NOT free it here.
            return qjs_mod.qjsThrowValue(ctx, v);
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const obj = jsc_mod.jscNewTypedError(ctx_ref, toJscKind(kind), message);
            if (obj == null) return false;
            const slot = callback_exception_slot orelse {
                // Unprotected object; JSC GC reclaims it. No runtime-wide exception slot exists to publish into.
                return false;
            };
            const out: [*c]jsc_mod.jsc.JSValueRef = @ptrCast(@alignCast(slot));
            out[0] = obj;
            return true;
        },
        .escargot, .hermes => {
            // pending_throw is message-only (Escargot trampoline → TypeError;
            // Hermes → `throw new Error(...)`). `kind` is honored on QJS/JSC arms only.
            var buf: [1024]u8 = undefined;
            if (message.len >= buf.len) return false;
            @memcpy(buf[0..message.len], message);
            buf[message.len] = 0;
            switch (backend.active_backend) {
                .escargot => @import("../backend/escargot/c_api.zig").escargot_throw(ctx, @ptrCast(&buf)),
                .hermes => @import("../backend/hermes/c_api.zig").hermes_throw(ctx, @ptrCast(&buf)),
                else => return false,
            }
            return true;
        },
    }
}

// ---- Internals ----

fn readStringProp(
    allocator: std.mem.Allocator,
    ctx: ActiveEngine.Context,
    value: ActiveEngine.Value,
    comptime key: [*:0]const u8,
) ?[]u8 {
    const prop = ActiveEngine.getPropertyVal(ctx, value, key) orelse return null;
    defer ActiveEngine.freeValue(ctx, prop);
    // One copy, owned by the caller. Do not dupe a buffer the backend already allocated for `allocator`.
    return ActiveEngine.valueToStringAlloc(allocator, ctx, prop);
}
