const std = @import("std");
const js_event_loop = @import("js_event_loop");
const zev = @import("zev");

const native_sync = js_event_loop.native_sync;
const testing = std.testing;
const CompleteStatus = @typeInfo(@TypeOf(native_sync.complete)).@"fn".return_type.?;

test "native sync: tightening a blocked wait to a future deadline wakes it" {
    const Gate = struct {
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        waiting: bool = false,
        completed: ?native_sync.Completed = null,

        fn observer(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.waiting = true;
            self.changed.broadcast();
        }
        fn wait(self: *@This(), request: *native_sync.Started) void {
            const result = native_sync.wait(request.request);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.completed = result;
            self.changed.broadcast();
        }
    };

    inline for ([_]bool{ false, true }, 0..) |bulk, index| {
        const instance_id: i32 = @intCast(3100 + index);
        var started = native_sync.start(instance_id) orelse return error.OutOfMemory;
        defer native_sync.finish(started.id, started.request);
        native_sync.tightenDeadline(started.request, zev.monotonicMilliseconds() + 1_000);
        var gate = Gate{};
        defer gate.changed.deinit();
        defer gate.mutex.deinit();
        native_sync.test_only.setWaitObserver(Gate.observer, &gate);
        defer native_sync.test_only.setWaitObserver(null, null);
        const waiter = try std.Thread.spawn(.{}, Gate.wait, .{ &gate, &started });
        defer waiter.join();

        gate.mutex.lock();
        while (!gate.waiting) gate.changed.wait(&gate.mutex);
        gate.mutex.unlock();
        const started_at = zev.monotonicMilliseconds();
        if (bulk) {
            native_sync.tightenDeadlinesForInstance(instance_id, started_at + 50);
        } else {
            native_sync.tightenDeadline(started.request, started_at + 50);
        }

        gate.mutex.lock();
        while (gate.completed == null) gate.changed.wait(&gate.mutex);
        const elapsed_ms = zev.monotonicMilliseconds() - started_at;
        const completed = gate.completed.?;
        gate.mutex.unlock();
        try testing.expectEqual(native_sync.Outcome.timeout, completed.outcome);
        try testing.expect(elapsed_ms < 500);
    }
}

test "native sync: cancelling a blocked wait wakes it" {
    const Gate = struct {
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        waiting: bool = false,
        outcome: ?native_sync.Outcome = null,

        fn observer(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.waiting = true;
            self.changed.broadcast();
        }
        fn wait(self: *@This(), request: *native_sync.Started) void {
            const result = native_sync.wait(request.request);
            self.mutex.lock();
            defer self.mutex.unlock();
            self.outcome = result.outcome;
            self.changed.broadcast();
        }
    };

    var started = native_sync.start(3105) orelse return error.OutOfMemory;
    defer native_sync.finish(started.id, started.request);
    var gate = Gate{};
    defer gate.changed.deinit();
    defer gate.mutex.deinit();
    native_sync.test_only.setWaitObserver(Gate.observer, &gate);
    defer native_sync.test_only.setWaitObserver(null, null);
    const waiter = try std.Thread.spawn(.{}, Gate.wait, .{ &gate, &started });
    defer waiter.join();
    gate.mutex.lock();
    while (!gate.waiting) gate.changed.wait(&gate.mutex);
    gate.mutex.unlock();
    native_sync.cancelForInstance(3105);
    gate.mutex.lock();
    while (gate.outcome == null) gate.changed.wait(&gate.mutex);
    const outcome = gate.outcome.?;
    gate.mutex.unlock();
    try testing.expectEqual(native_sync.Outcome.cancelled, outcome);
}

