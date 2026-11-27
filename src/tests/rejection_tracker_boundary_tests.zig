//! Additional unhandled rejection tests: deadlines, unregistration, time limits, and ID reuse.

const std = @import("std");
const testing = std.testing;
const io = @import("../platform/io.zig");
const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const promise = @import("../runtime/promise.zig");
const backend = @import("../backend.zig");
const types = @import("../types.zig");
const value_api = @import("../value/root.zig");
const runtime_control = @import("../runtime/runtime_control.zig");

const max_events = 8;
const max_reason = 256;

const RejectionLog = struct {
    count: u32 = 0,
    handled: [max_events]bool = @splat(false),
    reason: [max_events][max_reason]u8 = undefined,
    reason_len: [max_events]u16 = @splat(0),

    fn text(self: *const RejectionLog, index: usize) []const u8 {
        return self.reason[index][0..self.reason_len[index]];
    }
};

fn onRejection(
    _: i32,
    handled: bool,
    reason_ptr: [*]const u8,
    reason_len: usize,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const log: *RejectionLog = @ptrCast(@alignCast(userdata orelse return));
    if (log.count >= max_events) return;
    const i = log.count;
    log.handled[i] = handled;
    const n = @min(reason_len, max_reason);
    if (n > 0) @memcpy(log.reason[i][0..n], reason_ptr[0..n]);
    log.reason_len[i] = @intCast(n);
    log.count += 1;
}

fn install(id: i32, log: *RejectionLog) bool {
    return promise.setRejectionTracker(id, &onRejection, log);
}

const UnregisterOnRejection = struct {
    count: u32 = 0,
    handled: [max_events]bool = @splat(false),
    reason: [max_events][max_reason]u8 = undefined,
    reason_len: [max_events]u16 = @splat(0),

    fn handler(instance_id: i32, handled: bool, reason_ptr: [*]const u8, reason_len: usize, userdata: ?*anyopaque) callconv(.c) void {
        const self: *UnregisterOnRejection = @ptrCast(@alignCast(userdata orelse return));
        _ = promise.setRejectionTracker(instance_id, null, null);
        if (self.count >= max_events) return;
        const i = self.count;
        self.handled[i] = handled;
        const n = @min(reason_len, max_reason);
        if (n > 0) @memcpy(self.reason[i][0..n], reason_ptr[0..n]);
        self.reason_len[i] = @intCast(n);
        self.count += 1;
    }

    fn text(self: *const UnregisterOnRejection, index: usize) []const u8 {
        return self.reason[index][0..self.reason_len[index]];
    }
};

fn setShortPendingJobLimit(instance_id: i32, _: value_api.NativeArgs) value_api.NativeResult {
    return .{ .boolean = runtime_control.setExecutionTimeLimit(instance_id, 1) };
}

fn unregisterRejectionTracker(instance_id: i32, _: value_api.NativeArgs) value_api.NativeResult {
    _ = promise.setRejectionTracker(instance_id, null, null);
    return .undefined_val;
}

test "rejection: tracker checkpoint leaves ordinary timers on their deadlines" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);

    var log = RejectionLog{};
    if (!install(id, &log)) return;
    defer _ = promise.setRejectionTracker(id, null, null);

    try helpers.evalOk(id,
        \\globalThis.__timer100 = 0;
        \\globalThis.__timer2000 = 0;
        \\setTimeout(function () { globalThis.__timer100 += 1; }, 100);
        \\setTimeout(function () { globalThis.__timer2000 += 1; }, 2000);
        \\Promise.reject(new Error('checkpoint-marker'));
    );
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__timer100"));
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__timer2000"));

    _ = engine.testing.advance(id, 1000);
    try testing.expectEqual(@as(i64, 1100), engine.testing.advance(id, 1099));
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__timer100"));
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__timer2000"));
    try testing.expectEqual(@as(i64, 3000), engine.testing.advance(id, 1100));
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__timer100"));
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__timer2000"));
    try testing.expectEqual(@as(i64, 3000), engine.testing.advance(id, 2999));
    try testing.expectEqual(@as(i64, 0), try helpers.evalInt(id, "globalThis.__timer2000"));
    try testing.expectEqual(@as(i64, -1), engine.testing.advance(id, 3000));
    try testing.expectEqual(@as(i64, 1), try helpers.evalInt(id, "globalThis.__timer2000"));
    try testing.expectEqual(@as(u32, 1), log.count);
}

