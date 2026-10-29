const std = @import("std");
const js_event_loop = @import("js_event_loop");
const zev = @import("zev");

test "driver hides manual ticks behind engine integration" {
    try std.testing.expect(!@hasDecl(js_event_loop.Driver, "runOnce"));
    try std.testing.expect(@TypeOf(js_event_loop.Driver.integration.runOne) == fn (*js_event_loop.Driver, js_event_loop.Driver.Hooks) void);
}

test "driver handles stay closed after destruction or before initialization" {
    var unopened_timer: js_event_loop.Timer = .{};
    try std.testing.expectError(error.Closed, unopened_timer.reserve());
    try std.testing.expectError(error.Closed, unopened_timer.startAt(0));
    try std.testing.expectError(error.Closed, unopened_timer.startAfter(0));
    try std.testing.expect(!unopened_timer.cancel());
    unopened_timer.close();
    var unopened_notifier: js_event_loop.Notifier = .{};
    try std.testing.expect(!unopened_notifier.notify());
    unopened_notifier.close();

    var timer: js_event_loop.Timer = .{};
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    timer.init(driver, null, struct {
        fn callback(_: ?*anyopaque, _: *js_event_loop.Timer) void {}
    }.callback);
    driver.destroy();
    defer timer.close();
    try std.testing.expectError(error.Closed, timer.startAfter(0));
}

