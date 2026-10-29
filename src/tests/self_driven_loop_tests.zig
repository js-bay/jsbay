//! Public C API contracts for a self-driven JavaScript event loop.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const dispatch = @import("../runtime/dispatch.zig");
const helpers = @import("test_helpers.zig");
const zev = @import("zev");

const Api = struct {
    fn eval(id: i32, source: []const u8) !void {
        var value: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = "self-driven-loop.js".ptr, .len = "self-driven-loop.js".len }, null, &value, &exception));
        defer {
            if (value != 0) _ = c_api.jsbay_value_release(value);
            if (exception != 0) _ = c_api.jsbay_value_release(exception);
        }
    }

    fn bind(id: i32, name: []const u8, callback: *const fn (i32, ?*anyopaque, u64, usize, ?[*]const u64, *u64, *u64) callconv(.c) c_int, userdata: ?*anyopaque) !void {
        var function: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(id, .{ .data = name.ptr, .len = name.len }, callback, userdata, null, &function, &exception));
        defer _ = c_api.jsbay_value_release(function);
        try testing.expectEqual(@as(u64, 0), exception);
    }
};

const StopProbe = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn stop(id: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *StopProbe = @ptrCast(@alignCast(userdata.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        out_exception.* = 0;
        _ = c_api.jsbay_engine_stop_loop(id);
        return c_api.jsbay_value_undefined(id, out_value);
    }
};

const ReentrantRunProbe = struct {
    status: c_int = -1,

    fn run(id: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        self.status = c_api.jsbay_engine_run_loop(id);
        out_exception.* = 0;
        return c_api.jsbay_value_undefined(id, out_value);
    }
};

test "self-driven loop: run_loop rejects a native callback reentry and remains reusable" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var reentrant = ReentrantRunProbe{};
    var stop = StopProbe{};
    try Api.bind(id, "__rejectReentrantLoop", ReentrantRunProbe.run, &reentrant);
    try Api.bind(id, "__stopReusableLoop", StopProbe.stop, &stop);
    try Api.eval(id, "__rejectReentrantLoop(); globalThis.__outerLoopCallContinued = 1");
    try testing.expectEqual(@as(c_int, 2), reentrant.status);
    try Api.eval(id, "if (globalThis.__outerLoopCallContinued !== 1) throw new Error('outer evaluation stopped')");

    try Api.eval(id, "setTimeout(__stopReusableLoop, 0)");
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(@as(usize, 1), stop.calls.load(.seq_cst));
}

test "self-driven loop: run_loop fires timers and can stop from a native callback" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var probe: StopProbe = .{};
    try Api.bind(id, "__stopSelfDrivenLoop", StopProbe.stop, &probe);
    try Api.eval(id, "setTimeout(__stopSelfDrivenLoop, 1)");

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(@as(usize, 1), probe.calls.load(.seq_cst));
}

