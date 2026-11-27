const std = @import("std");

/// Queue for dispatched tasks, protected by the owning EngineInstance task mutex.
pub const TaskQueue = struct {
    items: std.ArrayList([:0]const u8) = .empty,
    head: usize = 0,

    pub fn pendingLen(self: *const TaskQueue) usize {
        return self.items.items.len - self.head;
    }

    pub fn pendingSlice(self: *const TaskQueue) []const [:0]const u8 {
        return self.items.items[self.head..];
    }

    pub fn push(self: *TaskQueue, allocator: std.mem.Allocator, script: [:0]const u8) !void {
        if (self.head > 0 and self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        }
        try self.items.append(allocator, script);
    }

    pub fn popFront(self: *TaskQueue) ?[:0]const u8 {
        if (self.head >= self.items.items.len) return null;
        const script = self.items.items[self.head];
        self.head += 1;
        if (self.head == self.items.items.len) {
            self.items.clearRetainingCapacity();
            self.head = 0;
        } else if (self.head >= 64 and self.head >= self.items.items.len / 2) {
            const remain = self.items.items[self.head..];
            var write: usize = 0;
            while (write < remain.len) : (write += 1) {
                self.items.items[write] = remain[write];
            }
            self.items.shrinkRetainingCapacity(remain.len);
            self.head = 0;
        }
        return script;
    }

    pub fn clear(self: *TaskQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.items = .empty;
        self.head = 0;
    }
};
