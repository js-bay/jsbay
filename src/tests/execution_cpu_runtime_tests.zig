//! Runtime coverage for execution CPU accounting.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const dispatch = @import("../runtime/dispatch.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const execution_cpu = @import("../runtime/execution_cpu.zig");
const instance_map = @import("../runtime/instance_map.zig");
const js_scheduler = @import("../runtime/js_scheduler.zig");
const promise = @import("../runtime/promise.zig");
const thread_cpu = @import("../platform/thread_cpu.zig");
const tsfn = @import("../runtime/tsfn.zig");
const host_value = @import("../abi/host_value.zig");
const io = @import("../platform/io.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;

const busy_script = "let total = 0; for (let i = 0; i < 4000000; i++) total += i; total;";

fn ledgerFor(instance_id: i32) !*execution_cpu.Ledger {
    const instance = instance_map.getInstance(instance_id) orelse return error.InstanceMissing;
    return instance.execution_cpu orelse return error.ExecutionCpuMissing;
}

fn total(ledger: *const execution_cpu.Ledger) u64 {
    return ledger.total_ns.load(.acquire);
}

fn expectIncreased(before: u64, after: u64) !void {
    if (thread_cpu.isSupported()) {
        try testing.expect(after > before);
    } else {
        try testing.expectEqual(before, after);
    }
}

fn burnHostCpu() void {
    thread_cpu.testing.consumeTick() catch @panic("CPU clock failed to advance during test work");
}

fn runBusy(instance_id: i32) !void {
    const result = engine.evalScript(instance_id, busy_script, "<execution-cpu-busy>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
}

test "execution CPU runtime: direct eval counts only engine work and isolates instances" {
    const first_id = helpers.nextInstanceId();
    const second_id = helpers.nextInstanceId();
    try testing.expect(engine.create(first_id, .{}));
    defer engine.destroy(first_id);
    try testing.expect(engine.create(second_id, .{}));
    defer engine.destroy(second_id);

    const first = try ledgerFor(first_id);
    const second = try ledgerFor(second_id);
    first.enable();
    defer first.disable();
    second.enable();
    defer second.disable();

    const before_host = total(first);
    burnHostCpu();
    try testing.expectEqual(before_host, total(first));

    const first_before = total(first);
    const second_before = total(second);
    try runBusy(first_id);
    try expectIncreased(first_before, total(first));
    try testing.expectEqual(second_before, total(second));
}

const NativeBusyTask = struct {
    instance_id: i32,
    ran: bool = false,

    fn run(raw: ?*anyopaque) void {
        const self: *NativeBusyTask = @ptrCast(@alignCast(raw orelse return));
        _ = self.instance_id;
        burnHostCpu();
        self.ran = true;
    }
};

const NestedEngineProbe = struct {
    target_id: i32,
    completed: bool = false,

    fn run(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *NestedEngineProbe = @ptrCast(@alignCast(raw orelse return 1));
        const result = engine.evalScript(self.target_id, "globalThis.__executionCpuCross = 0; for (let i = 0; i < 20000000; i++) globalThis.__executionCpuCross += i;", "<execution-cpu-cross-instance>");
        self.completed = result.err == null;
        helpers.freeEvalResult(result);
        host_value.clear(out);
        return 0;
    }
};

fn controlCost(instance_id: i32, ledger: *const execution_cpu.Ledger) !u64 {
    const before = total(ledger);
    const result = engine.evalScript(instance_id, "0", "<execution-cpu-control>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
    return total(ledger) - before;
}

test "execution CPU runtime: a disabled nested engine suppresses its enabled caller ledger" {
    const caller_id = helpers.nextInstanceId();
    const nested_id = helpers.nextInstanceId();
    try testing.expect(engine.create(caller_id, .{}));
    defer engine.destroy(caller_id);
    try testing.expect(engine.create(nested_id, .{}));
    defer engine.destroy(nested_id);
    const caller = try ledgerFor(caller_id);
    const nested = try ledgerFor(nested_id);
    caller.enable();
    defer caller.disable();
    var probe = NestedEngineProbe{ .target_id = nested_id };
    try testing.expect(engine_thread.hostInstall(caller_id, "__executionCpuCross", NestedEngineProbe.run, @ptrCast(&probe)));

    const direct_cost = try controlCost(caller_id, caller);
    const before_disabled = total(caller);
    const disabled = engine.evalScript(caller_id, "__executionCpuCross()", "<execution-cpu-cross-call>");
    defer helpers.freeEvalResult(disabled);
    try testing.expect(disabled.err == null);
    try testing.expect(probe.completed);
    const disabled_delta = total(caller) - before_disabled;
    try testing.expectEqual(@as(u64, 0), total(nested));
    try testing.expect(nested.seconds() == null);
    if (thread_cpu.isSupported()) try testing.expect(disabled_delta <= direct_cost * 8 + std.time.ns_per_ms);

    nested.enable();
    defer nested.disable();
    probe.completed = false;
    const before_enabled_caller = total(caller);
    const before_enabled_nested = total(nested);
    const enabled = engine.evalScript(caller_id, "__executionCpuCross()", "<execution-cpu-cross-call>");
    defer helpers.freeEvalResult(enabled);
    try testing.expect(enabled.err == null);
    try testing.expect(probe.completed);
    try expectIncreased(before_enabled_nested, total(nested));
    if (thread_cpu.isSupported()) try testing.expect(total(caller) - before_enabled_caller <= direct_cost * 8 + std.time.ns_per_ms);
}

const ReenteredCallerProbe = struct {
    caller_id: i32,
    nested_id: i32,
    completed: bool = false,

    fn enterNested(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *ReenteredCallerProbe = @ptrCast(@alignCast(raw orelse return 1));
        const result = engine.evalScript(self.nested_id, "__executionCpuReturnToCaller()", "<execution-cpu-enter-nested>");
        self.completed = result.err == null;
        helpers.freeEvalResult(result);
        host_value.clear(out);
        return 0;
    }

    fn returnToCaller(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *ReenteredCallerProbe = @ptrCast(@alignCast(raw orelse return 1));
        const result = engine.evalScript(self.caller_id, "var value = 0; for (let i = 0; i < 4000000; i++) value += i; globalThis.__executionCpuReentered = value;", "<execution-cpu-return-caller>");
        self.completed = result.err == null;
        helpers.freeEvalResult(result);
        host_value.clear(out);
        return 0;
    }
};

test "execution CPU runtime: an enabled caller counts reentry below a disabled nested engine" {
    const caller_id = helpers.nextInstanceId();
    const nested_id = helpers.nextInstanceId();
    try testing.expect(engine.create(caller_id, .{}));
    defer engine.destroy(caller_id);
    try testing.expect(engine.create(nested_id, .{}));
    defer engine.destroy(nested_id);
    const caller = try ledgerFor(caller_id);
    const nested = try ledgerFor(nested_id);
    caller.enable();
    defer caller.disable();
    var probe = ReenteredCallerProbe{ .caller_id = caller_id, .nested_id = nested_id };
    try testing.expect(engine_thread.hostInstall(caller_id, "__executionCpuEnterNested", ReenteredCallerProbe.enterNested, @ptrCast(&probe)));
    try testing.expect(engine_thread.hostInstall(nested_id, "__executionCpuReturnToCaller", ReenteredCallerProbe.returnToCaller, @ptrCast(&probe)));

    const direct_before = total(caller);
    try runBusy(caller_id);
    const direct_delta = total(caller) - direct_before;
    const before = total(caller);
    const result = engine.evalScript(caller_id, "__executionCpuEnterNested()", "<execution-cpu-reentry>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err == null);
    try testing.expect(probe.completed);
    try testing.expectEqual(@as(i64, 7_999_998_000_000), try helpers.evalInt(caller_id, "globalThis.__executionCpuReentered"));
    try testing.expectEqual(@as(u64, 0), total(nested));
    if (thread_cpu.isSupported()) try testing.expect(total(caller) - before > direct_delta / 4);
}

const YieldSuppressionProbe = struct {
    const Failure = enum { none, enter_middle, release, reacquire, child };

    owner_id: i32,
    middle_id: i32,
    child_id: i32,
    burn_middle: bool = false,
    valid: bool = true,
    failure: Failure = .none,
    setup_done: std.atomic.Value(bool) = .init(false),
    setup_ok: std.atomic.Value(bool) = .init(false),

    fn setupOnOwner(raw: ?*anyopaque) void {
        const self: *YieldSuppressionProbe = @ptrCast(@alignCast(raw orelse return));
        const created = engine.create(self.middle_id, .{}) and engine.create(self.child_id, .{});
        if (!created) {
            self.setup_done.store(true, .seq_cst);
            return;
        }
        const child = ledgerFor(self.child_id) catch {
            self.setup_done.store(true, .seq_cst);
            return;
        };
        child.enable();
        self.setup_ok.store(engine_thread.hostInstall(self.middle_id, "__executionCpuYieldThenChild", YieldSuppressionProbe.yieldThenChild, @ptrCast(self)), .seq_cst);
        self.setup_done.store(true, .seq_cst);
    }

    fn enterMiddle(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *YieldSuppressionProbe = @ptrCast(@alignCast(raw orelse return 1));
        const result = engine.evalScript(self.middle_id, "__executionCpuYieldThenChild()", "<execution-cpu-yield-middle>");
        if (result.err != null) {
            self.valid = false;
            self.failure = .enter_middle;
        }
        helpers.freeEvalResult(result);
        host_value.clear(out);
        return 0;
    }

    fn yieldThenChild(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *YieldSuppressionProbe = @ptrCast(@alignCast(raw orelse return 1));
        if (!engine_thread.releaseForExternalEval(self.owner_id)) {
            self.valid = false;
            self.failure = .release;
        }
        if (!engine_thread.reacquire(self.owner_id)) {
            self.valid = false;
            self.failure = .reacquire;
        }
        if (self.burn_middle) burnHostCpu();
        const result = engine.evalScript(self.child_id, "var childCpu = 0; for (var i = 0; i < 4000000; i++) childCpu += i; childCpu;", "<execution-cpu-yield-child>");
        if (result.err != null) {
            self.valid = false;
            self.failure = .child;
        }
        helpers.freeEvalResult(result);
        host_value.clear(out);
        return 0;
    }
};

fn runOnOwnerThread(instance_id: i32, source: []const u8) !void {
    var output: ?[]u8 = null;
    var failure: ?[]u8 = null;
    defer if (output) |value| std.heap.c_allocator.free(value);
    defer if (failure) |value| std.heap.c_allocator.free(value);
    try testing.expectEqual(engine_thread.status_ok, engine_thread.runScriptBytes(instance_id, source, "execution-cpu-owner.js", 10_000, &output, &failure));
}

test "execution CPU runtime: yielding inside a disabled nested engine keeps its caller suppressed" {
    const owner_id = helpers.nextInstanceId();
    const middle_id = helpers.nextInstanceId();
    const child_id = helpers.nextInstanceId();
    try testing.expect(engine.create(owner_id, .{}));
    defer engine.destroy(owner_id);
    const owner = try ledgerFor(owner_id);
    owner.enable();
    defer owner.disable();
    var probe = YieldSuppressionProbe{ .owner_id = owner_id, .middle_id = middle_id, .child_id = child_id };
    try testing.expect(engine_thread.hostInstall(owner_id, "__executionCpuYieldMiddle", YieldSuppressionProbe.enterMiddle, @ptrCast(&probe)));
    try testing.expect(engine_thread.threadStart(owner_id));
    defer engine_thread.threadStop(owner_id);
    try testing.expect(engine_thread.postToEngineThread(owner_id, YieldSuppressionProbe.setupOnOwner, @ptrCast(&probe)));
    const setup_deadline = io.monotonicMilliseconds() + 5_000;
    while (!probe.setup_done.load(.seq_cst)) {
        if (io.monotonicMilliseconds() >= setup_deadline) return error.OwnerSetupTimedOut;
        io.sleepMs(1);
    }
    try testing.expect(probe.setup_ok.load(.seq_cst));
    defer engine.destroy(middle_id);
    defer engine.destroy(child_id);
    const middle = try ledgerFor(middle_id);
    const child = try ledgerFor(child_id);
    defer child.disable();

    const control_before = total(owner);
    try runOnOwnerThread(owner_id, "__executionCpuYieldMiddle()");
    const control_delta = total(owner) - control_before;
    probe.burn_middle = true;
    const before = total(owner);
    try runOnOwnerThread(owner_id, "__executionCpuYieldMiddle()");
    if (!probe.valid) {
        return switch (probe.failure) {
            .enter_middle => error.MiddleEvaluationFailed,
            .release => error.ReleaseFailed,
            .reacquire => error.ReacquireFailed,
            .child => error.ChildEvaluationFailed,
            .none => error.UnknownProbeFailure,
        };
    }
    try testing.expectEqual(@as(u64, 0), total(middle));
    if (thread_cpu.isSupported()) try testing.expect(total(owner) - before <= control_delta * 8 + std.time.ns_per_ms);
    try testing.expect(total(child) > 0 or !thread_cpu.isSupported());
}

test "execution CPU runtime: promise, timer, and native dispatch execution increase the ledger" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ledger = try ledgerFor(id);
    ledger.enable();
    defer ledger.disable();

    const ctx = engine.getContext(id) orelse return error.ContextMissing;
    var deferred = promise.create(id) orelse return error.PromiseCreateFailed;
    defer deferred.deinit();
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    ActiveEngine.setPropertyStr(ctx, global, "__executionCpuPromise", ActiveEngine.dupValue(ctx, deferred.promise));
    try helpers.evalOk(id, "globalThis.__executionCpuPromise.then(() => { let value = 0; for (let i = 0; i < 4000000; i++) value += i; globalThis.__executionCpuPromiseValue = value; });");
    var before = total(ledger);
    const undefined_value = ActiveEngine.newUndefinedVal(ctx);
    defer ActiveEngine.freeValue(ctx, undefined_value);
    try testing.expect(deferred.resolve(undefined_value));
    js_scheduler.checkpointInstance(id);
    const promise_after = total(ledger);
    try expectIncreased(before, promise_after);
    try testing.expectEqual(@as(i64, 7_999_998_000_000), try helpers.evalInt(id, "globalThis.__executionCpuPromiseValue"));

    try helpers.evalOk(id, "setTimeout(() => { let value = 0; for (let i = 0; i < 4000000; i++) value += i; globalThis.__executionCpuTimer = value; }, 0);");
    before = total(ledger);
    _ = engine.testing.advance(id, 0);
    _ = engine.testing.advance(id, 0);
    const timer_after = total(ledger);
    try expectIncreased(before, timer_after);
    try testing.expectEqual(@as(i64, 7_999_998_000_000), try helpers.evalInt(id, "globalThis.__executionCpuTimer"));

    var task = NativeBusyTask{ .instance_id = id };
    before = total(ledger);
    try testing.expect(dispatch.postTask(id, .{ .ctx = &task, .run = NativeBusyTask.run }));
    _ = engine.testing.advance(id, 0);
    try testing.expect(task.ran);
    try expectIncreased(before, total(ledger));
}

test "execution CPU runtime: TSFN delivery increases the ledger" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ledger = try ledgerFor(id);
    ledger.enable();
    defer ledger.disable();

    try helpers.evalOk(id, "globalThis.__executionCpuTsfn = () => { let value = 0; for (let i = 0; i < 4000000; i++) value += i; globalThis.__executionCpuTsfnValue = value; };");
    const ctx = engine.getContext(id) orelse return error.ContextMissing;
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    const callback = ActiveEngine.getPropertyVal(ctx, global, "__executionCpuTsfn") orelse return error.CallbackMissing;
    defer ActiveEngine.freeValue(ctx, callback);
    const handle = tsfn.acquire(id, callback) orelse return error.TsfnAcquireFailed;
    defer tsfn.release(handle);

    const before = total(ledger);
    try testing.expect(tsfn.call(handle, "cpu"));
    try testing.expectEqual(@as(usize, 1), tsfn.drainPending(id));
    const after = total(ledger);
    try expectIncreased(before, after);
    try testing.expectEqual(@as(i64, 7_999_998_000_000), try helpers.evalInt(id, "globalThis.__executionCpuTsfnValue"));
}

const YieldProbe = struct {
    id: i32,
    released_total: std.atomic.Value(u64) = .init(0),
    after_host_total: std.atomic.Value(u64) = .init(0),
    host_ready: std.atomic.Value(bool) = .init(false),
    foreign_done: std.atomic.Value(bool) = .init(false),
    owner_done: std.atomic.Value(bool) = .init(false),
    valid: std.atomic.Value(bool) = .init(true),

    fn waitFor(flag: *const std.atomic.Value(bool)) bool {
        const deadline = io.monotonicMilliseconds() + 5_000;
        while (!flag.load(.seq_cst)) {
            if (io.monotonicMilliseconds() >= deadline) return false;
            io.sleepMs(1);
        }
        return true;
    }

    fn yieldHost(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *YieldProbe = @ptrCast(@alignCast(raw orelse return 1));
        if (!engine_thread.releaseForExternalEval(self.id)) self.valid.store(false, .seq_cst);
        const ledger = ledgerFor(self.id) catch {
            self.valid.store(false, .seq_cst);
            host_value.clear(out);
            return 0;
        };
        self.released_total.store(total(ledger), .seq_cst);
        burnHostCpu();
        self.after_host_total.store(total(ledger), .seq_cst);
        self.host_ready.store(true, .seq_cst);
        if (!waitFor(&self.foreign_done)) self.valid.store(false, .seq_cst);
        if (!engine_thread.reacquire(self.id)) self.valid.store(false, .seq_cst);
        host_value.clear(out);
        return 0;
    }

    fn ownerRun(raw: ?*anyopaque) void {
        const self: *YieldProbe = @ptrCast(@alignCast(raw orelse return));
        const result = engine.evalScript(self.id, "__executionCpuYieldHost()", "<execution-cpu-yield-owner>");
        if (result.err != null) self.valid.store(false, .seq_cst);
        helpers.freeEvalResult(result);
        self.owner_done.store(true, .seq_cst);
    }

    fn foreignRun(self: *YieldProbe) void {
        if (!waitFor(&self.host_ready)) {
            self.valid.store(false, .seq_cst);
            self.foreign_done.store(true, .seq_cst);
            return;
        }
        const result = engine.evalScript(self.id, busy_script, "<execution-cpu-yield-foreign>");
        if (result.err != null) self.valid.store(false, .seq_cst);
        helpers.freeEvalResult(result);
        self.foreign_done.store(true, .seq_cst);
    }
};

test "execution CPU runtime: yielding excludes owner host work and includes foreign engine work" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ledger = try ledgerFor(id);
    ledger.enable();
    defer ledger.disable();
    var probe = YieldProbe{ .id = id };
    try testing.expect(engine_thread.hostInstall(id, "__executionCpuYieldHost", YieldProbe.yieldHost, @ptrCast(&probe)));
    try testing.expect(engine_thread.threadStart(id));
    defer engine_thread.threadStop(id);
    const foreign = try std.Thread.spawn(.{}, YieldProbe.foreignRun, .{&probe});
    try testing.expect(engine_thread.postToEngineThread(id, YieldProbe.ownerRun, @ptrCast(&probe)));
    try testing.expect(YieldProbe.waitFor(&probe.owner_done));
    foreign.join();
    try testing.expect(probe.valid.load(.seq_cst));
    try testing.expectEqual(probe.released_total.load(.seq_cst), probe.after_host_total.load(.seq_cst));
    try expectIncreased(probe.after_host_total.load(.seq_cst), total(ledger));
}

test "execution CPU runtime: destroy and numeric-id reuse do not retain a prior ledger" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const old = try ledgerFor(id);
    old.enable();
    var in_flight = execution_cpu.begin(old);
    engine.destroy(id);
    in_flight.end();

    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const replacement = try ledgerFor(id);
    replacement.enable();
    defer replacement.disable();
    try testing.expectEqual(@as(u64, 0), total(replacement));
    try runBusy(id);
    try expectIncreased(0, total(replacement));
}

