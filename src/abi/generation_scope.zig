const engine = @import("../engine.zig");
const builtin = @import("builtin");
const host_wake = @import("js_event_loop").host_wake;
const instance_map = @import("../runtime/instance_map.zig");

var before_packed_admission_hook: ?*const fn (?*anyopaque) void = null;
var before_packed_admission_hook_data: ?*anyopaque = null;

pub fn setBeforePackedAdmissionHookForTesting(hook: ?*const fn (?*anyopaque) void, data: ?*anyopaque) void {
    if (!builtin.is_test) return;
    before_packed_admission_hook = hook;
    before_packed_admission_hook_data = data;
}

fn runBeforePackedAdmissionHookForTesting() void {
    if (!builtin.is_test) return;
    const hook = before_packed_admission_hook orelse return;
    const data = before_packed_admission_hook_data;
    before_packed_admission_hook = null;
    before_packed_admission_hook_data = null;
    hook(data);
}

pub fn run(
    comptime Operations: type,
    invalid_argument: c_int,
    instance_not_found: c_int,
    ok_status: c_int,
    instance_id: c_int,
    generation: u64,
    callback: ?*const fn (?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) c_int {
    const cb = callback orelse return invalid_argument;
    if (host_wake.isNotifying()) return invalid_argument;
    const id: i32 = @intCast(instance_id);
    if (instance_map.generationOf(id) != generation) return instance_not_found;
    if (Operations.packedTagOf(id) != null) {
        runBeforePackedAdmissionHookForTesting();
        var op = switch (Operations.beginPackedGenerationScopeOp(id, generation)) {
            .status => |status| return if (instance_map.generationOf(id) != generation) instance_not_found else status,
            .ok => |value| value,
        };
        defer op.deinit();
        if (@import("../runtime/instance_map.zig").generationOf(id) != generation)
            return instance_not_found;
        cb(user_data);
        return ok_status;
    }
    var op = switch (Operations.beginGenerationScopeOp(id, generation)) {
        .status => |status| return if (instance_map.generationOf(id) != generation) instance_not_found else status,
        .ok => |value| value,
    };
    defer op.deinit();
    if (op.generation != generation) return instance_not_found;
    cb(user_data);
    return ok_status;
}

pub export fn jsbay_engine_destroy_generation(instance_id: c_int, generation: u64) void {
    if (host_wake.isNotifying()) return;
    engine.destroyGeneration(@intCast(instance_id), generation);
}
