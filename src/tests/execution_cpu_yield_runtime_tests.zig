//! Runtime coverage for execution CPU accounting while owner work yields.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const execution_cpu = @import("../runtime/execution_cpu.zig");
const instance_map = @import("../runtime/instance_map.zig");
const thread_cpu = @import("../platform/thread_cpu.zig");
const host_value = @import("../abi/host_value.zig");
const io = @import("../platform/io.zig");
const helpers = @import("test_helpers.zig");

const ActiveEngine = backend.ActiveEngine;
const yielded_busy_script = "var total = 0; for (var i = 0; i < 100000; i++) total += i; total;";

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
        const result = engine.evalScript(self.id, yielded_busy_script, "<execution-cpu-yield-foreign>");
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
    const foreign = std.Thread.spawn(.{}, YieldProbe.foreignRun, .{&probe}) catch |err| {
        engine_thread.threadStop(id);
        return err;
    };
    var foreign_joined = false;
    defer {
        engine_thread.threadStop(id);
        if (!foreign_joined) foreign.join();
    }
    try testing.expect(engine_thread.postToEngineThread(id, YieldProbe.ownerRun, @ptrCast(&probe)));
    try testing.expect(YieldProbe.waitFor(&probe.owner_done));
    foreign.join();
    foreign_joined = true;
    try testing.expect(probe.valid.load(.seq_cst));
    try testing.expectEqual(probe.released_total.load(.seq_cst), probe.after_host_total.load(.seq_cst));
    try expectIncreased(probe.after_host_total.load(.seq_cst), total(ledger));
}
