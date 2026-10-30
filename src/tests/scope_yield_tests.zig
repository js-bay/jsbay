//! Temporarily yield the engine so another thread can eval.
//!
//! ScriptX `ExitEngineScope` drops the owning thread's claim; a second thread enters, then the owner takes the claim back. Before `threadStart` there is no engine thread, so release / reacquire do nothing.

const std = @import("std");
const testing = std.testing;

const c_api = @import("../c_api.zig");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const host_value = @import("../abi/host_value.zig");
const helpers = @import("test_helpers.zig");
const io = @import("../platform/io.zig");

fn expectPosted(id: i32, src: []const u8, expected: []const u8) !void {
    const job = engine_thread.postScript(id, src, "<posted>");
    try testing.expect(job != 0);
    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    const status = engine_thread.waitJob(id, job, 8_000, &result, &err);
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    try testing.expectEqual(engine_thread.status_ok, status);
    const text = std.mem.span(result orelse return error.MissingResult);
    try testing.expectEqualStrings(expected, text);
}

fn waitStep(phase: *Phase, want: u8) bool {
    var n: u32 = 0;
    while (phase.step.load(.seq_cst) < want) : (n += 1) {
        if (phase.cancel.load(.seq_cst)) return false;
        if (n > 2000) return false;
        io.sleepMs(1);
    }
    return true;
}

const Phase = struct {
    id: i32,
    step: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    foreign_release_accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    foreign_reacquire_accepted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release_from_engine: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reacquire_from_engine: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    blocked_while_yielded: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    eval_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    blocked_after: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    refused: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

const NativeTaskProbe = struct {
    hits: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

const HoldJsProbe = struct {
    instance_id: i32 = 0,
    probe_exclusive_lease: bool = false,
    exclusive_lease_allowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn holdJsCall(
    _: c_int,
    data: ?*anyopaque,
    _: u32,
    _: ?[*]const host_value.HostValue,
    out: *host_value.HostValue,
) callconv(.c) c_int {
    const probe: *HoldJsProbe = @ptrCast(@alignCast(data orelse return 1));
    if (probe.probe_exclusive_lease) {
        const lease = engine_thread.beginExclusiveTeardown(probe.instance_id);
        probe.exclusive_lease_allowed.store(lease.allowed, .seq_cst);
        engine_thread.endEval(lease);
    }
    probe.entered.store(true, .seq_cst);
    while (!probe.release.load(.seq_cst)) io.sleepMs(1);
    host_value.clear(out);
    return 0;
}

fn countNativeTask(data: ?*anyopaque) void {
    const probe: *NativeTaskProbe = @ptrCast(@alignCast(data orelse return));
    _ = probe.hits.fetchAdd(1, .seq_cst);
}

fn foreignNop(phase: *Phase) void {
    phase.foreign_release_accepted.store(engine_thread.releaseForExternalEval(phase.id), .seq_cst);
    phase.foreign_reacquire_accepted.store(engine_thread.reacquire(phase.id), .seq_cst);
}

fn yieldOnEngine(data: ?*anyopaque) void {
    const phase: *Phase = @ptrCast(@alignCast(data orelse return));
    const released = engine_thread.releaseForExternalEval(phase.id);
    phase.release_from_engine.store(released, .seq_cst);
    if (!released) return;
    phase.step.store(1, .seq_cst);
    if (!waitStep(phase, 2)) {
        _ = engine_thread.reacquire(phase.id);
        return;
    }
    const back = engine_thread.reacquire(phase.id);
    phase.reacquire_from_engine.store(back, .seq_cst);
    phase.step.store(3, .seq_cst);
    _ = waitStep(phase, 4);
}

fn yieldWorker(phase: *Phase) void {
    if (!waitStep(phase, 1)) return;
    phase.blocked_while_yielded.store(engine_thread.foreignEvalBlocked(phase.id), .seq_cst);
    const res = engine.evalScript(phase.id, "globalThis.marker = 7; 7", "<yield>");
    const ok = if (res.err != null) false else blk: {
        const text = res.result orelse break :blk false;
        break :blk std.mem.eql(u8, text, "7");
    };
    helpers.freeEvalResult(res);
    phase.eval_ok.store(ok, .seq_cst);
    phase.step.store(2, .seq_cst);
    if (!waitStep(phase, 3)) return;
    phase.blocked_after.store(engine_thread.foreignEvalBlocked(phase.id), .seq_cst);
    const refused_res = engine.evalScript(phase.id, "globalThis.marker = 8; 8", "<after>");
    const err = refused_res.err orelse "";
    const refused = refused_res.result == null and std.mem.eql(u8, err, engine_thread.foreign_eval_err);
    helpers.freeEvalResult(refused_res);
    phase.refused.store(refused, .seq_cst);
    phase.step.store(4, .seq_cst);
}

test "scope yield: release and reacquire do nothing before threadStart" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try testing.expect(!engine_thread.foreignEvalBlocked(id));
    try testing.expect(engine_thread.releaseForExternalEval(id));
    try testing.expect(engine_thread.reacquire(id));
    try helpers.expectEvalEquals(id, "1+1", "2");
    try helpers.evalOk(id, "globalThis.marker = 1;");
    try helpers.expectEvalEquals(id, "globalThis.marker", "1");
}

const PreStartCapture = struct {
    id: i32,
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    entered: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *PreStartCapture) void {
        const lease = engine_thread.beginEval(self.id);
        self.allowed.store(lease.allowed, .seq_cst);
        self.entered.store(true, .seq_cst);
        while (!self.release.load(.seq_cst)) io.sleepMs(1);
        engine_thread.endEval(lease);
        self.done.store(true, .seq_cst);
    }
};

const ThreadStartProbe = struct {
    id: i32,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ThreadStartProbe) void {
        self.started.store(engine_thread.threadStart(self.id), .seq_cst);
        self.done.store(true, .seq_cst);
    }
};