const PostedStop = struct {
    ready: zev.Waiter = .init,
    post_now: std.atomic.Value(bool) = .init(false),
    calls: std.atomic.Value(usize) = .init(0),

    fn readyCallback(_: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *PostedStop = @ptrCast(@alignCast(userdata.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.post_now.store(true, .seq_cst);
        self.ready.signal();
        out_value.* = 0;
        out_exception.* = 0;
        return 0;
    }
};

test "self-driven loop: a foreign dispatch wakes an otherwise idle loop" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var probe: PostedStop = .{};
    defer probe.ready.deinit();
    try Api.bind(id, "__selfDrivenReady", PostedStop.readyCallback, &probe);
    try Api.eval(id, "setTimeout(__selfDrivenReady, 0)");

    // The callback supplies the happens-before edge: the foreign post occurs only after the loop completed its first turn and returned to its idle wait.
    const Bridge = struct {
        fn run(instance: i32, state: *PostedStop) void {
            const seen = state.ready.generation();
            while (!state.post_now.load(.seq_cst)) {
                if (!state.ready.waitUntilChange(seen, 5_000)) return;
            }
            _ = dispatch.postTask(instance, .{ .ctx = null, .run = StopTask.run });
        }
        const StopTask = struct {
            fn run(_: ?*anyopaque) void {
                _ = c_api.jsbay_engine_stop_loop(stop_id);
            }
            var stop_id: i32 = 0;
        };
    };
    Bridge.StopTask.stop_id = id;
    const foreign = try std.Thread.spawn(.{}, Bridge.run, .{ id, &probe });
    defer foreign.join();

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(@as(usize, 1), probe.calls.load(.seq_cst));
}

const DestroyProbe = struct {
    calls: std.atomic.Value(usize) = .init(0),

    fn destroy(id: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *DestroyProbe = @ptrCast(@alignCast(userdata.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        out_value.* = 0;
        out_exception.* = 0;
        c_api.jsbay_engine_destroy(id);
        return 0;
    }
};

test "self-driven loop: destroy from a timer callback leaves no running loop" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var probe: DestroyProbe = .{};
    try Api.bind(id, "__destroySelfDrivenLoop", DestroyProbe.destroy, &probe);
    try Api.eval(id, "setTimeout(__destroySelfDrivenLoop, 0)");

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(@as(usize, 1), probe.calls.load(.seq_cst));
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));
}

test "self-driven loop: attachment is owner-only and excludes blocking runs" {
    const id = helpers.nextInstanceId();
    var platform: FakePlatform = .{};
    defer platform.deinit();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    try testing.expectEqual(@as(c_int, 4), c_api.jsbay_engine_attach_loop(id + 1, FakePlatform.schedule, FakePlatform.cancel, &platform));
    const Foreign = struct {
        fn attach(instance: i32, host: *FakePlatform, out: *c_int) void {
            out.* = c_api.jsbay_engine_attach_loop(instance, FakePlatform.schedule, FakePlatform.cancel, host);
        }
        fn detach(instance: i32, out: *c_int) void {
            out.* = c_api.jsbay_engine_detach_loop(instance);
        }
    };
    var status: c_int = 0;
    var foreign = try std.Thread.spawn(.{}, Foreign.attach, .{ id, &platform, &status });
    foreign.join();
    try testing.expectEqual(@as(c_int, 3), status);

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, FakePlatform.schedule, FakePlatform.cancel, &platform));
    try testing.expectEqual(@as(c_int, 2), c_api.jsbay_engine_run_loop(id));
    foreign = try std.Thread.spawn(.{}, Foreign.detach, .{ id, &status });
    foreign.join();
    try testing.expectEqual(@as(c_int, 3), status);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_detach_loop(id));
}

const FakePlatform = struct {
    const Task = struct {
        delay_ms: u64,
        task: *const fn (?*anyopaque) callconv(.c) void,
        data: ?*anyopaque,
        generation: u64,
    };

    mutex: zev.Mutex = .{},
    changed: zev.Waiter = .init,
    task: ?Task = null,
    generation: u64 = 0,
    schedule_count: usize = 0,
    cancel_count: usize = 0,

    fn deinit(self: *FakePlatform) void {
        self.changed.deinit();
        self.mutex.deinit();
    }

    fn schedule(userdata: ?*anyopaque, delay_ms: u64, task: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) callconv(.c) bool {
        const self: *FakePlatform = @ptrCast(@alignCast(userdata.?));
        self.mutex.lock();
        self.generation +%= 1;
        self.task = .{ .delay_ms = delay_ms, .task = task, .data = data, .generation = self.generation };
        self.schedule_count += 1;
        self.mutex.unlock();
        self.changed.signal();
        return true;
    }

    fn cancel(userdata: ?*anyopaque) callconv(.c) void {
        const self: *FakePlatform = @ptrCast(@alignCast(userdata.?));
        self.mutex.lock();
        self.generation +%= 1;
        self.task = null;
        self.cancel_count += 1;
        self.mutex.unlock();
        self.changed.signal();
    }

    fn takeNext(self: *FakePlatform) !Task {
        const seen = self.changed.generation();
        while (true) {
            self.mutex.lock();
            if (self.task) |task| {
                self.task = null;
                self.mutex.unlock();
                return task;
            }
            self.mutex.unlock();
            if (!self.changed.waitUntilChange(seen, 5_000)) return error.ScheduleMissing;
        }
    }

    fn runNextOnOwner(self: *FakePlatform) !void {
        const scheduled = try self.takeNext();
        self.runDequeuedOnOwner(scheduled);
    }

    fn runDequeuedOnOwner(self: *FakePlatform, scheduled: Task) void {
        zev.sleepMilliseconds(scheduled.delay_ms);
        self.mutex.lock();
        const still_current = self.generation == scheduled.generation;
        self.mutex.unlock();
        if (still_current) scheduled.task(scheduled.data);
    }
};

