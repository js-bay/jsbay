//! Host promise-rejection tracker.
//!
//! QuickJS reports a rejection only after the current microtask drain, so a synchronous `.catch` (or a `.catch` attached by an earlier microtask in the same drain) is silent. A rejection nobody caught is reported once. Attaching `.catch` afterwards reports handled=true.
//!
//! JSC's public C API has no JS_SetHostPromiseRejectionTracker equivalent. `promise.setRejectionTracker` returns false there and these tests return without asserting. There is no fake tracker.

const std = @import("std");
const io = @import("../platform/io.zig");
const testing = std.testing;
const backend = @import("../backend.zig");
const types = @import("../types.zig");

const engine = @import("../engine.zig");
const promise = @import("../runtime/promise.zig");
const helpers = @import("test_helpers.zig");
const c_api = @import("../c_api.zig");
const api_value = @import("../abi/api_value.zig");

const max_events = 4;
const max_reason = 96;

const RejectionLog = struct {
    count: u32 = 0,
    handled: [max_events]bool = @splat(false),
    reason: [max_events][max_reason]u8 = @splat(@as([max_reason]u8, @splat(0))),
    reason_len: [max_events]u8 = @splat(0),

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

const ErrorLog = struct {
    count: u32 = 0,
    kind: types.ErrorKind = .async_uncaught,
    borrowed_promise: u64 = 0,
    borrowed_value: u64 = 0,
    promise: u64 = 0,
    value: u64 = 0,

    fn handler(event: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *ErrorLog = @ptrCast(@alignCast(userdata orelse return));
        self.count += 1;
        self.kind = event.kind;
        self.borrowed_promise = event.promise;
        self.borrowed_value = event.value;
        if (event.promise != 0) _ = c_api.jsbay_value_retain(event.promise, &self.promise);
        _ = c_api.jsbay_value_retain(event.value, &self.value);
    }
};

const InterruptAfterFirstError = struct {
    count: u32 = 0,

    fn handler(event: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *InterruptAfterFirstError = @ptrCast(@alignCast(userdata orelse return));
        self.count += 1;
        if (self.count == 1) _ = c_api.jsbay_engine_request_interrupt(event.instance_id);
    }
};

const EventCount = struct {
    count: u32 = 0,

    fn handler(_: *const types.ErrorEvent, userdata: ?*anyopaque) callconv(.c) void {
        const self: *EventCount = @ptrCast(@alignCast(userdata orelse return));
        self.count += 1;
    }
};

const LegacyInterruptAfterFirst = struct {
    count: u32 = 0,

    fn handler(instance_id: i32, _: bool, _: [*]const u8, _: usize, userdata: ?*anyopaque) callconv(.c) void {
        const self: *LegacyInterruptAfterFirst = @ptrCast(@alignCast(userdata orelse return));
        self.count += 1;
        if (self.count == 1) _ = c_api.jsbay_engine_request_interrupt(instance_id);
    }
};

test "error observer: retains rejection handles and reports late handling" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id, "globalThis.__observer_reason = { marker: 17 }; globalThis.__observer_promise = Promise.reject(globalThis.__observer_reason);");
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expectEqual(types.ErrorKind.unhandled_rejection, log.kind);
    try testing.expect(log.promise != 0);
    try testing.expect(log.value != 0);
    try testing.expect(api_value.instanceFor(log.borrowed_promise) == null);
    try testing.expect(api_value.instanceFor(log.borrowed_value) == null);
    try testing.expect(api_value.instanceFor(log.promise) != null);
    try testing.expect(api_value.instanceFor(log.value) != null);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(log.promise));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(log.value));

    try helpers.evalOk(id, "globalThis.__observer_promise.catch(function () {});");
    try testing.expectEqual(@as(u32, 2), log.count);
    try testing.expectEqual(types.ErrorKind.rejection_handled, log.kind);
    try testing.expect(log.promise != 0);
    try testing.expect(log.value != 0);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(log.promise));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(log.value));
}

test "error observer: same-turn catch stays quiet and unregister suppresses future reports" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    try helpers.evalOk(id, "Promise.reject({ quiet: true }).catch(function () {});");
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_set_error_observer(id, null, null));
    try helpers.evalOk(id, "Promise.reject({ ignored: true });");
    try testing.expectEqual(@as(u32, 0), log.count);
}

test "error observer: timer throw keeps the original object" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id, "setTimeout(function () { throw { marker: 73 }; }, 0);");
    var attempts: u32 = 0;
    while (attempts < 200 and log.count == 0) : (attempts += 1) {
        engine.runEventLoopOnce(id);
        if (log.count == 0) io.sleepMs(1);
    }
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expectEqual(types.ErrorKind.async_uncaught, log.kind);
    try testing.expectEqual(@as(u64, 0), log.promise);
    var marker: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_get(log.value, .{ .data = "marker".ptr, .len = "marker".len }, &marker, &exception));
    defer _ = c_api.jsbay_value_release(marker);
    var number: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_number(marker, &number));
    try testing.expectEqual(@as(f64, 73), number);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(log.value));
}

test "error observer: queueMicrotask throw keeps the original object" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id, "queueMicrotask(function () { throw { marker: 91 }; });");
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expectEqual(types.ErrorKind.async_uncaught, log.kind);
    try testing.expectEqual(@as(u64, 0), log.promise);
    var marker: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_get(log.value, .{ .data = "marker".ptr, .len = "marker".len }, &marker, &exception));
    defer _ = c_api.jsbay_value_release(marker);
    var number: f64 = 0;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_to_number(marker, &number));
    try testing.expectEqual(@as(f64, 91), number);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_value_release(log.value));
}

