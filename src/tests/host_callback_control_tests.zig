//! Host callback cancellation must survive both callback outcomes and explicit user-interrupt clear.
const std = @import("std");
const testing = std.testing;
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const control = @import("../runtime/runtime_control.zig");
const host = @import("../abi/host_value.zig");
const helpers = @import("test_helpers.zig");
const backend = @import("../backend.zig");

const HostCancelProbe = struct {
    armed: bool = false,
    clear: bool = false,

    fn stop(id: c_int, raw: ?*anyopaque, _: u32, _: ?[*]const host.HostValue, out: *host.HostValue) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.armed = control.requestStopInterrupt(id);
        host.clear(out);
        return 1;
    }

    fn terminal(id: c_int, raw: ?*anyopaque, _: u32, _: ?[*]const host.HostValue, out: *host.HostValue) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.armed = control.requestShutdownCancel(id);
        self.clear = control.clearInterrupt(id);
        host.clear(out);
        return 0;
    }
};

test "execution cancellation: failed host callback rearms lifecycle stop" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var probe = HostCancelProbe{};
    try testing.expect(engine_thread.hostInstall(id, "__stopAndFail", HostCancelProbe.stop, &probe));
    const native_stop = !backend.isEscargotBackend(backend.active_backend);
    // Escargot declares lifecycle stop as cooperative host-side control, not mid-script interruption.
    const result = engine.evalScript(id, if (native_stop)
        "try { __stopAndFail(); } catch (_) {} while (true) {}"
    else
        "try { __stopAndFail(); } catch (_) {} 42", "<failed-host-stop>");
    defer helpers.freeEvalResult(result);
    try testing.expect(probe.armed);
    if (native_stop) try testing.expect(result.err != null) else try testing.expect(control.isStopRequested(id));
    try testing.expect(control.clearStopInterrupt(id));
    try helpers.expectEvalEquals(id, "40 + 2", "42");
}

test "execution cancellation: terminal cancellation survives public clear in a host callback" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    var probe = HostCancelProbe{};
    try testing.expect(engine_thread.hostInstall(id, "__terminalAndClear", HostCancelProbe.terminal, &probe));
    const result = engine.evalScript(id, "__terminalAndClear(); for (var i = 0; i < 100000; i++) {}", "<terminal-host-clear>");
    defer helpers.freeEvalResult(result);
    try testing.expect(probe.armed and probe.clear);
    try testing.expectEqual(control.ShutdownPhase.cancelled, control.shutdownStatus(id).?.phase);
    try testing.expect(!control.isHostDeferRequested(id));
    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) try testing.expect(result.err != null);
}
