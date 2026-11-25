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
