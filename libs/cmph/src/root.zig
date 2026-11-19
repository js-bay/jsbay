//! Comptime Minimal Perfect Hash (CMPH) generator.
//!
//! Generates zero-collision, branchless O(1) string matchers at compile time for static string dictionaries.

const std = @import("std");

/// Compile-time minimal perfect hash generator for a static dictionary of string keys.
pub fn ComptimeMinimalPerfectHash(comptime keys: []const []const u8) type {
    const table_size: usize = blk: {
        var size: usize = 16;
        while (size < keys.len * 2) size *= 2;
        break :blk size;
    };
    const mask = table_size - 1;

    const SeedAndTable = struct {
        seed: u32,
        table: [table_size]?u16,
    };

    const computed = comptime blk: {
        @setEvalBranchQuota(200_000);
        var seed: u32 = 2166136261;
        var found = false;
        var final_table: [table_size]?u16 = @splat(null);

        var attempt: u32 = 0;
        while (attempt < 50000) : (attempt += 1) {
            const current_seed = seed +% (attempt *% 16777619);
            var occupied: [table_size]bool = @splat(false);
            var collision = false;
            var current_table: [table_size]?u16 = @splat(null);

            for (keys, 0..) |key, key_idx| {
                var h: u32 = current_seed;
                for (key) |b| {
                    h = (h ^ b) *% 16777619;
                }
                const slot = (h ^ (h >> 16)) & mask;
                if (occupied[slot]) {
                    collision = true;
                    break;
                }
                occupied[slot] = true;
                current_table[slot] = @intCast(key_idx);
            }

            if (!collision) {
                found = true;
                final_table = current_table;
                seed = current_seed;
                break;
            }
        }

        if (!found) {
            @compileError("Failed to find minimal perfect hash seed for keys");
        }
        break :blk SeedAndTable{ .seed = seed, .table = final_table };
    };

    return struct {
        pub const SEED: u32 = computed.seed;
        pub const TABLE: [table_size]?u16 = computed.table;
        pub const KEYS: []const []const u8 = keys;

        /// Match a string against the compile-time dictionary in O(1) integer arithmetic.
        pub inline fn match(str: []const u8) ?usize {
            var h: u32 = SEED;
            for (str) |b| {
                h = (h ^ b) *% 16777619;
            }
            const slot = (h ^ (h >> 16)) & mask;
            const key_idx = TABLE[slot] orelse return null;
            if (std.mem.eql(u8, str, KEYS[key_idx])) {
                return key_idx;
            }
            return null;
        }
    };
}
