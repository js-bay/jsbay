//! Typed asynchronous-error observer for Hermes.
//!
//! The production C API (`jsbay_engine_set_error_observer`) is already tested as supported
//! on Hermes (only JSC is allowed to return JSBAY_UNSUPPORTED). Rejection events come from
//! the InternalBytecode hook with promise+reason values; timer / queueMicrotask throws are
//! reported as `async_uncaught` by the host timer path. Interrupt and time-limit deferral
//! match the QuickJS observer contract: keep pending events, stay quiet until recovery.

const std = @import("std");
const sync = @import("zev");
const c_api = @import("c_api.zig");
const types = @import("../../types.zig");
const api_value = @import("../../abi/api_value.zig");
const control = @import("../../runtime/runtime_control.zig");

const Context = c_api.Context;
const Value = c_api.Value;

const StoredObserver = struct {
    func: types.ErrorObserver,
    userdata: ?*anyopaque,
};

var mutex: sync.Mutex = .{};
var observers: ?std.AutoHashMap(i32, StoredObserver) = null;

fn observerMap() *std.AutoHashMap(i32, StoredObserver) {
    if (observers == null) observers = std.AutoHashMap(i32, StoredObserver).init(std.heap.c_allocator);
    return &observers.?;
}

fn copyObserver(instance_id: i32) ?StoredObserver {
    mutex.lock();
    defer mutex.unlock();
    return observerMap().get(instance_id);
}

pub fn shouldDefer(instance_id: i32) bool {
    if (control.isInterruptRequested(instance_id) or control.isStopRequested(instance_id) or control.isHostDeferRequested(instance_id)) return true;
    return if (control.remainingEffectiveExecutionLimitMillis(instance_id)) |remaining| remaining == 0 else false;
}

fn shouldDeferC(instance_id: i32) callconv(.c) bool {
    return shouldDefer(instance_id);
}

fn dispatchError(instance_id: i32, kind: types.ErrorKind, promise: Value, reason: Value) bool {
    if (shouldDefer(instance_id)) return false;
    const target = copyObserver(instance_id) orelse return true;
    const promise_handle = if (kind == .async_uncaught) 0 else (if (promise != null) api_value.putBorrowed(instance_id, promise) orelse return true else 0);
    defer if (promise_handle != 0) api_value.revokeBorrowed(promise_handle);
    const value_handle = if (reason != null) api_value.putBorrowed(instance_id, reason) orelse return true else 0;
    defer if (value_handle != 0) api_value.revokeBorrowed(value_handle);
    var event = types.ErrorEvent{
        .struct_size = @sizeOf(types.ErrorEvent),
        .kind = kind,
        .instance_id = instance_id,
        .promise = promise_handle,
        .value = value_handle,
    };
    target.func(&event, target.userdata);
    return true;
}

fn onObserver(instance_id: i32, kind: i32, promise: Value, reason: Value, _: ?*anyopaque) callconv(.c) bool {
    const k: types.ErrorKind = @enumFromInt(kind);
    return dispatchError(instance_id, k, promise, reason);
}

/// Notify the typed observer of an asynchronous uncaught exception. The caller retains ownership of `value`.
pub fn reportAsyncUncaught(_: ?*Context, instance_id: i32, value: Value) void {
    if (shouldDefer(instance_id)) return;
    _ = dispatchError(instance_id, .async_uncaught, null, value);
}

pub fn setErrorObserver(ctx: ?*Context, instance_id: i32, observer: ?types.ErrorObserver, userdata: ?*anyopaque) bool {
    const c = ctx orelse return false;
    mutex.lock();
    if (observer) |func| {
        observerMap().put(instance_id, .{ .func = func, .userdata = userdata }) catch {
            mutex.unlock();
            return false;
        };
    } else {
        _ = observerMap().remove(instance_id);
    }
    mutex.unlock();
    const fn_ptr: ?c_api.ErrorObserverFn = if (observer != null) &onObserver else null;
    const defer_ptr: ?c_api.ShouldDeferFn = if (observer != null) &shouldDeferC else null;
    return c_api.hermes_set_error_observer(c, instance_id, fn_ptr, defer_ptr, null);
}

pub fn dropObserver(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    if (observers) |*map| _ = map.remove(instance_id);
}