const RecordProbe = struct {
    calls: std.atomic.Value(usize) = .init(0),
    changed: zev.Waiter = .init,

    fn deinit(self: *RecordProbe) void {
        self.changed.deinit();
    }

    fn record(_: i32, userdata: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        const self: *RecordProbe = @ptrCast(@alignCast(userdata.?));
        _ = self.calls.fetchAdd(1, .seq_cst);
        self.changed.signal();
        out_value.* = 0;
        out_exception.* = 0;
        return 0;
    }
};

test "self-driven loop: attached platform replaces work, cancels on detach, and isolates id reuse" {
    const id = helpers.nextInstanceId();
    var first: FakePlatform = .{};
    defer first.deinit();
    var first_record: RecordProbe = .{};
    defer first_record.deinit();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, FakePlatform.schedule, FakePlatform.cancel, &first));
    try Api.bind(id, "__recordAttachedLoop", RecordProbe.record, &first_record);
    try Api.eval(id, "setTimeout(__recordAttachedLoop, 1)");
    while (first_record.calls.load(.seq_cst) != 1) try first.runNextOnOwner();
    try testing.expectEqual(@as(usize, 1), first_record.calls.load(.seq_cst));
    try testing.expect(first.schedule_count >= 1);

    try Api.eval(id, "setTimeout(__recordAttachedLoop, 1000)");
    const stale = try first.takeNext();
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_detach_loop(id));
    try testing.expect(first.cancel_count >= 1);
    c_api.jsbay_engine_destroy(id);

    // A platform may already have dequeued this callback when cancellation happens. Its owner queue must suppress it before it can touch a replacement instance that reuses the numeric id.
    first.runDequeuedOnOwner(stale);
    try testing.expectEqual(@as(usize, 1), first_record.calls.load(.seq_cst));

    var second: FakePlatform = .{};
    defer second.deinit();
    var second_record: RecordProbe = .{};
    defer second_record.deinit();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, FakePlatform.schedule, FakePlatform.cancel, &second));
    try Api.bind(id, "__recordAttachedLoop", RecordProbe.record, &second_record);
    try Api.eval(id, "setTimeout(__recordAttachedLoop, 1)");
    while (second_record.calls.load(.seq_cst) != 1) try second.runNextOnOwner();
    try testing.expectEqual(@as(usize, 1), second_record.calls.load(.seq_cst));
    try testing.expectEqual(@as(usize, 1), first_record.calls.load(.seq_cst));
}

test "self-driven loop: rejected platform wake is observable and still permits cleanup" {
    const Fixture = struct {
        reject: bool = false,
        task: ?c_api.LoopTask = null,
        data: ?*anyopaque = null,
        cancelled: bool = false,
        ran: bool = false,
        fn schedule(context: ?*anyopaque, _: u64, task: c_api.LoopTask, data: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.reject) return false;
            self.task = task;
            self.data = data;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancelled = true;
            self.task = null;
            self.data = null;
        }
        fn run(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.ran = true;
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var fixture: Fixture = .{};
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, Fixture.schedule, Fixture.cancel, &fixture));
    const initial = fixture.task orelse return error.NoInitialTask;
    fixture.task = null;
    initial(fixture.data);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_loop_status(id));
    fixture.reject = true;
    try testing.expect(dispatch.postTask(id, .{ .ctx = &fixture, .run = Fixture.run }));
    try testing.expectEqual(@as(c_int, 8), c_api.jsbay_engine_loop_status(id));
    var value: u64 = 0;
    try testing.expectEqual(@as(c_int, 8), c_api.jsbay_engine_global(id, &value));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expect(!fixture.ran);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_detach_loop(id));
    try testing.expect(fixture.cancelled);
}

