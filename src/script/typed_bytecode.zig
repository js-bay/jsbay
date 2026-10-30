//! Typed bytecode operations for the expert C ABI.
//!
//! The caller owns every non-null `bytes`, `value`, and `exception` field and must hold the engine's evaluation/lifecycle admission while calling these raw backend operations. QuickJS bytecode is trusted, build-specific data: callers must never use this interface on untrusted input.

const std = @import("std");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

pub const Result = struct {
    bytes: ?[]u8 = null,
    value: ?ActiveEngine.Value = null,
    exception: ?ActiveEngine.Value = null,
    out_of_memory: bool = false,
    unsupported: bool = false,
    invalid_argument: bool = false,
};

/// Compile without executing `source`. The byte buffer is copied into the C allocator, so `freeBytes` is always the matching release operation.
pub fn compile(ctx: ActiveEngine.Context, source: []const u8, filename: []const u8) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => compileQuickJs(ctx, source, filename),
        .jsc => .{ .unsupported = true },
        .escargot, .hermes => .{ .unsupported = true },
    };
}

/// Run bytecode emitted by `compile`. A successful result remains a live backend value, including objects, functions, and undefined.
pub fn run(ctx: ActiveEngine.Context, bytes: []const u8) Result {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => runQuickJs(ctx, bytes),
        .jsc => .{ .unsupported = true },
        .escargot, .hermes => .{ .unsupported = true },
    };
}

pub fn freeBytes(bytes: []u8) void {
    std.heap.c_allocator.free(bytes);
}

fn compileQuickJs(ctx: ActiveEngine.Context, source: []const u8, filename: []const u8) Result {
    const module = backend.ActiveEngineModule;
    // QuickJS reads source[input_len] while compiling even though `input_len` carries the semantic length. Give it a sentinel copy so callers may pass an arbitrary explicit-length slice, including embedded NUL bytes.
    const source_z = std.heap.c_allocator.dupeSentinel(u8, source, 0) catch return .{ .out_of_memory = true };
    defer std.heap.c_allocator.free(source_z);
    const filename_z = std.heap.c_allocator.dupeSentinel(u8, filename, 0) catch return .{ .out_of_memory = true };
    defer std.heap.c_allocator.free(filename_z);

    const compiled = module.qjs.JS_Eval(
        ctx,
        source_z.ptr,
        source.len,
        filename_z.ptr,
        module.qjs.JS_EVAL_TYPE_GLOBAL | module.QJS_EVAL_FLAG_COMPILE_ONLY,
    );
    if (module.c_api.jsIsException(compiled)) return .{ .exception = module.qjs.JS_GetException(ctx) };
    defer module.c_api.jsbay_qjs_JS_FreeValue(ctx, compiled);

    var raw_len: usize = 0;
    const raw = module.qjs.JS_WriteObject(ctx, &raw_len, compiled, 1) orelse
        return .{ .exception = module.qjs.JS_GetException(ctx) };
    defer module.qjs.js_free(ctx, raw);

    const owned = std.heap.c_allocator.alloc(u8, raw_len) catch return .{ .out_of_memory = true };
    @memcpy(owned, raw[0..raw_len]);
    return .{ .bytes = owned };
}

fn runQuickJs(ctx: ActiveEngine.Context, bytes: []const u8) Result {
    const module = backend.ActiveEngineModule;
    if (bytes.len == 0) return .{ .invalid_argument = true };

    const compiled = module.qjs.JS_ReadObject(ctx, bytes.ptr, bytes.len, 1);
    if (module.c_api.jsIsException(compiled)) return .{ .exception = module.qjs.JS_GetException(ctx) };
    // JS_EvalFunction consumes `compiled`, including when execution throws.
    const value = module.qjs.JS_EvalFunction(ctx, compiled);
    if (module.c_api.jsIsException(value)) return .{ .exception = module.qjs.JS_GetException(ctx) };
    return .{ .value = value };
}

