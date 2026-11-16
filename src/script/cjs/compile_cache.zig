//! Owned compiled bytes, never module instances. Disk lookup/rebuild and VM compile/replay stay with the admitted adapter.
const std = @import("std");

pub const Memory = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMap([]u8),

    pub fn init(allocator: std.mem.Allocator) Memory {
        return .{ .allocator = allocator, .entries = std.StringHashMap([]u8).init(allocator) };
    }

    /// Borrowed until this entry is replaced or the cache is destroyed.
    pub fn get(self: *Memory, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    /// Takes key ownership only on success. Copies bytecode; replacing stale bytes keeps the existing owned key. The return is borrowed from the cache.
    pub fn memoize(self: *Memory, key: []u8, compiled: []const u8) std.mem.Allocator.Error![]const u8 {
        const owned = try self.allocator.alloc(u8, compiled.len);
        @memcpy(owned, compiled);
        const entry = self.entries.getOrPut(key) catch |err| {
            self.allocator.free(owned);
            return err;
        };
        if (entry.found_existing) {
            self.allocator.free(key);
            self.allocator.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = owned;
        return owned;
    }

    pub fn deinit(self: *Memory) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }
};

pub fn makeKey(allocator: std.mem.Allocator, source_hash: []const u8, filename_hash: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ source_hash, filename_hash });
}

test "cjs compiled bytes: replacement keeps ownership balanced across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn run(allocator: std.mem.Allocator) !void {
            var memory = Memory.init(allocator);
            defer memory.deinit();
            {
                const key = try makeKey(allocator, "source", "filename");
                errdefer allocator.free(key);
                var payload = [_]u8{ 'o', 'l', 'd' };
                _ = try memory.memoize(key, &payload);
                payload[0] = 'X';
                try std.testing.expectEqualStrings("old", memory.get("source-filename").?);
            }
            {
                const key = try makeKey(allocator, "source", "filename");
                errdefer allocator.free(key);
                _ = try memory.memoize(key, "new");
            }
            try std.testing.expectEqual(@as(usize, 1), memory.entries.count());
            try std.testing.expectEqualStrings("new", memory.get("source-filename").?);
        }
    }.run, .{});
}