test "native sync: both deadline tightening APIs time out a completed result" {
    const direct = native_sync.start(3101) orelse return error.OutOfMemory;
    defer native_sync.finish(direct.id, direct.request);
    try testing.expectEqual(native_sync.complete(direct.id, .exception, .utf8_string, "{\"error\":true}"), .ok);
    native_sync.tightenDeadline(direct.request, 0);
    const direct_result = native_sync.wait(direct.request);
    try testing.expectEqual(native_sync.Outcome.timeout, direct_result.outcome);
    try testing.expect(direct_result.payload == null);

    const bulk = native_sync.start(3102) orelse return error.OutOfMemory;
    defer native_sync.finish(bulk.id, bulk.request);
    try testing.expectEqual(native_sync.complete(bulk.id, .ok, .utf8_string, "{\"value\":1}"), .ok);
    native_sync.tightenDeadlinesForInstance(3102, 0);
    const bulk_result = native_sync.wait(bulk.request);
    try testing.expectEqual(native_sync.Outcome.timeout, bulk_result.outcome);
    try testing.expect(bulk_result.payload == null);
}

test "native sync: a result returned by wait stays fixed until finish" {
    const direct = native_sync.start(3103) orelse return error.OutOfMemory;
    defer native_sync.finish(direct.id, direct.request);
    try testing.expectEqual(native_sync.complete(direct.id, .ok, .utf8_string, "direct"), .ok);
    const direct_result = native_sync.wait(direct.request);
    try testing.expectEqual(native_sync.Outcome.ok, direct_result.outcome);
    try testing.expectEqualStrings("direct", direct_result.payload.?);
    native_sync.tightenDeadline(direct.request, 0);
    try testing.expectEqualStrings("direct", direct_result.payload.?);
    const direct_after_tighten = native_sync.wait(direct.request);
    try testing.expectEqual(native_sync.Outcome.ok, direct_after_tighten.outcome);
    try testing.expectEqual(direct_result.payload.?.ptr, direct_after_tighten.payload.?.ptr);
    try testing.expectEqualStrings("direct", direct_after_tighten.payload.?);

    const bulk = native_sync.start(3104) orelse return error.OutOfMemory;
    defer native_sync.finish(bulk.id, bulk.request);
    try testing.expectEqual(native_sync.complete(bulk.id, .exception, .utf8_string, "bulk"), .ok);
    const bulk_result = native_sync.wait(bulk.request);
    try testing.expectEqual(native_sync.Outcome.exception, bulk_result.outcome);
    try testing.expectEqualStrings("bulk", bulk_result.payload.?);
    native_sync.tightenDeadlinesForInstance(3104, 0);
    try testing.expectEqualStrings("bulk", bulk_result.payload.?);
    const bulk_after_tighten = native_sync.wait(bulk.request);
    try testing.expectEqual(native_sync.Outcome.exception, bulk_after_tighten.outcome);
    try testing.expectEqual(bulk_result.payload.?.ptr, bulk_after_tighten.payload.?.ptr);
    try testing.expectEqualStrings("bulk", bulk_after_tighten.payload.?);
}

test "scheduler: a sync wait in each browser turn phase stops that turn and a later turn resumes" {
    const Stage = enum { prepare, task, checkpoint, none };
    const Probe = struct {
        scheduler: *js_event_loop.Scheduler,
        stage: Stage,
        events: [8]Stage = undefined,
        event_count: usize = 0,
        wait: ?js_event_loop.Scheduler.SyncWait = null,

        fn record(self: *@This(), stage: Stage) void {
            self.events[self.event_count] = stage;
            self.event_count += 1;
            if (self.stage == stage) self.wait = self.scheduler.beginSyncWait();
        }
        fn prepare(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.prepare);
        }
        fn task(context: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            var queued_task = self.scheduler.beginQueuedTask() orelse return false;
            self.record(.task);
            _ = queued_task.end();
            return true;
        }
        fn checkpoint(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.record(.checkpoint);
        }
    };
    const hooks = js_event_loop.Scheduler.TurnHooks{
        .context = undefined,
        .prepare_native_events = Probe.prepare,
        .run_one_task = Probe.task,
        .checkpoint = Probe.checkpoint,
    };

    const stages = [_]Stage{ .prepare, .task, .checkpoint };
    inline for (stages) |stage| {
        var scheduler = js_event_loop.Scheduler{};
        var probe = Probe{ .scheduler = &scheduler, .stage = stage };
        var staged_hooks = hooks;
        staged_hooks.context = &probe;
        try testing.expectEqual(stage != .prepare, scheduler.runTurn(staged_hooks));
        const expected_count: usize = switch (stage) {
            .prepare => 1,
            .task => 2,
            .checkpoint => 3,
            .none => unreachable,
        };
        try testing.expectEqual(expected_count, probe.event_count);
        try testing.expect(!scheduler.runTurn(staged_hooks));
        try testing.expectEqual(expected_count, probe.event_count);
        probe.wait.?.end();
        probe.wait = null;
        probe.event_count = 0;
        probe.stage = .none;
        try testing.expect(scheduler.runTurn(staged_hooks));
        try testing.expectEqual(@as(usize, 3), probe.event_count);
        try testing.expectEqual(Stage.prepare, probe.events[0]);
        try testing.expectEqual(Stage.task, probe.events[1]);
        try testing.expectEqual(Stage.checkpoint, probe.events[2]);
    }
}

