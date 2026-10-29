//! Engine contracts for the unified native and JavaScript timer scheduler.

const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");
const event_loop = @import("js_event_loop");
const timers = @import("../runtime/timers.zig");

test "timer unification: timer ids wrap without reusing a live id" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const instance = instance_map.getInstance(id) orelse return error.InstanceMissing;
    instance.timers.next_id = std.math.maxInt(i32);
    try helpers.evalOk(id, "setTimeout(() => {}, 1000);");
    instance.timers.next_id = std.math.maxInt(i32);
    try helpers.evalOk(id, "setTimeout(() => {}, 1000);");
    try testing.expect(instance.timers.entries.count() == 2);
    try testing.expect(instance.timers.entries.contains(std.math.maxInt(i32)));
    try testing.expect(instance.timers.entries.contains(1));
}

test "timer unification: JavaScript task zero timer waits for the next tick" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try helpers.evalOk(id, "setTimeout(() => { globalThis.__unifiedTimer__ = 1; setTimeout(() => globalThis.__unifiedTimer__ = 2, 0); }, 0);");
    _ = engine.testing.advance(id, 100);
    try helpers.expectEvalEquals(id, "globalThis.__unifiedTimer__", "1");
    _ = engine.testing.advance(id, 100);
    try helpers.expectEvalEquals(id, "globalThis.__unifiedTimer__", "2");
}

