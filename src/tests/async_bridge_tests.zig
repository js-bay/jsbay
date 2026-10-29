//! Tests for the async_bridge module (Zig-side await over JS Promises). Both backends must pass.

const std = @import("std");
const io = @import("../platform/io.zig");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const async_bridge = @import("../runtime/async_bridge.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const errors = @import("../value/errors.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const types = @import("../types.zig");

const ActiveEngine = backend.ActiveEngine;

/// Evaluate a script that must return a JS value and fetch that value back out via a globalThis stash. Returns a caller-owned Value (free via ActiveEngine.freeValue).
fn stashAndFetch(id: i32, script: []const u8) !ActiveEngine.Value {
    try helpers.evalOk(id, script);
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    return ActiveEngine.getPropertyVal(ctx, global, "__ab_v") orelse error.MissingStash;
}

// ----------------------------------------------------------------------
// 1. resolves sync — Promise.resolve(42) → 42.
// ----------------------------------------------------------------------

test "async_bridge: resolves synchronously" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(id, "globalThis.__ab_v = Promise.resolve(42);");
            defer ActiveEngine.freeValue(ctx, p);

            const result = try async_bridge.awaitPromise(id, p, .{});
            defer ActiveEngine.freeValue(ctx, result);

            const n = ActiveEngine.toInt32(ctx, result) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 42), n);
        }
    }.run);
}

// ----------------------------------------------------------------------
// 2. resolves via microtask chain.
// ----------------------------------------------------------------------

test "async_bridge: resolves after microtask chain" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(id, "globalThis.__ab_v = Promise.resolve().then(() => 7);");
            defer ActiveEngine.freeValue(ctx, p);

            const result = try async_bridge.awaitPromise(id, p, .{});
            defer ActiveEngine.freeValue(ctx, result);

            const n = ActiveEngine.toInt32(ctx, result) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 7), n);
        }
    }.run);
}

// ----------------------------------------------------------------------
// 3. rejects sync with an Error — out_reason is populated with the error.
// ----------------------------------------------------------------------

test "async_bridge: rejects synchronously with Error, reason captured" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(id, "globalThis.__ab_v = Promise.reject(new Error('nope'));");
            defer ActiveEngine.freeValue(ctx, p);

            var reason: ActiveEngine.Value = ActiveEngine.undefinedValue();
            const res = async_bridge.awaitPromise(id, p, .{ .out_reason = &reason });
            try testing.expectError(async_bridge.AwaitError.Rejected, res);

            // The reason must be an Error-like whose .message == "nope".
            defer ActiveEngine.freeValue(ctx, reason);
            const info = errors.inspectError(testing.allocator, id, reason) orelse
                return error.InspectReturnedNull;
            defer errors.freeJsErrorInfo(testing.allocator, info);
            try testing.expectEqualStrings("nope", info.message);
        }
    }.run);
}

// ----------------------------------------------------------------------
// 4. rejects asynchronously from a throwing .then handler.
// ----------------------------------------------------------------------

test "async_bridge: rejects async via throwing .then" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(
                id,
                "globalThis.__ab_v = Promise.resolve().then(() => { throw new Error('boom'); });",
            );
            defer ActiveEngine.freeValue(ctx, p);

            var reason: ActiveEngine.Value = ActiveEngine.undefinedValue();
            const res = async_bridge.awaitPromise(id, p, .{ .out_reason = &reason });
            try testing.expectError(async_bridge.AwaitError.Rejected, res);

            defer ActiveEngine.freeValue(ctx, reason);
            const info = errors.inspectError(testing.allocator, id, reason) orelse
                return error.InspectReturnedNull;
            defer errors.freeJsErrorInfo(testing.allocator, info);
            try testing.expectEqualStrings("boom", info.message);
        }
    }.run);
}

// ----------------------------------------------------------------------
// 5. not a thenable — plain object with a non-callable .then (or none).
// ----------------------------------------------------------------------

test "async_bridge: plain non-thenable yields NotAPromise" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // {} — no .then at all.
            const empty = try stashAndFetch(id, "globalThis.__ab_v = {};");
            defer ActiveEngine.freeValue(ctx, empty);
            try testing.expectError(
                async_bridge.AwaitError.NotAPromise,
                async_bridge.awaitPromise(id, empty, .{}),
            );

            // { then: 42 } — has .then but it's not callable.
            const non_fn = try stashAndFetch(id, "globalThis.__ab_v = { then: 42 };");
            defer ActiveEngine.freeValue(ctx, non_fn);
            try testing.expectError(
                async_bridge.AwaitError.NotAPromise,
                async_bridge.awaitPromise(id, non_fn, .{}),
            );
        }
    }.run);
}

// ----------------------------------------------------------------------
// 6. timeout — a forever-pending promise with a short deadline.
// ----------------------------------------------------------------------

