//! Uncatchable execution deadlines and recovery across native evaluator boundaries.
const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const control = @import("../runtime/runtime_control.zig");
const host = @import("../abi/host_value.zig");
const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");

const Probe = struct {
    id: i32,
    target: i32,
    armed: bool = false,
    nested_cancelled: bool = false,
    clear_nested_deadline: bool = false,

    fn arm(id: c_int, raw: ?*anyopaque, _: u32, _: ?[*]const host.HostValue, out: *host.HostValue) callconv(.c) c_int {
        const self: *Probe = @ptrCast(@alignCast(raw.?));
        self.armed = control.setExecutionTimeLimit(id, 20);
        host.clear(out);
        return 0;
    }

    fn reenter(_: c_int, raw: ?*anyopaque, _: u32, _: ?[*]const host.HostValue, out: *host.HostValue) callconv(.c) c_int {
        const self: *Probe = @ptrCast(@alignCast(raw.?));
        const result = engine.evalScript(self.target, "__jsbayArmCancel(); while (true) {}", "<nested-cancellation>");
        self.nested_cancelled = result.err != null;
        helpers.freeEvalResult(result);
        // The host can explicitly recover a protected nested eval; otherwise its deadline remains active.
        if (self.clear_nested_deadline) _ = control.setExecutionTimeLimit(self.target, 0);
        host.clear(out);
        return 0;
    }
};

fn checkCancellation(script: []const u8) !void {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var probe = Probe{ .id = id, .target = id };
    try testing.expect(engine_thread.hostInstall(id, "__jsbayArmCancel", Probe.arm, &probe));
    const result = engine.evalScript(id, script, "<execution-cancellation>");
    defer helpers.freeEvalResult(result);
    try testing.expect(probe.armed);
    try testing.expect(control.setExecutionTimeLimit(id, 0));
    try helpers.expectEvalEquals(id, "String(typeof __cancelCaught === 'undefined' && typeof __cancelPast === 'undefined')", "true");
    try helpers.evalOk(id, "globalThis.__cancelRecovered = 0; Promise.resolve().then(() => { globalThis.__cancelRecovered = 1; });");
    try helpers.expectEvalEquals(id, "__cancelRecovered", "1");
    try testing.expect(control.runGc(id));
    try helpers.expectEvalEquals(id, "40 + 2", "42");
}

test "execution cancellation: deadline bypasses script catch and finally" {
    try checkCancellation("__jsbayArmCancel(); try { while (true) {} } catch (e) { globalThis.__cancelCaught = true; } finally { globalThis.__cancelCaught = true; } globalThis.__cancelPast = true;");
}

test "execution cancellation: deadline bypasses Promise executor rejection conversion" {
    try checkCancellation("new Promise(() => { __jsbayArmCancel(); try { while (true) {} } catch (e) { globalThis.__cancelCaught = true; } globalThis.__cancelPast = true; }).catch(() => { globalThis.__cancelCaught = true; });");
}

test "execution cancellation: deadline bypasses Promise job rejection conversion" {
    try checkCancellation("Promise.resolve().then(() => { __jsbayArmCancel(); try { while (true) {} } catch (e) { globalThis.__cancelCaught = true; } globalThis.__cancelPast = true; }).catch(() => { globalThis.__cancelCaught = true; });");
}

test "execution cancellation: deadline bypasses async continuation rejection conversion" {
    try checkCancellation("(async () => { await null; __jsbayArmCancel(); try { while (true) {} } catch (e) { globalThis.__cancelCaught = true; } globalThis.__cancelPast = true; })().catch(() => { globalThis.__cancelCaught = true; });");
}

