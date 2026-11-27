//! Generation-scoped source submissions executed by the owner's native dispatch queue.

const std = @import("std");
const engine = @import("../engine.zig");
const dispatch = @import("dispatch.zig");
const engine_thread = @import("engine_thread.zig");
const instance_map = @import("instance_map.zig");
const runtime_control = @import("runtime_control.zig");
const host_value = @import("../abi/host_value.zig");
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");

pub const Status = enum(c_int) {
    completed = 0,
    exception = 1,
    cancelled = 2,
};

pub const Callback = *const fn (i32, u64, Status, ?[*]const u8, usize, ?*anyopaque) callconv(.c) void;

pub const Submission = struct {
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

    pub fn fromSourceWithAllocator(allocator: std.mem.Allocator, instance_id: i32, generation: u64, source: []const u8, filename: []const u8, callback: ?Callback, user_data: ?*anyopaque) !*Submission {
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

    pub fn destroy(self: *Submission) void {
        if (self.source.len != 0) self.allocator.free(self.source);
        if (self.filename.len != 0) self.allocator.free(self.filename);
        if (self.error_message) |error_message| self.allocator.free(error_message);
        self.allocator.destroy(self);
    }
};

fn data(ctx: ?*anyopaque) *Submission {
    return @ptrCast(@alignCast(ctx orelse unreachable));
}

pub fn canAdmit(ctx: ?*anyopaque) bool {
    return runtime_control.canSubmit(data(ctx).instance_id);
}

fn sealAfterAdmission(ctx: ?*anyopaque) void {
    const submission = data(ctx);
    submission.sealed = runtime_control.sealShutdown(submission.instance_id);
}

pub fn runScript(ctx: ?*anyopaque) void {
    const submission = data(ctx);
    if (runtime_control.shutdownStatus(submission.instance_id)) |shutdown| {
        if (shutdown.phase == .cancelled) {
            submission.status = .cancelled;
            return;
        }
    }
    const result = engine.evalScriptWithOptions(submission.instance_id, submission.source, submission.filename, .{ .stringify_result = false });
    defer if (result.result) |value| std.heap.c_allocator.free(@constCast(value));
    defer if (result.err_is_heap) if (result.err) |message| std.heap.c_allocator.free(@constCast(message));
    if (result.err) |message| {
        submission.status = .exception;
        const detail = if (message.len == 0) "script exception" else message;
        submission.error_message = submission.allocator.dupe(u8, detail) catch null;
    }
}

pub fn cancel(ctx: ?*anyopaque) void {
    data(ctx).status = .cancelled;
}

pub fn complete(ctx: ?*anyopaque) void {
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

pub fn postScriptWithAllocator(allocator: std.mem.Allocator, instance_id: i32, generation: u64, source: []const u8, filename: []const u8, callback: ?Callback, user_data: ?*anyopaque) bool {
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

const GcTask = struct {
    allocator: std.mem.Allocator,
    instance_id: i32,
    inst: *instance_map.EngineInstance,
};

fn runGcTask(ctx: ?*anyopaque) void {
    const raw = ctx orelse return;
    const task: *GcTask = @ptrCast(@alignCast(raw));
    defer task.allocator.destroy(task);
    task.inst.gc_state.store(.idle, .release);
    if (runtime_control.shutdownStatus(task.instance_id)) |shutdown| {
        if (shutdown.phase == .cancelled) return;
    }
    _ = runtime_control.runGc(task.instance_id);
}

fn cancelGcTask(ctx: ?*anyopaque) void {
    const raw = ctx orelse return;
    const task: *GcTask = @ptrCast(@alignCast(raw));
    defer task.allocator.destroy(task);
    task.inst.gc_state.store(.idle, .release);
}

fn onAdmitGc(ctx: ?*anyopaque) void {
    const raw = ctx orelse return;
    const task: *GcTask = @ptrCast(@alignCast(raw));
    task.inst.gc_state.store(.queued, .release);
}

fn canAdmitGc(ctx: ?*anyopaque) bool {
    const raw = ctx orelse return false;
    const task: *GcTask = @ptrCast(@alignCast(raw));
    return runtime_control.canSubmit(task.instance_id);
}

pub const PostGcError = error{
    InstanceNotFound,
    StaleGeneration,
    ShutdownInProgress,
    OutOfMemory,
    QueueRejected,
};

/// Generation-scoped asynchronous GC request posted to the engine event loop with an explicit allocator. Redundant requests are debounced.
pub fn postGcWithAllocator(allocator: std.mem.Allocator, instance_id: i32, generation: u64) PostGcError!bool {
    const lease = instance_map.beginControlPlane(instance_id) orelse return error.InstanceNotFound;
    defer lease.end();
    if (lease.inst.generation != generation) return error.StaleGeneration;
    if (!runtime_control.canSubmit(instance_id)) return error.ShutdownInProgress;

    while (true) {
        switch (lease.inst.gc_state.load(.acquire)) {
            .queued => return false,
            .idle => {
                if (lease.inst.gc_state.cmpxchgWeak(.idle, .submitting, .acquire, .monotonic)) |_| {
                    continue;
                }
                break;
            },
            .submitting => {
                std.Thread.yield() catch {};
                continue;
            },
        }
    }

    const task = allocator.create(GcTask) catch {
        lease.inst.gc_state.store(.idle, .release);
        return error.OutOfMemory;
    };
    task.* = .{ .allocator = allocator, .instance_id = instance_id, .inst = lease.inst };
    const token: dispatch.InstanceToken = .{ .instance_id = instance_id, .generation = generation };
    const accepted = dispatch.postTaskWithToken(token, .{
        .ctx = @ptrCast(task),
        .run = runGcTask,
        .cancel = cancelGcTask,
        .complete = null,
        .completion_ctx = null,
        .resource_kind = .script_task,
        .resource_bytes = @sizeOf(GcTask),
        .admission_check = canAdmitGc,
        .on_admitted = onAdmitGc,
    });
    if (!accepted) {
        lease.inst.gc_state.store(.idle, .release);
        allocator.destroy(task);
        return error.QueueRejected;
    }
    return true;
}

/// Generation-scoped asynchronous GC request posted to the engine event loop. Redundant requests are debounced.
pub fn postGc(instance_id: i32, generation: u64) PostGcError!bool {
    return postGcWithAllocator(std.heap.c_allocator, instance_id, generation);
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

test "submission: discards successful object results without invoking toJSON" {
    const instance_id: i32 = 58_313;
    try testing.expect(engine.create(instance_id, .{}));
    defer engine.destroy(instance_id);
    const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
    const CallbackProbe = struct {
        calls: usize = 0,
        status: Status = .cancelled,

        fn record(_: i32, _: u64, status: Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
            self.calls += 1;
            self.status = status;
        }
    };
    var probe = CallbackProbe{};
    const source = "globalThis.__submission_json_count = 0; globalThis.__submission_checkpoint = 0; queueMicrotask(() => { __submission_checkpoint = 1; }); ({ toJSON() { __submission_json_count += 1; return 1; } })";
    try testing.expect(postScript(instance_id, token.generation, source, "<submission-result>", CallbackProbe.record, @ptrCast(&probe)));
    try testing.expect(dispatch.tickInstance(instance_id) >= 1);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(Status.completed, probe.status);

    const state = engine.evalScript(instance_id, "__submission_json_count + ':' + __submission_checkpoint", "<submission-result-check>");
    defer if (state.result) |value| std.heap.c_allocator.free(@constCast(value));
    try testing.expect(state.err == null);
    try testing.expectEqualStrings("0:1", state.result.?);
}

test "submission: packed backend discards successful object results" {
    if (!backend.multi_pack) return error.SkipZigTest;
    var available: [8]c_api.BackendC = undefined;
    const count = c_api.jsbay_available_backends(&available, available.len);
    const primary = c_api.jsbay_library_backend();
    var exercised: usize = 0;
    for (available[0..count]) |tag| {
        if (@backingInt(tag) == primary) continue;
        const instance_id: i32 = 58_314 + @as(i32, @intCast(exercised));
        var options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = tag };
        try testing.expect(c_api.jsbay_engine_create_with_options(instance_id, &options));
        defer engine.destroy(instance_id);
        const token = dispatch.captureInstanceToken(instance_id) orelse return error.MissingToken;
        const CallbackProbe = struct {
            calls: usize = 0,
            status: Status = .cancelled,

            fn record(_: i32, _: u64, status: Status, _: ?[*]const u8, _: usize, user_data: ?*anyopaque) callconv(.c) void {
                const self: *@This() = @ptrCast(@alignCast(user_data orelse unreachable));
                self.calls += 1;
                self.status = status;
            }
        };
        var probe = CallbackProbe{};
        const source = "globalThis.__submission_json_count = 0; globalThis.__submission_checkpoint = 0; queueMicrotask(() => { __submission_checkpoint = 1; }); ({ toJSON() { __submission_json_count += 1; return 1; } })";
        try testing.expect(postScript(instance_id, token.generation, source, "<packed-submission-result>", CallbackProbe.record, @ptrCast(&probe)));
        try testing.expect(dispatch.tickInstance(instance_id) >= 1);
        try testing.expectEqual(@as(usize, 1), probe.calls);
        try testing.expectEqual(Status.completed, probe.status);
        const state = engine.evalScript(instance_id, "__submission_json_count + ':' + __submission_checkpoint", "<packed-submission-result-check>");
        defer if (state.result) |value| std.heap.c_allocator.free(@constCast(value));
        try testing.expect(state.err == null);
        try testing.expectEqualStrings("0:1", state.result.?);
        exercised += 1;
    }
    if (exercised == 0) return error.SkipZigTest;
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
