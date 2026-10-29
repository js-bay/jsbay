//! Bytecode cache stubs for the JSC backend.
//!
//! JavaScriptCore's public C API does not expose a stable bytecode serialization surface. Rather than silently degrade (e.g. stash the source text and re-parse on "run"), we return a clearly-labelled error so consumers can branch on the backend and either:
//!   1. Fall back to evalScript on JSC, or
//!   2. Switch to `-Dbackend=quickjs_ng` where bytecode caching works.

const types = @import("../../types.zig");
const common = @import("common.zig");

const jsc = common.jsc;

pub const Context = jsc.JSGlobalContextRef;

pub const jsc_bytecode_err_msg: []const u8 =
    "bytecode cache is not supported on JSC backend (use QuickJS)";

pub const JscCompileResult = struct {
    bytes: ?[]u8 = null,
    err: ?[]const u8 = null,
};

pub fn jscCompileBytecode(
    _: Context,
    _: []const u8,
    _: []const u8,
) JscCompileResult {
    return .{ .bytes = null, .err = jsc_bytecode_err_msg };
}

pub fn jscFreeBytecode(_: []u8) void {
    // No-op: jscCompileBytecode never returns a non-null `bytes` (the JSC public C API has no stable bytecode serialization surface).
}

pub fn jscRunBytecode(
    _: Context,
    _: []const u8,
) types.EvalResult {
    return .{ .result = null, .err = jsc_bytecode_err_msg, .err_is_heap = false };
}
