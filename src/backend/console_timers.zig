//! Process-wide state for the QuickJS-family `console.time` implementation.
//!
//! Values are native allocations, so keep both label size and entry count bounded independently of a VM heap limit.  All functions are safe to call from a console callback and deliberately fail closed on allocation failure.

const std = @import("std");
const sync = @import("zev");
const io = @import("../platform/io.zig");

pub const max_label_bytes = 1024;
pub const max_timers_per_instance = 256;
pub const max_timers_total = 4096;
pub const max_label_bytes_total = 1024 * 1024;

const TimerMap = std.StringHashMapUnmanaged(i64);

var mutex: sync.Mutex = .{};
var timers: TimerMap = .{};
var total_label_bytes: usize = 0;

fn makeKey(instance_id: i32, label: []const u8) ?[]u8 {
    if (label.len > max_label_bytes) return null;
    const key = std.heap.c_allocator.alloc(u8, @sizeOf(i32) + label.len) catch return null;
    std.mem.writeInt(i32, key[0..@sizeOf(i32)], instance_id, .little);
    @memcpy(key[@sizeOf(i32)..], label);
    return key;
}

fn keyInstanceId(key: []const u8) i32 {
    return std.mem.readInt(i32, key[0..@sizeOf(i32)], .little);
}

fn keyLabelLen(key: []const u8) usize {
    return key.len - @sizeOf(i32);
}

fn countForInstance(instance_id: i32) usize {
    var count: usize = 0;
    var it = timers.iterator();
    while (it.next()) |entry| {
        if (keyInstanceId(entry.key_ptr.*) == instance_id) count += 1;
    }
    return count;
}

/// Starts a timer only when it does not already exist.  The Web console contract does not reset a duplicate label; preserving the first timestamp also avoids replacing map-owned keys.
pub fn remember(instance_id: i32, label: []const u8) void {
    const key = makeKey(instance_id, label) orelse return;
    mutex.lock();
    defer mutex.unlock();

    if (timers.contains(key)) {
        std.heap.c_allocator.free(key);
        return;
    }
    if (timers.count() >= max_timers_total or
        countForInstance(instance_id) >= max_timers_per_instance or
        total_label_bytes + label.len > max_label_bytes_total)
    {
        std.heap.c_allocator.free(key);
        return;
    }
    timers.put(std.heap.c_allocator, key, io.milliTimestamp()) catch {
        std.heap.c_allocator.free(key);
        return;
    };
    total_label_bytes += label.len;
}

pub fn take(instance_id: i32, label: []const u8) ?i64 {
    const key = makeKey(instance_id, label) orelse return null;
    defer std.heap.c_allocator.free(key);
    mutex.lock();
    defer mutex.unlock();

    const removed = timers.fetchRemove(key) orelse return null;
    total_label_bytes -= keyLabelLen(removed.key);
    std.heap.c_allocator.free(removed.key);
    releaseStorageIfIdle();
    return removed.value;
}

/// Releases timer state before an instance id may be reused by another realm.
pub fn deinitInstance(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();

    while (true) {
        var it = timers.iterator();
        const key = while (it.next()) |entry| {
            if (keyInstanceId(entry.key_ptr.*) == instance_id) break entry.key_ptr.*;
        } else break;
        const removed = timers.fetchRemove(key).?;
        total_label_bytes -= keyLabelLen(removed.key);
        std.heap.c_allocator.free(removed.key);
    }
    releaseStorageIfIdle();
}

fn releaseStorageIfIdle() void {
    if (timers.count() != 0) return;
    timers.deinit(std.heap.c_allocator);
    timers = .{};
    total_label_bytes = 0;
}

test "console timer limits bound labels, entries, and native bytes" {
    const testing = std.testing;
    const base: i32 = -1_000_000_000;

    var oversized: [max_label_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    remember(base, &oversized);
    try testing.expect(take(base, &oversized) == null);

    var index: usize = 0;
    while (index < max_timers_total) : (index += 1) {
        const id = base + @as(i32, @intCast(index + 1));
        remember(id, "entry");
    }
    const overflow_entry_id = base + @as(i32, @intCast(max_timers_total + 1));
    remember(overflow_entry_id, "entry");
    try testing.expect(take(overflow_entry_id, "entry") == null);
    deinitInstance(base + 1);
    remember(overflow_entry_id, "entry");
    try testing.expect(take(overflow_entry_id, "entry") != null);
    index = 0;
    while (index < max_timers_total) : (index += 1) {
        deinitInstance(base + @as(i32, @intCast(index + 1)));
    }

    var label: [max_label_bytes]u8 = undefined;
    @memset(&label, 'y');
    index = 0;
    while (index < max_label_bytes_total / max_label_bytes) : (index += 1) {
        remember(base + @as(i32, @intCast(index + 20_000)), &label);
    }
    const overflow_byte_id = base + 30_000;
    remember(overflow_byte_id, "extra");
    try testing.expect(take(overflow_byte_id, "extra") == null);
    deinitInstance(base + 20_000);
    remember(overflow_byte_id, "extra");
    try testing.expect(take(overflow_byte_id, "extra") != null);
    index = 0;
    while (index < max_label_bytes_total / max_label_bytes) : (index += 1) {
        deinitInstance(base + @as(i32, @intCast(index + 20_000)));
    }
}

test "console timer duplicate preserves its map-owned key and timestamp" {
    const testing = std.testing;
    const instance_id: i32 = -999_999_999;
    const label = "duplicate";
    defer deinitInstance(instance_id);

    remember(instance_id, label);
    const lookup = makeKey(instance_id, label) orelse return error.OutOfMemory;
    defer std.heap.c_allocator.free(lookup);

    mutex.lock();
    var first_key_address: usize = 0;
    var it = timers.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, lookup)) continue;
        first_key_address = @intFromPtr(entry.key_ptr.*.ptr);
        entry.value_ptr.* = -123;
        break;
    }
    mutex.unlock();
    try testing.expect(first_key_address != 0);

    remember(instance_id, label);
    mutex.lock();
    defer mutex.unlock();
    it = timers.iterator();
    while (it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, lookup)) continue;
        try testing.expectEqual(first_key_address, @intFromPtr(entry.key_ptr.*.ptr));
        try testing.expectEqual(@as(i64, -123), entry.value_ptr.*);
        return;
    }
    return error.TimerMissing;
}
