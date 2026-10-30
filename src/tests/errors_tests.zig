//! Tests for the structured JS error API (src/value/errors.zig).
//!
//! Cover:
//!   1. inspectError on TypeError('boom') → kind/message/name populated
//!   2. inspectError on RangeError / SyntaxError / plain Error → correct kind
//!   3. inspectError on non-error values (string, number, plain object) → null
//!   4. newError produces a value JS recognises as `instanceof` its class
//!   5. .stack is populated for thrown-and-caught errors
//! 6. repeated inspect+free cycles do not leak (smoke test via testing allocator)
//!
//! A note on backend parity: JSC has no dedicated InternalError global, so newError(.internal_error) falls back to plain Error there. That branch is tested via backend.active_backend to stay green on both engines.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const errors = @import("../value/errors.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// ---------------------------------------------------------------------------
// 1. inspectError on `new TypeError('boom')` returns structured info.
// ---------------------------------------------------------------------------

test "errors: inspect TypeError yields kind/name/message" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Build the error via JS so we're testing inspection of a caller-constructed value, not our own newError path.
            try helpers.evalOk(id, "globalThis.__e__ = new TypeError('boom');");
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const err_val = ActiveEngine.getPropertyVal(ctx, global, "__e__") orelse
                return error.MissingError;
            defer ActiveEngine.freeValue(ctx, err_val);

            const info = errors.inspectError(testing.allocator, id, err_val) orelse
                return error.InspectReturnedNull;
            defer errors.freeJsErrorInfo(testing.allocator, info);

            try testing.expectEqual(errors.JsErrorKind.type_error, info.kind);
            try testing.expectEqualStrings("TypeError", info.name);
            try testing.expectEqualStrings("boom", info.message);

            try helpers.evalOk(id, "delete globalThis.__e__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 2. inspectError classifies the common derived error types.
// ---------------------------------------------------------------------------

test "errors: inspect classifies RangeError/SyntaxError/plain Error" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);

            const Case = struct {
                script: []const u8,
                expected_kind: errors.JsErrorKind,
                expected_name: []const u8,
            };
            const cases = [_]Case{
                .{
                    .script = "globalThis.__e__ = new RangeError('r');",
                    .expected_kind = .range_error,
                    .expected_name = "RangeError",
                },
                .{
                    .script = "globalThis.__e__ = new SyntaxError('s');",
                    .expected_kind = .syntax_error,
                    .expected_name = "SyntaxError",
                },
                .{
                    .script = "globalThis.__e__ = new ReferenceError('ref');",
                    .expected_kind = .reference_error,
                    .expected_name = "ReferenceError",
                },
                .{
                    .script = "globalThis.__e__ = new Error('plain');",
                    .expected_kind = .generic,
                    .expected_name = "Error",
                },
            };

            for (cases) |c| {
                try helpers.evalOk(id, c.script);
                const err_val = ActiveEngine.getPropertyVal(ctx, global, "__e__") orelse
                    return error.MissingError;
                defer ActiveEngine.freeValue(ctx, err_val);

                const info = errors.inspectError(testing.allocator, id, err_val) orelse
                    return error.InspectReturnedNull;
                defer errors.freeJsErrorInfo(testing.allocator, info);

                try testing.expectEqual(c.expected_kind, info.kind);
                try testing.expectEqualStrings(c.expected_name, info.name);
            }

            try helpers.evalOk(id, "delete globalThis.__e__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 3. inspectError on non-error values returns null.
// ---------------------------------------------------------------------------

test "errors: inspect returns null for non-error values" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // String.
            const s = ActiveEngine.newStringVal(ctx, "nope");
            defer ActiveEngine.freeValue(ctx, s);
            try testing.expect(errors.inspectError(testing.allocator, id, s) == null);

            // Number.
            const n = ActiveEngine.newInt32Val(ctx, 42);
            defer ActiveEngine.freeValue(ctx, n);
            try testing.expect(errors.inspectError(testing.allocator, id, n) == null);

            // Plain object (has .name/.message only when we set them, and we don't — the isError gate rejects it anyway).
            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            try testing.expect(errors.inspectError(testing.allocator, id, obj) == null);

            // Object that LOOKS like an error (has .name/.message) but was not built via an Error constructor — should still be rejected.
            try helpers.evalOk(id,
                \\globalThis.__fake__ = { name: 'TypeError', message: 'impostor' };
            );
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const fake = ActiveEngine.getPropertyVal(ctx, global, "__fake__") orelse
                return error.MissingFake;
            defer ActiveEngine.freeValue(ctx, fake);
            try testing.expect(errors.inspectError(testing.allocator, id, fake) == null);

            try helpers.evalOk(id, "delete globalThis.__fake__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 4. newError builds a value JS `instanceof` recognises.
// ---------------------------------------------------------------------------

test "errors: newError(type_error) is instanceof TypeError in JS" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const err = errors.newError(id, .type_error, "from-native") orelse
                return error.NewErrorFailed;
            // Park on globalThis so JS can interrogate it. setPropertyStr consumes `err` on both backends — do NOT freeValue afterwards.
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__n__", err);

            // Round-trip via JS: must be an Error AND more specifically a TypeError, with the correct message.
            try helpers.expectEvalEquals(
                id,
                "String(__n__ instanceof TypeError)",
                "true",
            );
            try helpers.expectEvalEquals(
                id,
                "String(__n__ instanceof Error)",
                "true",
            );
            try helpers.expectEvalEquals(id, "__n__.message", "from-native");

            try helpers.evalOk(id, "delete globalThis.__n__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 5. A thrown-then-caught Error carries a stack trace.
//
// Both engines populate `.stack` for errors that went through the engine's throw path. We try/catch and re-expose the error to native code, then assert the stack is present + non-empty.
// ---------------------------------------------------------------------------

test "errors: inspect returns a populated stack for thrown errors" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            try helpers.evalOk(id,
                \\try {
                \\    function outer() { throw new Error('with-stack'); }
                \\    outer();
                \\} catch (e) {
                \\    globalThis.__caught__ = e;
                \\}
            );

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const caught = ActiveEngine.getPropertyVal(ctx, global, "__caught__") orelse
                return error.MissingCaught;
            defer ActiveEngine.freeValue(ctx, caught);

            const info = errors.inspectError(testing.allocator, id, caught) orelse
                return error.InspectReturnedNull;
            defer errors.freeJsErrorInfo(testing.allocator, info);

            try testing.expectEqualStrings("Error", info.name);
            try testing.expectEqualStrings("with-stack", info.message);
            // Stack is engine-formatted; we only require "something non-trivial was attached". Most engines emit multiple lines; we conservatively assert length > 0 to stay portable.
            const stack = info.stack orelse return error.StackMissing;
            try testing.expect(stack.len > 0);

            try helpers.evalOk(id, "delete globalThis.__caught__;");
        }
    }.run);
}

