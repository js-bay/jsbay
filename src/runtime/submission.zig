//! Generation-scoped source submissions executed by the owner's native dispatch queue.

const std = @import("std");
const engine = @import("../engine.zig");
const dispatch = @import("dispatch.zig");
const engine_thread = @import("engine_thread.zig");
const instance_map = @import("instance_map.zig");
const runtime_control = @import("runtime_control.zig");
const host_value = @import("../abi/host_value.zig");

pub const Status = enum(c_int) {
    completed = 0,
    exception = 1,
    cancelled = 2,
};

pub const Callback = *const fn (i32, u64, Status, ?[*]const u8, usize, ?*anyopaque) callconv(.c) void;

const Submission = struct {
    allocator: std.mem.Allocator,
    instance_id: i32,
    generation: u64,
    source: []u8,
    filename: []u8,
    callback: ?Callback,
    user_data: ?*anyopaque,
    status: Status = .completed,
    error_message: ?[]u8 = null,
    seal_shutdown: bool = false,
    sealed: bool = false,

    fn fromSourceWithAllocator(allocator: std.mem.Allocator, instance_id: i32, generation: u64, source: []const u8, filename: []const u8, callback: ?Callback, user_data: ?*anyopaque) !*Submission {
        const submission = try allocator.create(Submission);
        errdefer allocator.destroy(submission);
        const source_copy = try allocator.dupe(u8, source);
        errdefer allocator.free(source_copy);
        const filename_copy = try allocator.dupe(u8, filename);
        submission.* = .{
            .allocator = allocator,
            .instance_id = instance_id,
            .generation = generation,
            .source = source_copy,
            .filename = filename_copy,
            .callback = callback,
            .user_data = user_data,
        };
        return submission;
    }

    fn fence(instance_id: i32, generation: u64, seal_shutdown: bool, callback: ?Callback, user_data: ?*anyopaque) ?*Submission {
        const submission = std.heap.c_allocator.create(Submission) catch return null;
        submission.* = .{
            .allocator = std.heap.c_allocator,
            .instance_id = instance_id,
            .generation = generation,
            .source = &.{},
            .filename = &.{},
            .callback = callback,
            .user_data = user_data,
            .seal_shutdown = seal_shutdown,
        };
        return submission;
    }

    fn destroy(self: *Submission) void {
        if (self.source.len != 0) self.allocator.free(self.source);
        if (self.filename.len != 0) self.allocator.free(self.filename);
        if (self.error_message) |error_message| self.allocator.free(error_message);
        self.allocator.destroy(self);
    }
};

fn data(ctx: ?*anyopaque) *Submission {
    return @ptrCast(@alignCast(ctx orelse unreachable));
}

fn canAdmit(ctx: ?*anyopaque) bool {
    return runtime_control.canSubmit(data(ctx).instance_id);
}

fn sealAfterAdmission(ctx: ?*anyopaque) void {
    const submission = data(ctx);
    submission.sealed = runtime_control.sealShutdown(submission.instance_id);
}

fn runScript(ctx: ?*anyopaque) void {
    const submission = data(ctx);
    if (runtime_control.shutdownStatus(submission.instance_id)) |shutdown| {
        if (shutdown.phase == .cancelled) {
            submission.status = .cancelled;
            return;
        }
    }
    const result = engine.evalScript(submission.instance_id, submission.source, submission.filename);
    defer if (result.result) |value| std.heap.c_allocator.free(@constCast(value));
    defer if (result.err_is_heap) if (result.err) |message| std.heap.c_allocator.free(@constCast(message));
    if (result.err) |message| {
        submission.status = .exception;
        const detail = if (message.len == 0) "script exception" else message;
        submission.error_message = submission.allocator.dupe(u8, detail) catch null;
    }
}

fn cancel(ctx: ?*anyopaque) void {
    data(ctx).status = .cancelled;
}

fn complete(ctx: ?*anyopaque) void {
    const submission = data(ctx);
    defer submission.destroy();
    if (runtime_control.shutdownStatus(submission.instance_id)) |shutdown| {
        if (shutdown.phase == .cancelled) submission.status = .cancelled;
    }
    if (submission.status == .completed and submission.seal_shutdown and (!submission.sealed or !runtime_control.completeShutdownDrain(submission.instance_id))) {
        submission.status = .cancelled;
    }
    if (submission.callback) |callback| {
        const message = submission.error_message;
        callback(
            submission.instance_id,
            submission.generation,
            submission.status,
            if (message) |text| text.ptr else null,
            if (message) |text| text.len else 0,
            submission.user_data,
        );
    }
}

