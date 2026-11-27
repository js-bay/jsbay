//! Reference lifetime contracts: weak collection, engine teardown, and Rooted.
//!
//! Object handles are created and released inside helpers so a JSC conservative stack scan cannot keep them alive across `engine.runGc`.

const std = @import("std");
const testing = std.testing;
const helpers = @import("test_helpers.zig");
const reference = @import("../value/reference.zig");
const engine = @import("../engine.zig");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const sync = @import("zev");

const ActiveEngine = backend.ActiveEngine;

const RefDestroyProbe = struct {
    const Event = enum { none, waiting, drained };

    instance_id: i32,
    mutex: sync.Mutex = .{},
    condition: sync.Condition = .init,
    release_entered: bool = false,
    resume_release: bool = false,
    owner_ready: bool = false,
    owner_done: bool = false,
    destroy_done: bool = false,
    resume_drain: bool = false,
    event: Event = .none,
    destroy_from_release: bool = false,
    pause_release: bool = true,
    deinit_after_drain: bool = false,
    request_deinit: bool = false,
    release_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn releaseHook(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        _ = self.release_count.fetchAdd(1, .seq_cst);
        if (self.destroy_from_release) {
            engine.destroy(self.instance_id);
            return;
        }
        if (!self.pause_release) return;
        self.mutex.lock();
        self.release_entered = true;
        self.condition.broadcast();
        while (!self.resume_release) self.condition.wait(&self.mutex);
        self.mutex.unlock();
    }

    fn waitHook(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.mutex.lock();
        self.event = .waiting;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn drainHook(raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.mutex.lock();
        self.event = .drained;
        self.condition.broadcast();
        while (!self.resume_drain) self.condition.wait(&self.mutex);
        self.mutex.unlock();
    }

    fn ownerThread(self: *@This()) void {
        if (!engine.create(self.instance_id, .{})) return;
        const ctx = engine.getContext(self.instance_id) orelse return;
        const value = ActiveEngine.newObject(ctx);
        var global = reference.Global(reference.Local).init(self.instance_id, value);
        ActiveEngine.freeValue(ctx, value);
        self.mutex.lock();
        self.owner_ready = true;
        self.condition.broadcast();
        while (self.deinit_after_drain and !self.request_deinit) self.condition.wait(&self.mutex);
        self.mutex.unlock();
        if (self.deinit_after_drain) {
            global.deinit();
        } else {
            global.reset();
        }
        self.mutex.lock();
        self.owner_done = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn destroyThread(self: *@This()) void {
        engine.destroy(self.instance_id);
        self.mutex.lock();
        self.destroy_done = true;
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

    fn releaseReached(self: *const @This()) bool {
        return self.release_entered;
    }

    fn ownerStarted(self: *const @This()) bool {
        return self.owner_ready;
    }

    fn teardownObserved(self: *const @This()) bool {
        return self.event != .none;
    }

    fn ownerFinished(self: *const @This()) bool {
        return self.owner_done;
    }

    fn destroyFinished(self: *const @This()) bool {
        return self.destroy_done;
    }

    fn drainReached(self: *const @This()) bool {
        return self.event == .drained;
    }

    fn resumeOwnerRelease(self: *@This()) void {
        self.mutex.lock();
        self.resume_release = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }

    fn resumeTeardown(self: *@This()) void {
        self.mutex.lock();
        self.resume_drain = true;
        self.condition.broadcast();
        self.mutex.unlock();
    }
};

fn runGlobalResetDestroyBarrier() !void {
    var probe = RefDestroyProbe{ .instance_id = helpers.nextInstanceId() };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    instance_map.setRefHooksForTesting(RefDestroyProbe.waitHook, RefDestroyProbe.drainHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    var destroyer_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        instance_map.setRefHooksForTesting(null, null, null);
        probe.resumeOwnerRelease();
        probe.resumeTeardown();
        if (owner_thread) |t| t.join();
        if (destroyer_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }

    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerStarted);
    try probe.waitFor(RefDestroyProbe.releaseReached);
    destroyer_thread = try std.Thread.spawn(.{}, RefDestroyProbe.destroyThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.teardownObserved);

    const event = probe.event;
    const correct_wait = event == .waiting;
    if (correct_wait) try testing.expect(engine.getContext(probe.instance_id) != null);

    probe.resumeOwnerRelease();
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try probe.waitFor(RefDestroyProbe.drainReached);
    probe.resumeTeardown();
    try probe.waitFor(RefDestroyProbe.destroyFinished);
    if (destroyer_thread) |t| {
        t.join();
        destroyer_thread = null;
    }

    try testing.expect(correct_wait);
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
    try testing.expect(engine.getContext(probe.instance_id) == null);
}

test "Global.reset keeps foreign destroy behind an active reference operation" {
    try runGlobalResetDestroyBarrier();
}

test "Global.reset defers a release callback destroy until its operation exits" {
    var probe = RefDestroyProbe{ .instance_id = helpers.nextInstanceId(), .destroy_from_release = true };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        probe.resumeOwnerRelease();
        if (owner_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }
    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try testing.expect(engine.getContext(probe.instance_id) == null);
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
}

test "Global deinit after teardown release frees the surrendered cell once" {
    var probe = RefDestroyProbe{
        .instance_id = helpers.nextInstanceId(),
        .pause_release = false,
        .deinit_after_drain = true,
    };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    instance_map.setRefHooksForTesting(RefDestroyProbe.waitHook, RefDestroyProbe.drainHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    var destroyer_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        instance_map.setRefHooksForTesting(null, null, null);
        probe.resumeOwnerRelease();
        probe.resumeTeardown();
        if (owner_thread) |t| t.join();
        if (destroyer_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }
    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerStarted);
    destroyer_thread = try std.Thread.spawn(.{}, RefDestroyProbe.destroyThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.drainReached);
    probe.mutex.lock();
    probe.request_deinit = true;
    probe.condition.broadcast();
    probe.mutex.unlock();
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try testing.expect(engine.getContext(probe.instance_id) != null);
    probe.resumeTeardown();
    try probe.waitFor(RefDestroyProbe.destroyFinished);
    if (destroyer_thread) |t| {
        t.join();
        destroyer_thread = null;
    }
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
    try testing.expect(engine.getContext(probe.instance_id) == null);
}

test "Global deinit during teardown release frees the surrendered cell once" {
    var probe = RefDestroyProbe{
        .instance_id = helpers.nextInstanceId(),
        .deinit_after_drain = true,
    };
    reference.setGlobalReleaseHookForTesting(RefDestroyProbe.releaseHook, @ptrCast(&probe));
    var owner_thread: ?std.Thread = null;
    var destroyer_thread: ?std.Thread = null;
    defer {
        reference.setGlobalReleaseHookForTesting(null, null);
        probe.resumeOwnerRelease();
        probe.resumeTeardown();
        if (owner_thread) |t| t.join();
        if (destroyer_thread) |t| t.join();
        probe.condition.deinit();
        probe.mutex.deinit();
    }

    owner_thread = try std.Thread.spawn(.{}, RefDestroyProbe.ownerThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.ownerStarted);
    destroyer_thread = try std.Thread.spawn(.{}, RefDestroyProbe.destroyThread, .{&probe});
    try probe.waitFor(RefDestroyProbe.releaseReached);

    probe.mutex.lock();
    probe.request_deinit = true;
    probe.condition.broadcast();
    probe.mutex.unlock();
    try probe.waitFor(RefDestroyProbe.ownerFinished);
    if (owner_thread) |t| {
        t.join();
        owner_thread = null;
    }
    try testing.expect(engine.getContext(probe.instance_id) != null);

    probe.resumeOwnerRelease();
    try probe.waitFor(RefDestroyProbe.destroyFinished);
    if (destroyer_thread) |t| {
        t.join();
        destroyer_thread = null;
    }
    try testing.expectEqual(@as(u32, 1), probe.release_count.load(.seq_cst));
    try testing.expect(engine.getContext(probe.instance_id) == null);
}

test "Global deinit after destroy does not touch an instance that reused its id" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ctx = engine.getContext(id) orelse return error.NoContext;
    const value = ActiveEngine.newObject(ctx);
    var old_global = reference.Global(reference.Local).init(id, value);
    ActiveEngine.freeValue(ctx, value);

    engine.destroy(id);
    try testing.expect(engine.create(id, .{}));
    old_global.deinit();
    try testing.expect(engine.getContext(id) != null);
    engine.destroy(id);
}