// The header line differs per backend, so only function names are asserted.
test "errors: stack of a nested throw names both functions" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            try helpers.evalOk(id,
                \\function innerThrower() { throw new Error('nested-stack'); }
                \\function outerCaller() { innerThrower(); }
                \\try { outerCaller(); } catch (e) { globalThis.__caught__ = e; }
            );

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const caught = ActiveEngine.getPropertyVal(ctx, global, "__caught__") orelse
                return error.MissingCaught;
            defer ActiveEngine.freeValue(ctx, caught);

            const info = errors.inspectError(testing.allocator, id, caught) orelse
                return error.InspectReturnedNull;
            defer errors.freeJsErrorInfo(testing.allocator, info);

            const stack = info.stack orelse return error.StackMissing;
            const inner_at = std.mem.indexOf(u8, stack, "innerThrower") orelse return error.InnerFrameMissing;
            const outer_at = std.mem.indexOf(u8, stack, "outerCaller") orelse return error.OuterFrameMissing;
            // The throwing frame is listed before its caller.
            try testing.expect(inner_at < outer_at);

            try helpers.evalOk(id, "delete globalThis.__caught__;");
        }
    }.run);
}

// The cause option is plain data on the error object, so it is readable through eval whatever the C ABI later exposes for it.
test "errors: cause option is an own non-enumerable property holding the same object" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try helpers.expectEvalEquals(id,
                \\(function () {
                \\    const root = new RangeError('root');
                \\    const mid = new TypeError('mid', { cause: root });
                \\    const top = new Error('top', { cause: mid });
                \\    const d = Object.getOwnPropertyDescriptor(top, 'cause');
                \\    return [
                \\        top.cause === mid,
                \\        top.cause.cause === root,
                \\        d.enumerable === false && d.writable === true && d.configurable === true,
                \\        Object.keys(top).indexOf('cause') === -1,
                \\    ].join(',');
                \\})()
            , "true,true,true,true");
            // Without the option the property is absent, not undefined-valued.
            try helpers.expectEvalEquals(id, "String(Object.prototype.hasOwnProperty.call(new Error('plain'), 'cause'))", "false");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 6. Repeated inspect+free cycles do not leak.