test "timer unification: dispatch task zero timer runs in its host tick" {
    const State = struct {
        const Self = @This();
        id: i32,
        fn task(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const result = engine.evalScript(self.id, "setTimeout(() => globalThis.__dispatchTimer__ = 1, 0)", "<dispatch-timer>");
            helpers.freeEvalResult(result);
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var state = State{ .id = id };
    try testing.expect(dispatch.postTask(id, .{ .ctx = &state, .run = State.task }));
    _ = engine.testing.advance(id, 100);
    _ = engine.testing.advance(id, 100);
    try helpers.expectEvalEquals(id, "globalThis.__dispatchTimer__", "1");
}

test "timer unification: native and JavaScript timers share the earliest deadline" {
    const State = struct {
        const Self = @This();
        calls: u8 = 0,
        fn callback(ctx: ?*anyopaque, _: *event_loop.Timer) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const loop = (instance_map.getPtrs(id) orelse return error.InstanceMissing).loop;
    try helpers.evalOk(id, "setTimeout(() => globalThis.__mixedTimer__ = 1, 100);");
    try testing.expectEqual(@as(i64, 100), engine.testing.advance(id, 0));
    var state: State = .{};
    var native: event_loop.Timer = .{};
    native.init(loop, &state, State.callback);
    try native.startAt(50);
    try testing.expectEqual(@as(i64, 50), engine.testing.advance(id, 0));
    _ = engine.testing.advance(id, 50);
    try testing.expectEqual(@as(u8, 1), state.calls);
    try helpers.expectEvalEquals(id, "typeof globalThis.__mixedTimer__", "undefined");
    try testing.expectEqual(@as(i64, -1), engine.testing.advance(id, 100));
    try helpers.expectEvalEquals(id, "globalThis.__mixedTimer__", "1");
    native.close();
}

test "timer unification: cancelling ready timers preserves the other due callbacks" {
    const first_id = helpers.nextInstanceId();
    try testing.expect(engine.create(first_id, .{}));
    defer engine.destroy(first_id);
    try helpers.evalOk(first_id, "globalThis.__readyTrace__=''; var b; setTimeout(() => { __readyTrace__ += 'A'; clearTimeout(b); }, 0); b=setTimeout(() => __readyTrace__ += 'B', 0); setTimeout(() => __readyTrace__ += 'C', 0);");
    _ = engine.testing.advance(first_id, 0);
    _ = engine.testing.advance(first_id, 0);
    try helpers.expectEvalEquals(first_id, "__readyTrace__", "AC");

    const second_id = helpers.nextInstanceId();
    try testing.expect(engine.create(second_id, .{}));
    defer engine.destroy(second_id);
    try helpers.evalOk(second_id, "globalThis.__readyTrace__=''; var c; setTimeout(() => { __readyTrace__ += 'A'; clearTimeout(c); }, 0); setTimeout(() => __readyTrace__ += 'B', 0); c=setTimeout(() => __readyTrace__ += 'C', 0);");
    _ = engine.testing.advance(second_id, 0);
    _ = engine.testing.advance(second_id, 0);
    try helpers.expectEvalEquals(second_id, "__readyTrace__", "AB");
}

test "timer unification: scheduler OOM keeps ids and caller state intact" {
    const Case = struct {
        fn run(fail_index: usize) !void {
            const id = helpers.nextInstanceId();
            try testing.expect(engine.create(id, .{}));
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
            const instance = instance_map.getInstance(id) orelse return error.InstanceMissing;
            instance.timers.deinit();
            instance.timers = timers.TimerRegistry.initWithAllocator(failing.allocator());
            // The failed registration must not consume an id or poison the JS context that still owns the callback value on failure.
            const result = engine.evalScript(id, "setTimeout(() => 1, 0)", "<timer-oom>");
            defer helpers.freeEvalResult(result);
            try testing.expect(result.err != null);
            try testing.expectEqual(@as(i32, 1), instance.timers.next_id);
            try testing.expectEqual(@as(usize, 0), instance.timers.entries.count());
            try helpers.evalOk(id, "1 + 1");
            engine.destroy(id);
        }
    };
    // First reject TimerData allocation, then reject the registry map put after TimerData allocation has succeeded and must be released.
    try Case.run(0);
    try Case.run(1);
}

test "timer unification: batch anchor OOM cannot run later timers before earlier pending work" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const instance = instance_map.getInstance(id) orelse return error.InstanceMissing;
    const old_loop = instance.loop;
    const replacement = try event_loop.Driver.create(failing.allocator());
    instance.loop = replacement;
    old_loop.destroy();
    defer engine.destroy(id);

    try helpers.evalOk(id, "globalThis.__batchTrace__=''; for (let i=0;i<8;i++) setTimeout(() => __batchTrace__ += 'L', 100); setTimeout(() => __batchTrace__ += 'E', 0);");
    // Permit one heap allocation, then make the next capacity expansion fail. The handle count forces the second deadline group to need another slot.
    failing.fail_index = failing.alloc_index + 1;
    failing.resize_fail_index = failing.resize_index;
    _ = engine.testing.advance(id, 100);
    _ = engine.testing.advance(id, 200);
    try testing.expect(failing.has_induced_failure);
    try helpers.expectEvalEquals(id, "__batchTrace__", "");

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = engine.testing.advance(id, 200);
    for (0..8) |_| _ = engine.testing.advance(id, 200);
    try helpers.expectEvalEquals(id, "__batchTrace__", "ELLLLLLLL");
}

test "timer unification: new zero timer stays pending while an anchored batch is incomplete" {
    const Post = struct {
        const Self = @This();
        id: i32,
        fn run(ctx: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            const result = engine.evalScript(self.id, "clearTimeout(__oldIds__[0]); setTimeout(() => __pendingTrace__ += 'N', 0)", "<pending-new>");
            helpers.freeEvalResult(result);
        }
    };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const instance = instance_map.getInstance(id) orelse return error.InstanceMissing;
    const old_loop = instance.loop;
    const replacement = try event_loop.Driver.create(failing.allocator());
    instance.loop = replacement;
    old_loop.destroy();
    defer engine.destroy(id);

    try helpers.evalOk(id, "globalThis.__pendingTrace__=''; globalThis.__oldIds__=[]; for (let i=0;i<9;i++) __oldIds__.push(setTimeout(() => __pendingTrace__ += 'O', 0));");
    var post = Post{ .id = id };
    try testing.expect(dispatch.postTask(id, .{ .ctx = &post, .run = Post.run }));
    failing.fail_index = failing.alloc_index + 1;
    failing.resize_fail_index = failing.resize_index;
    _ = engine.testing.advance(id, 100);
    try testing.expect(failing.has_induced_failure);
    try helpers.expectEvalEquals(id, "__pendingTrace__", "");

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = engine.testing.advance(id, 100);
    for (0..8) |_| _ = engine.testing.advance(id, 100);
    try helpers.expectEvalEquals(id, "__pendingTrace__", "OOOOOOOON");
}
