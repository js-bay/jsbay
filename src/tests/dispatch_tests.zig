//! Tests for native task dispatch, global emissions, and task lifecycles.
const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;

fn withTestContext(comptime test_fn: fn (ActiveEngine.Context, ActiveEngine.Runtime) anyerror!void) !void {
    const rt = ActiveEngine.newRuntime() orelse return error.RuntimeCreationFailed;
    defer ActiveEngine.freeRuntime(rt);

    const ctx = ActiveEngine.newContext(rt) orelse return error.ContextCreationFailed;
    defer ActiveEngine.freeContext(ctx);

    try test_fn(ctx, rt);
}

test "dispatch: emitGlobal calls global function with typed args" {
    try withTestContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            const eval_result = ActiveEngine.eval(
                ctx,
                \\globalThis.__dispatch_test__ = (id, name, payload) => {
                \\ globalThis.__dispatch_result__ = `${id}:${name}:${payload}`;
                \\};
            ,
                "<dispatch-test>",
            );
            // ActiveEngine.eval returns owned result/error strings even in module tests.
            defer if (eval_result.result) |s| std.heap.c_allocator.free(@constCast(s));
            defer if (eval_result.err_is_heap) {
                if (eval_result.err) |e| std.heap.c_allocator.free(@constCast(e));
            };
            if (eval_result.err != null) return error.JSException;

            const ok = dispatch.emitGlobal(ctx, "__dispatch_test__", &.{
                .{ .int32 = 7 },
                .{ .string = "tap" },
                .{ .string = "{\"x\":1}" },
            });
            try testing.expect(ok);

            const read_back = ActiveEngine.eval(ctx, "globalThis.__dispatch_result__", "<dispatch-read>");
            // Free both success and heap error paths to keep this test ownership-neutral.
            defer if (read_back.result) |s| std.heap.c_allocator.free(@constCast(s));
            defer if (read_back.err_is_heap) {
                if (read_back.err) |e| std.heap.c_allocator.free(@constCast(e));
            };
            if (read_back.err != null) return error.JSException;
            try testing.expectEqualStrings("7:tap:{\"x\":1}", read_back.result.?);
        }
    }.run);
}

test "dispatch: missing global function returns false" {
    try withTestContext(struct {
        fn run(ctx: ActiveEngine.Context, _: ActiveEngine.Runtime) !void {
            try testing.expect(!dispatch.emitGlobal(ctx, "__dispatch_missing__", &.{}));
        }
    }.run);
}

// -- Native task queue tests ---------------------------------------------

var task_flag: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn bumpTaskFlag(_: ?*anyopaque) void {
    _ = task_flag.fetchAdd(1, .seq_cst);
}

fn markTaskCancelled(_: ?*anyopaque) void {
    _ = task_flag.fetchAdd(100, .seq_cst);
}

test "dispatch: postTask runs closure on tickInstance" {
    const instance_id: i32 = 5_551;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    defer dispatch.releaseAllTasksForInstance(instance_id);

    try testing.expect(dispatch.postTask(instance_id, .{
        .ctx = null,
        .run = bumpTaskFlag,
    }));

    const dispatched = dispatch.tickInstance(instance_id);
    try testing.expect(dispatched >= 1);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));

    const dispatched_again = dispatch.tickInstance(instance_id);
    try testing.expectEqual(@as(usize, 0), dispatched_again);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));
}

test "dispatch: postTask after engine destroy does not crash" {
    const bogus_id: i32 = 12_345;
    defer dispatch.releaseAllTasksForInstance(bogus_id);

    const ok = dispatch.postTask(bogus_id, .{
        .ctx = null,
        .run = bumpTaskFlag,
    });
    try testing.expect(!ok);

    const n = dispatch.tickInstance(bogus_id);
    try testing.expectEqual(@as(usize, 0), n);
}

test "dispatch: token rejects completion from a reused instance id" {
    const instance_id: i32 = 5_554;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    const old_token = dispatch.captureInstanceToken(instance_id) orelse return error.NoToken;
    engine.destroy(instance_id);

    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const new_token = dispatch.captureInstanceToken(instance_id) orelse return error.NoToken;
    try testing.expect(old_token.generation != new_token.generation);
    const LateProducer = struct {
        token: dispatch.InstanceToken,
        accepted: *std.atomic.Value(bool),
        fn run(self: @This()) void {
            self.accepted.store(dispatch.postTaskWithToken(self.token, .{ .ctx = null, .run = bumpTaskFlag }), .seq_cst);
        }
    };
    var late_accepted = std.atomic.Value(bool).init(true);
    const late = try std.Thread.spawn(.{}, LateProducer.run, .{LateProducer{ .token = old_token, .accepted = &late_accepted }});
    late.join();
    try testing.expect(!late_accepted.load(.seq_cst));
    try testing.expect(dispatch.postTaskWithToken(new_token, .{ .ctx = null, .run = bumpTaskFlag }));
    _ = dispatch.tickInstance(instance_id);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));
}

