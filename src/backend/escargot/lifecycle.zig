//! Escargot Runtime/Context lifecycle and eval — native EscargotPublic via C bridge.
const std = @import("std");
const types = @import("../../types.zig");
const c_api = @import("c_api.zig");

/// Match JSC: optional opaque pointers so `!= null` checks typecheck.
pub const Runtime = ?*c_api.Runtime;
pub const Context = ?*c_api.Context;

pub fn newRuntime() ?Runtime {
    return c_api.escargot_runtime_new();
}

pub fn setMaxStackSize(_: Runtime, _: usize) void {}

pub fn newContext(rt: Runtime) ?Context {
    return c_api.escargot_context_new(rt);
}

pub fn freeContext(ctx: Context) void {
    c_api.escargot_context_free(ctx);
}

pub fn freeRuntime(rt: Runtime) void {
    c_api.escargot_runtime_free(rt);
}

pub fn runGc(rt: Runtime) void {
    c_api.escargot_runtime_gc(rt);
}

pub fn processPendingJobs(ctx: Context) void {
    c_api.escargot_process_pending_jobs(ctx);
}

pub fn eval(ctx: Context, script: []const u8, filename: []const u8) types.EvalResult {
    const raw = c_api.escargot_eval(ctx, script.ptr, script.len, filename.ptr, filename.len);
    const result = if (raw.result) |p| blk: {
        const s = std.mem.span(p);
        const owned = std.heap.c_allocator.dupe(u8, s) catch {
            _ = std.c.free(p);
            if (raw.err) |e| _ = std.c.free(e);
            return .{ .result = null, .err = "Out of memory", .err_is_heap = false };
        };
        _ = std.c.free(p);
        break :blk owned;
    } else null;
    const err = if (raw.err) |p| blk: {
        const s = std.mem.span(p);
        const owned = std.heap.c_allocator.dupe(u8, s) catch {
            _ = std.c.free(p);
            if (result) |r| std.heap.c_allocator.free(r);
            return .{ .result = null, .err = "Out of memory", .err_is_heap = false };
        };
        _ = std.c.free(p);
        break :blk owned;
    } else null;
    return .{ .result = result, .err = err, .err_is_heap = err != null };
}

pub fn threadEnter() void {
    c_api.escargot_thread_enter();
}
pub fn threadLeave() void {
    c_api.escargot_thread_leave();
}
