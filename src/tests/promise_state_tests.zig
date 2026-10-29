//! promise.state / promise.result.
//!
//! pending has no result. resolve(42) is fulfilled with 42. reject is rejected. A throwing eval whose exception object is never inspected does not stop a later Deferred.resolve from delivering 42, and the following eval still returns 2.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const promise = @import("../runtime/promise.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;

fn stashPromise(id: i32, deferred: *promise.Deferred) !void {
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const dup = ActiveEngine.dupValue(ctx, deferred.promise);
    ActiveEngine.setPropertyStr(ctx, global, "__p", dup);
}

test "promise state: pending result fails" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            try testing.expectEqual(promise.PromiseState.pending, promise.state(id, d.promise).?);
            try testing.expect(promise.result(id, d.promise) == null);

            const u = ActiveEngine.newUndefinedVal(ctx);
            defer ActiveEngine.freeValue(ctx, u);
            try testing.expect(d.resolve(u));
        }
    }.run);
}

test "promise state: resolve(42) is fulfilled with result 42" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();
            try stashPromise(id, &d);

            try helpers.evalOk(id, "globalThis.x = 0; globalThis.__p.then(function (v) { globalThis.x = v; });");

            const val = ActiveEngine.newInt32Val(ctx, 42);
            defer ActiveEngine.freeValue(ctx, val);
            try testing.expect(d.resolve(val));

            try testing.expectEqual(promise.PromiseState.fulfilled, promise.state(id, d.promise).?);
            const got = promise.result(id, d.promise) orelse return error.NoResult;
            defer ActiveEngine.freeValue(ctx, got);
            try testing.expectEqual(@as(i32, 42), ActiveEngine.toInt32(ctx, got).?);
            try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.x"));
        }
    }.run);
}

test "promise state: reject is rejected and result is the reason" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();

            const reason = ActiveEngine.newInt32Val(ctx, 7);
            defer ActiveEngine.freeValue(ctx, reason);
            try testing.expect(d.reject(reason));

            try testing.expectEqual(promise.PromiseState.rejected, promise.state(id, d.promise).?);
            const got = promise.result(id, d.promise) orelse return error.NoResult;
            defer ActiveEngine.freeValue(ctx, got);
            try testing.expectEqual(@as(i32, 7), ActiveEngine.toInt32(ctx, got).?);
        }
    }.run);
}

test "promise state: resolve still delivers 42 after an unread eval exception" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            var d = promise.create(id) orelse return error.NoDeferred;
            defer d.deinit();
            try stashPromise(id, &d);

            try helpers.evalOk(id, "globalThis.x = 0; globalThis.__p.then(function (v) { globalThis.x = v; });");

            // Do not inspect the exception object. freeEvalResult only releases the error string the eval API already produced.
            const thrown = engine.evalScript(id, "throw new Error('stale');", "<stale>");
            helpers.freeEvalResult(thrown);

            const val = ActiveEngine.newInt32Val(ctx, 42);
            defer ActiveEngine.freeValue(ctx, val);
            try testing.expect(d.resolve(val));
            try testing.expectEqual(@as(i64, 42), try helpers.evalInt(id, "globalThis.x"));
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}
