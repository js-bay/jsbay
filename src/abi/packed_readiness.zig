const backend = @import("../backend.zig");
const api_value = @import("api_value.zig");
const host_wake = @import("js_event_loop").host_wake;
const instance_map = @import("../runtime/instance_map.zig");

pub fn Result(comptime BackendType: type) type {
    return union(enum) {
        ok: struct { tag: BackendType, ctx_addr: usize },
        status: c_int,
    };
}

pub fn check(
    comptime Operations: type,
    instance_id: i32,
    check_loop_error: bool,
    invalid_argument: c_int,
    instance_not_found: c_int,
    wrong_thread: c_int,
    loop_failed: c_int,
) Result(backend.BackendType) {
    if (host_wake.isNotifying()) return .{ .status = invalid_argument };
    if (instance_map.isTeardownPending(instance_id)) return .{ .status = instance_not_found };
    if (!api_value.isOwner(instance_id)) {
        return .{ .status = if (instance_map.getPtrs(instance_id) == null) instance_not_found else wrong_thread };
    }
    const tag = Operations.packedTagOf(instance_id) orelse return .{ .status = instance_not_found };
    const handles = Operations.packedHandlesOf(instance_id) orelse return .{ .status = instance_not_found };
    if (check_loop_error) {
        if (instance_map.getInstance(instance_id)) |inst| {
            if (inst.loop.lastError() != null) return .{ .status = loop_failed };
        }
    }
    return .{ .ok = .{ .tag = tag, .ctx_addr = handles.ctx_addr } };
}
