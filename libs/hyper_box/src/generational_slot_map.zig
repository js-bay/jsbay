//! Generational Slot Map for Value Handles.
//!
//! Provides O(1) insertion, O(1) lookup with ABA generation validation, and O(1) removal. All active entries are stored in a contiguous array with an intrusive FIFO free list to minimize generation recycling wrap-around.

const std = @import("std");
const hyper_box64 = @import("hyper_box64.zig");
const Value = hyper_box64.Value;

pub const SENTINEL_FREE: u32 = 0xFFFF_FFFF;
pub const MAX_SLOTS: usize = 0x000F_FFFF; // 20 bits max slot index (1,048,575)

pub fn GenerationalSlotMap(comptime ValueType: type) type {
    return struct {
        const Self = @This();

        pub const Slot = struct {
            instance_id: i32 = 0,
            value: ValueType,
            generation: u16 = 1,
            is_active: bool = false,
            borrowed: bool = false,
            reserved: bool = false,
            next_free: u32 = SENTINEL_FREE,
            next_instance_slot: u32 = SENTINEL_FREE,
            prev_instance_slot: u32 = SENTINEL_FREE,
        };

        pub const Entry = struct {
            instance_id: i32,
            value: ValueType,
            borrowed: bool = false,
            reserved: bool = false,
        };

        slots: std.ArrayList(Slot),
        first_free: u32 = SENTINEL_FREE,
        last_free: u32 = SENTINEL_FREE,
        instance_heads: std.AutoHashMapUnmanaged(i32, u32) = .{},
        active_count: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .slots = std.ArrayList(Slot).empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.instance_heads.deinit(self.allocator);
            self.slots.deinit(self.allocator);
            self.* = undefined;
        }

        fn unlinkInstanceSlot(self: *Self, instance_id: i32, slot_idx: u32) void {
            const slot = &self.slots.items[slot_idx];
            const prev = slot.prev_instance_slot;
            const next = slot.next_instance_slot;
            if (prev != SENTINEL_FREE) {
                self.slots.items[prev].next_instance_slot = next;
            } else {
                if (next != SENTINEL_FREE) {
                    self.instance_heads.putAssumeCapacity(instance_id, next);
                } else {
                    _ = self.instance_heads.remove(instance_id);
                }
            }
            if (next != SENTINEL_FREE) {
                self.slots.items[next].prev_instance_slot = prev;
            }
            slot.prev_instance_slot = SENTINEL_FREE;
            slot.next_instance_slot = SENTINEL_FREE;
        }

        fn linkInstanceSlot(self: *Self, instance_id: i32, slot_idx: u32) void {
            const slot = &self.slots.items[slot_idx];
            if (self.instance_heads.getPtr(instance_id)) |head_ptr| {
                const old_head = head_ptr.*;
                slot.next_instance_slot = old_head;
                slot.prev_instance_slot = SENTINEL_FREE;
                if (old_head != SENTINEL_FREE) {
                    self.slots.items[old_head].prev_instance_slot = slot_idx;
                }
                head_ptr.* = slot_idx;
            } else {
                self.instance_heads.putAssumeCapacity(instance_id, slot_idx);
                slot.next_instance_slot = SENTINEL_FREE;
                slot.prev_instance_slot = SENTINEL_FREE;
            }
        }

        fn pushFreeSlot(self: *Self, slot_idx: u32) void {
            const slot = &self.slots.items[slot_idx];
            slot.next_free = SENTINEL_FREE;
            if (self.last_free != SENTINEL_FREE) {
                self.slots.items[self.last_free].next_free = slot_idx;
                self.last_free = slot_idx;
            } else {
                self.first_free = slot_idx;
                self.last_free = slot_idx;
            }
        }

        fn allocateSlot(self: *Self, instance_id: i32, value: ValueType, borrowed: bool, reserved: bool) !u64 {
            if (!self.instance_heads.contains(instance_id)) {
                try self.instance_heads.ensureUnusedCapacity(self.allocator, 1);
            }

            var slot_idx: u32 = 0;
            if (self.first_free != SENTINEL_FREE) {
                slot_idx = self.first_free;
                const slot = &self.slots.items[slot_idx];
                self.first_free = slot.next_free;
                if (self.first_free == SENTINEL_FREE) {
                    self.last_free = SENTINEL_FREE;
                }
                slot.instance_id = instance_id;
                slot.value = value;
                slot.is_active = true;
                slot.borrowed = borrowed;
                slot.reserved = reserved;
                slot.next_free = SENTINEL_FREE;
                self.linkInstanceSlot(instance_id, slot_idx);
                self.active_count += 1;
                return Value.fromHandle(@truncate(@as(u32, @bitCast(instance_id))), slot.generation, @truncate(slot_idx)).raw;
            }

            if (self.slots.items.len >= MAX_SLOTS) return error.OutOfMemory;
            slot_idx = @intCast(self.slots.items.len);
            try self.slots.append(self.allocator, .{
                .instance_id = instance_id,
                .value = value,
                .generation = 1,
                .is_active = true,
                .borrowed = borrowed,
                .reserved = reserved,
                .next_free = SENTINEL_FREE,
                .next_instance_slot = SENTINEL_FREE,
                .prev_instance_slot = SENTINEL_FREE,
            });
            self.linkInstanceSlot(instance_id, slot_idx);
            self.active_count += 1;
            return Value.fromHandle(@truncate(@as(u32, @bitCast(instance_id))), 1, @truncate(slot_idx)).raw;
        }

        pub fn insert(self: *Self, instance_id: i32, value: ValueType, borrowed: bool) !u64 {
            return self.allocateSlot(instance_id, value, borrowed, false);
        }

        pub fn reserve(self: *Self, instance_id: i32, dummy_value: ValueType) !u64 {
            return self.allocateSlot(instance_id, dummy_value, false, true);
        }

        pub fn commit(self: *Self, handle: u64, value: ValueType) bool {
            const val = Value{ .raw = handle };
            if (!val.isHandle()) return false;
            const h = val.decodeHandle();
            if (h.slot_index >= self.slots.items.len) return false;
            const slot = &self.slots.items[h.slot_index];
            if (!slot.is_active or slot.generation != h.generation) return false;
            if (!slot.reserved) return false;
            if (h.instance_id != @as(u12, @truncate(@as(u32, @bitCast(slot.instance_id))))) return false;
            slot.value = value;
            slot.reserved = false;
            return true;
        }

        pub fn cancel(self: *Self, handle: u64) bool {
            const val = Value{ .raw = handle };
            if (!val.isHandle()) return false;
            const h = val.decodeHandle();
            if (h.slot_index >= self.slots.items.len) return false;
            const slot = &self.slots.items[h.slot_index];
            if (!slot.is_active or slot.generation != h.generation) return false;
            if (!slot.reserved) return false;
            if (h.instance_id != @as(u12, @truncate(@as(u32, @bitCast(slot.instance_id))))) return false;
            _ = self.remove(handle);
            return true;
        }

        pub fn get(self: *const Self, handle: u64) ?Entry {
            const val = Value{ .raw = handle };
            if (!val.isHandle()) return null;
            const h = val.decodeHandle();
            if (h.slot_index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.slot_index];
            if (!slot.is_active or slot.reserved) return null;
            if (slot.generation != h.generation) return null;
            if (h.instance_id != @as(u12, @truncate(@as(u32, @bitCast(slot.instance_id))))) return null;
            return .{
                .instance_id = slot.instance_id,
                .value = slot.value,
                .borrowed = slot.borrowed,
                .reserved = false,
            };
        }

        pub fn isReserved(self: *const Self, handle: u64) bool {
            const val = Value{ .raw = handle };
            if (!val.isHandle()) return false;
            const h = val.decodeHandle();
            if (h.slot_index >= self.slots.items.len) return false;
            const slot = &self.slots.items[h.slot_index];
            if (!slot.is_active or slot.generation != h.generation) return false;
            if (h.instance_id != @as(u12, @truncate(@as(u32, @bitCast(slot.instance_id))))) return false;
            return slot.reserved;
        }

        pub fn instanceFor(self: *const Self, handle: u64) ?i32 {
            const val = Value{ .raw = handle };
            if (!val.isHandle()) return null;
            const h = val.decodeHandle();
            if (h.slot_index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.slot_index];
            if (!slot.is_active or slot.reserved) return null;
            if (slot.generation != h.generation) return null;
            if (h.instance_id != @as(u12, @truncate(@as(u32, @bitCast(slot.instance_id))))) return null;
            return slot.instance_id;
        }

        pub fn remove(self: *Self, handle: u64) ?Entry {
            const val = Value{ .raw = handle };
            if (!val.isHandle()) return null;
            const h = val.decodeHandle();
            if (h.slot_index >= self.slots.items.len) return null;
            const slot = &self.slots.items[h.slot_index];
            if (!slot.is_active or slot.generation != h.generation) return null;
            if (h.instance_id != @as(u12, @truncate(@as(u32, @bitCast(slot.instance_id))))) return null;

            const entry = Entry{
                .instance_id = slot.instance_id,
                .value = slot.value,
                .borrowed = slot.borrowed,
                .reserved = slot.reserved,
            };

            self.unlinkInstanceSlot(slot.instance_id, h.slot_index);
            slot.is_active = false;
            slot.borrowed = false;
            slot.reserved = false;
            slot.generation = slot.generation +% 1;
            if (slot.generation == 0) slot.generation = 1;
            self.pushFreeSlot(h.slot_index);
            self.active_count -= 1;
            return entry;
        }

        /// Detach the first active entry belonging to an instance in O(1) time without allocating.
        pub fn detachFirstForInstance(self: *Self, instance_id: i32) ?Entry {
            const head_idx = self.instance_heads.get(instance_id) orelse return null;
            const slot = &self.slots.items[head_idx];
            std.debug.assert(slot.is_active and slot.instance_id == instance_id);

            const entry = Entry{
                .instance_id = slot.instance_id,
                .value = slot.value,
                .borrowed = slot.borrowed,
                .reserved = slot.reserved,
            };

            self.unlinkInstanceSlot(instance_id, head_idx);
            slot.is_active = false;
            slot.borrowed = false;
            slot.reserved = false;
            slot.generation = slot.generation +% 1;
            if (slot.generation == 0) slot.generation = 1;
            self.pushFreeSlot(head_idx);
            self.active_count -= 1;
            return entry;
        }
    };
}
