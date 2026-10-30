//! Hermes .hbc bytecode compile (via hermesc) + run (JSI evaluateJavaScript Buffer).

const std = @import("std");
const types = @import("../../types.zig");

const Context = ?*anyopaque;

const HermesCompileResult = extern struct {
    bytes: ?[*]u8,
    len: usize,
    err: ?[*:0]u8,
};
const HermesEvalResult = extern struct {
    result: ?[*:0]u8,
    err: ?[*:0]u8,
};

extern fn hermes_compile_bytecode(src: [*]const u8, src_len: usize, filename: [*]const u8, filename_len: usize) HermesCompileResult;
extern fn hermes_compile_result_free(r: HermesCompileResult) void;
extern fn hermes_run_bytecode_ex(ctx: ?*anyopaque, bytes: [*]const u8, len: usize, out_decode_failed: *c_int) HermesEvalResult;
extern fn free(ptr: ?*anyopaque) void;

fn dupeAndFree(src_opt: ?[*:0]u8) ?[]const u8 {
    const src = src_opt orelse return null;
    const slice = std.mem.span(src);
    const owned = std.heap.c_allocator.dupe(u8, slice) catch {
        free(@ptrCast(src));
        return null;
    };
    free(@ptrCast(src));
    return owned;
}

pub const CompileOut = struct {
    bytes: ?[]u8 = null,
    err: ?[]const u8 = null,
};

pub fn hermesCompileBytecode(source: []const u8, filename: []const u8) CompileOut {
    // Empty Zig slices may have undefined .ptr — never pass that to C.
    const src_ptr: [*]const u8 = if (source.len > 0) source.ptr else @as([*]const u8, @ptrCast(""));
    const file_ptr: [*]const u8 = if (filename.len > 0) filename.ptr else @as([*]const u8, @ptrCast("<eval>"));
    const r = hermes_compile_bytecode(src_ptr, source.len, file_ptr, if (filename.len > 0) filename.len else 6);
    if (r.err != null) {
        const err = dupeAndFree(r.err) orelse "hermesc failed";
        if (r.bytes) |b| free(@ptrCast(b));
        return .{ .bytes = null, .err = err };
    }
    const ptr = r.bytes orelse return .{ .err = "no bytes" };
    // Transfer malloc ownership into a Zig slice (caller frees via c_allocator / freeBytecode).
    const slice = ptr[0..r.len];
    return .{ .bytes = slice };
}

pub fn hermesRunBytecode(ctx: Context, bytes: []const u8) types.EvalResult {
    var decode_failed: c_int = 0;
    const r = hermes_run_bytecode_ex(ctx, if (bytes.len > 0) bytes.ptr else @as([*]const u8, @ptrFromInt(1)), bytes.len, &decode_failed);
    if (r.err != null) {
        const err = dupeAndFree(r.err) orelse "bytecode run failed";
        if (r.result) |p| free(@ptrCast(p));
        return .{ .result = null, .err = err, .err_is_heap = true, .decode_failed = decode_failed != 0 };
    }
    return .{ .result = dupeAndFree(r.result), .err = null, .decode_failed = false };
}
