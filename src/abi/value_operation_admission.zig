const builtin = @import("builtin");
const instance_map = @import("../runtime/instance_map.zig");

var before_owner_check_hook_for_testing: ?*const fn (?*anyopaque) void = null;
var before_owner_check_hook_data_for_testing: ?*anyopaque = null;
var before_backend_enter_hook_for_testing: ?*const fn (?*anyopaque) void = null;
var before_backend_enter_hook_data_for_testing: ?*anyopaque = null;

pub fn setBeforeOwnerCheckHookForTesting(hook: ?*const fn (?*anyopaque) void, data: ?*anyopaque) void {
    if (!builtin.is_test) return;
    before_owner_check_hook_for_testing = hook;
    before_owner_check_hook_data_for_testing = data;
}

pub fn setBeforeBackendEnterHookForTesting(hook: ?*const fn (?*anyopaque) void, data: ?*anyopaque) void {
    if (!builtin.is_test) return;
    before_backend_enter_hook_for_testing = hook;
    before_backend_enter_hook_data_for_testing = data;
}

pub fn runBeforeOwnerCheckHookForTesting() void {
    if (!builtin.is_test) return;
    const hook = before_owner_check_hook_for_testing orelse return;
    const data = before_owner_check_hook_data_for_testing;
    before_owner_check_hook_for_testing = null;
    before_owner_check_hook_data_for_testing = null;
    hook(data);
}

pub fn runBeforeBackendEnterHookForTesting() void {
    if (!builtin.is_test) return;
    const hook = before_backend_enter_hook_for_testing orelse return;
    const data = before_backend_enter_hook_data_for_testing;
    before_backend_enter_hook_for_testing = null;
    before_backend_enter_hook_data_for_testing = null;
    hook(data);
}

pub fn ownerAdmissionFailureStatus(id: i32, wrong_thread: c_int, instance_not_found: c_int) c_int {
    if (instance_map.isTeardownPending(id) or instance_map.getPtrs(id) == null) return instance_not_found;
    return wrong_thread;
}
