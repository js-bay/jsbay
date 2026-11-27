//! Boundary and lifecycle concurrency tests for C API destroy, loop attachment, and replacement.
const std = @import("std");
const testing = std.testing;
const sync = @import("zev");

const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");
const dispatch = @import("../runtime/dispatch.zig");

const DestroyReuseProbe = struct {
    instance_id: i32,
    mutex: sync.Mutex = .{},
    condition: sync.Condition = .init,
    admission_closed: bool = false,
    resume_destroy: bool = false,
    replacement_done: bool = false,
    replacement_created: bool = false,

    fn afterAdmissionClosed(instance_id: i32, raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        std.debug.assert(instance_id == self.instance_id);
        self.mutex.lock();
        self.admission_closed = true;
        self.condition.broadcast();
        while (!self.resume_destroy) self.condition.wait(&self.mutex);
        self.mutex.unlock();
    }

    fn destroyThread(instance_id: i32) void {
        c_api.jsbay_engine_destroy(instance_id);
    }

    fn replaceThread(self: *@This()) void {
        engine.destroy(self.instance_id);
        const created = engine.create(self.instance_id, .{});
        self.mutex.lock();
        self.replacement_created = created;
        self.replacement_done = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn waitFor(self: *@This(), predicate: *const fn (*const @This()) bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (!predicate(self)) {
            if (self.condition.waitTimeout(&self.mutex, 10_000) == .timed_out) return error.BarrierTimedOut;
        }
    }

    fn admissionIsClosed(self: *const @This()) bool {
        return self.admission_closed;
    }

    fn replacementIsDone(self: *const @This()) bool {
        return self.replacement_done;
    }

    fn releaseDestroy(self: *@This()) void {
        self.mutex.lock();
        self.resume_destroy = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

const DestroySideEffectProbe = struct {
    instance_id: i32,
    stage_to_replace: c_api.test_only.DestroyStage,
    replacement_created: bool = false,
    attach_status: c_int = -1,
    detach_cancel_count: usize = 0,
    wake_count: usize = 0,

    fn schedule(_: ?*anyopaque, _: u64, _: c_api.LoopTask, _: ?*anyopaque) callconv(.c) bool {
        return true;
    }

    fn cancel(raw: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.detach_cancel_count += 1;
    }

    fn wake(_: c_int, raw: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.wake_count += 1;
    }

    fn noop(_: ?*anyopaque) void {}

    fn atStage(instance_id: i32, stage: c_api.test_only.DestroyStage, raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        if (instance_id != self.instance_id) return;
        if (stage == self.stage_to_replace) {
            engine.destroy(instance_id);
            self.replacement_created = c_api.jsbay_engine_create(instance_id, null, null);
            if (self.stage_to_replace == .before_detach) {
                self.attach_status = c_api.jsbay_engine_attach_loop(instance_id, schedule, cancel, self);
            } else {
                self.attach_status = c_api.test_only.setWakeHandler(instance_id, wake, self);
            }
            return;
        }
    }
};

test "c_api: old destroy detaches a reused instance loop" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var probe = DestroySideEffectProbe{ .instance_id = id, .stage_to_replace = .before_detach };
    c_api.test_only.setDestroyStageHook(DestroySideEffectProbe.atStage, &probe);
    defer {
        c_api.test_only.setDestroyStageHook(null, null);
        if (engine.getContext(id) != null) engine.destroy(id);
    }

    c_api.jsbay_engine_destroy(id);

    try testing.expect(probe.replacement_created);
    try testing.expectEqual(@as(c_int, 0), probe.attach_status);
    const instance = instance_map.getInstance(id) orelse return error.ReplacementWasDestroyed;
    try testing.expect(instance.loop.isAttached());
    try testing.expectEqual(@as(usize, 0), probe.detach_cancel_count);
}

test "c_api: old destroy drops a reused instance wake handler" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var probe = DestroySideEffectProbe{ .instance_id = id, .stage_to_replace = .before_wake_drop };
    c_api.test_only.setDestroyStageHook(DestroySideEffectProbe.atStage, &probe);
    defer {
        c_api.test_only.setDestroyStageHook(null, null);
        if (engine.getContext(id) != null) engine.destroy(id);
    }

    c_api.jsbay_engine_destroy(id);

    try testing.expect(probe.replacement_created);
    try testing.expectEqual(@as(c_int, 0), probe.attach_status);
    try testing.expect(engine.getContext(id) != null);
    try testing.expectEqual(@as(usize, 1), probe.wake_count);
    c_api.test_only.setDestroyStageHook(null, null);
    try testing.expect(dispatch.postTask(id, .{ .ctx = &probe, .run = DestroySideEffectProbe.noop }));
    try testing.expectEqual(@as(usize, 2), probe.wake_count);
}

test "c_api: destroy reentered by Host.cancel returns to the outer teardown" {
    const Probe = struct {
        instance_id: i32,
        cancel_calls: usize = 0,
        reentrant_returned: bool = false,

        fn schedule(_: ?*anyopaque, _: u64, _: c_api.LoopTask, _: ?*anyopaque) callconv(.c) bool {
            return true;
        }

        fn cancel(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.cancel_calls += 1;
            c_api.jsbay_engine_destroy(self.instance_id);
            self.reentrant_returned = true;
        }
    };

    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    var probe = Probe{ .instance_id = id };
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(id, Probe.schedule, Probe.cancel, &probe));

    c_api.jsbay_engine_destroy(id);

    try testing.expectEqual(@as(usize, 1), probe.cancel_calls);
    try testing.expect(probe.reentrant_returned);
    try testing.expect(engine.getContext(id) == null);
}

