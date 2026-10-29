//! Dependency-light bridge used by backend pending-job implementations. Root installs the hook after an engine instance exists; standalone backend contexts use the backend's default scheduling when no hook recognizes them.
const std = @import("std");
const zev = @import("zev");
pub const Hook = struct {
    enter: *const fn (?*anyopaque) bool,
    leave: *const fn (?*anyopaque) void,
};
var hook: ?Hook = null;
var hook_mutex: zev.Mutex = .{};
pub fn set(value: Hook) void {
    hook_mutex.lock();
    defer hook_mutex.unlock();
    if (hook == null) hook = value else std.debug.assert(hook.?.enter == value.enter and hook.?.leave == value.leave);
}
pub fn allows(ctx: ?*anyopaque) bool {
    hook_mutex.lock();
    const value = hook;
    hook_mutex.unlock();
    return if (value) |callbacks| callbacks.enter(ctx) else true;
}

pub fn finished(ctx: ?*anyopaque) void {
    hook_mutex.lock();
    const value = hook;
    hook_mutex.unlock();
    if (value) |callbacks| callbacks.leave(ctx);
}
