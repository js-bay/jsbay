const api_value = @import("api_value.zig");
const engine = @import("../engine.zig");
const engine_thread = @import("../runtime/engine_thread.zig");
const host_wake = @import("js_event_loop").host_wake;
const instance_map = @import("../runtime/instance_map.zig");
const backend_dispatch = @import("../backend_dispatch.zig");

pub fn begin(
    comptime Operations: type,
    instance_id: i32,
    expected_generation: u64,
    invalid_argument: c_int,
    instance_not_found: c_int,
    wrong_thread: c_int,
) Operations.PackedJsOpResult {
    if (host_wake.isNotifying()) return .{ .status = invalid_argument };
    if (instance_map.isTeardownPending(instance_id)) return .{ .status = instance_not_found };
    if (!api_value.isOwner(instance_id)) {
        return .{ .status = if (instance_map.getPtrs(instance_id) == null) instance_not_found else wrong_thread };
    }
    const lease = engine_thread.beginEval(instance_id);
    if (!lease.allowed) {
        return .{ .status = if (instance_map.getPtrs(instance_id) == null) instance_not_found else wrong_thread };
    }
    const inst = instance_map.getInstance(instance_id) orelse {
        engine.finishEvalEntry(instance_id, lease);
        return .{ .status = instance_not_found };
    };
    if (lease.generation != expected_generation or inst.generation != lease.generation) {
        engine.finishEvalEntry(instance_id, lease);
        return .{ .status = instance_not_found };
    }
    const handles = switch (inst.engine_handles) {
        .mono => {
            engine.finishEvalEntry(instance_id, lease);
            return .{ .status = instance_not_found };
        },
        .packed_alt => |handles| handles,
    };
    if (!backend_dispatch.enterJsPacked(handles.tag, handles.ctx_addr)) {
        engine.finishEvalEntry(instance_id, lease);
        return .{ .status = wrong_thread };
    }
    return .{ .ok = .{
        .id = instance_id,
        .tag = handles.tag,
        .ctx_addr = handles.ctx_addr,
        .lease = lease,
        .entered_js = true,
        .allocator = inst.allocator,
    } };
}
