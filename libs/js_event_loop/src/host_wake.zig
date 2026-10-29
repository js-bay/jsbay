//! Foreign-host notification slots. User callbacks run outside all locks; replacing or removing a handler waits for admitted notifications to finish.

const std = @import("std");
const zev = @import("zev");
const builtin = @import("builtin");

pub const Handler = *const fn (c_int, ?*anyopaque) callconv(.c) void;
const Slot = struct {
    handler: ?Handler,
    userdata: ?*anyopaque,
    active: usize = 0,
};
var mutex: zev.Mutex = .{};
var changed: zev.Condition = .init;
var slots = std.AutoHashMap(i32, *Slot).init(std.heap.c_allocator);
var slot_pool: std.heap.MemoryPool(Slot) = .empty;
threadlocal var notification_depth: usize = 0;

pub fn isNotifying() bool {
    return notification_depth != 0;
}

pub fn set(instance_id: i32, handler: ?Handler, userdata: ?*anyopaque) error{OutOfMemory}!void {
    std.debug.assert(!isNotifying());
    mutex.lock();
    while (true) {
        if (slots.get(instance_id)) |slot| {
            slot.handler = null;
            if (slot.active != 0) {
                if (builtin.is_test) test_only.notifyWaitObserver();
                changed.wait(&mutex);
                continue;
            }
            if (handler == null) {
                _ = slots.remove(instance_id);
                slot_pool.destroy(slot);
            } else {
                slot.handler = handler;
                slot.userdata = userdata;
            }
            break;
        }
        if (handler != null) {
            const slot = slot_pool.create(std.heap.c_allocator) catch {
                mutex.unlock();
                return error.OutOfMemory;
            };
            slot.* = .{ .handler = handler, .userdata = userdata };
            slots.put(instance_id, slot) catch {
                slot_pool.destroy(slot);
                mutex.unlock();
                return error.OutOfMemory;
            };
        }
        break;
    }
    mutex.unlock();
    if (handler != null) notify(instance_id);
}

pub fn drop(instance_id: i32) void {
    set(instance_id, null, null) catch unreachable;
}

pub fn notify(instance_id: i32) void {
    mutex.lock();
    const slot = slots.get(instance_id) orelse {
        mutex.unlock();
        return;
    };
    const handler = slot.handler orelse {
        mutex.unlock();
        return;
    };
    slot.active += 1;
    const userdata = slot.userdata;
    mutex.unlock();
    notification_depth += 1;
    handler(instance_id, userdata);
    notification_depth -= 1;
    mutex.lock();
    slot.active -= 1;
    if (slot.active == 0) changed.broadcast();
    mutex.unlock();
}

pub const test_only = if (builtin.is_test) struct {
    pub const WaitObserver = *const fn (?*anyopaque) void;

    var wait_observer: ?WaitObserver = null;
    var wait_observer_context: ?*anyopaque = null;

    /// The observer runs with `mutex` locked and may only signal a test barrier.
    pub fn setWaitObserver(observer: ?WaitObserver, context: ?*anyopaque) void {
        mutex.lock();
        defer mutex.unlock();
        wait_observer = observer;
        wait_observer_context = context;
    }

    fn notifyWaitObserver() void {
        if (wait_observer) |observer| observer(wait_observer_context);
    }
} else struct {
    fn notifyWaitObserver() void {}
};
