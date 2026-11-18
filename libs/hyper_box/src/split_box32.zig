//! 32-bit register split layout and dual-track Value abstraction.
//!
//! On 32-bit architectures, a 64-bit value occupies a pair of 32-bit registers (e.g. r0/r1 on ARM, edx:eax on x86). SplitBox32 provides word-level register unpacking and zero-cost 32-bit compatibility.

const std = @import("std");
const builtin = @import("builtin");

pub const SplitBox32 = if (builtin.cpu.arch.endian() == .little) extern struct {
    payload: u32,
    tag: u32,

    pub inline fn fromU64(raw: u64) SplitBox32 {
        return .{
            .payload = @truncate(raw),
            .tag = @truncate(raw >> 32),
        };
    }

    pub inline fn toU64(self: SplitBox32) u64 {
        return (@as(u64, self.tag) << 32) | @as(u64, self.payload);
    }
} else extern struct {
    tag: u32,
    payload: u32,

    pub inline fn fromU64(raw: u64) SplitBox32 {
        return .{
            .tag = @truncate(raw >> 32),
            .payload = @truncate(raw),
        };
    }

    pub inline fn toU64(self: SplitBox32) u64 {
        return (@as(u64, self.tag) << 32) | @as(u64, self.payload);
    }
};