test "scope yield: thread start waits for a pre-start capture lease" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    var cleanup = true;
    defer if (cleanup) engine.destroy(id);

    var capture = PreStartCapture{ .id = id };
    const capture_thread = try std.Thread.spawn(.{}, PreStartCapture.run, .{&capture});
    const capture_entered = waitAtomic(&capture.entered, 1000);
    var start = ThreadStartProbe{ .id = id };
    const start_thread = try std.Thread.spawn(.{}, ThreadStartProbe.run, .{&start});
    _ = waitAtomic(&start.done, 200);
    const start_returned_before_capture = start.done.load(.seq_cst);

    capture.release.store(true, .seq_cst);
    const capture_done = waitAtomic(&capture.done, 2000);
    const start_done = waitAtomic(&start.done, 2000);
    capture_thread.join();
    start_thread.join();

    // A started owner may be asleep in blockOnLoop when teardown begins. Keep the regression finite: before the loop's teardown exit condition, this join blocked forever after the existing lease assertions passed.
    const Destroy = struct {
        fn run(instance_id: i32, done: *std.atomic.Value(bool)) void {
            engine.destroy(instance_id);
            done.store(true, .seq_cst);
        }
    };
    var destroy_done = std.atomic.Value(bool).init(false);
    const destroy_thread = try std.Thread.spawn(.{}, Destroy.run, .{ id, &destroy_done });
    if (!waitAtomic(&destroy_done, 2_000)) {
        std.debug.print("scope-yield teardown did not leave the sleeping loop\n", .{});
        std.process.exit(1);
    }
    destroy_thread.join();
    cleanup = false;

    try testing.expect(capture_entered);
    try testing.expect(capture.allowed.load(.seq_cst));
    try testing.expect(!start_returned_before_capture);
    try testing.expect(capture_done);
    try testing.expect(start_done);
    try testing.expect(start.started.load(.seq_cst));
}

