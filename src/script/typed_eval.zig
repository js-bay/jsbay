//! Evaluate without converting the result or the thrown value to a string. The caller holds an engine EvalLease until it has published or freed the returned backend-owned value. Cache decoding never executes user code.

const std = @import("std");
const backend = @import("../backend.zig");
const cache = @import("cache.zig");
const instance_map = @import("../runtime/instance_map.zig");
const ActiveEngine = backend.ActiveEngine;

pub const Result = struct {
    value: ?ActiveEngine.Value = null,
    exception: ?ActiveEngine.Value = null,
    out_of_memory: bool = false,
    cache_hit: bool = false,
};

const source_url_cache_envelope = backend.active_backend == .quickjs and @import("build_options").inspector;
const cache_envelope_magic = "JBSURL01";
const cache_envelope_header_len = cache_envelope_magic.len + @sizeOf(u32);

const CacheArtifact = struct {
    bytecode: []const u8,
    effective_url: []const u8,
};

pub fn evaluate(ctx: ActiveEngine.Context, source: []const u8, filename: []const u8, cache_dir: []const u8, version: []const u8) Result {
    const result = switch (backend.active_backend) {
        .quickjs, .quickjs_ng => evaluateQuickJs(ctx, source, filename, cache_dir, version),
        .jsc => evaluateJsc(ctx, source, filename),
        .escargot, .hermes => evaluateSpike(ctx, source, filename),
    };
    if (result.exception) |exception| @import("../inspector/root.zig").exceptions.reportValue(ActiveEngine.instanceIdFromCtx(ctx), ctx, exception, filename);
    return result;
}

fn evaluateQuickJs(ctx: ActiveEngine.Context, source: []const u8, filename: []const u8, cache_dir: []const u8, version: []const u8) Result {
    const module = backend.ActiveEngineModule;
    const c = module.c_api;
    const qjs = module.qjs;
    if (!module.lifecycle.enterJs(ctx)) return .{ .out_of_memory = true };
    defer module.lifecycle.leaveJs(ctx);
    // Capture the original exception before draining jobs, which may throw too.
    defer {
        if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
    }

    const gpa = std.heap.c_allocator;
    const path = cacheFile(source, filename, cache_dir, version);
    defer if (path) |owned| gpa.free(owned);
    // Raw bytecode remains opaque. Classic QuickJS cache entries carry the compiler-selected identity in an outer envelope because runtime script tags are deliberately not serialized.
    const filename_z = gpa.dupeSentinel(u8, filename, 0) catch return .{ .out_of_memory = true };
    defer gpa.free(filename_z);
    if (path) |file| {
        if (cache.readBytes(file)) |bytes| {
            defer gpa.free(bytes);
            const artifact: ?CacheArtifact = if (comptime source_url_cache_envelope) decodeCacheArtifact(bytes) else .{ .bytecode = bytes, .effective_url = filename };
            if (artifact) |entry| {
                const compiled = qjs.JS_ReadObject(ctx, entry.bytecode.ptr, entry.bytecode.len, 1);
                if (!c.jsIsException(compiled)) {
                    if (comptime backend.supportsSourceJournal(backend.active_backend) and @import("build_options").inspector) {
                        if (comptime source_url_cache_envelope) {
                            const effective_url_z = gpa.dupeSentinel(u8, entry.effective_url, 0) catch {
                                c.jsbay_qjs_JS_FreeValue(ctx, compiled);
                                return .{ .out_of_memory = true };
                            };
                            defer gpa.free(effective_url_z);
                            _ = qjs.JS_RebindScriptTag(ctx, compiled, effective_url_z.ptr, source.ptr, source.len);
                        } else {
                            _ = qjs.JS_RebindScriptTag(ctx, compiled, filename_z.ptr, source.ptr, source.len);
                        }
                    }
                    // JS_EvalFunction consumes compiled even when the script throws. A runtime exception is never a reason to execute source again.
                    return quickJsResult(ctx, qjs.JS_EvalFunction(ctx, compiled), true);
                }
                c.jsbay_qjs_JS_FreeValue(ctx, qjs.JS_GetException(ctx));
                cache.deleteFile(file);
            } else {
                cache.deleteFile(file);
            }
        }
    }

    const source_z = gpa.dupeSentinel(u8, source, 0) catch return .{ .out_of_memory = true };
    defer gpa.free(source_z);
    if (path) |file| {
        var source_url: [*c]u8 = null;
        const compiled = if (comptime source_url_cache_envelope)
            qjs.jsbay_qjs_eval_with_source_url(ctx, source_z.ptr, source_z.len, filename_z.ptr, qjs.JS_EVAL_TYPE_GLOBAL | module.QJS_EVAL_FLAG_COMPILE_ONLY, &source_url)
        else
            qjs.JS_Eval(ctx, source_z.ptr, source_z.len, filename_z.ptr, qjs.JS_EVAL_TYPE_GLOBAL | module.QJS_EVAL_FLAG_COMPILE_ONLY);
        defer if (source_url != null) qjs.js_free(ctx, source_url);
        if (c.jsIsException(compiled)) return quickJsResult(ctx, compiled, false);
        var size: usize = 0;
        const bytes = qjs.JS_WriteObject(ctx, &size, compiled, 1);
        if (bytes != null) {
            if (comptime source_url_cache_envelope) {
                if (source_url != null) writeCacheArtifact(file, std.mem.span(source_url), bytes[0..size]);
            } else {
                cache.writeBytes(file, bytes[0..size]);
            }
            qjs.js_free(ctx, bytes);
        } else {
            // Serialization failure affects persistence only. The already compiled program is still executed exactly once.
            c.jsbay_qjs_JS_FreeValue(ctx, qjs.JS_GetException(ctx));
        }
        return quickJsResult(ctx, qjs.JS_EvalFunction(ctx, compiled), false);
    }

    return quickJsResult(ctx, qjs.JS_Eval(ctx, source_z.ptr, source_z.len, filename_z.ptr, qjs.JS_EVAL_TYPE_GLOBAL), false);
}