//
// The testing allocator panics on unfreed allocations at end-of-test, so this is effectively "run the loop and let the allocator catch leaks".
// ---------------------------------------------------------------------------

test "errors: inspect+free cycle leaves no leaks" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);

            try helpers.evalOk(id,
                \\globalThis.__rep__ = new RangeError('leak-check');
            );

            var i: u32 = 0;
            while (i < 32) : (i += 1) {
                const val = ActiveEngine.getPropertyVal(ctx, global, "__rep__") orelse
                    return error.MissingRep;
                defer ActiveEngine.freeValue(ctx, val);

                const info = errors.inspectError(testing.allocator, id, val) orelse
                    return error.InspectReturnedNull;
                errors.freeJsErrorInfo(testing.allocator, info);
            }

            try helpers.evalOk(id, "delete globalThis.__rep__;");
        }
    }.run);
}

// ---------------------------------------------------------------------------
// 7. (bonus) newError round-trips through inspectError for every kind.
//
// Skips .internal_error on JSC (no InternalError global, falls back to Error). Skips .unknown — that's the inspect-only "not-an-error" sentinel.
// ---------------------------------------------------------------------------

test "errors: newError then inspectError round-trips the kind" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const kinds = [_]errors.JsErrorKind{
                .generic,
                .type_error,
                .range_error,
                .reference_error,
                .syntax_error,
                .uri_error,
                .eval_error,
                .aggregate_error,
            };
            for (kinds) |k| {
                const err = errors.newError(id, k, "rt") orelse
                    return error.NewErrorFailed;
                defer ActiveEngine.freeValue(ctx, err);

                const info = errors.inspectError(testing.allocator, id, err) orelse
                    return error.InspectReturnedNull;
                defer errors.freeJsErrorInfo(testing.allocator, info);

                try testing.expectEqual(k, info.kind);
                try testing.expectEqualStrings("rt", info.message);
            }

            // internal_error: QuickJS supports it directly; JSC folds to Error.
            const inter = errors.newError(id, .internal_error, "int") orelse
                return error.NewErrorFailed;
            defer ActiveEngine.freeValue(ctx, inter);
            const info = errors.inspectError(testing.allocator, id, inter) orelse
                return error.InspectReturnedNull;
            defer errors.freeJsErrorInfo(testing.allocator, info);
            switch (backend.active_backend) {
                .quickjs, .quickjs_ng => try testing.expectEqual(errors.JsErrorKind.internal_error, info.kind),
                .jsc => try testing.expectEqual(errors.JsErrorKind.generic, info.kind),
                .escargot, .hermes => try testing.expectEqual(errors.JsErrorKind.generic, info.kind),
            }
        }
    }.run);
}
