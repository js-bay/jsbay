const std = @import("std");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");
const io = @import("../platform/io.zig");

fn spinUntil(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const start = io.monotonicMilliseconds();
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() - start >= timeout_ms) return false;
        io.sleepMs(1);
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

const StateAdmissionPause = struct {
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),

    fn hook(data: ?*anyopaque) void {
        const self: *StateAdmissionPause = @ptrCast(@alignCast(data.?));
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) io.sleepMs(1);
    }
};

const StartRunner = struct {
    id: i32,
    started: std.atomic.Value(bool) = .init(false),
    result: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    fn go(self: *StartRunner) void {
        self.started.store(true, .seq_cst);
        self.result.store(engine_thread.threadStart(self.id), .seq_cst);
        self.done.store(true, .seq_cst);
    }
};

const ExternalDestroy = struct {
    id: i32,
    started: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),

    fn go(self: *ExternalDestroy) void {
        self.started.store(true, .seq_cst);
        engine.destroy(self.id);
        self.done.store(true, .seq_cst);
    }
};

test "engine_thread: teardown waits for admitted State creation before same-id reuse" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));

    var pause = StateAdmissionPause{};
    engine_thread.setStateAdmissionHookForTesting(StateAdmissionPause.hook, &pause);
    defer engine_thread.setStateAdmissionHookForTesting(null, null);

    var starter = StartRunner{ .id = id };
    const start_thread = try std.Thread.spawn(.{}, StartRunner.go, .{&starter});
    if (!spinUntil(&pause.entered, 1_000)) {
        pause.release.store(true, .seq_cst);
        start_thread.join();
        return error.StateAdmissionHookNotReached;
    }

    var destroy = ExternalDestroy{ .id = id };
    const destroy_thread = try std.Thread.spawn(.{}, ExternalDestroy.go, .{&destroy});
    const teardown_deadline = io.monotonicMilliseconds() + 1_000;
    while (!instance_map.isTeardownPending(id)) {
        if (io.monotonicMilliseconds() >= teardown_deadline) {
            pause.release.store(true, .seq_cst);
            start_thread.join();
            destroy_thread.join();
            return error.DestroyDidNotCloseAdmission;
        }
        io.sleepMs(1);
    }
    try std.testing.expect(!destroy.done.load(.seq_cst));
    pause.release.store(true, .seq_cst);
    joinOrExit(start_thread, &starter.done, 2_000, "State-admission start did not return");
    joinOrExit(destroy_thread, &destroy.done, 2_000, "destroy did not drain admitted State creation");
    engine_thread.setStateAdmissionHookForTesting(null, null);
    try std.testing.expect(!starter.result.load(.seq_cst));
    try std.testing.expect(engine.getContext(id) == null);

    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    const result = engine.evalScript(id, "42", "<state-generation-reuse>");
    defer helpers.freeEvalResult(result);
    try std.testing.expect(result.err == null and result.result != null and std.mem.eql(u8, result.result.?, "42"));
    engine.destroy(id);
}