test "rejection: unregister during reporting does not leak across drains or instance reuse" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var first_alive = true;
    defer if (first_alive) engine.destroy(id);
    try engine.testing.setNow(id, 1000);

    var first_log = UnregisterOnRejection{};
    if (!promise.setRejectionTracker(id, &UnregisterOnRejection.handler, &first_log)) return;
    try helpers.evalOk(id,
        \\Promise.reject(new Error('first-checkpoint-marker'));
        \\Promise.reject(new Error('second-checkpoint-marker'));
    );
    try testing.expectEqual(@as(u32, 1), first_log.count);
    try testing.expect(!first_log.handled[0]);
    try testing.expect(std.mem.indexOf(u8, first_log.text(0), "first-checkpoint-marker") != null or
        std.mem.indexOf(u8, first_log.text(0), "second-checkpoint-marker") != null);
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 1), first_log.count);
    engine.destroy(id);
    first_alive = false;

    try testing.expect(engine.create(id, .{}));
    defer {
        _ = promise.setRejectionTracker(id, null, null);
        engine.destroy(id);
    }
    try engine.testing.setNow(id, 1000);
    var second_log = RejectionLog{};
    if (!install(id, &second_log)) return;
    try helpers.evalOk(id, "Promise.reject(new Error('reused-checkpoint-marker'));");
    try testing.expectEqual(@as(u32, 1), second_log.count);
    try testing.expect(!second_log.handled[0]);
    try testing.expect(std.mem.indexOf(u8, second_log.text(0), "reused-checkpoint-marker") != null);
    try testing.expectEqual(@as(u32, 1), first_log.count);
}

test "Hermes rejection: budget-interrupted microtask drain defers reporting until catch runs" {
    if (comptime backend.active_backend != .hermes) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var log = RejectionLog{};
    if (!install(id, &log)) return error.RejectionTrackerUnavailable;
    defer _ = promise.setRejectionTracker(id, null, null);
    value_api.registerFunction(id, null, "__set_short_pending_job_limit__", &setShortPendingJobLimit);

    try helpers.evalOk(id,
        \\globalThis.__pending_rejection = Promise.reject(new Error('pending-until-drained'));
        \\queueMicrotask(function () { globalThis.__pending_limit_armed = __set_short_pending_job_limit__(); });
        \\queueMicrotask(function () {
        \\  const end = Date.now() + 30;
        \\  while (Date.now() < end) {}
        \\});
        \\queueMicrotask(function () {
        \\  globalThis.__pending_rejection.catch(function () { globalThis.__pending_catch_ran = true; });
        \\});
    );
    try testing.expectEqual(@as(u32, 0), log.count);

    try testing.expect(runtime_control.setExecutionTimeLimit(id, 0));
    try helpers.expectEvalEquals(id, "globalThis.__pending_limit_armed", "true");
    try helpers.evalOk(id, "void 0;");
    try helpers.expectEvalEquals(id, "globalThis.__pending_catch_ran", "true");
    try testing.expectEqual(@as(u32, 0), log.count);
}

test "Hermes rejection: tracker unregister during reason formatting suppresses stale callback" {
    if (comptime backend.active_backend != .hermes) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var log = RejectionLog{};
    if (!install(id, &log)) return error.RejectionTrackerUnavailable;
    defer _ = promise.setRejectionTracker(id, null, null);
    value_api.registerFunction(id, null, "__unregister_rejection_tracker__", &unregisterRejectionTracker);

    try helpers.evalOk(id,
        \\Promise.reject(Object.defineProperty({}, 'message', {
        \\  get() {
        \\    __unregister_rejection_tracker__();
        \\    return 'unregistered-during-formatting';
        \\  }
        \\}));
    );
    try testing.expectEqual(@as(u32, 0), log.count);
}