fn decodeCacheArtifact(bytes: []const u8) ?CacheArtifact {
    if (bytes.len < cache_envelope_header_len + 1) return null;
    if (!std.mem.eql(u8, bytes[0..cache_envelope_magic.len], cache_envelope_magic)) return null;
    const url_len: usize = std.mem.readInt(u32, bytes[cache_envelope_magic.len..cache_envelope_header_len], .little);
    if (url_len == 0 or url_len > bytes.len - cache_envelope_header_len) return null;
    const url_end = cache_envelope_header_len + url_len;
    if (url_end == bytes.len) return null;
    const effective_url = bytes[cache_envelope_header_len..url_end];
    if (std.mem.indexOfScalar(u8, effective_url, 0) != null) return null;
    return .{ .effective_url = effective_url, .bytecode = bytes[url_end..] };
}

fn writeCacheArtifact(path: []const u8, effective_url: []const u8, bytecode: []const u8) void {
    if (effective_url.len == 0 or effective_url.len > std.math.maxInt(u32) or bytecode.len == 0) return;
    if (std.mem.indexOfScalar(u8, effective_url, 0) != null) return;
    const total = std.math.add(usize, cache_envelope_header_len, effective_url.len) catch return;
    const size = std.math.add(usize, total, bytecode.len) catch return;
    const artifact = std.heap.c_allocator.alloc(u8, size) catch return;
    defer std.heap.c_allocator.free(artifact);
    @memcpy(artifact[0..cache_envelope_magic.len], cache_envelope_magic);
    std.mem.writeInt(u32, artifact[cache_envelope_magic.len..cache_envelope_header_len], @intCast(effective_url.len), .little);
    @memcpy(artifact[cache_envelope_header_len..total], effective_url);
    @memcpy(artifact[total..], bytecode);
    cache.writeBytes(path, artifact);
}

test "typed eval: source URL cache envelope rejects malformed metadata" {
    const testing = std.testing;
    try testing.expect(decodeCacheArtifact("raw-bytecode") == null);
    try testing.expect(decodeCacheArtifact(cache_envelope_magic ++ "\x00\x00\x00\x00bytecode") == null);
    try testing.expect(decodeCacheArtifact(cache_envelope_magic ++ "\x05\x00\x00\x00url") == null);
    try testing.expect(decodeCacheArtifact(cache_envelope_magic ++ "\x03\x00\x00\x00a\x00bbytecode") == null);
    try testing.expect(decodeCacheArtifact(cache_envelope_magic ++ "\x03\x00\x00\x00url") == null);
    const valid = decodeCacheArtifact(cache_envelope_magic ++ "\x03\x00\x00\x00urlbytecode") orelse return error.ExpectedCacheArtifact;
    try testing.expectEqualStrings("url", valid.effective_url);
    try testing.expectEqualStrings("bytecode", valid.bytecode);
}