fn submit(submission: *Submission, run: *const fn (?*anyopaque) void) bool {
    const bytes = std.math.add(usize, submission.source.len, submission.filename.len) catch {
        submission.destroy();
        return false;
    };
    const token: dispatch.InstanceToken = .{ .instance_id = submission.instance_id, .generation = submission.generation };
    const accepted = dispatch.postTaskWithToken(token, .{
        .ctx = @ptrCast(submission),
        .run = run,
        .cancel = cancel,
        .complete = complete,
        .completion_ctx = @ptrCast(submission),
        .resource_kind = .script_task,
        .resource_bytes = bytes,
        .admission_check = canAdmit,
        .on_admitted = if (submission.seal_shutdown) sealAfterAdmission else null,
    });
    if (!accepted) submission.destroy();
    return accepted;
}

fn runFence(_: ?*anyopaque) void {}

fn postScriptWithAllocator(allocator: std.mem.Allocator, instance_id: i32, generation: u64, source: []const u8, filename: []const u8, callback: ?Callback, user_data: ?*anyopaque) bool {
    const bytes = std.math.add(usize, source.len, filename.len) catch return false;
    if (!runtime_control.canSubmit(instance_id)) return false;
    const token: dispatch.InstanceToken = .{ .instance_id = instance_id, .generation = generation };
    var reservation = dispatch.reserveTaskWithToken(token, .script_task, bytes) orelse return false;
    defer reservation.deinit();
    const submission = Submission.fromSourceWithAllocator(allocator, instance_id, generation, source, filename, callback, user_data) catch return false;
    const accepted = dispatch.postReservedTaskWithToken(token, &reservation, .{
        .ctx = @ptrCast(submission),
        .run = runScript,
        .cancel = cancel,
        .complete = complete,
        .completion_ctx = @ptrCast(submission),
        .resource_kind = .script_task,
        .resource_bytes = bytes,
        .admission_check = canAdmit,
    });
    if (!accepted) submission.destroy();
    return accepted;
}

/// Copies source and filename before returning. An accepted submission completes exactly once after the dispatch turn checkpoint.
pub fn postScript(instance_id: i32, generation: u64, source: []const u8, filename: []const u8, callback: ?Callback, user_data: ?*anyopaque) bool {
    return postScriptWithAllocator(std.heap.c_allocator, instance_id, generation, source, filename, callback, user_data);
}

/// A fence preserves queue order and can atomically seal a graceful shutdown once it entered the instance queue.
pub fn postFence(instance_id: i32, generation: u64, seal_shutdown: bool, callback: ?Callback, user_data: ?*anyopaque) bool {
    const submission = Submission.fence(instance_id, generation, seal_shutdown, callback, user_data) orelse return false;
    return submit(submission, runFence);
}

const testing = std.testing;

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

test "submission: exception completes before a following fence" {
    const instance_id: i32 = 58_301;
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    var probe = Probe{};
    try testing.expect(postScript(instance_id, token.generation, "throw new Error('submission')", "<submission>", record, @ptrCast(&probe)));
    try testing.expect(postFence(instance_id, token.generation, false, record, @ptrCast(&probe)));
    engine.runEventLoopOnce(instance_id);
    engine.runEventLoopOnce(instance_id);
    try testing.expectEqual(@as(usize, 2), probe.calls);
    try testing.expectEqual(Status.exception, probe.statuses[0]);
    try testing.expectEqual(Status.completed, probe.statuses[1]);
}

test "submission: stale generation is rejected without a callback" {
    const instance_id: i32 = 58_302;
    try testing.expect(engine.create(instance_id, .{}));
    const old_token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    engine.destroy(instance_id);
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    var probe = Probe{};
    try testing.expect(!postScript(instance_id, old_token.generation, "1", "<stale>", record, @ptrCast(&probe)));
    try testing.expectEqual(@as(usize, 0), probe.calls);
}

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
    const submission = try Submission.fromSourceWithAllocator(testing.allocator, instance_id, token.generation, source, filename, null, null);
    var submission_destroyed = false;
    defer if (!submission_destroyed) submission.destroy();
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
        .ctx = @ptrCast(submission),
        .run = runScript,
        .cancel = cancel,
        .complete = complete,
        .completion_ctx = @ptrCast(submission),
        .resource_kind = .script_task,
        .resource_bytes = bytes,
        .admission_check = canAdmit,
    }));
    submission.destroy();
    submission_destroyed = true;
    reservation.deinit();
    released = true;
    destroyer.join();
    joined = true;
    try testing.expect(destroy_done.load(.seq_cst));
    try testing.expect(engine.getContext(instance_id) == null);
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