test "c_api: nested Host.cancel destroys another instance without reentering the outer teardown" {
    const Watchdog = struct {
        mutex: sync.Mutex = .{},
        condition: sync.Condition = .init,
        finished: bool = false,

        fn run(self: *@This()) void {
            self.mutex.lock();
            while (!self.finished) {
                if (self.condition.waitTimeout(&self.mutex, 10_000) == .timed_out and !self.finished) {
                    self.mutex.unlock();
                    std.process.exit(1);
                }
            }
            self.mutex.unlock();
        }

        fn finish(self: *@This()) void {
            self.mutex.lock();
            self.finished = true;
            self.condition.broadcast();
            self.mutex.unlock();
        }
    };
    const Probe = struct {
        first_id: i32,
        second_id: i32,
        first_cancel_calls: usize = 0,
        second_cancel_calls: usize = 0,
        first_cancel_returned: bool = false,
        second_cancel_returned: bool = false,

        fn schedule(_: ?*anyopaque, _: u64, _: c_api.LoopTask, _: ?*anyopaque) callconv(.c) bool {
            return true;
        }

        fn firstCancel(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.first_cancel_calls += 1;
            c_api.jsbay_engine_destroy(self.second_id);
            self.first_cancel_returned = true;
        }

        fn secondCancel(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.second_cancel_calls += 1;
            c_api.jsbay_engine_destroy(self.first_id);
            self.second_cancel_returned = true;
        }
    };

    const first_id = helpers.nextInstanceId();
    const second_id = helpers.nextInstanceId();
    try testing.expect(first_id != second_id);
    try testing.expect(c_api.jsbay_engine_create(first_id, null, null));
    errdefer if (engine.getContext(first_id) != null) engine.destroy(first_id);
    try testing.expect(c_api.jsbay_engine_create(second_id, null, null));
    errdefer if (engine.getContext(second_id) != null) engine.destroy(second_id);

    var probe = Probe{ .first_id = first_id, .second_id = second_id };
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(first_id, Probe.schedule, Probe.firstCancel, &probe));
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_attach_loop(second_id, Probe.schedule, Probe.secondCancel, &probe));

    var watchdog = Watchdog{};
    const watchdog_thread = try std.Thread.spawn(.{}, Watchdog.run, .{&watchdog});
    defer {
        watchdog.finish();
        watchdog_thread.join();
    }

    c_api.jsbay_engine_destroy(first_id);

    try testing.expectEqual(@as(usize, 1), probe.first_cancel_calls);
    try testing.expectEqual(@as(usize, 1), probe.second_cancel_calls);
    try testing.expect(probe.first_cancel_returned);
    try testing.expect(probe.second_cancel_returned);
    try testing.expect(engine.getContext(first_id) == null);
    try testing.expect(engine.getContext(second_id) == null);
}

test "c_api: destroy resumed after same-id replacement preserves the replacement" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var old_snapshot: c_api.InstanceSnapshotC = undefined;
    old_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try testing.expect(c_api.jsbay_engine_snapshot(id, &old_snapshot));

    var probe = DestroyReuseProbe{ .instance_id = id };
    c_api.test_only.setDestroyAdmissionHook(DestroyReuseProbe.afterAdmissionClosed, @ptrCast(&probe));
    var destroyer: ?std.Thread = null;
    var replacer: ?std.Thread = null;
    var destroyer_joined = false;
    var replacer_joined = false;
    defer {
        probe.releaseDestroy();
        if (replacer) |thread| {
            if (!replacer_joined) thread.join();
        }
        if (destroyer) |thread| {
            if (!destroyer_joined) thread.join();
        }
        c_api.test_only.setDestroyAdmissionHook(null, null);
        if (engine.getContext(id) != null) engine.destroy(id);
        probe.condition.deinit();
        probe.mutex.deinit();
    }

    destroyer = try std.Thread.spawn(.{}, DestroyReuseProbe.destroyThread, .{id});
    try probe.waitFor(DestroyReuseProbe.admissionIsClosed);
    replacer = try std.Thread.spawn(.{}, DestroyReuseProbe.replaceThread, .{&probe});
    try probe.waitFor(DestroyReuseProbe.replacementIsDone);
    replacer.?.join();
    replacer_joined = true;
    try testing.expect(probe.replacement_created);

    var replacement: c_api.InstanceSnapshotC = undefined;
    replacement.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try testing.expect(c_api.jsbay_engine_snapshot(id, &replacement));
    try testing.expect(replacement.generation != old_snapshot.generation);

    probe.releaseDestroy();
    destroyer.?.join();
    destroyer_joined = true;
    try testing.expect(c_api.jsbay_engine_snapshot(id, &replacement));
    try testing.expect(!c_api.jsbay_engine_is_destroyed(id, replacement.generation));
}