fn quickJsResult(ctx: ActiveEngine.Context, value: ActiveEngine.Value, hit: bool) Result {
    const module = backend.ActiveEngineModule;
    if (module.c_api.jsIsException(value)) return .{ .exception = module.qjs.JS_GetException(ctx), .cache_hit = hit };
    return .{ .value = value, .cache_hit = hit };
}

fn cacheFile(source: []const u8, filename: []const u8, cache_dir: []const u8, version: []const u8) ?[]u8 {
    if (!@import("build_options").bytecode_cache) return null;
    if (cache_dir.len == 0 or !cache.isSafeVersion(version)) return null;
    const gpa = std.heap.c_allocator;
    const source_hash = cache.sha256Hex(source);
    if (source_hash.len == 0) return null;
    defer gpa.free(source_hash);
    const name_hash = cache.sha256Hex(filename);
    if (name_hash.len == 0) return null;
    defer gpa.free(name_hash);
    return cache.cachePath(gpa, cache_dir, version, source_hash, name_hash);
}

fn evaluateSpike(ctx: ActiveEngine.Context, source: []const u8, filename: []const u8) Result {
    defer {
        if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
    }
    // Prefer value-returning eval when the active backend exposes it (Escargot / Hermes).
    if (comptime @hasDecl(ActiveEngine, "evalValue")) {
        const er = ActiveEngine.evalValue(ctx, source, filename);
        // Bridge may report err_text without a retained exception value (non-JSError paths). Synthesize a string exception so public evaluate is not misclassified as OOM.
        if (er.exception != null) {
            if (er.err_text) |e| std.heap.c_allocator.free(e);
            return .{ .exception = er.exception };
        }
        if (er.err_text) |e| {
            defer std.heap.c_allocator.free(e);
            const synthesized = ActiveEngine.newStringVal(ctx, e) orelse return .{ .out_of_memory = true };
            return .{ .exception = synthesized };
        }
        return .{ .value = er.value };
    }
    // String eval fallback: keep live exceptions by allocating the message before freeing the heap err.
    const er = ActiveEngine.eval(ctx, source, filename);
    if (er.result) |r| std.heap.c_allocator.free(@constCast(r));
    if (er.err) |e| {
        const synthesized = ActiveEngine.newStringVal(ctx, e) orelse {
            if (er.err_is_heap) std.heap.c_allocator.free(@constCast(e));
            return .{ .out_of_memory = true };
        };
        if (er.err_is_heap) std.heap.c_allocator.free(@constCast(e));
        return .{ .exception = synthesized };
    }
    return .{};
}

fn evaluateJsc(ctx: ActiveEngine.Context, source: []const u8, filename: []const u8) Result {
    const module = @import("../backend/jsc.zig");
    const jsc = module.jsc;
    const ctx_ref: jsc.JSContextRef = @ptrCast(ctx);
    const source_string = jscString(source) orelse return .{ .out_of_memory = true };
    defer jsc.JSStringRelease(source_string);
    const filename_string = jscString(filename) orelse return .{ .out_of_memory = true };
    defer jsc.JSStringRelease(filename_string);
    defer {
        if (!instance_map.isTeardownPending(ActiveEngine.instanceIdFromCtx(ctx))) ActiveEngine.processPendingJobs(ctx);
    }
    var exception: jsc.JSValueRef = null;
    const result = jsc.JSEvaluateScript(ctx_ref, source_string, null, filename_string, 1, &exception);
    if (exception != null) {
        jsc.JSValueProtect(ctx_ref, exception);
        return .{ .exception = exception };
    }
    if (result == null) return .{ .out_of_memory = true };
    jsc.JSValueProtect(ctx_ref, result);
    return .{ .value = result };
}

fn jscString(input: []const u8) @import("../backend/jsc.zig").jsc.JSStringRef {
    const jsc = @import("../backend/jsc.zig").jsc;
    const chars = std.unicode.utf8ToUtf16LeAlloc(std.heap.c_allocator, input) catch return null;
    defer std.heap.c_allocator.free(chars);
    const empty = [_]u16{0};
    return jsc.JSStringCreateWithCharacters(if (chars.len == 0) &empty else chars.ptr, chars.len);
}