const DestroyFromCallbackProbe = struct {
    id: i32,
    scope_ended: bool = false,

    fn run(
        _: c_int,
        raw: ?*anyopaque,
        _: u32,
        _: ?[*]const host_value.HostValue,
        out: *host_value.HostValue,
    ) callconv(.c) c_int {
        const self: *DestroyFromCallbackProbe = @ptrCast(@alignCast(raw orelse return 1));
        const ledger = ledgerFor(self.id) catch {
            host_value.clear(out);
            return 1;
        };
        var scope = execution_cpu.begin(ledger);
        engine.destroy(self.id);
        scope.end();
        self.scope_ended = true;
        host_value.clear(out);
        return 0;
    }
};

test "execution CPU runtime: callback destroy defers ledger release until its scope ends" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    const ledger = try ledgerFor(id);
    ledger.enable();
    var probe = DestroyFromCallbackProbe{ .id = id };
    try testing.expect(engine_thread.hostInstall(id, "__executionCpuDestroy", DestroyFromCallbackProbe.run, @ptrCast(&probe)));
    const result = engine.evalScript(id, "__executionCpuDestroy()", "<execution-cpu-destroy-callback>");
    helpers.freeEvalResult(result);
    try testing.expect(probe.scope_ended);
    try testing.expect(instance_map.getInstance(id) == null);

    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const replacement = try ledgerFor(id);
    replacement.enable();
    defer replacement.disable();
    try testing.expectEqual(@as(u64, 0), total(replacement));
    try runBusy(id);
    try expectIncreased(0, total(replacement));
}
