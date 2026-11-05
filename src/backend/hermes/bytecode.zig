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
    result: ?[*]u8,
    result_len: usize,
    err: ?[*]u8,
    err_len: usize,
};

extern fn hermes_compile_bytecode(src: [*]const u8, src_len: usize, filename: [*]const u8, filename_len: usize) HermesCompileResult;
extern fn hermes_compile_result_free(r: HermesCompileResult) void;
extern fn hermes_run_bytecode_ex(ctx: ?*anyopaque, bytes: [*]const u8, len: usize, out_decode_failed: *c_int) HermesEvalResult;
extern fn hermes_run_bytecode_value(ctx: ?*anyopaque, bytes: [*]const u8, len: usize, out_decode_failed: *c_int) HermesValueResultC;
extern fn hermes_value_result_free_err(r: HermesValueResultC) void;
extern fn free(ptr: ?*anyopaque) void;

const HermesValueResultC = extern struct {
    value: ?*anyopaque,
    err: ?[*:0]u8,
};

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

fn dupeAndFreeLen(src_opt: ?[*]u8, len: usize) ?[]const u8 {
    const src = src_opt orelse return null;
    const slice = src[0..len];
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
    /// true if `err` is heap-allocated (c_allocator); false for string literals.
    err_is_heap: bool = false,
};

pub fn hermesCompileBytecode(source: []const u8, filename: []const u8) CompileOut {
    // Empty Zig slices may have undefined .ptr — never pass that to C.
    const src_ptr: [*]const u8 = if (source.len > 0) source.ptr else @as([*]const u8, @ptrCast(""));
    const file_ptr: [*]const u8 = if (filename.len > 0) filename.ptr else @as([*]const u8, @ptrCast("<eval>"));
    const r = hermes_compile_bytecode(src_ptr, source.len, file_ptr, if (filename.len > 0) filename.len else 6);
    if (r.err != null) {
        const duped = dupeAndFree(r.err);
        const err = duped orelse "hermesc failed";
        if (r.bytes) |b| free(@ptrCast(b));
        return .{ .bytes = null, .err = err, .err_is_heap = duped != null };
    }
    const ptr = r.bytes orelse return .{ .err = "no bytes", .err_is_heap = false };
    // Transfer malloc ownership into a Zig slice (caller frees via c_allocator / freeBytecode).
    const slice = ptr[0..r.len];
    return .{ .bytes = slice };
}

pub fn hermesRunBytecode(ctx: Context, bytes: []const u8) types.EvalResult {
    var decode_failed: c_int = 0;
    const r = hermes_run_bytecode_ex(ctx, if (bytes.len > 0) bytes.ptr else @as([*]const u8, @ptrFromInt(1)), bytes.len, &decode_failed);
    if (r.err != null) {
        const duped = dupeAndFreeLen(r.err, r.err_len);
        const err = duped orelse "bytecode run failed";
        if (r.result) |p| free(@ptrCast(p));
        return .{ .result = null, .err = err, .err_is_heap = duped != null, .decode_failed = decode_failed != 0 };
    }
    return .{ .result = dupeAndFreeLen(r.result, r.result_len), .err = null, .decode_failed = false };
}

pub const ValueRunOut = struct {
    value: ?*anyopaque = null,
    exception: ?*anyopaque = null,
    err_text: ?[]u8 = null,
    decode_failed: bool = false,
    out_of_memory: bool = false,
};

/// Run .hbc and return a retained live Value (or exception Value). Caller owns value/exception/err_text.
pub fn hermesRunBytecodeValue(ctx: Context, bytes: []const u8) ValueRunOut {
    var decode_failed: c_int = 0;
    const ptr: [*]const u8 = if (bytes.len > 0) bytes.ptr else @as([*]const u8, @ptrFromInt(1));
    const r = hermes_run_bytecode_value(ctx, ptr, bytes.len, &decode_failed);
    if (r.err) |e| {
        const span = std.mem.span(e);
        const err_text = std.heap.c_allocator.dupe(u8, span) catch {
            hermes_value_result_free_err(r);
            if (r.value) |v| {
                // Drop retained exception if we cannot surface the message; typed layer synthesizes OOM.
                _ = v;
            }
            return .{ .out_of_memory = true, .decode_failed = decode_failed != 0 };
        };
        hermes_value_result_free_err(r);
        return .{ .value = null, .exception = r.value, .err_text = err_text, .decode_failed = decode_failed != 0 };
    }
    return .{ .value = r.value, .exception = null, .err_text = null, .decode_failed = false };
}
