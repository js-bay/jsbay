//! Test-only observations for the debug cold-path contracts.
//!
//! Every call is compiled away outside Zig test binaries. These counters do not choose a production code path; they only make native work observable to behavior tests that otherwise could not distinguish an unnecessary stack copy from a cheap no-op.

const std = @import("std");
const builtin = @import("builtin");

var debug_stack_copies: std.atomic.Value(usize) = .init(0);
var job_hook_callbacks: std.atomic.Value(usize) = .init(0);

pub inline fn noteDebugStackCopy() void {
    if (comptime builtin.is_test) _ = debug_stack_copies.fetchAdd(1, .seq_cst);
}

pub fn resetDebugStackCopies() void {
    if (comptime builtin.is_test) debug_stack_copies.store(0, .seq_cst);
}

pub fn debugStackCopies() usize {
    if (comptime builtin.is_test) return debug_stack_copies.load(.seq_cst);
    return 0;
}

/// Count native QuickJS job-hook invocations. This distinguishes avoiding queue retention from avoiding the callback and its depth/mutex work.
pub inline fn noteJobHookCallback() void {
    if (comptime builtin.is_test) _ = job_hook_callbacks.fetchAdd(1, .seq_cst);
}

pub fn resetJobHookCallbacks() void {
    if (comptime builtin.is_test) job_hook_callbacks.store(0, .seq_cst);
}

pub fn jobHookCallbacks() usize {
    if (comptime builtin.is_test) return job_hook_callbacks.load(.seq_cst);
    return 0;
}