test "typed bytecode: compile and run preserve live values and throw values" {
    // True limitation: EscargotPublic and Hermes JSI expose no compile-only bytecode blob API comparable to QuickJS JS_WriteObject / JS_EvalFunction. Keep skipped until an engine-native blob API exists; do not shim via eval.
    if (comptime backend.isSpikeBackend(backend.active_backend)) return error.SkipZigTest;
    const testing = std.testing;
    const engine = @import("../engine.zig");
    const id = @import("../tests/test_helpers.zig").nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = engine.getContext(id) orelse return error.MissingContext;
    const lease = @import("../runtime/engine_thread.zig").beginEval(id);
    defer engine.finishEvalEntry(id, lease);
    try testing.expect(lease.allowed);
    const entered_js = if (comptime backend.isQuickJsApiBackend(backend.active_backend))
        backend.ActiveEngineModule.lifecycle.enterJs(ctx)
    else
        true;
    defer if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        if (entered_js) backend.ActiveEngineModule.lifecycle.leaveJs(ctx);
    };
    try testing.expect(entered_js);

    if (comptime backend.isJscApiBackend(backend.active_backend)) {
        const unsupported = compile(ctx, "1", "unsupported.js");
        try testing.expect(unsupported.unsupported);
        return;
    }

    // Empty source is a valid explicit-length input. Compilation must not execute it, so only retain and release the produced bytecode here.
    const empty_code = compile(ctx, "", "empty-source.js");
    const empty_bytes = empty_code.bytes orelse return error.ExpectedEmptyBytecode;
    defer freeBytes(empty_bytes);

    // The parser must receive bytes after an embedded NUL instead of treating the slice as a C string. The visible prefix compiles, while this full explicit-length slice must report the invalid trailing token.
    const nul_source = [_]u8{ '1', ';', 0, '@' };
    const nul_code = compile(ctx, &nul_source, "embedded-nul-source.js");
    const nul_exception = nul_code.exception orelse return error.ExpectedEmbeddedNulException;
    defer ActiveEngine.freeValue(ctx, nul_exception);

    const object_code = compile(ctx, "({ answer: 42 })", "object.js");
    const object_bytes = object_code.bytes orelse return error.ExpectedBytecode;
    defer freeBytes(object_bytes);
    const object_result = run(ctx, object_bytes);
    const object = object_result.value orelse return error.ExpectedObject;
    defer ActiveEngine.freeValue(ctx, object);
    const answer = ActiveEngine.getPropertyVal(ctx, object, "answer") orelse return error.ExpectedAnswer;
    defer ActiveEngine.freeValue(ctx, answer);
    try testing.expectEqual(@as(f64, 42), ActiveEngine.toFloat64(ctx, answer).?);

    // A public source slice has an explicit length and is not required to carry a trailing NUL. QuickJS still dereferences source[len] internally, so compile() must make its own sentinel copy without changing the semantic source length.
    const dynamic_source = try testing.allocator.dupe(u8, "40 + 2");
    defer testing.allocator.free(dynamic_source);
    const dynamic_code = compile(ctx, dynamic_source, "dynamic-source.js");
    const dynamic_bytes = dynamic_code.bytes orelse return error.ExpectedDynamicBytecode;
    defer freeBytes(dynamic_bytes);
    const dynamic_result = run(ctx, dynamic_bytes);
    const dynamic_value = dynamic_result.value orelse return error.ExpectedDynamicValue;
    defer ActiveEngine.freeValue(ctx, dynamic_value);
    try testing.expectEqual(@as(f64, 42), ActiveEngine.toFloat64(ctx, dynamic_value).?);

    const function_code = compile(ctx, "(() => 7)", "function.js");
    const function_bytes = function_code.bytes orelse return error.ExpectedBytecode;
    defer freeBytes(function_bytes);
    const function_result = run(ctx, function_bytes);
    const function = function_result.value orelse return error.ExpectedFunction;
    defer ActiveEngine.freeValue(ctx, function);
    try testing.expect(ActiveEngine.isFunction(ctx, function));

    const undefined_code = compile(
        ctx,
        "globalThis.__typed_bytecode_compile_count = (globalThis.__typed_bytecode_compile_count || 0) + 1; void 0",
        "undefined.js",
    );
    const undefined_bytes = undefined_code.bytes orelse return error.ExpectedBytecode;
    defer freeBytes(undefined_bytes);
    const global = ActiveEngine.getGlobalObject(ctx);
    defer ActiveEngine.freeValue(ctx, global);
    try testing.expect(!ActiveEngine.hasProperty(ctx, global, "__typed_bytecode_compile_count"));
    const undefined_result = run(ctx, undefined_bytes);
    const undefined_value = undefined_result.value orelse return error.ExpectedUndefined;
    defer ActiveEngine.freeValue(ctx, undefined_value);
    try testing.expect(ActiveEngine.isUndefined(ctx, undefined_value));
    const after_run = ActiveEngine.getPropertyVal(ctx, global, "__typed_bytecode_compile_count") orelse return error.ExpectedCounter;
    defer ActiveEngine.freeValue(ctx, after_run);
    try testing.expectEqual(@as(f64, 1), ActiveEngine.toFloat64(ctx, after_run).?);

    // The compile succeeds because compile-only execution never evaluates the throw. The raw numeric exception appears only when replayed.
    const throwing_code = compile(ctx, "throw 42", "throw.js");
    const throwing_bytes = throwing_code.bytes orelse return error.ExpectedBytecode;
    defer freeBytes(throwing_bytes);
    const thrown = run(ctx, throwing_bytes);
    const exception = thrown.exception orelse return error.ExpectedException;
    defer ActiveEngine.freeValue(ctx, exception);
    try testing.expectEqual(@as(f64, 42), ActiveEngine.toFloat64(ctx, exception).?);

    const syntax = compile(ctx, "function {", "syntax.js");
    const syntax_exception = syntax.exception orelse return error.ExpectedSyntaxException;
    defer ActiveEngine.freeValue(ctx, syntax_exception);
}