test "driver runs due native timers without a host clock" {
    const Probe = struct {
        fired: usize = 0,

        fn timer(context: ?*anyopaque, _: *js_event_loop.Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.fired += 1;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };

    var probe = Probe{};
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(driver.now());
    _ = js_event_loop.Driver.testing.runOnce(driver, .{ .context = &probe, .run_one_task = Probe.runTask, .checkpoint = Probe.checkpoint, .next_task_deadline = Probe.nextDeadline });
    try std.testing.expectEqual(@as(usize, 1), probe.fired);
}

test "driver returns the earlier native or host deadline" {
    const Probe = struct {
        deadline: u64 = 0,

        fn timer(_: ?*anyopaque, _: *js_event_loop.Timer) void {}
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(context: ?*anyopaque) ?u64 {
            return (@as(*@This(), @ptrCast(@alignCast(context.?)))).deadline;
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, null, Probe.timer);
    defer timer.close();
    const now = driver.now();
    try timer.startAt(now + 50);
    var probe = Probe{ .deadline = now + 20 };
    const next = js_event_loop.Driver.testing.runOnce(driver, .{ .context = &probe, .run_one_task = Probe.runTask, .checkpoint = Probe.checkpoint, .next_task_deadline = Probe.nextDeadline });
    try std.testing.expectEqual(probe.deadline, next.?);
}

test "attached driver schedules deadlines, merges wakes, and cancels on detach" {
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        schedules: usize = 0,
        cancels: usize = 0,
        delay: u64 = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,

        fn schedule(context: ?*anyopaque, delay_ms: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.schedules += 1;
            self.delay = delay_ms;
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancels += 1;
            self.task = null;
            self.task_context = null;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{ .context = null, .run_one_task = runTask, .checkpoint = checkpoint, .next_task_deadline = nextDeadline });
        }
        fn runScheduled(self: *@This()) void {
            const task = self.task orelse return;
            const context = self.task_context;
            self.task = null;
            self.task_context = null;
            task(context);
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
    try std.testing.expectEqual(@as(usize, 1), fixture.schedules);
    try std.testing.expectEqual(@as(u64, 0), fixture.delay);
    fixture.runScheduled();

    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, null, struct {
        fn callback(_: ?*anyopaque, _: *js_event_loop.Timer) void {}
    }.callback);
    defer timer.close();
    try timer.startAfter(1_000);
    try std.testing.expectEqual(@as(usize, 2), fixture.schedules);
    try std.testing.expectEqual(@as(u64, 0), fixture.delay);
    fixture.runScheduled();
    try std.testing.expectEqual(@as(usize, 3), fixture.schedules);
    try std.testing.expect(fixture.delay > 0);

    driver.wake();
    driver.wake();
    try std.testing.expectEqual(@as(usize, 4), fixture.schedules);
    try std.testing.expectEqual(@as(u64, 0), fixture.delay);
    driver.detach();
    try std.testing.expectEqual(@as(usize, 1), fixture.cancels);
    try std.testing.expect(!driver.isAttached());
}

test "runFor zero executes one turn" {
    const Probe = struct {
        tasks: usize = 0,
        fn task(context: ?*anyopaque, source: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (source != .host_script) return false;
            self.tasks += 1;
            return true;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };
    var probe = Probe{};
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    try driver.runFor(.{ .context = &probe, .run_one_task = Probe.task, .checkpoint = Probe.checkpoint, .next_task_deadline = Probe.nextDeadline }, 0);
    try std.testing.expectEqual(@as(usize, 1), probe.tasks);
}

test "runFor rejects reentrant scheduler phases" {
    const Probe = struct {
        fn task(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };
    const hooks: js_event_loop.Driver.Hooks = .{ .context = null, .run_one_task = Probe.task, .checkpoint = Probe.checkpoint, .next_task_deadline = Probe.nextDeadline };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();

    var execution = driver.scheduler.beginExecution();
    try std.testing.expectError(error.AlreadyRunning, driver.runFor(hooks, 0));
    execution.end();

    var wait = driver.scheduler.beginSyncWait();
    try std.testing.expectError(error.AlreadyRunning, driver.runFor(hooks, 0));
    wait.end();

    var checkpoint_guard = driver.scheduler.beginCheckpoint() orelse return error.MissingCheckpoint;
    try std.testing.expectError(error.AlreadyRunning, driver.runFor(hooks, 0));
    checkpoint_guard.end();

    const TurnProbe = struct {
        driver: *js_event_loop.Driver,
        error_seen: ?js_event_loop.Driver.Error = null,
        fn prepare(_: ?*anyopaque) void {}
        fn task(context: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runFor(hooks, 0) catch |err| {
                self.error_seen = err;
            };
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
    };
    var turn = TurnProbe{ .driver = driver };
    _ = driver.scheduler.runTurn(.{ .context = &turn, .prepare_native_events = TurnProbe.prepare, .run_one_task = TurnProbe.task, .checkpoint = TurnProbe.checkpoint });
    try std.testing.expectEqual(error.AlreadyRunning, turn.error_seen.?);
}

test "attach reports a rejected initial platform schedule" {
    const Host = struct {
        accepted: bool,
        cancels: usize = 0,
        fn schedule(context: ?*anyopaque, _: u64, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.accepted;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancels += 1;
        }
        fn drive(_: ?*anyopaque) void {}
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var rejected = Host{ .accepted = false };
    try std.testing.expectError(error.ScheduleFailed, driver.attach(.{ .context = &rejected, .schedule = Host.schedule, .cancel = Host.cancel }, Host.drive, null));
    try std.testing.expect(!driver.isAttached());
    try std.testing.expectEqual(error.ScheduleFailed, driver.lastError().?);
    try std.testing.expectEqual(@as(usize, 1), rejected.cancels);
    driver.detach();
    try std.testing.expectEqual(@as(usize, 1), rejected.cancels);
    var accepted = Host{ .accepted = true };
    try driver.attach(.{ .context = &accepted, .schedule = Host.schedule, .cancel = Host.cancel }, Host.drive, null);
    try std.testing.expect(driver.isAttached());
    try std.testing.expect(driver.lastError() == null);
    driver.detach();
    try std.testing.expectEqual(@as(usize, 1), accepted.cancels);
}

test "attached scheduling failures stay visible and stop later turns" {
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        reject_at: usize = 0,
        schedules: usize = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,
        before_calls: usize = 0,

        fn schedule(context: ?*anyopaque, _: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.schedules += 1;
            if (self.reject_at == self.schedules) return false;
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(_: ?*anyopaque) callconv(.c) void {}
        fn before(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.before_calls += 1;
            return true;
        }
        fn taskHook(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn deadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{ .context = self, .before_turn = before, .run_one_task = taskHook, .checkpoint = checkpoint, .next_task_deadline = deadline });
        }
        fn fire(self: *@This()) void {
            const task = self.task orelse return;
            const context = self.task_context;
            self.task = null;
            self.task_context = null;
            task(context);
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
    fixture.fire();
    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, null, struct {
        fn callback(_: ?*anyopaque, _: *js_event_loop.Timer) void {}
    }.callback);
    defer timer.close();
    try timer.startAfter(1_000);
    fixture.reject_at = 3;
    fixture.fire();
    try std.testing.expectEqual(error.ScheduleFailed, driver.lastError().?);
    try std.testing.expect(driver.isAttached());
    const before_calls = fixture.before_calls;
    driver.runAttached(.{ .context = &fixture, .before_turn = Fixture.before, .run_one_task = Fixture.taskHook, .checkpoint = Fixture.checkpoint, .next_task_deadline = Fixture.deadline });
    try std.testing.expectEqual(before_calls, fixture.before_calls);
    try std.testing.expectError(error.ScheduleFailed, driver.runFor(.{ .context = &fixture, .before_turn = Fixture.before, .run_one_task = Fixture.taskHook, .checkpoint = Fixture.checkpoint, .next_task_deadline = Fixture.deadline }, 0));
    driver.detach();

    const foreign_driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer foreign_driver.destroy();
    var foreign = Fixture{ .driver = foreign_driver };
    try foreign_driver.attach(.{ .context = &foreign, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &foreign);
    foreign.fire();
    foreign.reject_at = 2;
    foreign_driver.wake();
    try std.testing.expectEqual(error.ScheduleFailed, foreign_driver.lastError().?);
    try std.testing.expect(foreign_driver.isAttached());
    foreign_driver.detach();
}

test "an idle one-shot turn ignores a prior blocking stop and does not finish a rejected turn" {
    const Probe = struct {
        finished: usize = 0,
        fn task(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn finish(context: ?*anyopaque) void {
            (@as(*@This(), @ptrCast(@alignCast(context.?)))).finished += 1;
        }
    };
    var probe = Probe{};
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    driver.requestStop();
    var execution = driver.scheduler.beginExecution();
    _ = js_event_loop.Driver.testing.runOnce(driver, .{ .context = &probe, .run_one_task = Probe.task, .checkpoint = Probe.checkpoint, .finish_turn = Probe.finish, .next_task_deadline = Probe.nextDeadline });
    execution.end();
    try std.testing.expectEqual(@as(usize, 0), probe.finished);
    _ = js_event_loop.Driver.testing.runOnce(driver, .{ .context = &probe, .run_one_task = Probe.task, .checkpoint = Probe.checkpoint, .finish_turn = Probe.finish, .next_task_deadline = Probe.nextDeadline });
    try std.testing.expectEqual(@as(usize, 1), probe.finished);
}

test "suspend keeps timers registered and blocks turns until resume catch-up" {
    const Probe = struct {
        fired: usize = 0,
        fn timer(context: ?*anyopaque, _: *js_event_loop.Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.fired += 1;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };

    var probe = Probe{};
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    const hooks: js_event_loop.Driver.Hooks = .{
        .context = &probe,
        .run_one_task = Probe.runTask,
        .checkpoint = Probe.checkpoint,
        .next_task_deadline = Probe.nextDeadline,
    };

    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, &probe, Probe.timer);
    defer timer.close();
    try timer.startAt(10);

    driver.suspendScheduling();
    try std.testing.expect(driver.isSuspended());
    try std.testing.expect(timer.isActive());

    // Advancing past the deadline must not dispatch while suspended.
    _ = js_event_loop.Driver.testing.advance(driver, hooks, 50);
    try std.testing.expectEqual(@as(usize, 0), probe.fired);
    try std.testing.expect(timer.isActive());

    driver.resumeScheduling();
    try std.testing.expect(!driver.isSuspended());
    _ = js_event_loop.Driver.testing.advance(driver, hooks, 50);
    try std.testing.expectEqual(@as(usize, 1), probe.fired);
}

test "attached suspend cancels Host schedule; wake stays dirty until resume" {
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        schedules: usize = 0,
        cancels: usize = 0,
        turns: usize = 0,
        delay: u64 = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,
        fired: usize = 0,

        fn schedule(context: ?*anyopaque, delay_ms: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.schedules += 1;
            self.delay = delay_ms;
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancels += 1;
            self.task = null;
            self.task_context = null;
        }
        fn timer(context: ?*anyopaque, _: *js_event_loop.Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.fired += 1;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn before(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.turns += 1;
            return true;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{
                .context = self,
                .before_turn = before,
                .run_one_task = runTask,
                .checkpoint = checkpoint,
                .next_task_deadline = nextDeadline,
            });
        }
        fn runScheduled(self: *@This()) void {
            const task = self.task orelse return;
            const context = self.task_context;
            self.task = null;
            self.task_context = null;
            task(context);
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    driver.test_now = 1_000;
    var fixture = Fixture{ .driver = driver };
    try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
    try std.testing.expectEqual(@as(usize, 1), fixture.schedules);
    fixture.runScheduled();

    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, &fixture, Fixture.timer);
    defer timer.close();
    try timer.startAt(2_000);
    try std.testing.expect(fixture.schedules >= 2);
    const schedules_before_suspend = fixture.schedules;
    const cancels_before = fixture.cancels;

    driver.suspendScheduling();
    try std.testing.expect(driver.isSuspended());
    try std.testing.expect(driver.isAttached());
    try std.testing.expectEqual(cancels_before + 1, fixture.cancels);
    try std.testing.expect(fixture.task == null);
    try std.testing.expect(timer.isActive());

    // Time passes and foreign wakes arrive while suspended: no Host schedule, no fire.
    driver.test_now = 5_000;
    driver.wake();
    driver.wake();
    try std.testing.expectEqual(schedules_before_suspend, fixture.schedules);
    try std.testing.expectEqual(@as(usize, 0), fixture.fired);
    try std.testing.expect(timer.isActive());

    const turns_before = fixture.turns;
    driver.runAttached(.{
        .context = &fixture,
        .before_turn = Fixture.before,
        .run_one_task = Fixture.runTask,
        .checkpoint = Fixture.checkpoint,
        .next_task_deadline = Fixture.nextDeadline,
    });
    try std.testing.expectEqual(turns_before, fixture.turns);

    driver.resumeScheduling();
    try std.testing.expect(!driver.isSuspended());
    try std.testing.expect(driver.isAttached());
    try std.testing.expect(fixture.schedules > schedules_before_suspend);
    try std.testing.expectEqual(@as(u64, 0), fixture.delay);
    fixture.runScheduled();
    try std.testing.expectEqual(@as(usize, 1), fixture.fired);
    try std.testing.expect(!timer.isActive());

    // suspend remains distinct from detach: attach relation can be dropped while suspended stays sticky until resume.
    driver.suspendScheduling();
    try std.testing.expect(driver.isAttached());
    try std.testing.expect(driver.isSuspended());
    driver.detach();
    try std.testing.expect(!driver.isAttached());
    try std.testing.expect(driver.isSuspended());
    driver.resumeScheduling();
    try std.testing.expect(!driver.isSuspended());
}

test "suspend does not clear stop or destroy semantics" {
    const Probe = struct {
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    driver.suspendScheduling();
    try std.testing.expect(driver.isSuspended());
    driver.requestStop();
    // Idle one-shot turns still ignore a prior blocking stop (existing contract); suspended also gates.
    _ = js_event_loop.Driver.testing.runOnce(driver, .{
        .context = null,
        .run_one_task = Probe.runTask,
        .checkpoint = Probe.checkpoint,
        .next_task_deadline = Probe.nextDeadline,
    });
    driver.resumeScheduling();
    try std.testing.expect(!driver.isSuspended());
}

test "attached soft Host cancel survives suspend resume (SDK hard-cancel regression)" {
    // Mimics shipping SDK Hosts after the soft-cancel fix: cancel drops pending work only.
    // With the old SDK bug (cancel permanently deactivated the binding), resume latched ScheduleFailed.
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        alive: bool = true,
        hard_cancel: bool = false,
        schedules: usize = 0,
        cancels: usize = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,
        fired: usize = 0,

        fn schedule(context: ?*anyopaque, delay_ms: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            _ = delay_ms;
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.alive) return false;
            self.schedules += 1;
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancels += 1;
            self.task = null;
            self.task_context = null;
            // Old SDK bug class: permanent teardown inside cancel.
            if (self.hard_cancel) self.alive = false;
        }
        fn timer(context: ?*anyopaque, _: *js_event_loop.Timer) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.fired += 1;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{
                .context = self,
                .run_one_task = runTask,
                .checkpoint = checkpoint,
                .next_task_deadline = nextDeadline,
            });
        }
        fn runScheduled(self: *@This()) void {
            const task = self.task orelse return;
            const ctx = self.task_context;
            self.task = null;
            self.task_context = null;
            task(ctx);
        }
    };

    // Soft cancel path (correct SDKs): suspend with pending schedule → resume schedules again → timer fires.
    {
        const driver = try js_event_loop.Driver.create(std.testing.allocator);
        defer driver.destroy();
        driver.test_now = 1_000;
        var fixture = Fixture{ .driver = driver, .hard_cancel = false };
        try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
        fixture.runScheduled();

        var timer: js_event_loop.Timer = undefined;
        timer.init(driver, &fixture, Fixture.timer);
        defer timer.close();
        try timer.startAt(2_000);
        try std.testing.expect(fixture.task != null);

        driver.suspendScheduling();
        try std.testing.expect(fixture.cancels >= 1);
        try std.testing.expect(fixture.alive);
        try std.testing.expect(fixture.task == null);

        driver.test_now = 5_000;
        driver.resumeScheduling();
        try std.testing.expect(driver.lastError() == null);
        try std.testing.expect(fixture.alive);
        try std.testing.expect(fixture.task != null);
        fixture.runScheduled();
        try std.testing.expectEqual(@as(usize, 1), fixture.fired);
        driver.detach();
    }

    // Hard cancel path documents the pre-fix SDK bug: resume schedule fails → ScheduleFailed.
    {
        const driver = try js_event_loop.Driver.create(std.testing.allocator);
        defer driver.destroy();
        driver.test_now = 1_000;
        var fixture = Fixture{ .driver = driver, .hard_cancel = true };
        try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
        fixture.runScheduled();

        var timer: js_event_loop.Timer = undefined;
        timer.init(driver, &fixture, Fixture.timer);
        defer timer.close();
        try timer.startAt(2_000);

        driver.suspendScheduling();
        try std.testing.expect(!fixture.alive);
        driver.test_now = 5_000;
        driver.resumeScheduling();
        try std.testing.expect(driver.lastError() != null);
        try std.testing.expectEqual(js_event_loop.Driver.Error.ScheduleFailed, driver.lastError().?);
        driver.detach();
    }
}

test "attached stop during suspend then resume clears stop latch" {
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        schedules: usize = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,

        fn schedule(context: ?*anyopaque, _: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.schedules += 1;
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.task = null;
            self.task_context = null;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{
                .context = self,
                .run_one_task = runTask,
                .checkpoint = checkpoint,
                .next_task_deadline = nextDeadline,
            });
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
    const schedules_after_attach = fixture.schedules;

    driver.suspendScheduling();
    driver.requestStop();
    try std.testing.expect(driver.isSuspended());

    // Without the resume fix, stop_requested would make scheduleAttachedUnlocked a no-op forever.
    driver.resumeScheduling();
    try std.testing.expect(!driver.isSuspended());
    try std.testing.expect(driver.lastError() == null);
    try std.testing.expect(fixture.schedules > schedules_after_attach);
    driver.detach();
}

test "late schedule race soft-cancel runs outside state_mutex" {
    // R3 P1: when Host.schedule returns after suspend/detach raced, soft-cancel must not hold state_mutex.
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        entered_schedule: std.atomic.Value(bool) = .init(false),
        allow_schedule_return: std.atomic.Value(bool) = .init(false),
        block_next_schedule: std.atomic.Value(bool) = .init(false),
        cancel_saw_unlocked: ?bool = null,
        cancels: usize = 0,
        schedules: usize = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,

        fn schedule(context: ?*anyopaque, _: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.schedules += 1;
            if (self.block_next_schedule.swap(false, .seq_cst)) {
                self.entered_schedule.store(true, .seq_cst);
                while (!self.allow_schedule_return.load(.seq_cst)) std.Thread.yield() catch {};
            }
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.cancels += 1;
            // If cancel ran under state_mutex, tryLock would fail.
            self.cancel_saw_unlocked = self.driver.state_mutex.tryLock();
            if (self.cancel_saw_unlocked.?) self.driver.state_mutex.unlock();
            self.task = null;
            self.task_context = null;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{
                .context = self,
                .run_one_task = runTask,
                .checkpoint = checkpoint,
                .next_task_deadline = nextDeadline,
            });
        }
        fn runScheduled(self: *@This()) void {
            const task = self.task orelse return;
            const ctx = self.task_context;
            self.task = null;
            self.task_context = null;
            task(ctx);
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
    fixture.runScheduled();

    fixture.block_next_schedule.store(true, .seq_cst);
    const Suspender = struct {
        fn run(f: *Fixture) void {
            while (!f.entered_schedule.load(.seq_cst)) std.Thread.yield() catch {};
            f.driver.suspendScheduling();
            f.allow_schedule_return.store(true, .seq_cst);
        }
    };
    const thread = try std.Thread.spawn(.{}, Suspender.run, .{&fixture});
    driver.wake();
    thread.join();

    try std.testing.expect(driver.isSuspended());
    try std.testing.expect(fixture.cancel_saw_unlocked != null);
    try std.testing.expect(fixture.cancel_saw_unlocked.?);
    try std.testing.expect(fixture.cancels >= 1);
    driver.resumeScheduling();
    driver.detach();
}

test "detach waits for in-flight Host.schedule before cancel" {
    // R5 P2: Host may free context after detach's cancel returns. detach drains host_ops so
    // schedule (+ race soft-cancel) finish first; Host ops never run under state_mutex.
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        entered_schedule: std.atomic.Value(bool) = .init(false),
        allow_schedule_return: std.atomic.Value(bool) = .init(false),
        block_next_schedule: std.atomic.Value(bool) = .init(false),
        context_alive: std.atomic.Value(bool) = .init(true),
        race_cancel_order: std.atomic.Value(usize) = .init(0),
        detach_cancel_order: std.atomic.Value(usize) = .init(0),
        next_order: std.atomic.Value(usize) = .init(1),
        cancels: usize = 0,
        schedules: usize = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,

        fn schedule(context: ?*anyopaque, _: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.context_alive.load(.seq_cst)) @panic("Host.schedule after context freed");
            self.schedules += 1;
            if (self.block_next_schedule.swap(false, .seq_cst)) {
                self.entered_schedule.store(true, .seq_cst);
                while (!self.allow_schedule_return.load(.seq_cst)) std.Thread.yield() catch {};
            }
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.context_alive.load(.seq_cst)) @panic("Host.cancel after context freed");
            self.cancels += 1;
            const ord = self.next_order.fetchAdd(1, .seq_cst);
            // After a blocked schedule has started, first cancel is race soft-cancel; later is detach.
            if (self.entered_schedule.load(.seq_cst) and self.race_cancel_order.load(.seq_cst) == 0) {
                self.race_cancel_order.store(ord, .seq_cst);
            } else if (self.race_cancel_order.load(.seq_cst) != 0 and self.detach_cancel_order.load(.seq_cst) == 0) {
                self.detach_cancel_order.store(ord, .seq_cst);
                self.context_alive.store(false, .seq_cst);
            }
            self.task = null;
            self.task_context = null;
        }
        fn runTask(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
            return false;
        }
        fn checkpoint(_: ?*anyopaque) void {}
        fn nextDeadline(_: ?*anyopaque) ?u64 {
            return null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(.{
                .context = self,
                .run_one_task = runTask,
                .checkpoint = checkpoint,
                .next_task_deadline = nextDeadline,
            });
        }
        fn runScheduled(self: *@This()) void {
            const task = self.task orelse return;
            const ctx = self.task_context;
            self.task = null;
            self.task_context = null;
            task(ctx);
        }
    };

    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    try driver.attach(.{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel }, Fixture.drive, &fixture);
    fixture.runScheduled();

    fixture.block_next_schedule.store(true, .seq_cst);
    const Detacher = struct {
        fn run(f: *Fixture) void {
            while (!f.entered_schedule.load(.seq_cst)) std.Thread.yield() catch {};
            f.driver.detach();
        }
    };
    const Releaser = struct {
        fn run(f: *Fixture) void {
            while (!f.entered_schedule.load(.seq_cst)) std.Thread.yield() catch {};
            // Brief pause so detacher can enter host_ops wait (no std.Thread.sleep in this Zig).
            var spins: usize = 0;
            while (spins < 10000) : (spins += 1) std.Thread.yield() catch {};
            f.allow_schedule_return.store(true, .seq_cst);
        }
    };
    const t_detach = try std.Thread.spawn(.{}, Detacher.run, .{&fixture});
    const t_release = try std.Thread.spawn(.{}, Releaser.run, .{&fixture});
    driver.wake();
    t_detach.join();
    t_release.join();

    try std.testing.expect(fixture.race_cancel_order.load(.seq_cst) != 0);
    try std.testing.expect(fixture.detach_cancel_order.load(.seq_cst) != 0);
    try std.testing.expect(fixture.race_cancel_order.load(.seq_cst) < fixture.detach_cancel_order.load(.seq_cst));
    try std.testing.expect(!fixture.context_alive.load(.seq_cst));
}

const CountingProbe = struct {
    turns: usize = 0,
    fn prepare(context: ?*anyopaque, _: u64) bool {
        (@as(*@This(), @ptrCast(@alignCast(context.?)))).turns += 1;
        return true;
    }
    fn task(_: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource, _: u64) bool {
        return false;
    }
    fn checkpoint(_: ?*anyopaque) void {}
    fn nextDeadline(_: ?*anyopaque) ?u64 {
        return null;
    }
    fn hooks(self: *@This()) js_event_loop.Driver.Hooks {
        return .{ .context = self, .prepare = prepare, .run_one_task = task, .checkpoint = checkpoint, .next_task_deadline = nextDeadline };
    }
};

test "a stop requested before a blocking run applies to the next run exactly once" {
    var probe = CountingProbe{};
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    driver.requestStop();
    try driver.runFor(probe.hooks(), 50);
    try std.testing.expectEqual(@as(usize, 0), probe.turns);
    try driver.runFor(probe.hooks(), 0);
    try std.testing.expectEqual(@as(usize, 1), probe.turns);
}

test "a stop that ends an active run is consumed by that run" {
    const Stopper = struct {
        probe: CountingProbe = .{},
        driver: *js_event_loop.Driver,
        fn prepare(context: ?*anyopaque, _: u64) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.probe.turns += 1;
            self.driver.requestStop();
            return true;
        }
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var stopper = Stopper{ .driver = driver };
    try driver.run(.{ .context = &stopper, .prepare = Stopper.prepare, .run_one_task = CountingProbe.task, .checkpoint = CountingProbe.checkpoint, .next_task_deadline = CountingProbe.nextDeadline });
    try std.testing.expectEqual(@as(usize, 1), stopper.probe.turns);
    var probe = CountingProbe{};
    try driver.runFor(probe.hooks(), 0);
    try std.testing.expectEqual(@as(usize, 1), probe.turns);
}

test "a stop requested while attached freezes driving until the next attach and never leaks into a later run" {
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        probe: CountingProbe = .{},
        schedules: usize = 0,
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,
        fn schedule(context: ?*anyopaque, _: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.schedules += 1;
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.task = null;
            self.task_context = null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(self.probe.hooks());
        }
        fn runScheduled(self: *@This()) void {
            const task = self.task orelse return;
            const task_context = self.task_context;
            self.task = null;
            self.task_context = null;
            task(task_context);
        }
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    const host = js_event_loop.Driver.Host{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel };
    try driver.attach(host, Fixture.drive, &fixture);
    fixture.runScheduled();
    try std.testing.expectEqual(@as(usize, 1), fixture.probe.turns);

    driver.requestStop();
    driver.wake();
    fixture.runScheduled();
    try std.testing.expectEqual(@as(usize, 1), fixture.probe.turns);
    try std.testing.expect(fixture.task == null);
    try std.testing.expect(driver.isAttached());

    driver.detach();
    var blocking = CountingProbe{};
    try driver.runFor(blocking.hooks(), 0);
    try std.testing.expectEqual(@as(usize, 1), blocking.turns);

    try driver.attach(host, Fixture.drive, &fixture);
    fixture.runScheduled();
    try std.testing.expectEqual(@as(usize, 2), fixture.probe.turns);
}

test "a rejected turn reports no pending work until the host wakes the driver" {
    const Probe = struct {
        fn reject(_: ?*anyopaque) bool {
            return false;
        }
        fn ready(_: ?*anyopaque) ?u64 {
            return 0;
        }
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    const hooks = js_event_loop.Driver.Hooks{ .context = null, .before_turn = Probe.reject, .run_one_task = CountingProbe.task, .checkpoint = CountingProbe.checkpoint, .next_task_deadline = Probe.ready };
    try std.testing.expectEqual(@as(?u64, null), js_event_loop.Driver.testing.runOnce(driver, hooks));
}

const BlockingRun = struct {
    driver: *js_event_loop.Driver,
    turns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    callbacks: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn prepare(context: ?*anyopaque, _: u64) bool {
        _ = (@as(*@This(), @ptrCast(@alignCast(context.?)))).turns.fetchAdd(1, .seq_cst);
        return true;
    }
    fn hooks(self: *@This()) js_event_loop.Driver.Hooks {
        return .{ .context = self, .prepare = prepare, .run_one_task = CountingProbe.task, .checkpoint = CountingProbe.checkpoint, .next_task_deadline = CountingProbe.nextDeadline };
    }
    fn body(self: *@This()) void {
        self.driver.run(self.hooks()) catch self.failed.store(true, .seq_cst);
        self.finished.store(true, .seq_cst);
    }
    fn onNotifier(context: ?*anyopaque, _: *js_event_loop.Notifier) void {
        _ = (@as(*@This(), @ptrCast(@alignCast(context.?)))).callbacks.fetchAdd(1, .seq_cst);
    }
    fn onTimer(context: ?*anyopaque, _: *js_event_loop.Timer) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        _ = self.callbacks.fetchAdd(1, .seq_cst);
        self.driver.requestStop();
    }
    fn reached(counter: *const std.atomic.Value(usize), target: usize) bool {
        var waited: u64 = 0;
        while (counter.load(.seq_cst) < target) : (waited += 1) {
            if (waited >= 5_000) return false;
            zev.sleepMilliseconds(1);
        }
        return true;
    }
    fn finishedInTime(self: *const @This()) bool {
        var waited: u64 = 0;
        while (!self.finished.load(.seq_cst)) : (waited += 1) {
            if (waited >= 5_000) return false;
            zev.sleepMilliseconds(1);
        }
        return true;
    }
};

test "a blocking run idles and ends promptly on a request from another thread" {
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var run = BlockingRun{ .driver = driver };
    const thread = try std.Thread.spawn(.{}, BlockingRun.body, .{&run});
    try std.testing.expect(BlockingRun.reached(&run.turns, 1));
    zev.sleepMilliseconds(20);
    try std.testing.expect(!run.finished.load(.seq_cst));
    try std.testing.expect(run.turns.load(.seq_cst) <= 2);
    driver.requestStop();
    const ended = run.finishedInTime();
    if (!ended) driver.requestStop();
    thread.join();
    try std.testing.expect(ended);
    try std.testing.expect(!run.failed.load(.seq_cst));
}

test "a stop requested at any moment around a blocking run starts never hangs it" {
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var round: usize = 0;
    while (round < 200) : (round += 1) {
        var run = BlockingRun{ .driver = driver };
        const thread = try std.Thread.spawn(.{}, BlockingRun.body, .{&run});
        if (round % 3 == 1) std.Thread.yield() catch {};
        if (round % 3 == 2) zev.sleepMilliseconds(1);
        driver.requestStop();
        const ended = run.finishedInTime();
        if (!ended) driver.requestStop();
        thread.join();
        try std.testing.expect(ended);
        try std.testing.expect(!run.failed.load(.seq_cst));
    }
}

test "every notification from another thread wakes an idle blocking run" {
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var run = BlockingRun{ .driver = driver };
    var notifier: js_event_loop.Notifier = undefined;
    notifier.init(driver, &run, BlockingRun.onNotifier);
    defer notifier.close();
    const thread = try std.Thread.spawn(.{}, BlockingRun.body, .{&run});
    var delivered = true;
    var round: usize = 1;
    while (round <= 300 and delivered) : (round += 1) {
        _ = notifier.notify();
        delivered = BlockingRun.reached(&run.callbacks, round);
    }
    driver.requestStop();
    const ended = run.finishedInTime();
    if (!ended) driver.requestStop();
    thread.join();
    try std.testing.expect(delivered);
    try std.testing.expect(ended);
}

test "a blocking run sleeps until a native timer is due and then fires it" {
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var run = BlockingRun{ .driver = driver };
    var timer: js_event_loop.Timer = undefined;
    timer.init(driver, &run, BlockingRun.onTimer);
    defer timer.close();
    const started = zev.monotonicMilliseconds();
    try timer.startAfter(40);
    const thread = try std.Thread.spawn(.{}, BlockingRun.body, .{&run});
    const ended = run.finishedInTime();
    if (!ended) driver.requestStop();
    thread.join();
    try std.testing.expect(ended);
    try std.testing.expectEqual(@as(usize, 1), run.callbacks.load(.seq_cst));
    try std.testing.expect(zev.monotonicMilliseconds() - started >= 40);
    try std.testing.expect(run.turns.load(.seq_cst) <= 4);
}

test "a notification posted at the end of a turn still wakes the wait that follows it" {
    const Turn = struct {
        run: BlockingRun,
        notifier: js_event_loop.Notifier = undefined,
        posted: bool = false,
        fn nextDeadline(context: ?*anyopaque) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (!self.posted) {
                self.posted = true;
                _ = self.notifier.notify();
            }
            return null;
        }
        fn onNotifier(context: ?*anyopaque, _: *js_event_loop.Notifier) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            _ = self.run.callbacks.fetchAdd(1, .seq_cst);
            self.run.driver.requestStop();
        }
        fn body(self: *@This()) void {
            self.run.driver.run(.{ .context = self, .run_one_task = CountingProbe.task, .checkpoint = CountingProbe.checkpoint, .next_task_deadline = nextDeadline }) catch self.run.failed.store(true, .seq_cst);
            self.run.finished.store(true, .seq_cst);
        }
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var turn = Turn{ .run = .{ .driver = driver } };
    turn.notifier.init(driver, &turn, Turn.onNotifier);
    defer turn.notifier.close();
    const thread = try std.Thread.spawn(.{}, Turn.body, .{&turn});
    const ended = turn.run.finishedInTime();
    if (!ended) driver.requestStop();
    thread.join();
    try std.testing.expect(ended);
    try std.testing.expectEqual(@as(usize, 1), turn.run.callbacks.load(.seq_cst));
}

test "attach discards a stop requested while idle so the new attachment drives" {
    const Fixture = struct {
        driver: *js_event_loop.Driver,
        probe: CountingProbe = .{},
        task: ?*const fn (?*anyopaque) callconv(.c) void = null,
        task_context: ?*anyopaque = null,
        fn schedule(context: ?*anyopaque, _: u64, task: *const fn (?*anyopaque) callconv(.c) void, task_context: ?*anyopaque) callconv(.c) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.task = task;
            self.task_context = task_context;
            return true;
        }
        fn cancel(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.task = null;
            self.task_context = null;
        }
        fn drive(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.driver.runAttached(self.probe.hooks());
        }
    };
    const driver = try js_event_loop.Driver.create(std.testing.allocator);
    defer driver.destroy();
    var fixture = Fixture{ .driver = driver };
    const host = js_event_loop.Driver.Host{ .context = &fixture, .schedule = Fixture.schedule, .cancel = Fixture.cancel };
    driver.requestStop();
    try driver.attach(host, Fixture.drive, &fixture);
    const task = fixture.task orelse return error.NothingScheduled;
    task(fixture.task_context);
    try std.testing.expectEqual(@as(usize, 1), fixture.probe.turns);
    driver.detach();
}