test "dispatch: token rejects closed instance and cannot cross instances" {
    const first: i32 = 5_555;
    const second: i32 = 5_556;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(first, .{}));
    defer engine.destroy(first);
    try testing.expect(engine.create(second, .{}));
    defer engine.destroy(second);

    const first_token = dispatch.captureInstanceToken(first) orelse return error.NoToken;
    const second_token = dispatch.captureInstanceToken(second) orelse return error.NoToken;
    try testing.expect(first_token.generation != second_token.generation);
    try testing.expect(dispatch.postTaskWithToken(second_token, .{ .ctx = null, .run = bumpTaskFlag }));
    _ = dispatch.tickInstance(second);
    try testing.expectEqual(@as(u32, 1), task_flag.load(.seq_cst));

    instance_map.markTeardownPending(first);
    try testing.expect(!dispatch.postTaskWithToken(first_token, .{ .ctx = null, .run = bumpTaskFlag }));
    try testing.expect(dispatch.closeInstanceTasks(first));
    try testing.expect(dispatch.captureInstanceToken(first) == null);
    try testing.expect(!dispatch.postTaskWithToken(first_token, .{ .ctx = null, .run = bumpTaskFlag }));
}

test "dispatch: releaseAllTasksForInstance drops pending work" {
    const instance_id: i32 = 5_552;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    defer dispatch.releaseAllTasksForInstance(instance_id);

    try testing.expect(dispatch.postTask(instance_id, .{ .ctx = null, .run = bumpTaskFlag }));
    try testing.expect(dispatch.postTask(instance_id, .{ .ctx = null, .run = bumpTaskFlag }));
    try testing.expect(dispatch.postTask(instance_id, .{ .ctx = null, .run = bumpTaskFlag }));

    dispatch.releaseAllTasksForInstance(instance_id);

    const dispatched = dispatch.tickInstance(instance_id);
    try testing.expectEqual(@as(usize, 0), dispatched);
    try testing.expectEqual(@as(u32, 0), task_flag.load(.seq_cst));
}

test "dispatch: releasing queued tasks invokes their cancellation cleanup" {
    const instance_id: i32 = 5_553;
    task_flag.store(0, .seq_cst);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    defer dispatch.releaseAllTasksForInstance(instance_id);

    try testing.expect(dispatch.postTask(instance_id, .{
        .ctx = null,
        .run = bumpTaskFlag,
        .cancel = markTaskCancelled,
    }));
    dispatch.releaseAllTasksForInstance(instance_id);
    try testing.expectEqual(@as(u32, 100), task_flag.load(.seq_cst));
}

var deferred_destroy_test_generation = std.atomic.Value(u64).init(0);
var deferred_destroy_test_inside_owner = std.atomic.Value(bool).init(true);

fn recordDeferredDestroyForTesting(instance_id: i32, generation: u64) void {
    deferred_destroy_test_inside_owner.store(dispatch.isRunningTaskForInstance(instance_id), .seq_cst);
    deferred_destroy_test_generation.store(generation, .seq_cst);
}

test "dispatch: deferred destroy runs after its owner callback leaves" {
    const instance_id: i32 = 5_555;
    deferred_destroy_test_generation.store(0, .seq_cst);
    deferred_destroy_test_inside_owner.store(true, .seq_cst);
    var frame: dispatch.TaskOwnerFrame = undefined;
    dispatch.enterTaskOwnerFrame(&frame, instance_id, null);
    try testing.expect(dispatch.deferDestroyForCurrentTask(instance_id, 17, recordDeferredDestroyForTesting));
    try testing.expectEqual(@as(u64, 0), deferred_destroy_test_generation.load(.seq_cst));
    dispatch.leaveTaskOwnerFrame(&frame);
    try testing.expectEqual(@as(u64, 17), deferred_destroy_test_generation.load(.seq_cst));
    try testing.expect(!deferred_destroy_test_inside_owner.load(.seq_cst));
}
