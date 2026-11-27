//! Submission queue companion tests for budgets, limits, and cancellations.

const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const dispatch = @import("../runtime/dispatch.zig");
const submission = @import("../runtime/submission.zig");
const instance_map = @import("../runtime/instance_map.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const runtime_control = @import("../runtime/runtime_control.zig");
const host_value = @import("../abi/host_value.zig");

const Status = submission.Status;
const postScript = submission.postScript;
const postFence = submission.postFence;
const postScriptWithAllocator = submission.postScriptWithAllocator;
const postGcWithAllocator = submission.postGcWithAllocator;
const Submission = submission.Submission;
const canAdmit = submission.canAdmit;
const runScript = submission.runScript;
const cancel = submission.cancel;
const complete = submission.complete;

const Probe = struct {
    calls: usize = 0,
    statuses: [4]Status = undefined,
    saw_error: bool = false,
};

fn record(instance_id: i32, generation: u64, status: Status, error_data: ?[*]const u8, error_len: usize, user_data: ?*anyopaque) callconv(.c) void {
    _ = instance_id;
    _ = generation;
    const probe: *Probe = @ptrCast(@alignCast(user_data orelse unreachable));
    probe.statuses[probe.calls] = status;
    probe.calls += 1;
    probe.saw_error = error_data != null and error_len != 0;
}

const SideEffectProbe = struct {
    calls: usize = 0,

    fn call(_: c_int, user_data: ?*anyopaque, _: u32, _: ?[*]const host_value.HostValue, out: *host_value.HostValue) callconv(.c) c_int {
        const probe: *SideEffectProbe = @ptrCast(@alignCast(user_data orelse unreachable));
        probe.calls += 1;
        host_value.clear(out);
        return 0;
    }
};

test "submission: resource limits admit a script larger than one mebibyte" {
    const instance_id: i32 = 58_307;
    const source_len = 1024 * 1024 + 1;
    try testing.expect(engine.create(instance_id, .{ .resource_limits = .{ .max_pending_bytes = source_len + 64 } }));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    const source = try testing.allocator.alloc(u8, source_len);
    defer testing.allocator.free(source);
    @memset(source, ' ');
    source[0] = '/';
    source[1] = '/';
    var probe = Probe{};
    try testing.expect(postScript(instance_id, token.generation, source, "<large-comment>", record, @ptrCast(&probe)));
    engine.runEventLoopOnce(instance_id);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(Status.completed, probe.statuses[0]);
}

test "submission: failed queue append releases reservation before destroy" {
    const instance_id: i32 = 58_308;
    try testing.expect(engine.create(instance_id, .{}));
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var probe = Probe{};
    dispatch.failNextQueueAllocationForTesting();
    try testing.expect(!postScript(instance_id, token.generation, "1", "<append-fail>", record, @ptrCast(&probe)));
    try testing.expectEqual(@as(usize, 0), probe.calls);
    engine.destroy(instance_id);
    try testing.expect(engine.getContext(instance_id) == null);
}

test "submission: source copy failure releases reservation before destroy" {
    const instance_id: i32 = 58_309;
    try testing.expect(engine.create(instance_id, .{}));
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var probe = Probe{};
    try testing.expect(!postScriptWithAllocator(failing.allocator(), instance_id, token.generation, "source", "<copy-fail>", record, @ptrCast(&probe)));
    try testing.expectEqual(@as(usize, 0), probe.calls);
    engine.destroy(instance_id);
    try testing.expect(engine.getContext(instance_id) == null);
}

test "submission: exhausted pending-byte budget rejects before source allocation" {
    const instance_id: i32 = 58_310;
    try testing.expect(engine.create(instance_id, .{ .resource_limits = .{ .max_pending_bytes = 1 } }));
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var probe = Probe{};
    try testing.expect(!postScriptWithAllocator(failing.allocator(), instance_id, token.generation, "source", "<over-budget>", record, @ptrCast(&probe)));
    try testing.expectEqual(@as(usize, 0), failing.alloc_index);
    try testing.expectEqual(@as(usize, 0), probe.calls);
    engine.destroy(instance_id);
    try testing.expect(engine.getContext(instance_id) == null);
}

test "submission: close between reserve and commit releases the reservation" {
    const instance_id: i32 = 58_311;
    const source = "1";
    const filename = "<close-between-reserve-and-commit>";
    try testing.expect(engine.create(instance_id, .{}));
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    const bytes = try std.math.add(usize, source.len, filename.len);
    var reservation = dispatch.reserveTaskWithToken(token, .script_task, bytes) orelse return error.ReservationRejected;
    var released = false;
    defer if (!released) reservation.deinit();
    const sub = try Submission.fromSourceWithAllocator(testing.allocator, instance_id, token.generation, source, filename, null, null);
    var submission_destroyed = false;
    defer if (!submission_destroyed) sub.destroy();
    var destroy_done = std.atomic.Value(bool).init(false);
    const Destroyer = struct {
        fn run(id: i32, done: *std.atomic.Value(bool)) void {
            engine.destroy(id);
            done.store(true, .seq_cst);
        }
    };
    const destroyer = try std.Thread.spawn(.{}, Destroyer.run, .{ instance_id, &destroy_done });
    var joined = false;
    defer if (!joined) destroyer.join();

    var spins: usize = 0;
    while (spins < 10_000 and !instance_map.isTeardownPending(instance_id)) : (spins += 1) std.Thread.yield() catch {};
    try testing.expect(instance_map.isTeardownPending(instance_id));
    try testing.expect(!destroy_done.load(.seq_cst));
    const usage = reservation.resources.?.usage();
    try testing.expectEqual(bytes, usage.bytes);
    try testing.expect(!dispatch.postReservedTaskWithToken(token, &reservation, .{
        .ctx = @ptrCast(sub),
        .run = runScript,
        .cancel = cancel,
        .complete = complete,
        .completion_ctx = @ptrCast(sub),
        .resource_kind = .script_task,
        .resource_bytes = bytes,
        .admission_check = canAdmit,
    }));
    sub.destroy();
    submission_destroyed = true;
    reservation.deinit();
    released = true;
    destroyer.join();
    joined = true;
    try testing.expect(destroy_done.load(.seq_cst));
    try testing.expect(engine.getContext(instance_id) == null);
}

test "submission: reserved task rejects mismatched accounting" {
    const instance_id: i32 = 58_312;
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var reservation = dispatch.reserveTaskWithToken(token, .script_task, 4) orelse return error.ReservationRejected;
    defer reservation.deinit();
    const accepted = dispatch.postReservedTaskWithToken(token, &reservation, .{
        .ctx = null,
        .run = struct {
            fn run(_: ?*anyopaque) void {}
        }.run,
        .resource_kind = .script_task,
        .resource_bytes = 0,
    });
    try testing.expect(!accepted);
    try testing.expectEqual(@as(usize, 4), reservation.resources.?.usage().bytes);
    try testing.expect(!dispatch.postReservedTaskWithToken(token, &reservation, .{
        .ctx = null,
        .run = struct {
            fn run(_: ?*anyopaque) void {}
        }.run,
        .resource_kind = .native_task,
        .resource_bytes = 4,
    }));
    try testing.expectEqual(@as(usize, 4), reservation.resources.?.usage().bytes);
    const resources = reservation.resources.?;
    reservation.deinit();
    try testing.expectEqual(@as(usize, 0), resources.usage().bytes);
}

test "submission: rejected reservation releases its control lease before destroy" {
    const instance_id: i32 = 58_306;
    try testing.expect(engine.create(instance_id, .{}));
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    const stale = dispatch.InstanceToken{ .instance_id = instance_id, .generation = token.generation + 1 };
    try testing.expect(dispatch.reserveTaskWithToken(stale, .script_task, 1) == null);
    engine.destroy(instance_id);
    try testing.expect(engine.getContext(instance_id) == null);
}

test "submission: close cancels one accepted pending callback" {
    const instance_id: i32 = 58_303;
    try testing.expect(engine.create(instance_id, .{}));
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var probe = Probe{};
    try testing.expect(postScript(instance_id, token.generation, "globalThis.submissionValue = 1", "<close>", record, @ptrCast(&probe)));
    engine.destroy(instance_id);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(Status.cancelled, probe.statuses[0]);
}

test "submission: shutdown cancellation skips an accepted script before it runs" {
    const instance_id: i32 = 58_312;
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var callback_probe = Probe{};
    var side_effect_probe = SideEffectProbe{};
    try testing.expect(engine_thread.hostInstall(instance_id, "recordSubmissionSideEffect", SideEffectProbe.call, @ptrCast(&side_effect_probe)));
    try testing.expect(postScript(instance_id, token.generation, "recordSubmissionSideEffect()", "<cancelled-before-run>", record, @ptrCast(&callback_probe)));
    try testing.expect(runtime_control.requestShutdownCancel(instance_id));
    engine.runEventLoopOnce(instance_id);
    try testing.expectEqual(@as(usize, 0), side_effect_probe.calls);
    try testing.expectEqual(@as(usize, 1), callback_probe.calls);
    try testing.expectEqual(Status.cancelled, callback_probe.statuses[0]);
}

test "submission: cancelled sealing fence does not mark shutdown drained" {
    const instance_id: i32 = 58_305;
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var probe = Probe{};
    try testing.expect(runtime_control.beginShutdown(instance_id, 1_000));
    try testing.expect(postFence(instance_id, token.generation, true, record, @ptrCast(&probe)));
    try testing.expect(runtime_control.requestShutdownCancel(instance_id));
    engine.runEventLoopOnce(instance_id);
    const status = runtime_control.shutdownStatus(instance_id) orelse return error.MissingStatus;
    try testing.expectEqual(runtime_control.ShutdownPhase.cancelled, status.phase);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(Status.cancelled, probe.statuses[0]);
}

test "submission: source copy releases earlier allocations when filename copy fails" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
    try testing.expectError(error.OutOfMemory, Submission.fromSourceWithAllocator(failing.allocator(), 58_304, 1, "source", "filename", null, null));
}

