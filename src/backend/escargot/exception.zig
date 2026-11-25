//! Owner-scoped typed asynchronous errors with borrowed public value handles.
const types = @import("../../types.zig");
const instances = @import("../../runtime/instance_map.zig");
const api_value = @import("../../abi/api_value.zig");
const control = @import("../../runtime/runtime_control.zig");
const c_api = @import("c_api.zig");

pub fn shouldDefer(instance_id: i32) callconv(.c) bool {
    if (control.isInterruptRequested(instance_id) or control.isStopRequested(instance_id) or control.isHostDeferRequested(instance_id)) return true;
    return if (control.remainingEffectiveExecutionLimitMillis(instance_id)) |remaining| remaining == 0 else false;
}

fn dispatch(instance_id: i32, kind: types.ErrorKind, promise: c_api.Value, reason: c_api.Value) bool {
    if (shouldDefer(instance_id)) return false;
    const inst = instances.getInstance(instance_id) orelse return true;
    const observer = inst.error_observer orelse return true;
    const userdata = inst.error_observer_userdata;
    const promise_handle = if (kind == .async_uncaught) 0 else api_value.putBorrowed(instance_id, promise) orelse return true;
    defer if (promise_handle != 0) api_value.revokeBorrowed(promise_handle);
    const reason_handle = api_value.putBorrowed(instance_id, reason) orelse return true;
    defer api_value.revokeBorrowed(reason_handle);
    var event = types.ErrorEvent{ .struct_size = @sizeOf(types.ErrorEvent), .kind = kind, .instance_id = instance_id, .promise = promise_handle, .value = reason_handle };
    observer(&event, userdata);
    return true;
}

fn onObserver(instance_id: i32, kind: i32, promise: c_api.Value, reason: c_api.Value, _: ?*anyopaque) callconv(.c) bool {
    const event_kind: types.ErrorKind = switch (kind) {
        0 => .async_uncaught,
        1 => .unhandled_rejection,
        2 => .rejection_handled,
        else => return true,
    };
    return dispatch(instance_id, event_kind, promise, reason);
}

pub fn reportAsyncUncaught(_: ?*c_api.Context, instance_id: i32, reason: c_api.Value) void {
    _ = dispatch(instance_id, .async_uncaught, null, reason);
}

pub fn setErrorObserver(ctx: ?*c_api.Context, instance_id: i32, observer: ?types.ErrorObserver, userdata: ?*anyopaque) bool {
    const inst = instances.getInstance(instance_id) orelse return false;
    inst.error_observer = observer;
    inst.error_observer_userdata = userdata;
    c_api.escargot_set_error_observer(ctx, instance_id, if (observer != null) &onObserver else null, if (observer != null) &shouldDefer else null);
    return true;
}
