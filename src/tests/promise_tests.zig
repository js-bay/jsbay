//! Tests for the promise module (native-side create/resolve/reject/detect). Both backends must pass.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const promise = @import("../runtime/promise.zig");
const engine = @import("../engine.zig");
const reference = @import("../value/reference.zig");
const backend = @import("../backend.zig");
const value_mod = @import("../value/root.zig");

const ActiveEngine = backend.ActiveEngine;

// ----------------------------------------------------------------------
// Basic round-trips
// ----------------------------------------------------------------------

test "promise.create + resolve with i32 runs .then with the value" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            // Stash the promise on globalThis so JS can attach .then.
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const promise_dup = ActiveEngine.dupValue(ctx, d.promise);
            ActiveEngine.setPropertyStr(ctx, global, "__p", promise_dup);

            // Register .then handler that writes to global.x.
            try helpers.evalOk(id, "globalThis.x = 0; globalThis.__p.then(v => { globalThis.x = v; });");

            // Resolve with 42.
            const val = ActiveEngine.newInt32Val(ctx, 42);
            defer ActiveEngine.freeValue(ctx, val);
            try testing.expect(d.resolve(val));

            // The final eval flushes the QJS job queue (for JSC it's already drained); verify the .then ran.
            const got = try helpers.evalInt(id, "globalThis.x");
            try testing.expectEqual(@as(i64, 42), got);
        }
    }.run);
}

test "promise.create + reject fires .catch" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const promise_dup = ActiveEngine.dupValue(ctx, d.promise);
            ActiveEngine.setPropertyStr(ctx, global, "__p", promise_dup);

            try helpers.evalOk(id,
                \\globalThis.msg = "";
                \\globalThis.__p.catch(e => { globalThis.msg = String(e.message || e); });
            );

            // Reject with an Error object.
            const err_val = blk: {
                const r = engine.evalScript(id, "new Error('boom')", "<test>");
                helpers.freeEvalResult(r);
                // evalScript doesn't return the value; build it directly via JS.
                const s = ActiveEngine.newStringVal(ctx, "boom");
                break :blk s;
            };
            defer ActiveEngine.freeValue(ctx, err_val);
            try testing.expect(d.reject(err_val));

            const result = try helpers.evalString(std.testing.allocator, id, "String(globalThis.msg)");
            defer std.testing.allocator.free(result);
            try testing.expectEqualStrings("boom", result);
        }
    }.run);
}

// Rejecting with an Error object hands the same object, not a copy or message, to the handler.
test "promise.reject with an Error object delivers the same object to .catch" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "__p", ActiveEngine.dupValue(ctx, d.promise));

            // The Error is built in JS and published so the handler can compare identity.
            try helpers.evalOk(id,
                \\globalThis.__err = new TypeError('rejected-with-error');
                \\globalThis.__same = 'pending';
                \\globalThis.__p.catch(e => { globalThis.__same = String(e === globalThis.__err); });
            );
            const err_val = ActiveEngine.getPropertyVal(ctx, global, "__err") orelse return error.MissingError;
            defer ActiveEngine.freeValue(ctx, err_val);
            try testing.expect(d.reject(err_val));

            try helpers.expectEvalEquals(id, "globalThis.__same", "true");
            try helpers.expectEvalEquals(id, "globalThis.__err.name + ':' + globalThis.__err.message", "TypeError:rejected-with-error");
        }
    }.run);
}

test "promise.isPromise true for created promise, false for primitives" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            try testing.expect(promise.isPromise(id, d.promise));

            const num = ActiveEngine.newInt32Val(ctx, 123);
            defer ActiveEngine.freeValue(ctx, num);
            try testing.expect(!promise.isPromise(id, num));

            const str = ActiveEngine.newStringVal(ctx, "hi");
            defer ActiveEngine.freeValue(ctx, str);
            try testing.expect(!promise.isPromise(id, str));

            const obj = ActiveEngine.newObject(ctx);
            defer ActiveEngine.freeValue(ctx, obj);
            try testing.expect(!promise.isPromise(id, obj));

            // Resolve so deinit doesn't leave a pending promise.
            const u = ActiveEngine.newUndefinedVal(ctx);
            defer ActiveEngine.freeValue(ctx, u);
            _ = d.resolve(u);
        }
    }.run);
}

test "resolve is idempotent: second call is a no-op" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const promise_dup = ActiveEngine.dupValue(ctx, d.promise);
            ActiveEngine.setPropertyStr(ctx, global, "__p", promise_dup);

            try helpers.evalOk(id, "globalThis.x = 0; globalThis.__p.then(v => { globalThis.x = v; });");

            const v1 = ActiveEngine.newInt32Val(ctx, 7);
            defer ActiveEngine.freeValue(ctx, v1);
            try testing.expect(d.resolve(v1));

            // Second attempt must be a no-op and must not crash.
            const v2 = ActiveEngine.newInt32Val(ctx, 99);
            defer ActiveEngine.freeValue(ctx, v2);
            try testing.expect(!d.resolve(v2));
            try testing.expect(!d.reject(v2));

            const got = try helpers.evalInt(id, "globalThis.x");
            try testing.expectEqual(@as(i64, 7), got);
        }
    }.run);
}

