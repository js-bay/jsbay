//! Boundary and lifecycle tests for engine thread direct eval and replacement.
const std = @import("std");
const testing = std.testing;

const c_api = @import("../c_api.zig");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread_mod = @import("../runtime/engine_thread.zig");
const host_value = @import("../abi/host_value.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;
const JsBayHostValue = host_value.HostValue;
const JsBayHostFn = host_value.HostFn;
const host_number: u32 = 1;

fn skipEscargotDestroyDefer() !void {
    if (comptime backend.isEscargotBackend(backend.active_backend)) return error.SkipZigTest;
}

fn spinUntil(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const deadline = io.monotonicMilliseconds() + timeout_ms;
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= deadline) return false;
        std.Thread.yield() catch {};
    }
    return true;
}

fn joinOrExit(thread: std.Thread, done: *const std.atomic.Value(bool), timeout_ms: i64, what: []const u8) void {
    if (!spinUntil(done, timeout_ms)) {
        std.debug.print("{s} did not finish within {d}ms\n", .{ what, timeout_ms });
        std.process.exit(1);
    }
    thread.join();
}

const Live = struct {
    id: i32,
    closed: bool = false,

    fn close(self: *Live) void {
        if (self.closed) return;
        engine.destroy(self.id);
        self.closed = true;
    }
};

fn createInstance(id: i32) !Live {
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    return .{ .id = id };
}

fn install(id: i32, name: []const u8, func: JsBayHostFn, user: ?*anyopaque) !void {
    try testing.expect(engine_thread_mod.hostInstall(id, name, func, user));
}

const DestroyFromHost = struct {
    destroy_entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    callback_returned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn cb(
        instance_id: c_int,
        user: ?*anyopaque,
        _: u32,
        _: ?[*]const JsBayHostValue,
        out: *JsBayHostValue,
    ) callconv(.c) c_int {
        const self: *DestroyFromHost = @ptrCast(@alignCast(user.?));
        self.destroy_entered.store(true, .seq_cst);
        engine.destroy(instance_id);
        out.* = .{
            .tag = host_number,
            .reserved = 0,
            .number = 1,
            .ptr = null,
            .len = 0,
        };
        self.callback_returned.store(true, .seq_cst);
        return 0;
    }
};

const DirectEvalDestroy = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    result_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *DirectEvalDestroy) void {
        const result = engine.evalScript(self.id, "hostDestroy(); 42", "<direct-destroy-eval>");
        self.result_ok.store(result.err == null and result.result != null and std.mem.eql(u8, result.result.?, "42"), .seq_cst);
        helpers.freeEvalResult(result);
        self.done.store(true, .seq_cst);
    }
};

const FinishEvalDestroyReuseProbe = struct {
    id: i32,
    reached: std.atomic.Value(bool) = .init(false),
    resume_hook: std.atomic.Value(bool) = .init(false),
    replacement_done: std.atomic.Value(bool) = .init(false),
    replacement_created: std.atomic.Value(bool) = .init(false),

    fn pauseAfterLeaseRelease(instance_id: i32, raw: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        std.debug.assert(instance_id == self.id);
        self.reached.store(true, .seq_cst);
        while (!self.resume_hook.load(.seq_cst)) std.Thread.yield() catch {};
    }

    fn destroyAndReplace(self: *@This()) void {
        engine.destroy(self.id);
        self.replacement_created.store(engine.create(self.id, .{}), .seq_cst);
        self.replacement_done.store(true, .seq_cst);
    }
};

test "engine_thread: direct eval callback destroy defers runtime free until eval unwinds" {
    try skipEscargotDestroyDefer();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var dying = DestroyFromHost{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &dying);
    var direct = DirectEvalDestroy{ .id = id };
    const eval_thread = try std.Thread.spawn(.{}, DirectEvalDestroy.run, .{&direct});
    joinOrExit(eval_thread, &direct.done, 3000, "destroy from direct eval callback did not unwind");
    cleanup = false;
    live.closed = true;

    try testing.expect(dying.destroy_entered.load(.seq_cst));
    try testing.expect(dying.callback_returned.load(.seq_cst));
    try testing.expect(direct.result_ok.load(.seq_cst));
    try testing.expect(engine.getContext(id) == null);
}

test "engine_thread: direct eval deferred destroy preserves a same-id replacement" {
    try skipEscargotDestroyDefer();
    const id = helpers.nextInstanceId();
    var live = try createInstance(id);
    var cleanup = true;
    errdefer if (cleanup) live.close();

    var old_snapshot: c_api.InstanceSnapshotC = undefined;
    old_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try testing.expect(c_api.jsbay_engine_snapshot(id, &old_snapshot));

    var dying = DestroyFromHost{};
    try install(id, "hostDestroy", DestroyFromHost.cb, &dying);
    var direct = DirectEvalDestroy{ .id = id };
    var probe = FinishEvalDestroyReuseProbe{ .id = id };
    engine.setFinishEvalDestroyHookForTesting(FinishEvalDestroyReuseProbe.pauseAfterLeaseRelease, @ptrCast(&probe));
    defer {
        probe.resume_hook.store(true, .seq_cst);
        engine.setFinishEvalDestroyHookForTesting(null, null);
    }

    const eval_thread = try std.Thread.spawn(.{}, DirectEvalDestroy.run, .{&direct});
    if (!spinUntil(&probe.reached, 3_000)) {
        probe.resume_hook.store(true, .seq_cst);
        joinOrExit(eval_thread, &direct.done, 3_000, "direct eval did not reach deferred destroy handoff");
        return error.DeferredDestroyHandoffNotReached;
    }

    const replace_thread = try std.Thread.spawn(.{}, FinishEvalDestroyReuseProbe.destroyAndReplace, .{&probe});
    joinOrExit(replace_thread, &probe.replacement_done, 3_000, "same-id replacement did not finish");
    try testing.expect(probe.replacement_created.load(.seq_cst));
    const replacement_generation = instance_map.captureGeneration(id) orelse return error.ReplacementMissing;
    try testing.expect(replacement_generation != old_snapshot.generation);

    probe.resume_hook.store(true, .seq_cst);
    joinOrExit(eval_thread, &direct.done, 3_000, "direct eval did not finish after deferred destroy resumed");
    engine.setFinishEvalDestroyHookForTesting(null, null);

    try testing.expect(dying.destroy_entered.load(.seq_cst));
    try testing.expect(dying.callback_returned.load(.seq_cst));
    try testing.expect(direct.result_ok.load(.seq_cst));
    try testing.expect(engine.getContext(id) != null);
    try testing.expectEqual(replacement_generation, instance_map.captureGeneration(id).?);
    engine.destroy(id);
    cleanup = false;
    live.closed = true;
}
