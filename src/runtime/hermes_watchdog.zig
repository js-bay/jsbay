const std = @import("std");
const backend = @import("../backend.zig");
const instance_map = @import("instance_map.zig");
const runtime_control = @import("runtime_control.zig");

pub fn hermesTriggerTimeout(instance_id: i32) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    @import("../backend/hermes.zig").c_api_mod.hermes_runtime_async_trigger_timeout(rt);
}

pub fn hermesTriggerTeardownTimeout(instance_id: i32, generation: u64) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    const lease = instance_map.beginTeardownSignals(instance_id, generation) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    @import("../backend/hermes.zig").c_api_mod.hermes_runtime_async_trigger_timeout(rt);
}

pub fn hermesWatchTimeLimit(instance_id: i32, millis: u64) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    const her = @import("../backend/hermes.zig");
    if (millis == 0) {
        her.c_api_mod.hermes_runtime_unwatch_time_limit(rt);
        return;
    }
    const capped: u32 = if (millis > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(millis);
    her.c_api_mod.hermes_runtime_watch_time_limit(rt, capped);
}

pub fn hermesDrainAsyncTimeout(instance_id: i32) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    const lease = instance_map.beginControlPlane(instance_id) orelse return;
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    @import("../backend/hermes.zig").c_api_mod.hermes_runtime_drain_async_timeout(rt);
}

pub fn softRearmHermesStopAfterHost(instance_id: i32) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    const et = @import("engine_thread.zig");
    rearmOneHermesStop(instance_id);
    et.forEachEvalActiveOnCurrentThread(rearmOneHermesStop);
}

fn rearmOneHermesStop(instance_id: i32) void {
    if (comptime !backend.isHermesBackend(backend.active_backend)) return;
    if (!runtime_control.isStopRequested(instance_id)) return;
    const lease = instance_map.beginControlPlane(instance_id) orelse blk: {
        const generation = instance_map.registeredGeneration(instance_id) orelse return;
        break :blk instance_map.beginTeardownSignals(instance_id, generation) orelse return;
    };
    defer lease.end();
    const rt = lease.inst.monoRuntime() orelse return;
    const api = @import("../backend/hermes.zig").c_api_mod;
    api.hermes_runtime_drain_async_timeout(rt);
    api.hermes_runtime_watch_time_limit(rt, 25);
}