test "execution cancellation: native reentry preserves the deadline until explicit host recovery" {
    for ([_]bool{ false, true }) |clear| {
        const id = helpers.nextInstanceId();
        try testing.expect(engine.create(id, .{}));
        defer engine.destroy(id);
        var probe = Probe{ .id = id, .target = id, .clear_nested_deadline = clear };
        try testing.expect(engine_thread.hostInstall(id, "__jsbayArmCancel", Probe.arm, &probe));
        try testing.expect(engine_thread.hostInstall(id, "__jsbayNestedCancel", Probe.reenter, &probe));
        // A finite opcode count need not reach JSC's CPU-time watchdog; the uncleared case must reach a real cancellation check.
        const result = engine.evalScript(id, if (clear)
            "__jsbayNestedCancel(); for (var i = 0; i < 1000000; i++) {} globalThis.__cancelPast = true;"
        else
            "__jsbayNestedCancel(); while (true) {} globalThis.__cancelPast = true;", "<outer-cancellation>");
        defer helpers.freeEvalResult(result);
        try testing.expect(probe.armed and probe.nested_cancelled);
        try testing.expectEqual(!clear, result.err != null);
        try testing.expect(control.setExecutionTimeLimit(id, 0));
        try helpers.expectEvalEquals(id, "typeof __cancelPast", if (clear) "boolean" else "undefined");
        try helpers.expectEvalEquals(id, "40 + 2", "42");
    }
}

test "execution cancellation: a nested instance cannot terminate its caller" {
    const id = helpers.nextInstanceId();
    const target = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(engine.create(target, .{}));
    defer engine.destroy(target);
    var probe = Probe{ .id = id, .target = target, .clear_nested_deadline = true };
    try testing.expect(engine_thread.hostInstall(target, "__jsbayArmCancel", Probe.arm, &probe));
    try testing.expect(engine_thread.hostInstall(id, "__jsbayNestedCancel", Probe.reenter, &probe));
    try helpers.expectEvalEquals(id, "__jsbayNestedCancel(); 42", "42");
    try testing.expect(probe.armed and probe.nested_cancelled);
    try helpers.expectEvalEquals(target, "40 + 2", "42");
}

test "execution cancellation: entry budget terminates without becoming catchable" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(control.setExecutionBudget(id, 20));
    const result = engine.evalScript(id, "try { while (true) {} } catch(e) { globalThis.__cancelCaught = true; }", "<budget-cancellation>");
    defer helpers.freeEvalResult(result);
    try testing.expect(result.err != null);
    try testing.expect(control.setExecutionBudget(id, 0));
    try helpers.expectEvalEquals(id, "typeof __cancelCaught", "undefined");
    try helpers.expectEvalEquals(id, "40 + 2", "42");
}

test "execution cancellation: generator termination preserves VM recovery" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var probe = Probe{ .id = id, .target = id };
    try testing.expect(engine_thread.hostInstall(id, "__jsbayArmCancel", Probe.arm, &probe));
    const result = engine.evalScript(id, "globalThis.__cancelGenerator = (function*(){ yield 1; __jsbayArmCancel(); while(true){} })(); __cancelGenerator.next(); __cancelGenerator.next();", "<generator-cancellation>");
    defer helpers.freeEvalResult(result);
    try testing.expect(probe.armed and result.err != null);
    try testing.expect(control.setExecutionTimeLimit(id, 0));
    if (comptime backend.active_backend == .jsc) {
        // System JSC skips generatorResume's JavaScript catch on termination, leaving that generator executing and unusable.
        try helpers.expectEvalEquals(id, "(() => { try { __cancelGenerator.next(); return 'unexpected resume'; } catch (e) { return e.name + ': ' + e.message; } })()", "TypeError: Generator is executing");
    } else {
        try helpers.expectEvalEquals(id, "String(__cancelGenerator.next().done)", "true");
    }
    try helpers.evalOk(id, "__cancelGenerator = null;");
    try testing.expect(control.runGc(id));
    try helpers.expectEvalEquals(id, "40 + 2", "42");
}

test "execution cancellation: formatting a thrown object stays inside its host boundary" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var probe = Probe{ .id = id, .target = id };
    try testing.expect(engine_thread.hostInstall(id, "__jsbayArmCancel", Probe.arm, &probe));
    const result = engine.evalScript(id, "throw { toString(){ __jsbayArmCancel(); try { while(true){} } catch(e) { globalThis.__cancelCaught = true; } } };", "<format-cancellation>");
    defer helpers.freeEvalResult(result);
    try testing.expect(probe.armed and result.err != null);
    try testing.expect(control.setExecutionTimeLimit(id, 0));
    try helpers.expectEvalEquals(id, "typeof __cancelCaught", "undefined");
    try testing.expect(control.runGc(id));
    try helpers.expectEvalEquals(id, "40 + 2", "42");
}
