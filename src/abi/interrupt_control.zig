const runtime_control = @import("../runtime/runtime_control.zig");
const instance_map = @import("../runtime/instance_map.zig");
const native_sync = @import("js_event_loop").native_sync;
const engine_events = @import("../runtime/engine_events.zig");

/// Thread-safe control-plane request. The engine owner observes the flag from its backend interrupt handler and turns the running evaluation into an exception; this function never waits for the JavaScript thread.
pub export fn jsbay_engine_request_interrupt(instance_id: c_int) bool {
    const id: i32 = @intCast(instance_id);
    const accepted = runtime_control.requestInterrupt(id);
    if (accepted) {
        native_sync.cancelForInstance(id);
        engine_events.fireInterrupted(id, 0, "interrupt requested");
    }
    return accepted;
}

/// Request a recoverable interrupt only for the specified live instance generation.
pub export fn jsbay_engine_request_interrupt_for_generation(instance_id: c_int, generation: u64) bool {
    const id: i32 = @intCast(instance_id);
    const lease = instance_map.beginControlPlane(id) orelse return false;
    defer lease.end();
    if (generation == 0 or lease.inst.generation != generation) return false;
    const accepted = runtime_control.requestInterrupt(id);
    if (accepted) {
        native_sync.cancelForInstance(id);
        engine_events.fireInterrupted(id, 0, "interrupt requested");
    }
    return accepted;
}