test "async_bridge: forever-pending promise times out" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);

            const start = io.milliTimestamp();
            const res = async_bridge.awaitPromise(id, p, .{ .timeout_ms = 50 });
            const elapsed = io.milliTimestamp() - start;

            try testing.expectError(async_bridge.AwaitError.TimedOut, res);
            // Loose upper bound — pump loop adds ~1ms per iteration plus any microtask/uv overhead. 200ms is generous.
            try testing.expect(elapsed < 200);
            // And a sanity lower bound: we shouldn't return before the deadline either.
            try testing.expect(elapsed >= 45);
        }
    }.run);
}

test "async_bridge: runtime deadline ends a pending wait" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);

            try testing.expect(runtime_control.setExecutionTimeLimit(id, 25));
            defer _ = runtime_control.setExecutionTimeLimit(id, 0);
            try testing.expectError(async_bridge.AwaitError.TimedOut, async_bridge.awaitPromise(id, p, .{}));
        }
    }.run);
}

const InterruptAwait = struct {
    instance_id: i32,

    fn request(self: *const InterruptAwait) void {
        io.sleepMs(10);
        _ = runtime_control.requestInterrupt(self.instance_id);
    }
};

const DestroyAwait = struct {
    instance_id: i32,
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn log(_: i32, _: types.LogLevel, _: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
        const self: *DestroyAwait = @ptrCast(@alignCast(user.?));
        self.entered.store(true, .seq_cst);
    }

    fn destroyAfterEntry(self: *DestroyAwait) void {
        waitForOrExit(&self.entered, 1_000, "awaitPromise did not reach an event-loop task");
        engine.destroy(self.instance_id);
        self.done.store(true, .seq_cst);
    }
};

fn waitForOrExit(done: *const std.atomic.Value(bool), timeout_ms: i64, what: []const u8) void {
    const started = io.monotonicMilliseconds();
    while (!done.load(.seq_cst)) {
        if (io.monotonicMilliseconds() - started >= timeout_ms) {
            std.debug.print("{s} did not finish within {d}ms\n", .{ what, timeout_ms });
            std.process.exit(1);
        }
        io.sleepMs(1);
    }
}

test "async_bridge: destroy releases a pending await" {
    const id = helpers.nextInstanceId();
    var destroyer = DestroyAwait{ .instance_id = id };
    try testing.expect(engine.create(id, .{ .log_handler = DestroyAwait.log, .log_user_data = &destroyer }));

    // Keep the Promise alive through globalThis, then release the caller's owned handle before teardown can win. awaitPromise borrows the raw value only long enough to duplicate it into its own holder.
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const p = try stashAndFetch(id,
        \\globalThis.__ab_v = new Promise(() => {});
        \\setTimeout(() => console.log('await-ready'), 0);
    );
    ActiveEngine.freeValue(ctx, p);

    const thread = try std.Thread.spawn(.{}, DestroyAwait.destroyAfterEntry, .{&destroyer});
    try testing.expectError(async_bridge.AwaitError.InstanceGone, async_bridge.awaitPromise(id, p, .{}));
    waitForOrExit(&destroyer.done, 1_000, "destroy while awaitPromise is pending");
    thread.join();
}

const SelfDestroyAwait = struct {
    called: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn log(instance_id: i32, _: types.LogLevel, _: [*:0]const u8, user: ?*anyopaque) callconv(.c) void {
        const self: *SelfDestroyAwait = @ptrCast(@alignCast(user.?));
        self.called.store(true, .seq_cst);
        engine.destroy(instance_id);
    }
};

test "async_bridge: callback self-destroy ends a pending wait" {
    const id = helpers.nextInstanceId();
    var callback = SelfDestroyAwait{};
    try testing.expect(engine.create(id, .{ .log_handler = SelfDestroyAwait.log, .log_user_data = &callback }));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const p = try stashAndFetch(id,
        \\globalThis.__ab_v = new Promise(() => {});
        \\setTimeout(() => console.log('await-self-destroy'), 0);
    );
    // The only owner that outlives this borrowed value is globalThis. Releasing the caller reference before the callback destroys the runtime makes the test obey the public value-lifetime contract.
    ActiveEngine.freeValue(ctx, p);

    try testing.expectError(async_bridge.AwaitError.InstanceGone, async_bridge.awaitPromise(id, p, .{}));
    try testing.expect(callback.called.load(.seq_cst));
}

const StopAwait = struct {
    instance_id: i32,

    fn request(self: *const StopAwait) void {
        io.sleepMs(10);
        _ = runtime_control.requestStopInterrupt(self.instance_id);
    }
};

test "async_bridge: lifecycle stop ends a pending wait as instance gone" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);

            const request = StopAwait{ .instance_id = id };
            const thread = try std.Thread.spawn(.{}, StopAwait.request, .{&request});
            defer thread.join();
            defer _ = runtime_control.clearStopInterrupt(id);
            try testing.expectError(async_bridge.AwaitError.InstanceGone, async_bridge.awaitPromise(id, p, .{}));
        }
    }.run);
}

test "async_bridge: prearmed lifecycle stop does not enter the VM" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);
            try testing.expect(runtime_control.requestStopInterrupt(id));
            defer _ = runtime_control.clearStopInterrupt(id);
            try testing.expectError(async_bridge.AwaitError.InstanceGone, async_bridge.awaitPromise(id, p, .{}));
        }
    }.run);
}

