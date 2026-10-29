const std = @import("std");
const api = @import("../c_api.zig");
const dispatch = @import("../runtime/dispatch.zig");
const helpers = @import("test_helpers.zig");
const sync = @import("zev");

const Counter = struct {
    hints: std.atomic.Value(usize) = .init(0),
    ran: std.atomic.Value(usize) = .init(0),
    fn wake(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
        const self: *Counter = @ptrCast(@alignCast(ptr.?));
        _ = self.hints.fetchAdd(1, .seq_cst);
    }
    fn run(ptr: ?*anyopaque) void {
        const self: *Counter = @ptrCast(@alignCast(ptr.?));
        _ = self.ran.fetchAdd(1, .seq_cst);
    }
};

test "host wake: an idle foreign host receives work without a timer" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(api.jsbay_engine_create(id, null, null));
    defer api.jsbay_engine_destroy(id);
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, null, null));
    var count: Counter = .{};
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, Counter.wake, &count));
    try std.testing.expectEqual(@as(usize, 1), count.hints.load(.seq_cst));
    try std.testing.expectEqual(@as(i64, -1), api.test_only.advance(id, 0));
    const Post = struct {
        fn call(instance: i32, counter: *Counter) void {
            std.debug.assert(dispatch.postTask(instance, .{ .ctx = counter, .run = Counter.run }));
        }
    };
    const thread = try std.Thread.spawn(.{}, Post.call, .{ id, &count });
    thread.join();
    try std.testing.expectEqual(@as(usize, 2), count.hints.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), count.ran.load(.seq_cst));
    _ = api.test_only.advance(id, 1);
    try std.testing.expectEqual(@as(usize, 1), count.ran.load(.seq_cst));
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, null, null));
}

test "host wake: replacement removal and id reuse detach old userdata" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(api.jsbay_engine_create(id, null, null));
    var old: Counter = .{};
    var current: Counter = .{};
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, Counter.wake, &old));
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, Counter.wake, &current));
    try std.testing.expect(dispatch.postTask(id, .{ .ctx = &current, .run = Counter.run }));
    try std.testing.expectEqual(@as(usize, 1), old.hints.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 2), current.hints.load(.seq_cst));
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, null, null));
    try std.testing.expect(dispatch.postTask(id, .{ .ctx = &current, .run = Counter.run }));
    try std.testing.expectEqual(@as(usize, 2), current.hints.load(.seq_cst));
    api.jsbay_engine_destroy(id);
    try std.testing.expect(api.jsbay_engine_create(id, null, null));
    defer api.jsbay_engine_destroy(id);
    try std.testing.expect(dispatch.postTask(id, .{ .ctx = &old, .run = Counter.run }));
    try std.testing.expectEqual(@as(usize, 1), old.hints.load(.seq_cst));
}

test "host wake: registration rejects foreign threads and reentrant teardown" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(api.jsbay_engine_create(id, null, null));
    defer api.jsbay_engine_destroy(id);
    var result: c_int = 0;
    const Foreign = struct {
        fn call(instance: i32, out: *c_int) void {
            out.* = api.test_only.setWakeHandler(instance, null, null);
        }
    };
    const thread = try std.Thread.spawn(.{}, Foreign.call, .{ id, &result });
    thread.join();
    try std.testing.expectEqual(@as(c_int, 3), result);
    const Reentrant = struct {
        fn wake(instance: c_int, ptr: ?*anyopaque) callconv(.c) void {
            const out: *c_int = @ptrCast(@alignCast(ptr.?));
            out.* = api.test_only.setWakeHandler(instance, null, null);
            api.jsbay_engine_destroy(instance);
        }
    };
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, Reentrant.wake, &result));
    try std.testing.expectEqual(@as(c_int, 2), result);
    try std.testing.expectEqual(@as(i64, -1), api.test_only.advance(id, 0));
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, null, null));
}

test "host wake: unregister waits for admitted foreign notifications" {
    const Gate = struct {
        mutex: sync.Mutex = .{},
        changed: sync.Condition = .init,
        block: bool = false,
        entered: bool = false,
        clearing: bool = false,
        released: bool = false,
        exited: bool = false,
        fn wake(_: c_int, ptr: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.block) return;
            self.entered = true;
            self.changed.broadcast();
            while (!self.released) self.changed.wait(&self.mutex);
            self.exited = true;
        }
        fn release(self: *@This()) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (!self.clearing) self.changed.wait(&self.mutex);
            self.released = true;
            self.changed.broadcast();
        }
        fn post(id: i32) void {
            std.debug.assert(dispatch.postTask(id, .{ .ctx = null, .run = noop }));
        }
        fn noop(_: ?*anyopaque) void {}
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(api.jsbay_engine_create(id, null, null));
    defer api.jsbay_engine_destroy(id);
    var gate: Gate = .{};
    defer gate.changed.deinit();
    defer gate.mutex.deinit();
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, Gate.wake, &gate));
    gate.block = true;
    const poster = try std.Thread.spawn(.{}, Gate.post, .{id});
    const releaser = try std.Thread.spawn(.{}, Gate.release, .{&gate});
    gate.mutex.lock();
    while (!gate.entered) gate.changed.wait(&gate.mutex);
    gate.clearing = true;
    gate.changed.broadcast();
    gate.mutex.unlock();
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, null, null));
    gate.mutex.lock();
    const exited = gate.exited;
    gate.mutex.unlock();
    poster.join();
    releaser.join();
    try std.testing.expect(exited);
}

test "host wake: deferred destroy detaches notifications before returning" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(api.jsbay_engine_create(id, null, null));
    var counter: Counter = .{};
    try std.testing.expectEqual(@as(c_int, 0), api.test_only.setWakeHandler(id, Counter.wake, &counter));
    const Close = struct {
        fn start(instance: c_int, ptr: ?*anyopaque, _: u64, _: u64, _: usize, _: ?[*]const u64) callconv(.c) void {
            api.jsbay_engine_destroy(instance);
            _ = dispatch.postTask(instance, .{ .ctx = ptr, .run = Counter.run });
        }
    };
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "closeDuringSync";
    try std.testing.expectEqual(@as(c_int, 0), api.jsbay_engine_bind_sync(id, .{ .data = name.ptr, .len = name.len }, Close.start, &counter, null, 100, &function, &exception));
    _ = api.jsbay_value_release(function);
    var value: u64 = 0;
    const script = "closeDuringSync()";
    const filename = "wake-close.js";
    try std.testing.expectEqual(@as(c_int, 4), api.jsbay_engine_evaluate(id, .{ .data = script.ptr, .len = script.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
    try std.testing.expectEqual(@as(usize, 1), counter.hints.load(.seq_cst));
}