test "rejection: replaced Error that throws does not break unhandled reporting" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var log = RejectionLog{};
            // JSC has no host rejection tracker. Skip the assertions; the test still has to compile on that backend.
            if (!install(id, &log)) return;
            defer _ = promise.setRejectionTracker(id, null, null);

            // `toString` calls the replaced Error while the host formats the unhandled reason. That throw must not assert or recurse.
            try helpers.evalOk(id,
                \\globalThis.Error = function () { throw "broken-error"; };
                \\globalThis.__rej = Promise.reject({
                \\  toString: function () { return new Error("during-report"); }
                \\});
            );
            engine.runEventLoopOnce(id);

            // The tracker may run once, or give up when `Error` throws. Either way the report must not recurse.
            try testing.expect(log.count <= 2);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "rejection: timer callback rejection is reported before teardown and tracker is clean after ID reuse" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var first_instance_alive = true;
    defer if (first_instance_alive) {
        // Keep the callback userdata valid until the tracker is unregistered on failure paths. The success path intentionally destroys while the tracker is still installed.
        _ = promise.setRejectionTracker(id, null, null);
        engine.destroy(id);
    };

    var log = RejectionLog{};
    if (!install(id, &log)) return;

    try helpers.evalOk(
        id,
        "setTimeout(function () { Promise.reject(new Error('timer-rejection-marker')); }, 0);",
    );

    var attempts: u32 = 0;
    while (attempts < 200 and log.count == 0) : (attempts += 1) {
        engine.runEventLoopOnce(id);
        if (log.count == 0) io.sleepMs(5);
    }

    try testing.expectEqual(@as(u32, 1), log.count);
    // Keep draining after the first report so a duplicate notification cannot hide behind the loop's early-exit condition.
    var extra_drains: u32 = 0;
    while (extra_drains < 5) : (extra_drains += 1) {
        engine.runEventLoopOnce(id);
        io.sleepMs(1);
    }
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expect(!log.handled[0]);
    try testing.expect(std.mem.indexOf(u8, log.text(0), "timer-rejection-marker") != null);

    // Do not unregister the tracker first: teardown must release it while its userdata is valid, after the timer callback has reported.
    engine.destroy(id);
    try testing.expect(engine.getContext(id) == null);
    first_instance_alive = false;

    try testing.expect(engine.create(id, .{}));
    defer {
        _ = promise.setRejectionTracker(id, null, null);
        engine.destroy(id);
    }

    var second_log = RejectionLog{};
    if (!install(id, &second_log)) return;
    try helpers.evalOk(id, "Promise.reject(new Error('reused-id-rejection-marker'));");

    try testing.expectEqual(@as(u32, 1), second_log.count);
    try testing.expect(!second_log.handled[0]);
    try testing.expect(std.mem.indexOf(u8, second_log.text(0), "reused-id-rejection-marker") != null);
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expect(std.mem.indexOf(u8, log.text(0), "timer-rejection-marker") != null);
    try testing.expect(std.mem.indexOf(u8, log.text(0), "reused-id-rejection-marker") == null);
}

test "rejection: a timer callback that catches its own rejection reports nothing" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var log = RejectionLog{};
            if (!install(id, &log)) return;
            defer _ = promise.setRejectionTracker(id, null, null);

            try helpers.evalOk(id,
                \\globalThis.__timerRan = 0;
                \\globalThis.__caught = 0;
                \\setTimeout(function () {
                \\    globalThis.__timerRan = 1;
                \\    Promise.reject(new Error('timer-caught')).catch(function () { globalThis.__caught = 1; });
                \\}, 0);
            );

            // Keep draining past the point the callback has run, so a late notification cannot hide behind an early exit.
            var attempts: u32 = 0;
            while (attempts < 200) : (attempts += 1) {
                engine.runEventLoopOnce(id);
                const ran = try helpers.evalInt(id, "globalThis.__timerRan + globalThis.__caught");
                if (ran == 2) break;
                io.sleepMs(5);
            }
            try helpers.expectEvalEquals(id, "globalThis.__timerRan + ',' + globalThis.__caught", "1,1");
            var extra: u32 = 0;
            while (extra < 5) : (extra += 1) {
                engine.runEventLoopOnce(id);
                io.sleepMs(1);
            }
            try testing.expectEqual(@as(u32, 0), log.count);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}