test "async_bridge: user interrupt ends a pending wait" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);

            const request = InterruptAwait{ .instance_id = id };
            const thread = try std.Thread.spawn(.{}, InterruptAwait.request, .{&request});
            defer thread.join();
            defer _ = runtime_control.clearInterrupt(id);
            try testing.expectError(async_bridge.AwaitError.Interrupted, async_bridge.awaitPromise(id, p, .{}));
        }
    }.run);
}

test "async_bridge: prearmed user interrupt does not become NotAPromise" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);
            try testing.expect(runtime_control.requestInterrupt(id));
            defer _ = runtime_control.clearInterrupt(id);
            try testing.expectError(async_bridge.AwaitError.Interrupted, async_bridge.awaitPromise(id, p, .{}));
        }
    }.run);
}

test "async_bridge: expired runtime deadline does not become NotAPromise" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id, "globalThis.__ab_v = new Promise(() => {});");
            defer ActiveEngine.freeValue(ctx, p);
            try testing.expect(runtime_control.setExecutionTimeLimit(id, 1));
            defer _ = runtime_control.setExecutionTimeLimit(id, 0);
            io.sleepMs(2);
            try testing.expectError(async_bridge.AwaitError.TimedOut, async_bridge.awaitPromise(id, p, .{}));
        }
    }.run);
}

// ----------------------------------------------------------------------
// 7. resolves via setTimeout — proves the event loop is being pumped.
// ----------------------------------------------------------------------

test "async_bridge: setTimeout-backed resolution drives the event loop" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(
                id,
                "globalThis.__ab_v = new Promise(r => setTimeout(() => r(99), 10));",
            );
            defer ActiveEngine.freeValue(ctx, p);

            const result = try async_bridge.awaitPromise(id, p, .{ .timeout_ms = 2000 });
            defer ActiveEngine.freeValue(ctx, result);

            const n = ActiveEngine.toInt32(ctx, result) orelse return error.NotAnInt;
            try testing.expectEqual(@as(i32, 99), n);
        }
    }.run);
}

test "async_bridge: holder cleanup does not invoke a replaced setter" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;
            const p = try stashAndFetch(id,
                \\globalThis.__ab_setter_calls = 0;
                \\globalThis.__ab_v = new Promise(r => setTimeout(r, 0)).then(() => {
                \\  for (const name of Object.getOwnPropertyNames(globalThis)) {
                \\    if (name.startsWith('__jsbay_qjs_await_') && !name.endsWith('_h')) {
                \\      Object.defineProperty(globalThis, name, {
                \\        configurable: true,
                \\        set() { globalThis.__ab_setter_calls++; },
                \\      });
                \\    }
                \\  }
                \\  return 12;
                \\});
            );
            defer ActiveEngine.freeValue(ctx, p);

            const result = try async_bridge.awaitPromise(id, p, .{ .timeout_ms = 2_000 });
            defer ActiveEngine.freeValue(ctx, result);
            try testing.expectEqual(@as(i32, 12), ActiveEngine.toInt32(ctx, result).?);
            try helpers.expectEvalEquals(id, "__ab_setter_calls", "0");
            try helpers.expectEvalEquals(id, "Object.getOwnPropertyNames(globalThis).filter(n => n.startsWith('__jsbay_qjs_await_')).length", "0");
        }
    }.run);
}

// ----------------------------------------------------------------------
// 8. huge timeout_ms clamps instead of overflowing i64 arithmetic.
// ----------------------------------------------------------------------

test "async_bridge: ridiculous timeout clamps safely" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            // Use a sync-resolving promise so we never actually hit the clamped deadline — we just want to verify that passing std.math.maxInt(u64) doesn't panic the arithmetic.
            const p = try stashAndFetch(id, "globalThis.__ab_v = Promise.resolve(1);");
            defer ActiveEngine.freeValue(ctx, p);

            const result = try async_bridge.awaitPromise(id, p, .{
                .timeout_ms = std.math.maxInt(u64),
            });
            defer ActiveEngine.freeValue(ctx, result);

            try testing.expectEqual(@as(i32, 1), ActiveEngine.toInt32(ctx, result).?);
        }
    }.run);
}

// ----------------------------------------------------------------------
// 9. rejection with `undefined` reason doesn't crash the pump.
// ----------------------------------------------------------------------

test "async_bridge: reject with undefined reason" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            const ctx = engine.getContext(id) orelse return error.NoContext;

            const p = try stashAndFetch(id, "globalThis.__ab_v = Promise.reject(undefined);");
            defer ActiveEngine.freeValue(ctx, p);

            var reason: ActiveEngine.Value = undefined;
            const res = async_bridge.awaitPromise(id, p, .{ .out_reason = &reason });
            try testing.expectError(async_bridge.AwaitError.Rejected, res);
            // `out_reason` should be populated with undefined; freeing must be a no-op rather than a crash.
            ActiveEngine.freeValue(ctx, reason);
        }
    }.run);
}
