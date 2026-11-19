//! Compact Bit-Matrix Dispatcher.
//!
//! Uses single-cycle hardware count-trailing-zeros instructions to route events and listeners across bit-sets without branch cascades.

const std = @import("std");

/// Branchless bit-matrix router using hardware ctz instructions for single-cycle dispatch.
pub const BitMatrix = struct {
    /// Select the next set bit representing an active, matching instance or event listener.
    pub inline fn nextMatching(active_mask: u64, filter_mask: u64, from_bit: u6) ?u6 {
        const shifted_mask = (~@as(u64, 0)) << from_bit;
        const candidate = (active_mask & filter_mask) & shifted_mask;
        if (candidate == 0) return null;
        return @truncate(@ctz(candidate));
    }

    /// Single-match fast check: returns the first matched bit if present.
    pub inline fn firstMatching(active_mask: u64, filter_mask: u64) ?u6 {
        const candidate = active_mask & filter_mask;
        if (candidate == 0) return null;
        return @truncate(@ctz(candidate));
    }

    /// Total count of active, matching entities.
    pub inline fn countMatching(active_mask: u64, filter_mask: u64) u7 {
        return @truncate(@popCount(active_mask & filter_mask));
    }
};

/// Zero-allocation, branchless iterator over matching bits.
pub const BitMatrixIterator = struct {
    remaining: u64,

    pub inline fn init(active_mask: u64, filter_mask: u64) BitMatrixIterator {
        return .{ .remaining = active_mask & filter_mask };
    }

    pub inline fn next(self: *BitMatrixIterator) ?u6 {
        if (self.remaining == 0) return null;
        const idx: u6 = @truncate(@ctz(self.remaining));
        self.remaining &= self.remaining - 1;
        return idx;
    }
};
