//! ES module loader support.
//!
//! Design:
//! * EngineConfig.module_loader is a `*const types.ModuleLoader` owned by the user and guaranteed to outlive the engine instance.
//! * engine.create forwards the pointer to JS_SetModuleLoaderFunc as the runtime `opaque` argument, so the trampolines can reach the user's vtable without any per-call lookup.
//! * The loader trampoline compiles module source with JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY and extracts the resulting JSModuleDef* from the JSValue's ptr slot (tag == MODULE).
//! * engine.evalModule / engine.importModule go through evalAsModule / importModuleBySpecifier defined here.

const std = @import("std");
const c = @import("c_api.zig");
const qjs = c.qjs;

const exception = @import("exception.zig");
const lifecycle = @import("lifecycle.zig");
const types_mod = @import("../../types.zig");

/// Flags we derive manually because cImport hides `#define`s behind no symbol we can cross-link. Values mirror quickjs.h exactly.
pub const QJS_EVAL_TYPE_MODULE: c_int = 1 << 0;
pub const QJS_EVAL_FLAG_COMPILE_ONLY: c_int = 1 << 5;

/// Install the user-supplied module loader on `rt`. Called from engine.create when `EngineConfig.module_loader != null`. The pointer is stashed in the runtime opaque slot exposed by QuickJS; callbacks cast it back to `*const types_mod.ModuleLoader`.
pub fn installModuleLoader(rt: ?*qjs.JSRuntime, loader: *const types_mod.ModuleLoader) void {
    // `JSModuleNormalizeFunc` / `JSModuleLoaderFunc` both take `void *opaque` as their trailing argument, so we can pass the user's ModuleLoader directly. `@constCast` strips the const — QuickJS will not mutate it.
    const opaque_ptr: ?*anyopaque = @ptrCast(@constCast(loader));
    qjs.JS_SetModuleLoaderFunc(rt, qjsModuleNormalize, qjsModuleLoader, opaque_ptr);
}

/// Normalizer trampoline (JSModuleNormalizeFunc). Must return a string allocated with `js_malloc` / `js_strdup`; QuickJS frees it via `js_free`.
fn qjsModuleNormalize(
    ctx: ?*qjs.JSContext,
    module_base_name: [*c]const u8,
    module_name: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) [*c]u8 {
    // Fallback: `js_strdup(module_name)` is the "identity" behaviour that matches QuickJS's default normalizer for absolute ids.
    const loader_ptr = opaque_ptr orelse return qjs.js_strdup(ctx, module_name);
    const loader: *const types_mod.ModuleLoader = @ptrCast(@alignCast(loader_ptr));
    const resolve = loader.vtable.resolve orelse return qjs.js_strdup(ctx, module_name);

    // User resolve() receives the specifier from the `import` statement and the referrer (the importer's canonical id). QuickJS passes empty strings for the top-level eval entry; preserve that.
    const ref_z: [*:0]const u8 = @ptrCast(module_base_name);
    const spec_z: [*:0]const u8 = @ptrCast(module_name);
    const user_out = resolve(loader.user_data, ref_z, spec_z) orelse
        return qjs.js_strdup(ctx, module_name);

    // Copy into QJS-owned memory so we can hand the user's allocation back.
    const copied = qjs.js_strdup(ctx, @ptrCast(user_out));
    if (loader.vtable.free_resolved) |fr| fr(loader.user_data, user_out);
    return copied;
}

/// Loader trampoline (JSModuleLoaderFunc). Must return a non-null `JSModuleDef *` on success; on failure, throw into `ctx` and return null.
fn qjsModuleLoader(
    ctx: ?*qjs.JSContext,
    module_name: [*c]const u8,
    opaque_ptr: ?*anyopaque,
) callconv(.c) ?*qjs.JSModuleDef {
    const loader_ptr = opaque_ptr orelse {
        _ = qjs.JS_ThrowReferenceError(ctx, "no module loader configured");
        return null;
    };
    const loader: *const types_mod.ModuleLoader = @ptrCast(@alignCast(loader_ptr));

    const id_z: [*:0]const u8 = @ptrCast(module_name);
    var out: types_mod.ModuleLoadResult = .{ .source = undefined, .source_len = 0 };
    if (!loader.vtable.load(loader.user_data, id_z, &out)) {
        _ = qjs.JS_ThrowReferenceError(ctx, "could not load module '%s'", module_name);
        return null;
    }

    // The callback has returned, so its source must still be valid while we copy it into a NUL-terminated buffer QuickJS can lex past the end of.
    const src_copy = std.heap.c_allocator.allocSentinel(u8, out.source_len, 0) catch {
        _ = qjs.JS_ThrowOutOfMemory(ctx);
        return null;
    };
    defer std.heap.c_allocator.free(src_copy);
    if (out.source_len > 0) {
        @memcpy(src_copy, out.source[0..out.source_len]);
    }

    if (!lifecycle.enterJs(ctx)) {
        // Refused (concurrent cross-thread entry): do NOT touch ctx. The loader is only reached from within JS execution on the owning thread, so this indicates host misuse; return null without parking an exception.
        return null;
    }
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    const compiled = qjs.JS_Eval(
        ctx,
        src_copy.ptr,
        src_copy.len,
        module_name,
        QJS_EVAL_TYPE_MODULE | QJS_EVAL_FLAG_COMPILE_ONLY,
    );
    if (c.jsIsException(compiled)) {
        // Exception is already parked in `ctx`; QuickJS will propagate it.
        c.jsbay_qjs_JS_FreeValue(ctx, compiled);
        return null;
    }
    // With COMPILE_ONLY + TYPE_MODULE QuickJS returns a JSValue with tag == JS_TAG_MODULE whose `u.ptr` is the JSModuleDef*.
    if (compiled.tag != qjs.JS_TAG_MODULE) {
        c.jsbay_qjs_JS_FreeValue(ctx, compiled);
        _ = qjs.JS_ThrowReferenceError(ctx, "module compile produced unexpected tag for '%s'", module_name);
        return null;
    }
    const mod_ptr: ?*qjs.JSModuleDef = @ptrCast(@alignCast(compiled.u.ptr));
    // Mirror QuickJS's own `js_module_loader` reference impl: extract the module pointer, then `JS_FreeValue` the JSValue wrapper — the module is kept alive by the runtime's internal module table, so the refcount drop here only releases the wrapper.
    c.jsbay_qjs_JS_FreeValue(ctx, compiled);
    return mod_ptr;
}

