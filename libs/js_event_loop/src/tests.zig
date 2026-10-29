const std = @import("std");
const js_event_loop = @import("js_event_loop");

test "a backend drain cannot recursively drain another pending job" {
    var scheduler = js_event_loop.Scheduler{};
    var checkpoint = scheduler.beginCheckpoint() orelse return error.MissingCheckpoint;
    defer checkpoint.end();
    try std.testing.expect(scheduler.beginBackendDrain());
    defer scheduler.endBackendDrain();
    try std.testing.expect(scheduler.consumeBackendDrain());
    try std.testing.expect(!scheduler.consumeBackendDrain());
}

test "synchronous native wait rejects queued work and reentrant checkpoints" {
    var scheduler = js_event_loop.Scheduler{};
    var wait = scheduler.beginSyncWait();
    defer wait.end();
    try std.testing.expect(scheduler.isSynchronouslyWaiting());
    try std.testing.expect(scheduler.beginQueuedTask() == null);
    try std.testing.expect(scheduler.beginCheckpoint() == null);
}

test "outer queued task admits one checkpoint after it returns" {
    var scheduler = js_event_loop.Scheduler{};
    var task = scheduler.beginQueuedTask() orelse return error.UnexpectedRejection;
    try std.testing.expect(scheduler.beginQueuedTask() == null);
    try std.testing.expect(scheduler.beginCheckpoint() == null);
    try std.testing.expect(task.end());
    var checkpoint = scheduler.beginCheckpoint() orelse return error.MissingCheckpoint;
    try std.testing.expect(scheduler.beginQueuedTask() == null);
    try std.testing.expect(scheduler.beginCheckpoint() == null);
    checkpoint.end();
    try std.testing.expect(scheduler.allowsQueuedWork());
}

test "ordinary JavaScript execution cannot reenter the queued scheduler" {
    var scheduler = js_event_loop.Scheduler{};
    var execution = scheduler.beginExecution();
    defer execution.end();
    try std.testing.expect(scheduler.beginQueuedTask() == null);
    try std.testing.expect(scheduler.beginCheckpoint() == null);
}

test "turn hook cannot reenter the same turn" {
    const Probe = struct {
        scheduler: *js_event_loop.Scheduler,
        calls: usize = 0,
        reentered: bool = true,
        fn task(context: ?*anyopaque, _: js_event_loop.Scheduler.TaskSource) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            var queued_task = self.scheduler.beginQueuedTask() orelse return false;
            self.reentered = self.scheduler.runTurn(.{ .context = self, .prepare_native_events = noop, .run_one_task = task, .checkpoint = noop });
            _ = queued_task.end();
            return true;
        }
        fn noop(_: ?*anyopaque) void {}
    };
    var scheduler = js_event_loop.Scheduler{};
    var probe = Probe{ .scheduler = &scheduler };
    try std.testing.expect(scheduler.runTurn(.{ .context = &probe, .prepare_native_events = Probe.noop, .run_one_task = Probe.task, .checkpoint = Probe.noop }));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(!probe.reentered);
}

test "turn admits one queued task only through the selected source" {
    const Probe = struct {
        scheduler: *js_event_loop.Scheduler,
        prepare_rejected: bool = false,
        second_task_rejected: bool = false,
        checkpoint_rejected: bool = false,
        finish_rejected: bool = false,
        candidates: usize = 0,

        fn prepare(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.prepare_rejected = self.scheduler.beginQueuedTask() == null;
        }
        fn task(context: ?*anyopaque, source: js_event_loop.Scheduler.TaskSource) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.candidates += 1;
            if (source == .host_script) {
                var empty = self.scheduler.beginQueuedTask() orelse return false;
                _ = empty.end();
                self.second_task_rejected = self.scheduler.beginQueuedTask() == null;
                return false;
            }
            if (source != .native_dispatch) return false;
            var queued_task = self.scheduler.beginQueuedTask() orelse return false;
            _ = queued_task.end();
            return true;
        }
        fn checkpoint(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.checkpoint_rejected = self.scheduler.beginQueuedTask() == null;
        }
        fn finish(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.finish_rejected = self.scheduler.beginQueuedTask() == null;
        }
    };

    var scheduler = js_event_loop.Scheduler{};
    var probe = Probe{ .scheduler = &scheduler };
    try std.testing.expect(scheduler.runTurn(.{
        .context = &probe,
        .prepare_native_events = Probe.prepare,
        .run_one_task = Probe.task,
        .checkpoint = Probe.checkpoint,
        .finish_task = Probe.finish,
    }));
    try std.testing.expect(probe.prepare_rejected);
    try std.testing.expect(probe.second_task_rejected);
    try std.testing.expect(probe.checkpoint_rejected);
    try std.testing.expect(probe.finish_rejected);
    try std.testing.expectEqual(@as(usize, 2), probe.candidates);
}