test "self-driven loop: rejected attachment releases its platform context before returning" {
    const Fixture = struct {
        reject: bool = true,
        cancelled: usize = 0,
        fn schedule(context: ?*anyopaque, _: u64, _: c_api.LoopTask, _: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return !self.reject;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancelled += 1;
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var fixture: Fixture = .{};
    try testing.expectEqual(@as(c_int, 8), c_api.jsbay_engine_attach_loop(id, Fixture.schedule, Fixture.cancel, &fixture));
    try testing.expectEqual(@as(usize, 1), fixture.cancelled);
    try testing.expectEqual(@as(c_int, 8), c_api.jsbay_engine_loop_status(id));
    fixture.reject = false;
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, Fixture.schedule, Fixture.cancel, &fixture));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_loop_status(id));
    c_api.jsbay_engine_destroy(id);
    try testing.expectEqual(@as(usize, 2), fixture.cancelled);
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    c_api.jsbay_engine_destroy(id);
    try testing.expectEqual(@as(usize, 2), fixture.cancelled);
}

test "self-driven loop: suspend and resume keep state and remain distinct from stop" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    try testing.expect(!c_api.jsbay_engine_is_suspended(id));
    try testing.expect(c_api.jsbay_engine_suspend(id));
    try testing.expect(c_api.jsbay_engine_is_suspended(id));
    // Idempotent suspend.
    try testing.expect(c_api.jsbay_engine_suspend(id));
    try testing.expect(c_api.jsbay_engine_is_suspended(id));

    var stop = StopProbe{};
    try Api.bind(id, "__stopAfterResume", StopProbe.stop, &stop);
    try Api.eval(id, "setTimeout(__stopAfterResume, 0)");

    // Resume must not drop the queued timer; run_loop then fires it.
    try testing.expect(c_api.jsbay_engine_resume(id));
    try testing.expect(!c_api.jsbay_engine_is_suspended(id));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_run_loop(id));
    try testing.expectEqual(@as(usize, 1), stop.calls.load(.seq_cst));

    try testing.expect(!c_api.jsbay_engine_suspend(id + 1));
    try testing.expect(!c_api.jsbay_engine_is_suspended(id + 1));
}

test "self-driven loop: attached suspend cancels Host schedule without detaching" {
    const id = helpers.nextInstanceId();
    var platform: FakePlatform = .{};
    defer platform.deinit();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, FakePlatform.schedule, FakePlatform.cancel, &platform));
    try testing.expect(platform.task != null);
    const schedules_before = platform.schedule_count;
    const cancels_before = platform.cancel_count;

    try testing.expect(c_api.jsbay_engine_suspend(id));
    try testing.expect(c_api.jsbay_engine_is_suspended(id));
    try testing.expectEqual(cancels_before + 1, platform.cancel_count);
    try testing.expect(platform.task == null);

    // Registering a timer while suspended must not re-arm the platform schedule.
    try Api.eval(id, "setTimeout(() => {}, 1000)");
    try testing.expectEqual(schedules_before, platform.schedule_count);
    try testing.expect(platform.task == null);

    try testing.expect(c_api.jsbay_engine_resume(id));
    try testing.expect(!c_api.jsbay_engine_is_suspended(id));
    try testing.expect(platform.schedule_count > schedules_before);
    try testing.expect(platform.task != null);
    // Soft Host cancel must keep the loop healthy — hard cancel would latch LOOP_FAILED here.
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_loop_status(id));

    var stop = StopProbe{};
    try Api.bind(id, "__stopAfterAttachedResume", StopProbe.stop, &stop);
    try Api.eval(id, "setTimeout(__stopAfterAttachedResume, 0)");
    // Drain attached platform callbacks until stop runs (or timeout via schedule count bound).
    var spins: usize = 0;
    while (stop.calls.load(.seq_cst) == 0 and spins < 64) : (spins += 1) {
        try platform.runNextOnOwner();
    }
    try testing.expectEqual(@as(usize, 1), stop.calls.load(.seq_cst));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_loop_status(id));

    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_detach_loop(id));
}