test "typed eval: keeps live functions and raw exceptions" {
    // Spike backends use evaluateSpike (value-returning eval via native bridge).
    const engine = @import("../engine.zig");
    const id = @import("../tests/test_helpers.zig").nextInstanceId();
    try std.testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const lease = @import("../runtime/engine_thread.zig").beginEval(id);
    defer engine.finishEvalEntry(id, lease);
    try std.testing.expect(lease.allowed);
    const ctx = engine.getContext(id).?;
    const object = evaluate(ctx, "({run:()=>42})", "typed.js", "", "");
    try std.testing.expect(!object.out_of_memory and object.exception == null);
    const value = object.value orelse return error.ExpectedObject;
    defer ActiveEngine.freeValue(ctx, value);
    const function = ActiveEngine.getPropertyVal(ctx, value, "run") orelse return error.ExpectedFunction;
    defer ActiveEngine.freeValue(ctx, function);
    try std.testing.expect(ActiveEngine.isFunction(ctx, function));
    const thrown = evaluate(ctx, "throw 7", "throw.js", "", "");
    try std.testing.expect(thrown.value == null);
    const exception = thrown.exception orelse return error.ExpectedException;
    defer ActiveEngine.freeValue(ctx, exception);
    try std.testing.expectEqual(@as(f64, 7), ActiveEngine.toFloat64(ctx, exception).?);
}

test "typed eval: cache preserves live exports and never repeats side effects" {
    // Spike backends use evaluateSpike (value-returning eval via native bridge).
    const testing = std.testing;
    const engine = @import("../engine.zig");
    const id = @import("../tests/test_helpers.zig").nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const lease = @import("../runtime/engine_thread.zig").beginEval(id);
    defer engine.finishEvalEntry(id, lease);
    try testing.expect(lease.allowed);
    const ctx = engine.getContext(id).?;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(testing.io, "cache");
    const directory = try temp.dir.realPathFileAlloc(testing.io, "cache", testing.allocator);
    defer testing.allocator.free(directory);
    const source = "globalThis.typedCount=(globalThis.typedCount||0)+1; ({n:typedCount,run(){return 42}})";
    const persistent_cache = @import("build_options").bytecode_cache;

    for (0..2) |index| {
        const result = evaluate(ctx, source, "exports.js", directory, "v1");
        try testing.expect(result.exception == null and !result.out_of_memory);
        try testing.expectEqual(persistent_cache and !backend.isJscApiBackend(backend.active_backend) and !backend.isSpikeBackend(backend.active_backend) and index == 1, result.cache_hit);
        const value = result.value orelse return error.ExpectedExports;
        defer ActiveEngine.freeValue(ctx, value);
        const number = ActiveEngine.getPropertyVal(ctx, value, "n") orelse return error.ExpectedCount;
        defer ActiveEngine.freeValue(ctx, number);
        try testing.expectEqual(@as(f64, @floatFromInt(index + 1)), ActiveEngine.toFloat64(ctx, number).?);
        const function = ActiveEngine.getPropertyVal(ctx, value, "run") orelse return error.ExpectedFunction;
        defer ActiveEngine.freeValue(ctx, function);
        try testing.expect(ActiveEngine.isFunction(ctx, function));
    }

    if (!persistent_cache) {
        var cache_dir = try std.Io.Dir.cwd().openDir(testing.io, directory, .{ .iterate = true });
        defer cache_dir.close(testing.io);
        var entries = cache_dir.iterate();
        try testing.expect((try entries.next(testing.io)) == null);
        return;
    }

    const path = cacheFile(source, "exports.js", directory, "v1") orelse return error.OutOfMemory;
    defer std.heap.c_allocator.free(path);
    cache.writeBytes(path, "corrupt-bytecode");
    const recovered = evaluate(ctx, source, "exports.js", directory, "v1");
    try testing.expect(!recovered.cache_hit and recovered.exception == null);
    const value = recovered.value orelse return error.ExpectedRecovery;
    defer ActiveEngine.freeValue(ctx, value);
    const number = ActiveEngine.getPropertyVal(ctx, value, "n") orelse return error.ExpectedCount;
    defer ActiveEngine.freeValue(ctx, number);
    try testing.expectEqual(@as(f64, 3), ActiveEngine.toFloat64(ctx, number).?);

    const throwing = "globalThis.throwCount=(globalThis.throwCount||0)+1;throw throwCount";
    for (0..2) |index| {
        const result = evaluate(ctx, throwing, "throw-once.js", directory, "v1");
        try testing.expect(result.value == null and !result.out_of_memory);
        try testing.expectEqual(!backend.isJscApiBackend(backend.active_backend) and !backend.isSpikeBackend(backend.active_backend) and index == 1, result.cache_hit);
        const exception = result.exception orelse return error.ExpectedException;
        defer ActiveEngine.freeValue(ctx, exception);
        try testing.expectEqual(@as(f64, @floatFromInt(index + 1)), ActiveEngine.toFloat64(ctx, exception).?);
    }
}
