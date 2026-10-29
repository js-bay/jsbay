//! Best-effort engine telemetry events for host reporting.
//!
//! Handlers are snapshotted under the instance-map lock and invoked outside it so a
//! re-entrant host callback cannot deadlock. Handlers must not call engine/Value APIs.

const types = @import("../types.zig");
const instance_map = @import("instance_map.zig");

const Snapshot = struct {
    handler: types.EngineEventHandler,
    user_data: ?*anyopaque,
};

fn snapshot(instance_id: i32) ?Snapshot {
    return instance_map.withInstanceReturn(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?Snapshot {
            const handler = inst.event_handler orelse return null;
            return .{ .handler = handler, .user_data = inst.event_user_data };
        }
    }{});
}

pub fn setHandler(instance_id: i32, handler: ?types.EngineEventHandler, user_data: ?*anyopaque) bool {
    return instance_map.withInstanceReturn(instance_id, struct {
        handler: ?types.EngineEventHandler,
        user_data: ?*anyopaque,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?bool {
            inst.event_handler = self.handler;
            inst.event_user_data = if (self.handler != null) self.user_data else null;
            return true;
        }
    }{ .handler = handler, .user_data = user_data }) orelse false;
}

pub fn fire(
    instance_id: i32,
    kind: types.EngineEventKind,
    status: i32,
    detail: u64,
    message: ?[*:0]const u8,
) void {
    const target = snapshot(instance_id) orelse return;
    var event = types.EngineEvent{
        .struct_size = @sizeOf(types.EngineEvent),
        .kind = kind,
        .instance_id = @intCast(instance_id),
        .status = status,
        .detail = detail,
        .message = message,
    };
    target.handler(&event, target.user_data);
}

pub fn fireLog(instance_id: i32, message: ?[*:0]const u8) void {
    fire(instance_id, .log, 0, 0, message);
}

pub fn fireInterrupted(instance_id: i32, detail: u64, message: ?[*:0]const u8) void {
    fire(instance_id, .execution_interrupted, 1, detail, message); // status EXCEPTION = 1
}

pub fn fireMemoryLimit(instance_id: i32, detail: u64, status: i32) void {
    fire(instance_id, .memory_limit, status, detail, "memory limit");
}

pub fn fireLoopFailed(instance_id: i32) void {
    fire(instance_id, .loop_failed, 8, 0, "loop failed"); // LOOP_FAILED = 8
}
