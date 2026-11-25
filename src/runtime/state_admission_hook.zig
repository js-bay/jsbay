var hook_for_testing: ?*const fn (?*anyopaque) void = null;
var data_for_testing: ?*anyopaque = null;

pub fn setForTesting(hook: ?*const fn (?*anyopaque) void, data: ?*anyopaque) void {
    hook_for_testing = hook;
    data_for_testing = data;
}

pub fn run() void {
    const hook = hook_for_testing;
    const data = data_for_testing;
    if (hook) |callback| callback(data);
}

pub fn setDeferredStopForTesting(
    instance_id: i32,
    hook: *const fn (?*anyopaque) void,
    data: ?*anyopaque,
    comptime retain: anytype,
    comptime release: anytype,
) bool {
    const state = retain(instance_id) orelse return false;
    defer release(state);
    state.queue_mu.lock();
    state.deferred_stop_hook_for_testing = hook;
    state.deferred_stop_hook_data_for_testing = data;
    state.queue_mu.unlock();
    return true;
}