test "scheduler: an idle turn does not run a microtask checkpoint" {
    const Probe = struct {
        scheduler: *js_event_loop.Scheduler,
        source_attempts: usize = 0,
        checkpoint_count: usize = 0,
        checkpoint_started: bool = false,

        fn prepare(_: ?*anyopaque) void {}
        fn noTask(context: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.source_attempts += 1;
            return false;
        }
        fn checkpoint(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.checkpoint_count += 1;
            var guard = self.scheduler.beginCheckpoint() orelse return;
            self.checkpoint_started = true;
            guard.end();
        }
    };

    var scheduler = js_event_loop.Scheduler{};
    var probe = Probe{ .scheduler = &scheduler };
    try testing.expect(!scheduler.runTurn(.{
        .context = &probe,
        .prepare_native_events = Probe.prepare,
        .run_one_task = Probe.noTask,
        .checkpoint = Probe.checkpoint,
    }));
    try testing.expectEqual(@as(usize, 4), probe.source_attempts);
    try testing.expectEqual(@as(usize, 0), probe.checkpoint_count);
    try testing.expect(!probe.checkpoint_started);
}

test "scheduler: abandoned and implicit backend drain state is restored" {
    var scheduler = js_event_loop.Scheduler{};
    var checkpoint = scheduler.beginCheckpoint() orelse return error.MissingCheckpoint;
    try testing.expect(scheduler.beginBackendDrain());
    scheduler.endBackendDrain();
    checkpoint.end();
    try testing.expect(scheduler.allowsQueuedWork());

    try testing.expect(scheduler.consumeBackendDrain());
    scheduler.endBackendDrain();
    try testing.expect(scheduler.allowsQueuedWork());
    var task = scheduler.beginQueuedTask() orelse return error.MissingTask;
    _ = task.end();
}

test "scheduler: debugger control end and backend drain permit are idempotent" {
    var scheduler = js_event_loop.Scheduler{};
    var control = scheduler.beginDebuggerControl() orelse return error.MissingDebuggerControl;
    control.end();
    control.end();
    try testing.expectEqual(@as(usize, 0), scheduler.execution_depth);
    try testing.expect(!scheduler.debugger_control_active);

    var checkpoint = scheduler.beginCheckpoint() orelse return error.MissingCheckpoint;
    defer checkpoint.end();
    try testing.expect(scheduler.beginBackendDrain());
    try testing.expect(!scheduler.beginBackendDrain());
    scheduler.endBackendDrain();
}