test "error observer: synchronous evaluation and interrupted timer stay quiet" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalErr(id, "throw { marker: 101 };");
    try testing.expectEqual(@as(u32, 0), log.count);
    try helpers.evalOk(id, "setTimeout(function () { throw { marker: 102 }; }, 0);");
    try testing.expect(c_api.jsbay_engine_request_interrupt(id));
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
}

test "error observer: interrupted rejection drain stays quiet until its catch runs" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id,
        \\setTimeout(function () {
        \\  globalThis.__observer_late_promise = Promise.reject({ marker: 111 });
        \\  queueMicrotask(function () { while (true) {} });
        \\}, 0);
    );
    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 20));
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 0));
    try helpers.evalOk(id, "globalThis.__observer_late_promise.catch(function () { globalThis.__observer_late_catch = 1; });");
    try helpers.expectEvalEquals(id, "globalThis.__observer_late_catch", "1");
    try testing.expectEqual(@as(u32, 0), log.count);
}

test "error observer: interrupted unhandled rejection is reported after recovery" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = ErrorLog{};
    const registered = c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id,
        \\setTimeout(function () {
        \\  Promise.reject({ marker: 112 });
        \\  queueMicrotask(function () { while (true) {} });
        \\}, 0);
    );
    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 20));
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 0), log.count);
    try testing.expect(c_api.jsbay_engine_set_execution_time_limit(id, 0));
    try helpers.evalOk(id, "void 0;");
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expectEqual(types.ErrorKind.unhandled_rejection, log.kind);
}

test "error observer: interrupt during a batch preserves unreported rejections" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var log = InterruptAfterFirstError{};
    const registered = c_api.jsbay_engine_set_error_observer(id, InterruptAfterFirstError.handler, &log);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);

    try helpers.evalOk(id, "setTimeout(function () { Promise.reject(1); Promise.reject(2); Promise.reject(3); }, 0);");
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 1), log.count);
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
    try helpers.evalOk(id, "void 0;");
    try testing.expectEqual(@as(u32, 3), log.count);
}

test "error observer: legacy interrupt does not hide the current typed event" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var typed = EventCount{};
    var legacy = LegacyInterruptAfterFirst{};
    const registered = c_api.jsbay_engine_set_error_observer(id, EventCount.handler, &typed);
    if (backend.active_backend == .jsc) {
        try testing.expectEqual(@as(c_int, 7), registered);
        return;
    }
    try testing.expectEqual(@as(c_int, 0), registered);
    defer _ = c_api.jsbay_engine_set_error_observer(id, null, null);
    try testing.expect(promise.setRejectionTracker(id, LegacyInterruptAfterFirst.handler, &legacy));
    defer _ = promise.setRejectionTracker(id, null, null);

    try helpers.evalOk(id, "setTimeout(function () { Promise.reject(1); Promise.reject(2); Promise.reject(3); }, 0);");
    engine.runEventLoopOnce(id);
    try testing.expectEqual(@as(u32, 1), typed.count);
    try testing.expectEqual(@as(u32, 1), legacy.count);
    try testing.expect(c_api.jsbay_engine_clear_interrupt(id));
    try helpers.evalOk(id, "void 0;");
    try testing.expectEqual(@as(u32, 3), typed.count);
    try testing.expectEqual(@as(u32, 3), legacy.count);
}

test "error observer: teardown-pending registration is rejected" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    @import("../runtime/instance_map.zig").markTeardownPending(id);
    try testing.expectEqual(@as(c_int, 4), c_api.jsbay_engine_set_error_observer(id, ErrorLog.handler, null));
}

test "rejection: synchronous catch is not reported" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var log = RejectionLog{};
            if (!install(id, &log)) return;
            defer _ = promise.setRejectionTracker(id, null, null);

            try helpers.evalOk(id, "Promise.reject(new Error('sync-catch')).catch(function () {});");
            engine.runEventLoopOnce(id);
            try testing.expectEqual(@as(u32, 0), log.count);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "rejection: catch attached in the same microtask drain is not reported" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var log = RejectionLog{};
            if (!install(id, &log)) return;
            defer _ = promise.setRejectionTracker(id, null, null);

            try helpers.evalOk(id,
                \\var p = Promise.reject(new Error('micro'));
                \\Promise.resolve().then(function () { p.catch(function () {}); });
            );
            try testing.expectEqual(@as(u32, 0), log.count);
        }
    }.run);
}

test "rejection: unhandled rejection is reported once, then handled" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            var log = RejectionLog{};
            if (!install(id, &log)) return;
            defer _ = promise.setRejectionTracker(id, null, null);

            try helpers.evalOk(id, "globalThis.__rej = Promise.reject(new Error('oops'));");
            try testing.expectEqual(@as(u32, 1), log.count);
            try testing.expect(!log.handled[0]);
            try testing.expect(std.mem.indexOf(u8, log.text(0), "oops") != null);

            try helpers.evalOk(id, "globalThis.__rej.catch(function () {});");
            try testing.expectEqual(@as(u32, 2), log.count);
            try testing.expect(log.handled[1]);
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
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