/// Implementation for engine.evalModule. Compiles+evaluates `source` as an ES module under `filename`.
pub fn evalAsModule(ctx: ?*qjs.JSContext, source: []const u8, filename: []const u8) types_mod.EvalResult {
    if (!lifecycle.enterJs(ctx)) return .{ .result = null, .err = lifecycle.cross_thread_reentry_msg, .err_is_heap = false };
    defer lifecycle.leaveJs(ctx);
    lifecycle.syncStackTopForJs(ctx);
    const fname = std.heap.c_allocator.dupeSentinel(u8, filename, 0) catch {
        return .{ .result = null, .err = "Failed to allocate filename", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(fname);
    const src = std.heap.c_allocator.dupeSentinel(u8, source, 0) catch {
        return .{ .result = null, .err = "Failed to allocate module source", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(src);

    const result = qjs.JS_Eval(
        ctx,
        src.ptr,
        src.len,
        fname.ptr,
        QJS_EVAL_TYPE_MODULE,
    );

    if (c.jsIsException(result)) {
        const msg = exception.getAndFormatException(ctx);
        c.jsbay_qjs_JS_FreeValue(ctx, result);
        return .{ .result = null, .err = msg, .err_is_heap = true };
    }

    // Drain any module top-level await microtasks before stringifying.
    lifecycle.processPendingJobsImpl(ctx);

    const ret: ?[]const u8 = if (c.jsIsUndefined(result) or c.jsIsNull(result))
        null
    else if (c.jsIsObject(result))
        exception.jsonStringify(ctx, result)
    else
        exception.valueToString(ctx, result);

    c.jsbay_qjs_JS_FreeValue(ctx, result);
    return .{ .result = ret, .err = null };
}

/// Implementation for engine.importModule. Dispatches the entry specifier through the configured loader and evaluates the returned source as a module. Returns an error `EvalResult` if no loader is configured or the loader's load() returns false.
pub fn importModuleBySpecifier(ctx: ?*qjs.JSContext, entry_specifier: []const u8) types_mod.EvalResult {
    // Recover the ModuleLoader from the runtime opaque. We don't use JS_GetRuntimeOpaque because JS_SetModuleLoaderFunc stores the pointer in a separate slot internal to QJS — so instead we emit a shim `import * as ns from '<specifier>'; globalThis.__jsbay_qjs_entry__ = ns;` which forces QJS's module resolver to kick in (and hit our loader).
    //
    // This indirection keeps the engine from needing a second copy of the loader pointer: the one passed to JS_SetModuleLoaderFunc is sufficient.
    const spec_z = std.heap.c_allocator.dupeSentinel(u8, entry_specifier, 0) catch {
        return .{ .result = null, .err = "Failed to allocate specifier", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(spec_z);

    // Escape single quotes in the specifier so embedded quotes can't break out of the shim. Paths/ids realistically shouldn't contain them but defensively escape anyway.
    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(std.heap.c_allocator);
    for (entry_specifier) |ch| {
        switch (ch) {
            '\\' => escaped.appendSlice(std.heap.c_allocator, "\\\\") catch return .{ .result = null, .err = "OOM", .err_is_heap = false },
            '\'' => escaped.appendSlice(std.heap.c_allocator, "\\'") catch return .{ .result = null, .err = "OOM", .err_is_heap = false },
            '\n' => escaped.appendSlice(std.heap.c_allocator, "\\n") catch return .{ .result = null, .err = "OOM", .err_is_heap = false },
            '\r' => escaped.appendSlice(std.heap.c_allocator, "\\r") catch return .{ .result = null, .err = "OOM", .err_is_heap = false },
            else => escaped.append(std.heap.c_allocator, ch) catch return .{ .result = null, .err = "OOM", .err_is_heap = false },
        }
    }

    const shim = std.fmt.allocPrint(
        std.heap.c_allocator,
        "import * as ns from '{s}';\n",
        .{escaped.items},
    ) catch {
        return .{ .result = null, .err = "Failed to allocate import shim", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(shim);

    return evalAsModule(ctx, shim, "<entry>");
}
