//! Typed Value handles for packed-alt (non-primary) instances.
//!
//! Values are stored as erased backend bytes + tag + ctx addr (same pattern as TimerData).
//! Handles use the high bit set so they never collide with primary `api_value` / host-string ids.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const dispatch = @import("../backend_dispatch.zig");
const instance_map = @import("../runtime/instance_map.zig");

pub const handle_flag: u64 = 1 << 63;

pub const Entry = struct {
    instance_id: i32,
    tag: backend.BackendType,
    ctx_addr: usize,
    storage: [dispatch.value_storage_size]u8 = undefined,
    len: u8,
    borrowed: bool = false,

    pub fn bytes(self: *const Entry) []const u8 {
        return self.storage[0..self.len];
    }
};

var mutex: sync.Mutex = .{};
var values = std.AutoHashMap(u64, Entry).init(std.heap.c_allocator);
var next_handle: u64 = 1;

pub fn isPackedHandle(handle: u64) bool {
    return handle & handle_flag != 0;
}

fn encode(raw: u64) u64 {
    return raw | handle_flag;
}

pub fn instanceFor(handle: u64) ?i32 {
    if (!isPackedHandle(handle)) return null;
    mutex.lock();
    defer mutex.unlock();
    return (values.get(handle) orelse return null).instance_id;
}

pub fn get(handle: u64) ?Entry {
    if (!isPackedHandle(handle)) return null;
    mutex.lock();
    defer mutex.unlock();
    return values.get(handle);
}

pub fn putOwned(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, value_bytes: []const u8) ?u64 {
    if (value_bytes.len == 0 or value_bytes.len > dispatch.value_storage_size) return null;
    mutex.lock();
    defer mutex.unlock();
    if (next_handle == 0 or next_handle > std.math.maxInt(i64)) return null;
    const handle = encode(next_handle);
    next_handle += 1;
    var entry: Entry = .{
        .instance_id = instance_id,
        .tag = tag,
        .ctx_addr = ctx_addr,
        .len = @intCast(value_bytes.len),
    };
    @memcpy(entry.storage[0..value_bytes.len], value_bytes);
    values.put(handle, entry) catch return null;
    return handle;
}

pub fn retain(handle: u64) ?u64 {
    mutex.lock();
    const entry = values.get(handle);
    mutex.unlock();
    const live = entry orelse return null;
    var dup_buf: [dispatch.value_storage_size]u8 = undefined;
    const dup_len = dispatch.timerDupValue(live.tag, live.ctx_addr, live.bytes(), dup_buf[0..]) orelse return null;
    return putOwned(live.instance_id, live.tag, live.ctx_addr, dup_buf[0..dup_len]) orelse {
        dispatch.timerFreeValue(live.tag, live.ctx_addr, dup_buf[0..dup_len]);
        return null;
    };
}

pub fn release(handle: u64) bool {
    if (!isPackedHandle(handle)) return false;
    mutex.lock();
    if ((values.get(handle) orelse {
        mutex.unlock();
        return false;
    }).borrowed) {
        mutex.unlock();
        return false;
    }
    const removed = values.fetchRemove(handle);
    mutex.unlock();
    const kv = removed orelse return false;
    dispatch.timerFreeValue(kv.value.tag, kv.value.ctx_addr, kv.value.bytes());
    return true;
}

pub fn dropInstance(instance_id: i32) void {
    while (true) {
        mutex.lock();
        var found: ?u64 = null;
        var it = values.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.instance_id == instance_id) {
                found = item.key_ptr.*;
                break;
            }
        }
        const entry = if (found) |h| values.fetchRemove(h) else null;
        mutex.unlock();
        const removed = entry orelse break;
        if (!removed.value.borrowed) {
            dispatch.timerFreeValue(removed.value.tag, removed.value.ctx_addr, removed.value.bytes());
        }
    }
}