test "host wake: two concurrent changes wait for an active notification without retaining old userdata" {
    const wake = js_event_loop.host_wake;
    const State = struct {
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        old_calls: usize = 0,
        callback_entered: bool = false,
        release_callback: bool = false,
        waiters: usize = 0,
        waiter_ids: [2]std.Thread.Id = undefined,
        block_callbacks: bool = false,

        fn oldHandler(_: c_int, userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.old_calls += 1;
            if (!self.block_callbacks) return;
            self.callback_entered = true;
            self.changed.broadcast();
            while (!self.release_callback) self.changed.wait(&self.mutex);
        }
        fn observer(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            const thread_id = std.Thread.getCurrentId();
            for (self.waiter_ids[0..self.waiters]) |other_id| {
                if (other_id == thread_id) return;
            }
            std.debug.assert(self.waiters < self.waiter_ids.len);
            self.waiter_ids[self.waiters] = thread_id;
            self.waiters += 1;
            self.changed.broadcast();
        }
    };
    const Change = struct {
        fn drop() void {
            wake.drop(3201);
        }
        fn notify() void {
            wake.notify(3201);
        }
    };

    var state = State{};
    defer state.changed.deinit();
    defer state.mutex.deinit();
    try wake.set(3201, State.oldHandler, &state);
    defer wake.drop(3201);
    wake.test_only.setWaitObserver(State.observer, &state);
    defer wake.test_only.setWaitObserver(null, null);

    state.mutex.lock();
    state.block_callbacks = true;
    state.mutex.unlock();
    const active = try std.Thread.spawn(.{}, Change.notify, .{});
    state.mutex.lock();
    while (!state.callback_entered) state.changed.wait(&state.mutex);
    state.mutex.unlock();

    const first_removal = std.Thread.spawn(.{}, Change.drop, .{}) catch |err| {
        state.mutex.lock();
        state.release_callback = true;
        state.changed.broadcast();
        state.mutex.unlock();
        active.join();
        return err;
    };
    const second_removal = std.Thread.spawn(.{}, Change.drop, .{}) catch |err| {
        state.mutex.lock();
        state.release_callback = true;
        state.changed.broadcast();
        state.mutex.unlock();
        active.join();
        first_removal.join();
        return err;
    };
    state.mutex.lock();
    while (state.waiters < 2) state.changed.wait(&state.mutex);
    state.block_callbacks = false;
    state.release_callback = true;
    state.changed.broadcast();
    state.mutex.unlock();
    active.join();
    first_removal.join();
    second_removal.join();

    wake.notify(3201);
    state.mutex.lock();
    defer state.mutex.unlock();
    try testing.expectEqual(@as(usize, 2), state.old_calls);
}

test "host wake: concurrent replacement and removal detach the active userdata" {
    const wake = js_event_loop.host_wake;
    const State = struct {
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        old_calls: usize = 0,
        callback_entered: bool = false,
        release_callback: bool = false,
        waiters: usize = 0,
        waiter_ids: [2]std.Thread.Id = undefined,

        fn oldHandler(_: c_int, userdata: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.old_calls += 1;
            if (self.old_calls == 1) return;
            self.callback_entered = true;
            self.changed.broadcast();
            while (!self.release_callback) self.changed.wait(&self.mutex);
        }
        fn replacementHandler(_: c_int, userdata: ?*anyopaque) callconv(.c) void {
            const calls: *usize = @ptrCast(@alignCast(userdata.?));
            calls.* += 1;
        }
        fn observer(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            const thread_id = std.Thread.getCurrentId();
            for (self.waiter_ids[0..self.waiters]) |other_id| if (other_id == thread_id) return;
            std.debug.assert(self.waiters < self.waiter_ids.len);
            self.waiter_ids[self.waiters] = thread_id;
            self.waiters += 1;
            self.changed.broadcast();
        }
    };
    const Change = struct {
        fn replace(calls: *usize) void {
            wake.set(3204, State.replacementHandler, calls) catch unreachable;
        }
        fn drop() void {
            wake.drop(3204);
        }
        fn notify() void {
            wake.notify(3204);
        }
    };

    var state = State{};
    defer state.changed.deinit();
    defer state.mutex.deinit();
    var replacement_calls: usize = 0;
    try wake.set(3204, State.oldHandler, &state);
    defer wake.drop(3204);
    wake.test_only.setWaitObserver(State.observer, &state);
    defer wake.test_only.setWaitObserver(null, null);
    const active = try std.Thread.spawn(.{}, Change.notify, .{});
    state.mutex.lock();
    while (!state.callback_entered) state.changed.wait(&state.mutex);
    state.mutex.unlock();
    const replacement = std.Thread.spawn(.{}, Change.replace, .{&replacement_calls}) catch |err| {
        state.mutex.lock();
        state.release_callback = true;
        state.changed.broadcast();
        state.mutex.unlock();
        active.join();
        return err;
    };
    const removal = std.Thread.spawn(.{}, Change.drop, .{}) catch |err| {
        state.mutex.lock();
        state.release_callback = true;
        state.changed.broadcast();
        state.mutex.unlock();
        active.join();
        replacement.join();
        return err;
    };
    state.mutex.lock();
    while (state.waiters < 2) state.changed.wait(&state.mutex);
    state.release_callback = true;
    state.changed.broadcast();
    state.mutex.unlock();
    active.join();
    replacement.join();
    removal.join();
    wake.notify(3204);
    state.mutex.lock();
    defer state.mutex.unlock();
    try testing.expectEqual(@as(usize, 2), state.old_calls);
}

