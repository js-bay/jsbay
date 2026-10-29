//! Copies a configured console callback while the instance registry is locked.
//!
//! Calling host code from `withInstance` can re-enter the engine and deadlock on the registry mutex.  The configuration is immutable after create, and the enclosing JS/native task already owns the instance lifetime lease.

const instance_map = @import("../runtime/instance_map.zig");
const types = @import("../types.zig");
const engine_events = @import("../runtime/engine_events.zig");

pub const Snapshot = struct {
    handler: types.LogHandler,
    user_data: ?*anyopaque,
};

pub fn snapshot(instance_id: i32) ?Snapshot {
    return instance_map.withInstanceReturn(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?Snapshot {
            const handler = inst.log_handler orelse return null;
            return .{ .handler = handler, .user_data = inst.log_user_data };
        }
    }{});
}

/// Deliver a console line to the optional log_handler and, independently, to the telemetry event handler as JSBAY_EVENT_LOG.
pub fn deliver(instance_id: i32, level: types.LogLevel, message: [*:0]const u8) void {
    if (snapshot(instance_id)) |target| target.handler(instance_id, level, message, target.user_data);
    engine_events.fireLog(instance_id, message);
}