test "scope yield: native tasks for separate instances do not block each other" {
    const id_a = helpers.nextInstanceId();
    const id_b = helpers.nextInstanceId();
    if (!engine.create(id_a, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id_a);
    if (!engine.create(id_b, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id_b);
    try testing.expect(engine_thread.threadStart(id_a));
    try testing.expect(engine_thread.threadStart(id_b));

    var held_js = HoldJsProbe{};
    defer held_js.release.store(true, .seq_cst);
    try testing.expect(engine_thread.hostInstall(id_a, "holdJs", holdJsCall, @ptrCast(&held_js)));
    const held_job = engine_thread.postScript(id_a, "holdJs()", "<hold-native-slot>");
    try testing.expect(held_job != 0);
    const hold_deadline = io.monotonicMilliseconds() + 2000;
    while (!held_js.entered.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= hold_deadline) return error.HostCallbackDidNotEnter;
        io.sleepMs(1);
    }

    var probe_a = NativeTaskProbe{};
    var probe_b = NativeTaskProbe{};
    try testing.expect(engine_thread.postToEngineThread(id_a, countNativeTask, @ptrCast(&probe_a)));
    try testing.expect(engine_thread.postToEngineThread(id_b, countNativeTask, @ptrCast(&probe_b)));

    // Instance A cannot take its native task while the host callback is holding the engine thread. B must still accept and run its own task.
    const deadline = io.monotonicMilliseconds() + 2000;
    while (probe_b.hits.load(.seq_cst) == 0) {
        if (io.monotonicMilliseconds() >= deadline) return error.NativeTaskTimedOut;
        io.sleepMs(1);
    }
    try testing.expectEqual(@as(u32, 0), probe_a.hits.load(.seq_cst));
    held_js.release.store(true, .seq_cst);

    var result: ?[*:0]u8 = null;
    var err: ?[*:0]u8 = null;
    defer c_api.test_only.freeCString(result);
    defer c_api.test_only.freeCString(err);
    try testing.expectEqual(engine_thread.status_ok, engine_thread.waitJob(id_a, held_job, 2000, &result, &err));
    const finish_deadline = io.monotonicMilliseconds() + 2000;
    while (probe_a.hits.load(.seq_cst) == 0) {
        if (io.monotonicMilliseconds() >= finish_deadline) return error.NativeTaskTimedOut;
        io.sleepMs(1);
    }
    try testing.expectEqual(@as(u32, 1), probe_a.hits.load(.seq_cst));
    try testing.expectEqual(@as(u32, 1), probe_b.hits.load(.seq_cst));
}

const ConcurrentEvalProbe = struct {
    id: i32,
    active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    max_active: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn probeConcurrentEval(
    _: c_int,
    user_data: ?*anyopaque,
    _: u32,
    _: ?[*]const host_value.HostValue,
    out: *host_value.HostValue,
) callconv(.c) c_int {
    const probe: *ConcurrentEvalProbe = @ptrCast(@alignCast(user_data orelse return 1));
    const active = probe.active.fetchAdd(1, .seq_cst) + 1;
    var max = probe.max_active.load(.seq_cst);
    while (active > max) {
        if (probe.max_active.cmpxchgWeak(max, active, .seq_cst, .seq_cst)) |actual| {
            max = actual;
        } else break;
    }
    io.sleepMs(25);
    _ = probe.active.fetchSub(1, .seq_cst);
    host_value.clear(out);
    return 0;
}

const EvalWorker = struct {
    id: i32,
    probe: *ConcurrentEvalProbe,

    fn run(self: *EvalWorker) void {
        while (!self.probe.started.load(.seq_cst)) io.sleepMs(1);
        const res = engine.evalScript(self.id, "probeConcurrentEval()", "<yield-concurrency>");
        helpers.freeEvalResult(res);
        _ = self.probe.done.fetchAdd(1, .seq_cst);
    }
};

fn yieldConcurrentEval(data: ?*anyopaque) void {
    const probe: *ConcurrentEvalProbe = @ptrCast(@alignCast(data orelse return));
    if (!engine_thread.releaseForExternalEval(probe.id)) return;
    probe.started.store(true, .seq_cst);
    const deadline = io.monotonicMilliseconds() + 2000;
    while (probe.done.load(.seq_cst) != 2) {
        if (io.monotonicMilliseconds() >= deadline) break;
        io.sleepMs(1);
    }
    _ = engine_thread.reacquire(probe.id);
}

test "scope yield: JSC serializes simultaneous foreign evaluations" {
    if (!backend.isJscApiBackend(backend.active_backend)) return;
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);
    var probe = ConcurrentEvalProbe{ .id = id };
    try testing.expect(engine_thread.hostInstall(id, "probeConcurrentEval", probeConcurrentEval, @ptrCast(&probe)));
    try testing.expect(engine_thread.threadStart(id));

    var worker_a = EvalWorker{ .id = id, .probe = &probe };
    var worker_b = EvalWorker{ .id = id, .probe = &probe };
    const thread_a = try std.Thread.spawn(.{}, EvalWorker.run, .{&worker_a});
    const thread_b = try std.Thread.spawn(.{}, EvalWorker.run, .{&worker_b});
    try testing.expect(engine_thread.postToEngineThread(id, yieldConcurrentEval, @ptrCast(&probe)));

    const deadline = io.monotonicMilliseconds() + 3000;
    while (probe.done.load(.seq_cst) != 2) {
        if (io.monotonicMilliseconds() >= deadline) return error.ConcurrentEvalTimedOut;
        io.sleepMs(1);
    }
    thread_a.join();
    thread_b.join();
    try testing.expectEqual(@as(u32, 1), probe.max_active.load(.seq_cst));
}

const ExclusiveTeardownProbe = struct {
    id: i32,
    held_js: HoldJsProbe,
    owner_yielded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    owner_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    owner_acquired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    owner_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn waitAtomic(flag: *const std.atomic.Value(bool), timeout_ms: i64) bool {
    const deadline = io.monotonicMilliseconds() + timeout_ms;
    while (!flag.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= deadline) return false;
        io.sleepMs(1);
    }
    return true;
}

fn exclusiveTeardownOnYieldedOwner(data: ?*anyopaque) void {
    const probe: *ExclusiveTeardownProbe = @ptrCast(@alignCast(data orelse return));
    if (!engine_thread.releaseForExternalEval(probe.id)) return;
    // Publish yield before waiting for the foreign holdJs() entry so the test thread does not race a pre-yield beginEval refusal.
    probe.owner_yielded.store(true, .seq_cst);
    const deadline = io.monotonicMilliseconds() + 3000;
    while (!probe.held_js.entered.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= deadline) {
            _ = engine_thread.reacquire(probe.id);
            probe.owner_done.store(true, .seq_cst);
            return;
        }
        io.sleepMs(1);
    }

    probe.owner_requested.store(true, .seq_cst);
    const lease = engine_thread.beginExclusiveTeardown(probe.id);
    probe.owner_acquired.store(lease.allowed, .seq_cst);
    engine_thread.endEval(lease);
    _ = engine_thread.reacquire(probe.id);
    probe.owner_done.store(true, .seq_cst);
}