test "native sync: completion holding a temporary reference survives owner finish" {
    const Gate = struct {
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        entered: bool = false,
        release: bool = false,
        status: ?CompleteStatus = null,

        fn observer(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.entered = true;
            self.changed.broadcast();
            while (!self.release) self.changed.wait(&self.mutex);
        }
        fn complete(self: *@This(), id: u64) void {
            const status = native_sync.complete(id, .ok, .utf8_string, "finished-owner");
            self.mutex.lock();
            defer self.mutex.unlock();
            self.status = status;
            self.changed.broadcast();
        }
    };

    const request = native_sync.start(3202) orelse return error.OutOfMemory;
    var finished = false;
    errdefer if (!finished) native_sync.finish(request.id, request.request);
    var gate = Gate{};
    defer gate.changed.deinit();
    defer gate.mutex.deinit();
    native_sync.test_only.setCompleteObserver(Gate.observer, &gate);
    defer native_sync.test_only.setCompleteObserver(null, null);
    const worker = try std.Thread.spawn(.{}, Gate.complete, .{ &gate, request.id });
    gate.mutex.lock();
    while (!gate.entered) gate.changed.wait(&gate.mutex);
    gate.mutex.unlock();

    native_sync.finish(request.id, request.request);
    finished = true;
    gate.mutex.lock();
    gate.release = true;
    gate.changed.broadcast();
    gate.mutex.unlock();
    worker.join();
    gate.mutex.lock();
    defer gate.mutex.unlock();
    try testing.expectEqual(@as(?CompleteStatus, .ok), gate.status);
    try testing.expectEqual(@as(CompleteStatus, .stale), native_sync.complete(request.id, .ok, .utf8_string, "late"));
}

test "native sync: cancel winning before a gated completion makes that completion stale" {
    const Gate = struct {
        mutex: zev.Mutex = .{},
        changed: zev.Condition = .init,
        release: bool = false,
        status: ?CompleteStatus = null,

        fn complete(self: *@This(), id: u64) void {
            self.mutex.lock();
            while (!self.release) self.changed.wait(&self.mutex);
            self.mutex.unlock();
            const status = native_sync.complete(id, .ok, .utf8_string, "late");
            self.mutex.lock();
            defer self.mutex.unlock();
            self.status = status;
            self.changed.broadcast();
        }
    };
    const request = native_sync.start(3203) orelse return error.OutOfMemory;
    defer native_sync.finish(request.id, request.request);
    var gate = Gate{};
    defer gate.changed.deinit();
    defer gate.mutex.deinit();
    const worker = try std.Thread.spawn(.{}, Gate.complete, .{ &gate, request.id });
    native_sync.cancel(request.id);
    gate.mutex.lock();
    gate.release = true;
    gate.changed.broadcast();
    while (gate.status == null) gate.changed.wait(&gate.mutex);
    gate.mutex.unlock();
    worker.join();
    try testing.expectEqual(native_sync.Outcome.cancelled, native_sync.wait(request.request).outcome);
    try testing.expectEqual(@as(?CompleteStatus, .stale), gate.status);
}

test "native sync: typed complete preserves kind through wait" {
    const started = native_sync.start(3201) orelse return error.OutOfMemory;
    defer native_sync.finish(started.id, started.request);
    const binary = [_]u8{ 9, 8, 7 };
    try testing.expectEqual(native_sync.complete(started.id, .ok, .bytes, &binary), .ok);
    const result = native_sync.wait(started.request);
    try testing.expectEqual(native_sync.Outcome.ok, result.outcome);
    try testing.expectEqual(native_sync.PayloadKind.bytes, result.kind);
    try testing.expectEqualSlices(u8, &binary, result.payload.?);
}
