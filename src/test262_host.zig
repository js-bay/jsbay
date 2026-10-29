//! Test262 subprocess instrumentation, excluded from the distributed core.
const api = @import("root.zig");
var unhandled: usize = 0;

fn rejection(_: i32, handled: bool, _: [*]const u8, _: usize, _: ?*anyopaque) callconv(.c) void {
    if (!handled) unhandled += 1;
}

pub export fn jsbay_test262_watch(instance_id: c_int) bool {
    unhandled = 0;
    return api.promise.setRejectionTracker(instance_id, rejection, null);
}

pub export fn jsbay_test262_unhandled() usize {
    return unhandled;
}

comptime {
    _ = api.c_api;
}
