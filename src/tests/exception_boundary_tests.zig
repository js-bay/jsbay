//! Exception values crossing the JS / native boundary.
//!
//! A thrown Error's message (including non-ASCII text) is visible on the eval error string, and the same message is visible to a JS catch when a native callback calls `errors.throwError`. Either path leaves the engine able to evaluate again — there is no sticky "all APIs fail until an explicit clear" mode.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const errors = @import("../value/errors.zig");
const helpers = @import("test_helpers.zig");
const typed_eval = @import("../script/typed_eval.zig");
const value = @import("../value/root.zig");

const ActiveEngine = backend.ActiveEngine;

const boundary_message = "错误 👍";

fn installThrower(id: i32) void {
    const ctx = engine.getContext(id) orelse return;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);

    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        const qjs_mod = @import("../backend.zig").ActiveEngineModule;
        const cb = struct {
            fn call(
                ctx_: ?*qjs_mod.qjs.JSContext,
                _: qjs_mod.qjs.JSValue,
                _: c_int,
                _: [*c]qjs_mod.qjs.JSValue,
            ) callconv(.c) qjs_mod.qjs.JSValue {
                const instance_id = ActiveEngine.instanceIdFromCtx(ctx_);
                _ = errors.throwError(instance_id, .generic, boundary_message);
                return qjs_mod.JS_EXCEPTION;
            }
        }.call;
        ActiveEngine.setPropertyStr(
            ctx,
            global,
            "__throwUtf8",
            ActiveEngine.newCFunction(ctx, &cb, "__throwUtf8", 0),
        );
    } else if (comptime backend.isJscApiBackend(backend.active_backend)) {
        const jsc_mod = @import("../backend/jsc.zig");
        const common = @import("../backend/jsc/common.zig");
        const cb = struct {
            fn call(
                ctx_: jsc_mod.jsc.JSContextRef,
                _: jsc_mod.jsc.JSObjectRef,
                _: jsc_mod.jsc.JSObjectRef,
                _: usize,
                _: [*c]const jsc_mod.jsc.JSValueRef,
                exception: [*c]jsc_mod.jsc.JSValueRef,
            ) callconv(.c) jsc_mod.jsc.JSValueRef {
                errors.bindCallbackException(@ptrCast(exception));
                defer errors.bindCallbackException(null);
                const global_ctx: jsc_mod.jsc.JSGlobalContextRef = @constCast(ctx_);
                const instance_id = common.instanceIdFromCtx(global_ctx);
                _ = errors.throwError(instance_id, .generic, boundary_message);
                return jsc_mod.jsc.JSValueMakeUndefined(ctx_);
            }
        }.call;
        const func = common.makeFunction(@ptrCast(ctx), "__throwUtf8", &cb);
        if (func != null) jsc_mod.jsc.JSValueProtect(@ptrCast(ctx), func);
        ActiveEngine.setPropertyStr(ctx, global, "__throwUtf8", func);
    } else {
        // Escargot/Hermes: native callback trampoline not wired; leave global unset.
        _ = .{ ctx, global };
    }
}

test "exception boundary: eval Error message keeps utf-8 and the next eval works" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const res = engine.evalScript(id, "throw new Error('错误 👍');", "<boundary>");
            defer helpers.freeEvalResult(res);
            const err = res.err orelse return error.ExpectedException;
            try testing.expect(std.mem.indexOf(u8, err, boundary_message) != null);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "exception boundary: native throwError is caught in JS with the same message" {
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            installThrower(id);
            try helpers.evalOk(id,
                \\var caught = '';
                \\try { __throwUtf8(); caught = 'missed'; }
                \\catch (e) { caught = e.message; }
            );
            try helpers.expectEvalEquals(id, "caught", boundary_message);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "exception boundary: typed eval hands back the exact object JS threw" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const lease = @import("../runtime/engine_thread.zig").beginEval(id);
    defer engine.finishEvalEntry(id, lease);
    try testing.expect(lease.allowed);
    const ctx = engine.getContext(id) orelse return error.NoContext;

    const setup = typed_eval.evaluate(ctx, "globalThis.__thrown = { marker: 'original' }; globalThis.__thrown", "setup.js", "", "");
    const original = setup.value orelse return error.ExpectedObject;
    defer ActiveEngine.freeValue(ctx, original);

    const thrown = typed_eval.evaluate(ctx, "throw globalThis.__thrown", "throw.js", "", "");
    try testing.expect(thrown.value == null);
    const exception = thrown.exception orelse return error.ExpectedException;
    defer ActiveEngine.freeValue(ctx, exception);
    try testing.expect(value.strictEquals(id, original, exception));

    // A fresh object with the same shape must not compare equal.
    const lookalike = typed_eval.evaluate(ctx, "({ marker: 'original' })", "lookalike.js", "", "");
    const other = lookalike.value orelse return error.ExpectedObject;
    defer ActiveEngine.freeValue(ctx, other);
    try testing.expect(!value.strictEquals(id, other, exception));
}