test "submission: asynchronous GC task debouncing and lifecycle" {
    const instance_id: i32 = 58_315;
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;

    const posted = try postGcWithAllocator(testing.allocator, instance_id, token.generation);
    try testing.expect(posted);

    const debounced = try postGcWithAllocator(testing.allocator, instance_id, token.generation);
    try testing.expect(!debounced);

    engine.runEventLoopOnce(instance_id);

    const posted_after = try postGcWithAllocator(testing.allocator, instance_id, token.generation);
    try testing.expect(posted_after);
    engine.runEventLoopOnce(instance_id);
}

test "submission: postGcWithAllocator error propagation" {
    const instance_id: i32 = 58_316;

    // 1. InstanceNotFound
    try testing.expectError(error.InstanceNotFound, postGcWithAllocator(testing.allocator, 999_998, 1));

    // 2. StaleGeneration
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;

    try testing.expectError(error.StaleGeneration, postGcWithAllocator(testing.allocator, instance_id, token.generation + 10));

    // 3. ShutdownInProgress (sealed shutdown rejects submissions)
    try testing.expect(runtime_control.beginShutdown(instance_id, 1_000));
    try testing.expect(runtime_control.sealShutdown(instance_id));
    try testing.expectError(error.ShutdownInProgress, postGcWithAllocator(testing.allocator, instance_id, token.generation));
    _ = runtime_control.requestShutdownCancel(instance_id);
}
