pub fn Module(comptime Host: type) type {
    const std = @import("std");
    const transport_mod = @import("transport.zig");
    const sync = Host.sync;

    return struct {
        pub const message_count_cap: usize = 256;
        pub const message_bytes_cap: usize = 8 * 1024 * 1024;

        pub const Message = struct {
            session_id: transport_mod.SessionId,
            payload: []u8,
        };

        pub const Queue = struct {
            mutex: sync.Mutex = .{},
            messages: std.ArrayList(Message) = .empty,
            bytes: usize = 0,
            draining: bool = false,
        };

        pub fn admit(queue: *Queue, allocator: std.mem.Allocator, session_id: transport_mod.SessionId, payload: []const u8) !bool {
            queue.mutex.lock();
            defer queue.mutex.unlock();
            if (!queue.draining) {
                queue.draining = true;
                return true;
            }
            if (queue.messages.items.len >= message_count_cap or payload.len > message_bytes_cap - queue.bytes) return error.QueueFull;
            const copy = try allocator.dupe(u8, payload);
            errdefer allocator.free(copy);
            try queue.messages.append(allocator, .{ .session_id = session_id, .payload = copy });
            queue.bytes += payload.len;
            return false;
        }

        pub fn next(queue: *Queue) ?Message {
            queue.mutex.lock();
            defer queue.mutex.unlock();
            if (queue.messages.items.len == 0) {
                queue.draining = false;
                return null;
            }
            const message = queue.messages.orderedRemove(0);
            queue.bytes -= message.payload.len;
            return message;
        }

        pub fn discardSession(queue: *Queue, allocator: std.mem.Allocator, session_id: transport_mod.SessionId) void {
            queue.mutex.lock();
            var i: usize = 0;
            while (i < queue.messages.items.len) {
                const message = queue.messages.items[i];
                if (message.session_id != session_id) {
                    i += 1;
                    continue;
                }
                queue.bytes -= message.payload.len;
                allocator.free(message.payload);
                _ = queue.messages.orderedRemove(i);
            }
            queue.mutex.unlock();
        }

        pub fn clear(queue: *Queue, allocator: std.mem.Allocator) void {
            queue.mutex.lock();
            for (queue.messages.items) |message| allocator.free(message.payload);
            queue.messages.clearRetainingCapacity();
            queue.bytes = 0;
            queue.draining = false;
            queue.mutex.unlock();
        }

        pub fn deinit(queue: *Queue, allocator: std.mem.Allocator) void {
            clear(queue, allocator);
            queue.messages.deinit(allocator);
            queue.mutex.deinit();
        }
    };
}