const native_sync = js_event_loop.native_sync;
const testing = std.testing;

test "paused debugger control preserves application and synchronous wait exclusion" {
    var scheduler = js_event_loop.Scheduler{};
    var script = scheduler.beginExecution();
    var control = scheduler.beginDebuggerControl() orelse return error.ControlRejected;
    try testing.expect(scheduler.beginDebuggerControl() == null);
    try testing.expect(scheduler.beginQueuedTask() == null);
    try testing.expect(scheduler.beginCheckpoint() == null);
    control.end();
    var wait = scheduler.beginSyncWait();
    try testing.expect(scheduler.beginDebuggerControl() == null);
    wait.end();
    try testing.expect(scheduler.beginQueuedTask() == null);
    script.end();
    try testing.expect(scheduler.allowsQueuedWork());
}

test "native completion wakes the owner without executing a JavaScript task" {
    const request = native_sync.start(1001) orelse return error.OutOfMemory;
    defer native_sync.finish(request.id, request.request);
    const Worker = struct {
        fn complete(id: u64) void {
            std.debug.assert(native_sync.complete(id, .ok, .utf8_string, "41") == .ok);
        }
    };
    const worker = try std.Thread.spawn(.{}, Worker.complete, .{request.id});
    defer worker.join();
    const result = native_sync.wait(request.request);
    try testing.expectEqual(native_sync.Outcome.ok, result.outcome);
    try testing.expectEqualStrings("41", result.payload.?);
    try testing.expect(native_sync.complete(request.id, .ok, .utf8_string, "42") == .stale);
}

test "cancelling native waits is isolated by environment and deadlines expire" {
    const first = native_sync.start(1002) orelse return error.OutOfMemory;
    defer native_sync.finish(first.id, first.request);
    const other = native_sync.start(1003) orelse return error.OutOfMemory;
    defer native_sync.finish(other.id, other.request);
    native_sync.cancelForInstance(1002);
    try testing.expectEqual(native_sync.Outcome.cancelled, native_sync.wait(first.request).outcome);
    try testing.expect(native_sync.complete(other.id, .ok, .utf8_string, "true") == .ok);
    try testing.expectEqual(native_sync.Outcome.ok, native_sync.wait(other.request).outcome);
    const expired = native_sync.start(1004) orelse return error.OutOfMemory;
    defer native_sync.finish(expired.id, expired.request);
    native_sync.tightenDeadline(expired.request, 0);
    try testing.expectEqual(native_sync.Outcome.timeout, native_sync.wait(expired.request).outcome);
    try testing.expect(native_sync.complete(expired.id, .ok, .utf8_string, "null") == .stale);
}

test "a host wake handler is detached before its environment identifier is reused" {
    const Wake = struct {
        fn notify(_: c_int, userdata: ?*anyopaque) callconv(.c) void {
            const calls: *usize = @ptrCast(@alignCast(userdata.?));
            calls.* += 1;
        }
    };
    const wake = js_event_loop.host_wake;
    var old_calls: usize = 0;
    var new_calls: usize = 0;
    try wake.set(1005, Wake.notify, &old_calls);
    defer wake.drop(1005);
    try testing.expectEqual(@as(usize, 1), old_calls);
    wake.drop(1005);
    wake.notify(1005);
    try testing.expectEqual(@as(usize, 1), old_calls);
    try wake.set(1005, Wake.notify, &new_calls);
    wake.notify(1005);
    try testing.expectEqual(@as(usize, 1), old_calls);
    try testing.expectEqual(@as(usize, 2), new_calls);
}

test "native sync: request IDs exhaust without wrapping or reuse" {
    native_sync.test_only.setNextId(std.math.maxInt(u64) - 1);
    const first = native_sync.start(1) orelse return error.MissingFirst;
    try testing.expectEqual(std.math.maxInt(u64) - 1, first.id);
    native_sync.finish(first.id, first.request);
    const last = native_sync.start(1) orelse return error.MissingLast;
    try testing.expectEqual(std.math.maxInt(u64), last.id);
    native_sync.finish(last.id, last.request);
    try testing.expect(native_sync.start(1) == null);
    native_sync.test_only.setNextId(1);
}

comptime {
    _ = @import("regression_tests.zig");
    _ = @import("driver_tests.zig");
}