const HeldForeignEval = struct {
    id: i32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *HeldForeignEval) void {
        const result = engine.evalScript(self.id, "holdJs()", "<foreign-held-eval>");
        helpers.freeEvalResult(result);
        self.done.store(true, .seq_cst);
    }
};

const ForeignEvalAttempt = struct {
    id: i32,
    test_exclusive_api: bool = false,
    exclusive_allowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    succeeded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ForeignEvalAttempt) void {
        if (self.test_exclusive_api) {
            const lease = engine_thread.beginExclusiveTeardown(self.id);
            self.exclusive_allowed.store(lease.allowed, .seq_cst);
            engine_thread.endEval(lease);
        }
        const result = engine.evalScript(self.id, "1+1", "<foreign-after-stop>");
        self.succeeded.store(result.err == null and result.result != null, .seq_cst);
        helpers.freeEvalResult(result);
        self.done.store(true, .seq_cst);
    }
};

test "scope yield: JSC owner teardown excludes active foreign eval and rejects new entries" {
    if (!backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    var probe = ExclusiveTeardownProbe{
        .id = id,
        .held_js = .{ .instance_id = id, .probe_exclusive_lease = true },
    };
    try testing.expect(engine_thread.hostInstall(id, "holdJs", holdJsCall, @ptrCast(&probe.held_js)));
    try testing.expect(engine_thread.threadStart(id));
    defer engine_thread.threadStop(id);
    try testing.expect(engine_thread.postToEngineThread(id, exclusiveTeardownOnYieldedOwner, @ptrCast(&probe)));

    // Wait until the engine thread has actually yielded; a foreign eval that races before that is correctly refused and would leave holdJs unentered.
    try testing.expect(waitAtomic(&probe.owner_yielded, 2000));
    var held_eval = HeldForeignEval{ .id = id };
    const held_thread = try std.Thread.spawn(.{}, HeldForeignEval.run, .{&held_eval});
    const held_entered = waitAtomic(&probe.held_js.entered, 2000);
    const stop_requested = waitAtomic(&probe.owner_requested, 2000);

    var early_teardown = false;
    const owner_deadline = io.monotonicMilliseconds() + 100;
    while (io.monotonicMilliseconds() < owner_deadline) {
        if (probe.owner_acquired.load(.seq_cst)) {
            early_teardown = true;
            break;
        }
        io.sleepMs(1);
    }
    const new_entries_blocked = engine_thread.foreignEvalBlocked(id);

    var next_eval = ForeignEvalAttempt{ .id = id, .test_exclusive_api = true };
    const next_thread = try std.Thread.spawn(.{}, ForeignEvalAttempt.run, .{&next_eval});
    const rejected_before_release = waitAtomic(&next_eval.done, 1000);
    const second_eval_succeeded_early = next_eval.succeeded.load(.seq_cst);
    const foreign_claimed_exclusive = next_eval.exclusive_allowed.load(.seq_cst);

    probe.held_js.release.store(true, .seq_cst);
    const held_finished = waitAtomic(&held_eval.done, 3000);
    const owner_finished = waitAtomic(&probe.owner_done, 3000);
    const next_finished = waitAtomic(&next_eval.done, 3000);
    held_thread.join();
    next_thread.join();

    try testing.expect(held_entered);
    try testing.expect(probe.held_js.exclusive_lease_allowed.load(.seq_cst));
    try testing.expect(stop_requested);
    try testing.expect(!early_teardown);
    try testing.expect(new_entries_blocked);
    try testing.expect(rejected_before_release);
    try testing.expect(!foreign_claimed_exclusive);
    try testing.expect(!second_eval_succeeded_early);
    try testing.expect(held_finished);
    try testing.expect(owner_finished);
    try testing.expect(next_finished);
}

const YieldAndReturnTask = struct {
    id: i32,
    held_js: *HoldJsProbe,
    yielded: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(data: ?*anyopaque) void {
        const self: *YieldAndReturnTask = @ptrCast(@alignCast(data.?));
        if (!engine_thread.releaseForExternalEval(self.id)) {
            self.done.store(true, .seq_cst);
            return;
        }
        self.yielded.store(true, .seq_cst);
        const deadline = io.monotonicMilliseconds() + 3000;
        while (!self.held_js.entered.load(.seq_cst)) {
            if (io.monotonicMilliseconds() >= deadline) break;
            io.sleepMs(1);
        }
        // Leave the engine loop while the foreign EvalLease remains held. threadStop can now return before that already admitted eval ends.
        self.done.store(true, .seq_cst);
    }
};

const ExclusiveTeardownWorker = struct {
    id: i32,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allowed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ExclusiveTeardownWorker) void {
        self.started.store(true, .seq_cst);
        const lease = engine_thread.beginExclusiveTeardown(self.id);
        self.allowed.store(lease.allowed, .seq_cst);
        engine_thread.endEval(lease);
        self.done.store(true, .seq_cst);
    }
};