test "self-driven loop: hard Host cancel on suspend latches LOOP_FAILED (SDK bug class)" {
    const HardPlatform = struct {
        alive: bool = true,
        pending: bool = false,
        generation: u64 = 0,
        schedule_count: usize = 0,
        cancel_count: usize = 0,

        fn schedule(userdata: ?*anyopaque, delay_ms: u64, task: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) callconv(.c) bool {
            _ = delay_ms;
            _ = task;
            _ = data;
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (!self.alive) return false;
            self.generation +%= 1;
            self.pending = true;
            self.schedule_count += 1;
            return true;
        }
        fn cancel(userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.generation +%= 1;
            self.pending = false;
            self.cancel_count += 1;
            self.alive = false; // pre-fix SDK permanent teardown
        }
    };

    const id = helpers.nextInstanceId();
    var platform: HardPlatform = .{};
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, HardPlatform.schedule, HardPlatform.cancel, &platform));
    try testing.expect(platform.pending);

    try testing.expect(c_api.jsbay_engine_suspend(id));
    try testing.expect(!platform.alive);
    try testing.expect(c_api.jsbay_engine_resume(id));
    try testing.expectEqual(@as(c_int, 8), c_api.jsbay_engine_loop_status(id)); // JSBAY_LOOP_FAILED
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_detach_loop(id));
}

test "self-driven loop: control plane refuses teardown_pending" {
    const instance_map = @import("../runtime/instance_map.zig");
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    instance_map.markTeardownPending(id);
    try testing.expect(!c_api.jsbay_engine_suspend(id));
    try testing.expect(!c_api.jsbay_engine_resume(id));
    try testing.expect(!c_api.jsbay_engine_is_suspended(id));
    try testing.expect(!c_api.jsbay_engine_stop_loop(id));

    c_api.jsbay_engine_destroy(id);
    try testing.expect(!c_api.jsbay_engine_suspend(id));
}

test "self-driven loop: destroy waits for in-flight control-plane lease" {
    const engine = @import("../engine.zig");
    const instance_map = @import("../runtime/instance_map.zig");
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));

    const Race = struct {
        id: i32,
        lease_held: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        destroy_started: std.atomic.Value(bool) = .init(false),
        destroy_done: std.atomic.Value(bool) = .init(false),

        fn holdLease(self: *@This()) void {
            const lease = instance_map.beginControlPlane(self.id) orelse return;
            self.lease_held.store(true, .seq_cst);
            while (!self.release.load(.seq_cst)) std.Thread.yield() catch {};
            lease.end();
        }

        fn destroy(self: *@This()) void {
            self.destroy_started.store(true, .seq_cst);
            engine.destroy(self.id);
            self.destroy_done.store(true, .seq_cst);
        }
    };

    var race: Race = .{ .id = id };
    const holder = try std.Thread.spawn(.{}, Race.holdLease, .{&race});
    while (!race.lease_held.load(.seq_cst)) std.Thread.yield() catch {};

    const destroyer = try std.Thread.spawn(.{}, Race.destroy, .{&race});
    while (!race.destroy_started.load(.seq_cst)) std.Thread.yield() catch {};
    var spins: usize = 0;
    while (spins < 2000) : (spins += 1) std.Thread.yield() catch {};
    try testing.expect(!race.destroy_done.load(.seq_cst));

    race.release.store(true, .seq_cst);
    holder.join();
    destroyer.join();
    try testing.expect(race.destroy_done.load(.seq_cst));
    try testing.expect(!c_api.jsbay_engine_suspend(id));
}