test "resolve with a JS string propagates to .then" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const promise_dup = ActiveEngine.dupValue(ctx, d.promise);
            ActiveEngine.setPropertyStr(ctx, global, "__p", promise_dup);

            try helpers.evalOk(id, "globalThis.s = ''; globalThis.__p.then(v => { globalThis.s = v; });");

            const s = ActiveEngine.newStringVal(ctx, "hello-async");
            defer ActiveEngine.freeValue(ctx, s);
            try testing.expect(d.resolve(s));

            const out = try helpers.evalString(std.testing.allocator, id, "String(globalThis.s)");
            defer std.testing.allocator.free(out);
            try testing.expectEqualStrings("hello-async", out);
        }
    }.run);
}

test "resolve after intervening JS evaluation (true async pattern)" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const promise_dup = ActiveEngine.dupValue(ctx, d.promise);
            ActiveEngine.setPropertyStr(ctx, global, "__p", promise_dup);

            try helpers.evalOk(id,
                \\globalThis.log = [];
                \\globalThis.log.push('before-then');
                \\globalThis.__p.then(v => { globalThis.log.push('then:' + v); });
                \\globalThis.log.push('after-then');
            );

            // Run some unrelated JS that does not touch the promise.
            try helpers.evalOk(id, "globalThis.log.push('between'); (function(){ let s=0; for(let i=0;i<50;i++) s+=i; return s; })();");

            // Now settle. The .then must run and append.
            const v = ActiveEngine.newInt32Val(ctx, 5);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(d.resolve(v));

            const got = try helpers.evalString(std.testing.allocator, id, "globalThis.log.join(',')");
            defer std.testing.allocator.free(got);
            try testing.expectEqualStrings("before-then,after-then,between,then:5", got);
        }
    }.run);
}

test "engine teardown with unresolved promise does not leak or crash" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    {
        const d = promise.create(id) orelse {
            engine.destroy(id);
            return error.NoDeferred;
        };
        // Intentionally do NOT settle or deinit — engine teardown must release the resolving Globals via bookkeeping.
        _ = d;
    }
    engine.destroy(id);
}

test "deinit without settling is safe (releases resolving callbacks)" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var d = promise.create(id) orelse return error.NoDeferred;
            d.deinit();
            // Second deinit must be a no-op.
            d.deinit();
        }
    }.run);
}

test "NativeResult.promise: handler returns promise, JS awaits it" {
    try helpers.withDefaultEngine(struct {
        // Stash the resolve function globally so we can settle it from the test body after the handler has returned.
        var stash_deferred: ?promise.Deferred = null;

        fn handler(instance_id: i32, args: value_mod.NativeArgs) value_mod.NativeResult {
            _ = args;
            var d = promise.create(instance_id) orelse return .{ .err = "no-promise" };
            // Keep the resolve/reject handles alive for the test body. We move d into a stash; return just the promise as the JS function's return value.
            const ctx = engine.getContext(instance_id) orelse {
                d.deinit();
                return .{ .err = "no-ctx" };
            };
            // Dup promise before handing to JS; the NativeResult.promise pathway takes ownership.
            const promise_for_js = ActiveEngine.dupValue(ctx, d.promise);
            stash_deferred = d;
            return .{ .promise = promise_for_js };
        }

        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            value_mod.registerFunction(id, null, "makeAsync", handler);

            try helpers.evalOk(id,
                \\globalThis.result = null;
                \\const p = makeAsync();
                \\if (typeof p !== 'object' || p === null || typeof p.then !== 'function') {
                \\    throw new Error('not a promise');
                \\}
                \\p.then(v => { globalThis.result = v; });
            );

            // Handler stashed the deferred — settle it.
            var d = stash_deferred orelse return error.NoStash;
            defer d.deinit();
            const v = ActiveEngine.newInt32Val(ctx, 123);
            defer ActiveEngine.freeValue(ctx, v);
            try testing.expect(d.resolve(v));
            stash_deferred = null;

            const got = try helpers.evalInt(id, "globalThis.result");
            try testing.expectEqual(@as(i64, 123), got);
        }
    }.run);
}

test "promise.isPromise on value returned from JS `Promise.resolve`" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            // Build and protect a Promise.resolve(1) value from JS.
            try helpers.evalOk(id, "globalThis.__q = Promise.resolve(1);");

            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            const p = ActiveEngine.getPropertyVal(ctx, global, "__q") orelse return error.MissingQ;
            defer ActiveEngine.freeValue(ctx, p);

            try testing.expect(promise.isPromise(id, p));
        }
    }.run);
}