test "scope yield: JSC teardown waits for a foreign lease after threadStop" {
    if (!backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    var held_js = HoldJsProbe{ .instance_id = id, .probe_exclusive_lease = true };
    try testing.expect(engine_thread.hostInstall(id, "holdJs", holdJsCall, @ptrCast(&held_js)));
    try testing.expect(engine_thread.threadStart(id));
    var yield_task = YieldAndReturnTask{ .id = id, .held_js = &held_js };
    try testing.expect(engine_thread.postToEngineThread(id, YieldAndReturnTask.run, @ptrCast(&yield_task)));

    const yielded = waitAtomic(&yield_task.yielded, 2000);
    var held_eval = HeldForeignEval{ .id = id };
    const held_thread = try std.Thread.spawn(.{}, HeldForeignEval.run, .{&held_eval});
    const held_entered = waitAtomic(&held_js.entered, 2000);
    const yielded_task_done = waitAtomic(&yield_task.done, 2000);
    engine_thread.threadStop(id);

    var teardown = ExclusiveTeardownWorker{ .id = id };
    const teardown_thread = try std.Thread.spawn(.{}, ExclusiveTeardownWorker.run, .{&teardown});
    const teardown_started = waitAtomic(&teardown.started, 1000);
    const gate_deadline = io.monotonicMilliseconds() + 1000;
    while (!engine_thread.exclusiveEvalForTesting(id)) {
        if (io.monotonicMilliseconds() >= gate_deadline) break;
        io.sleepMs(1);
    }
    const gate_active = engine_thread.exclusiveEvalForTesting(id);
    const teardown_finished_early = teardown.done.load(.seq_cst);
    const lease_owner_nested = held_js.exclusive_lease_allowed.load(.seq_cst);

    var next_eval = ForeignEvalAttempt{ .id = id };
    const next_thread = try std.Thread.spawn(.{}, ForeignEvalAttempt.run, .{&next_eval});
    const next_rejected = waitAtomic(&next_eval.done, 1000);

    held_js.release.store(true, .seq_cst);
    const held_finished = waitAtomic(&held_eval.done, 3000);
    const teardown_finished = waitAtomic(&teardown.done, 3000);
    const next_finished = waitAtomic(&next_eval.done, 3000);
    held_thread.join();
    teardown_thread.join();
    next_thread.join();

    try testing.expect(held_entered);
    try testing.expect(yielded);
    try testing.expect(yielded_task_done);
    try testing.expect(teardown_started);
    try testing.expect(gate_active);
    try testing.expect(!teardown_finished_early);
    try testing.expect(lease_owner_nested);
    try testing.expect(next_rejected);
    try testing.expect(!next_eval.succeeded.load(.seq_cst));
    try testing.expect(held_finished);
    try testing.expect(teardown.allowed.load(.seq_cst));
    try testing.expect(teardown_finished);
    try testing.expect(next_finished);
    try helpers.expectEvalEquals(id, "6*7", "42");
}

test "scope yield: foreign eval runs while released and fails after reacquire" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    defer engine.destroy(id);

    try helpers.evalOk(id, "globalThis.marker = 0;");
    var phase = Phase{ .id = id };
    try testing.expect(engine_thread.threadStart(id));
    defer engine_thread.threadStop(id);

    // The engine thread is up. A different thread must not yield, and must not abort.
    try expectPosted(id, "1", "1");
    const nop = try std.Thread.spawn(.{}, foreignNop, .{&phase});
    nop.join();
    try testing.expect(!phase.foreign_release_accepted.load(.seq_cst));
    try testing.expect(!phase.foreign_reacquire_accepted.load(.seq_cst));

    const worker = try std.Thread.spawn(.{}, yieldWorker, .{&phase});
    defer {
        phase.cancel.store(true, .seq_cst);
        worker.join();
    }

    // Runs on the engine thread outside eval, matching ExitEngineScope.
    try testing.expect(engine_thread.postToEngineThread(id, yieldOnEngine, @ptrCast(&phase)));
    try testing.expect(waitStep(&phase, 4));

    try testing.expect(phase.release_from_engine.load(.seq_cst));
    try testing.expect(phase.reacquire_from_engine.load(.seq_cst));
    try testing.expect(!phase.blocked_while_yielded.load(.seq_cst));
    try testing.expect(phase.eval_ok.load(.seq_cst));
    try testing.expect(phase.blocked_after.load(.seq_cst));
    try testing.expect(phase.refused.load(.seq_cst));
    try expectPosted(id, "globalThis.marker", "7");
}
