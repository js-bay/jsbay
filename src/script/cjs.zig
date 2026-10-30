//! CommonJS `require()` support.
//!
//! Sits entirely in Zig userspace on top of the existing backend primitives. Reuses the same `ModuleLoader` vtable users configure for ES modules via `EngineConfig.module_loader` — there is no separate loader type.
//!
//! Semantics:
//! * `require(spec)` resolves `spec` through the loader (`resolve` if supplied, else identity), loads source via `load`, wraps it as `(function (exports, module, require, __filename, __dirname) { ... })`, evaluates, and calls the wrapper with a fresh `{}` for `exports` and `{ exports }` for `module`. The final `module.exports` is cached and returned.
//! * Cached entries are keyed by canonical id (the string returned by `resolve`, or the original specifier when `resolve` is null).
//! * The cached JS value is pinned via `ActiveEngine.dupValue` so repeated `require(id)` yields the same object identity (same as Node).
//! * Cyclic `require` chains: like Node, the cache entry for `id` is installed BEFORE the wrapper runs, so a nested `require(id)` returns the partially-initialised `module.exports` (usually the initial `{}`). Callers that need complete exports inside a cycle must defer access until after the top-level call returns.
//!
//! Thread safety: all operations on a given `instance_id` MUST happen on the owning thread — the per-instance state is stored behind a global mutex but the JS context itself is single-threaded.

const std = @import("std");
const sync = @import("zev");
const types = @import("../types.zig");
const engine = @import("../engine.zig");
const bytecode = @import("bytecode.zig");
const cache = @import("cache.zig");
const instance_map = @import("../runtime/instance_map.zig");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

// --------------------------------------------------------------------------
// Per-instance state
// --------------------------------------------------------------------------

const CacheEntry = struct {
    /// Canonical id owned by `arena`.
    id: []const u8,
    /// Pinned (duped) JS value for this module's `module.exports`.
    exports: ActiveEngine.Value,
};

const CjsState = struct {
    instance_id: i32,
    ctx: ActiveEngine.Context,
    loader: *const types.ModuleLoader,
    /// Arena for interned canonical-id strings (keys of `cache`). Freed in bulk by `uninstall`.
    arena: std.heap.ArenaAllocator,
    /// Canonical id → cached exports.  Keys are arena-owned slices.
    cache: std.StringHashMap(CacheEntry),
    /// Tracks whether the global `require` has been registered on the JS context — prevents duplicate registration on repeat install() calls.
    require_installed: bool = false,
    /// Tracks whether the global `__jsbay_cjsCache` has been registered.
    cjs_cache_installed: bool = false,
    /// In-process bytecode cache for `__jsbay_cjsCache`: sourceHash + filenameHash → bytes. Both keys and bytes are c_allocator-owned and freed on uninstall. This lets repeat mounts of the same module body at the same source location skip re-compile without conflating filename metadata.
    bytecode_cache: std.StringHashMap([]u8),
};

var cjs_states: std.AutoHashMap(i32, *CjsState) = std.AutoHashMap(i32, *CjsState).init(std.heap.c_allocator);
var cjs_mutex: sync.Mutex = .{};

fn getState(instance_id: i32) ?*CjsState {
    cjs_mutex.lock();
    defer cjs_mutex.unlock();
    return cjs_states.get(instance_id);
}

fn putState(state: *CjsState) !void {
    cjs_mutex.lock();
    defer cjs_mutex.unlock();
    try cjs_states.put(state.instance_id, state);
}

fn removeState(instance_id: i32) ?*CjsState {
    cjs_mutex.lock();
    defer cjs_mutex.unlock();
    const kv = cjs_states.fetchRemove(instance_id) orelse return null;
    return kv.value;
}

// Recover the state pointer from a JS context via instance_id opaque.
fn stateFromCtx(ctx: ActiveEngine.Context) ?*CjsState {
    const id = ActiveEngine.instanceIdFromCtx(ctx);
    return getState(id);
}

// --------------------------------------------------------------------------
// Public API
// --------------------------------------------------------------------------

/// Install a global `require(specifier)` on the instance, tied to the given module loader. Idempotent — subsequent calls on the same instance are no-ops and return `true`.
///
/// The `loader` pointer must outlive the engine instance (same contract as `EngineConfig.module_loader`). Pass the same pointer you configured via `EngineConfig` so ES-module and CommonJS paths share loader state.
///
/// Returns `false` if the instance is unknown or native-function registration fails.
pub fn install(instance_id: i32, loader: *const types.ModuleLoader) bool {
    if (getState(instance_id)) |_| return true; // already installed
    const ctx = engine.getContext(instance_id) orelse return false;

    const state = std.heap.c_allocator.create(CjsState) catch return false;
    state.* = .{
        .instance_id = instance_id,
        .ctx = ctx,
        .loader = loader,
        .arena = std.heap.ArenaAllocator.init(std.heap.c_allocator),
        .cache = std.StringHashMap(CacheEntry).init(std.heap.c_allocator),
        .bytecode_cache = std.StringHashMap([]u8).init(std.heap.c_allocator),
    };
    putState(state) catch {
        state.arena.deinit();
        state.cache.deinit();
        std.heap.c_allocator.destroy(state);
        return false;
    };

    if (!registerGlobalRequire(ctx)) {
        // State is now registered but require didn't install — roll back so callers see a clean "failure" outcome.
        _ = removeState(instance_id);
        state.arena.deinit();
        state.cache.deinit();
        std.heap.c_allocator.destroy(state);
        return false;
    }

    state.require_installed = true;
    // Also register the bytecode-cached CommonJS helper so the host runtime can replace its `new Function("module","exports","require", source)` cold-compile with a cached replay. Registration is best-effort: failing it must not block require().install (some backends/contexts don't support it); the app-runtime degrades back to `new Function`.
    state.cjs_cache_installed = registerGlobalCjsCache(ctx);
    return true;
}

/// Evaluate `source` as a CommonJS script — `require`, `module`, `exports`, `__filename`, `__dirname` are in scope. The script's `module.exports` drives the return value.
///
/// Returned `result` is JSON-stringified (objects) or toString'd (primitives), matching `engine.evalScript`'s contract. `err` is populated on exception.
pub fn evalAsCjs(instance_id: i32, source: []const u8, filename: []const u8) types.EvalResult {
    const lease = @import("../runtime/engine_thread.zig").beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return .{ .err = "Engine is unavailable", .err_is_heap = false };
    var execution = @import("../runtime/js_scheduler.zig").beginExecution(instance_id) orelse
        return .{ .err = "Engine is unavailable", .err_is_heap = false };
    defer {
        execution.end();
        if (instance_map.getPtrs(instance_id)) |ptrs| @import("../runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    }

    const state = getState(instance_id) orelse
        return .{ .result = null, .err = "cjs.install not called for this instance", .err_is_heap = false };

    // Compute dirname from filename (strip trailing basename). Mirrors Node's Path.dirname: "/a/b/c.js" → "/a/b"; "foo.js" → ".".
    const dirname = dirnameOf(filename);

    // Pre-create module/exports/require so we can expose `module.exports` to the caller after the wrapper runs.
    const call = runWrappedSource(state, source, filename, dirname) catch |e| {
        const msg = switch (e) {
            error.OutOfMemory => "out of memory",
            error.Compile => "failed to compile CJS wrapper",
            error.CallFailed => "CJS module threw during evaluation",
        };
        const heap = std.heap.c_allocator.dupe(u8, msg) catch null;
        return .{ .result = null, .err = heap, .err_is_heap = heap != null };
    };
    defer ActiveEngine.freeValue(state.ctx, call.exports);

    // Stringify `module.exports` similarly to engine.evalScript's result shape.
    const ret_str = stringifyValue(state.ctx, call.exports);
    return .{ .result = ret_str, .err = null };
}

/// Empty the per-instance require cache. Does NOT uninstall the global `require` function — subsequent `require` calls will re-load modules and repopulate the cache.
pub fn clearCache(instance_id: i32) void {
    const state = getState(instance_id) orelse return;
    clearCacheState(state);
}

fn clearCacheState(state: *CjsState) void {
    var it = state.cache.iterator();
    while (it.next()) |entry| {
        ActiveEngine.freeValue(state.ctx, entry.value_ptr.exports);
    }
    state.cache.clearRetainingCapacity();
    // Reset the arena so old canonical-id allocations are released. Note: this invalidates any outstanding Key pointers, which is fine — we just cleared all map entries.
    _ = state.arena.reset(.retain_capacity);
}

/// Uninstall and free per-instance state. Idempotent. `engine.destroy` invokes this automatically after active JavaScript has unwound and before it frees the context. Direct callers may explicitly uninstall only on the owning thread while no JavaScript entry is active.
pub fn uninstall(instance_id: i32) void {
    const state = removeState(instance_id) orelse return;
    clearCacheState(state);
    // Free in-process bytecode-cache keys and payloads, then the map itself.
    var bc_it = state.bytecode_cache.iterator();
    while (bc_it.next()) |entry| {
        std.heap.c_allocator.free(entry.key_ptr.*);
        std.heap.c_allocator.free(entry.value_ptr.*);
    }
    state.bytecode_cache.deinit();
    state.cache.deinit();
    state.arena.deinit();
    std.heap.c_allocator.destroy(state);
    // We intentionally do NOT remove the global `require` from the JS context — the context may be mid-teardown. After uninstall, `require` returns undefined for all callers because state lookup yields null.
}

// --------------------------------------------------------------------------
// require() core
// --------------------------------------------------------------------------

const RequireError = error{
    OutOfMemory,
    Compile,
    CallFailed,
};

const CallResult = struct {
    exports: ActiveEngine.Value, // duped for caller to freeValue
};

/// Evaluate wrapped source + invoke wrapper with freshly-minted exports/ module/require. Returns the resulting `module.exports` pinned via `dupValue` — caller owns and must `freeValue`.
fn runWrappedSource(
    state: *CjsState,
    source: []const u8,
    filename: []const u8,
    dirname: []const u8,
) !CallResult {
    // Compose wrapper: ( function (exports, module, require, __filename, __dirname) { <source>\n} )
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.heap.c_allocator);
    buf.appendSlice(std.heap.c_allocator, "(function (exports, module, require, __filename, __dirname) { ") catch return error.OutOfMemory;
    buf.appendSlice(std.heap.c_allocator, source) catch return error.OutOfMemory;
    buf.appendSlice(std.heap.c_allocator, "\n})") catch return error.OutOfMemory;

    const wrapper_fn = try compileWrapper(state.ctx, buf.items, filename);
    defer ActiveEngine.freeValue(state.ctx, wrapper_fn);

    // Build fresh exports + module = { exports }.
    const exports_obj = ActiveEngine.newObject(state.ctx);
    const module_obj = ActiveEngine.newObject(state.ctx);
    // Duplicate exports for the module.exports property so freeing either side independently is safe.
    const exp_for_module = ActiveEngine.dupValue(state.ctx, exports_obj);
    ActiveEngine.setPropertyStr(state.ctx, module_obj, "exports", exp_for_module);

    const filename_val = ActiveEngine.newStringVal(state.ctx, filename);
    const dirname_val = ActiveEngine.newStringVal(state.ctx, dirname);

    // The instance's global `require` is the same function — reuse it via globalThis.require rather than synthesising a bound wrapper. Nested require calls go through the global, which still has access to the cache and loader (per-instance via stateFromCtx).
    const require_fn = getGlobalRequire(state.ctx);
    defer ActiveEngine.freeValue(state.ctx, require_fn);

    const argv = [_]ActiveEngine.Value{
        exports_obj,
        module_obj,
        require_fn,
        filename_val,
        dirname_val,
    };

    const undef = ActiveEngine.undefinedValue();
    const call_result = ActiveEngine.callFunction(state.ctx, wrapper_fn, undef, &argv) orelse {
        // Exception already parked / consumed by callFunction; release the owned temporaries so nothing leaks.
        ActiveEngine.freeValue(state.ctx, exports_obj);
        ActiveEngine.freeValue(state.ctx, module_obj);
        ActiveEngine.freeValue(state.ctx, filename_val);
        ActiveEngine.freeValue(state.ctx, dirname_val);
        return error.CallFailed;
    };
    ActiveEngine.freeValue(state.ctx, call_result);

    // Fetch module.exports (the wrapper may have reassigned `module.exports`).
    const current_exports = ActiveEngine.getPropertyVal(state.ctx, module_obj, "exports") orelse
        ActiveEngine.dupValue(state.ctx, exports_obj);

    // Release locals.  `current_exports` is our return value — transfer ownership.
    ActiveEngine.freeValue(state.ctx, exports_obj);
    ActiveEngine.freeValue(state.ctx, module_obj);
    ActiveEngine.freeValue(state.ctx, filename_val);
    ActiveEngine.freeValue(state.ctx, dirname_val);

    return .{ .exports = current_exports };
}

fn compileWrapper(
    ctx: ActiveEngine.Context,
    source: []const u8,
    filename: []const u8,
) RequireError!ActiveEngine.Value {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            var err_out: ?[]const u8 = null;
            const val = qjs_mod.qjsCjsEvalToValue(ctx, source, filename, &err_out);
            if (qjs_mod.Backend.jsIsException(val)) {
                if (err_out) |e| std.heap.c_allocator.free(@constCast(e));
                return error.Compile;
            }
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            var err_out: ?[]const u8 = null;
            const raw = jsc_mod.jscCjsEvalToValue(ctx, source, filename, &err_out);
            if (raw == null) {
                if (err_out) |e| std.heap.c_allocator.free(@constCast(e));
                return error.Compile;
            }
            if (err_out) |e| std.heap.c_allocator.free(@constCast(e));
            // Protect so the caller can freeValue (JSValueUnprotect) symmetrically.
            return ActiveEngine.dupValue(ctx, raw);
        },
        .escargot, .hermes => {
            const r = ActiveEngine.evalValue(ctx, source, filename);
            if (r.err_text) |e| {
                std.heap.c_allocator.free(e);
                if (r.exception) |ex| ActiveEngine.freeValue(ctx, ex);
                return error.Compile;
            }
            return r.value orelse return error.Compile;
        },
    }
}

// --------------------------------------------------------------------------
// Global `require` registration
// --------------------------------------------------------------------------

/// Wrap a module body in the same `(function (exports, module, require, __filename, __dirname) { ... })` form `runWrappedSource` compiles. Returns the wrapper source in a caller-owned buffer.
fn wrapModuleSource(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(alloc);
    try buf.appendSlice(alloc, @import("cjs_wrapper.zig").prefix);
    try buf.appendSlice(alloc, source);
    try buf.appendSlice(alloc, @import("cjs_wrapper.zig").suffix);
    return buf.toOwnedSlice(alloc);
}

/// Execute an already-compiled CommonJS wrapper *function* with a fresh `exports`/`module`/`require`/`filename`/`dirname` environment (the same environment `runWrappedSource` builds) and return the resulting `module.exports`, pinned via `dupValue` — caller owns and must `freeValue`. `wrapper_fn` must be a callable function value; the caller keeps ownership of it.
fn runModuleFn(
    state: *CjsState,
    wrapper_fn: ActiveEngine.Value,
    filename: []const u8,
    dirname: []const u8,
) RequireError!CallResult {
    // Build fresh exports + module = { exports }.
    const exports_obj = ActiveEngine.newObject(state.ctx);
    const module_obj = ActiveEngine.newObject(state.ctx);
    const exp_for_module = ActiveEngine.dupValue(state.ctx, exports_obj);
    ActiveEngine.setPropertyStr(state.ctx, module_obj, "exports", exp_for_module);

    const filename_val = ActiveEngine.newStringVal(state.ctx, filename);
    const dirname_val = ActiveEngine.newStringVal(state.ctx, dirname);

    // The instance's global `require` is the same function — reuse it via globalThis.require rather than synthesising a bound wrapper. Nested require calls go through the global, which still has access to the cache and loader (per-instance via stateFromCtx).
    const require_fn = getGlobalRequire(state.ctx);
    defer ActiveEngine.freeValue(state.ctx, require_fn);

    const argv = [_]ActiveEngine.Value{
        exports_obj,
        module_obj,
        require_fn,
        filename_val,
        dirname_val,
    };

    const undef = ActiveEngine.undefinedValue();
    const call_result = ActiveEngine.callFunction(state.ctx, wrapper_fn, undef, &argv) orelse {
        ActiveEngine.freeValue(state.ctx, exports_obj);
        ActiveEngine.freeValue(state.ctx, module_obj);
        ActiveEngine.freeValue(state.ctx, filename_val);
        ActiveEngine.freeValue(state.ctx, dirname_val);
        return error.CallFailed;
    };
    ActiveEngine.freeValue(state.ctx, call_result);

    // Fetch module.exports (the wrapper may have reassigned `module.exports`).
    const current_exports = ActiveEngine.getPropertyVal(state.ctx, module_obj, "exports") orelse
        ActiveEngine.dupValue(state.ctx, exports_obj);

    ActiveEngine.freeValue(state.ctx, exports_obj);
    ActiveEngine.freeValue(state.ctx, module_obj);
    ActiveEngine.freeValue(state.ctx, filename_val);
    ActiveEngine.freeValue(state.ctx, dirname_val);

    return .{ .exports = current_exports };
}

// --------------------------------------------------------------------------
// Cached CommonJS evaluation (bytecode-compiled module bodies)
// --------------------------------------------------------------------------

pub const CjsCacheResult = struct {
    /// JSON-stringified `module.exports`, matching `evalAsCjs`'s contract.
    result: ?[]const u8 = null,
    err: ?[]const u8 = null,
    err_is_heap: bool = false,
    cache_hit: bool = false,
    /// True when the cached payload couldn't be decoded (stale/corrupt) and the caller should rebuild rather than re-surface as a script error.
    decode_failed: bool = false,
};

/// Compile a CommonJS module body into bytecode WITHOUT executing it. The body is wrapped in the standard CJS wrapper so executing the bytecode later yields a *function* value (not a script result), suitable for `runCommonJS` to invoke with a per-module environment.
///
/// Returns a `CompileResult` exactly like `bytecode.compile`. On non-QuickJS backends this is "not supported" (matching `bytecode.compile`'s JSC contract).
pub fn compileCommonJS(instance_id: i32, source: []const u8, filename: []const u8) bytecode.CompileResult {
    const wrapped = wrapModuleSource(std.heap.c_allocator, source) catch
        return .{ .err = "out of memory", .err_is_heap = false };
    defer std.heap.c_allocator.free(wrapped);
    return bytecode.compile(instance_id, wrapped, filename);
}

/// Execute a CommonJS module body from previously-compiled bytecode: recover the wrapper *function* (`qjsRunBytecodeToFn`), invoke it with a fresh `exports`/`module`/`require`/`filename`/`dirname` environment, and return the resulting `module.exports`.
///
/// Returns an `EvalResult`-shaped struct. On any inability to decode or invoke, `err` is populated (and `err_is_heap` set when heap-allocated).
pub fn runCommonJS(instance_id: i32, bytes: []const u8, filename: []const u8) CjsCacheResult {
    const lease = @import("../runtime/engine_thread.zig").beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return .{ .err = "Engine is unavailable", .err_is_heap = false };
    var execution = @import("../runtime/js_scheduler.zig").beginExecution(instance_id) orelse
        return .{ .err = "Engine is unavailable", .err_is_heap = false };
    defer {
        execution.end();
        if (instance_map.getPtrs(instance_id)) |ptrs| @import("../runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    }

    const state = getState(instance_id) orelse
        return .{ .result = null, .err = "cjs.install not called for this instance", .err_is_heap = false };
    const dirname = dirnameOf(filename);

    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const tofn = qjs_mod.qjsRunBytecodeToFn(state.ctx, bytes);
            if (tofn.decode_failed or tofn.err != null) {
                if (tofn.err_is_heap) {
                    if (tofn.err) |e| std.heap.c_allocator.free(@constCast(e));
                }
                var cj = CjsCacheResult{ .err = tofn.err, .err_is_heap = tofn.err_is_heap };
                if (tofn.decode_failed and tofn.err == null) {
                    cj.err = "stale or corrupt bytecode";
                    cj.err_is_heap = false;
                }
                cj.decode_failed = tofn.decode_failed;
                return cj;
            }
            const fn_val = tofn.fn_value orelse return .{ .err = "no function value", .err_is_heap = false };
            const call = runModuleFn(state, fn_val, filename, dirname) catch |e| {
                const msg = switch (e) {
                    error.OutOfMemory => "out of memory",
                    error.Compile => "failed to compile CJS wrapper",
                    error.CallFailed => "CJS module threw during evaluation",
                };
                const heap = std.heap.c_allocator.dupe(u8, msg) catch null;
                ActiveEngine.freeValue(state.ctx, fn_val);
                return .{ .err = heap orelse msg, .err_is_heap = heap != null };
            };
            ActiveEngine.freeValue(state.ctx, fn_val);
            return exportsToCjsCache(state, call);
        },
        .jsc => {
            return .{ .err = "runCommonJS not supported on JSC", .err_is_heap = false };
        },
        .escargot, .hermes => {
            // No stable bytecode blob on Escargot; Hermes .hbc path is separate (hermesCompileBytecode).
            // Text CJS goes through require()/evalAsCjs + evalValue.
            return .{ .err = "runCommonJS bytecode path not supported on Escargot/Hermes", .err_is_heap = false };
        },
    }
}

fn exportsToCjsCache(state: *CjsState, call: CallResult) CjsCacheResult {
    defer ActiveEngine.freeValue(state.ctx, call.exports);
    const str = stringifyValue(state.ctx, call.exports);
    return .{ .result = str, .cache_hit = false };
}

/// Bytecode-cache a CommonJS module body, mirroring `cache.evalCached`'s content-keyed persistence + atomic-write contract but for the CJS wrapper path. `source` must be a deterministic module body (same bytes ⇒ same module); keying is content + filename + caller version + the library build fingerprint, exactly like `cache.evalCached`.
///
/// Hit ⇒ run cached bytecode through `runCommonJS`; miss ⇒ compile wrapper via `compileCommonJS`, persist, run. `version` is the engine-version string used for invalidation (see `cache.evalCached`). On any cache or compile failure this degrades to a plain `evalAsCjs` so it can never break module loading — `cache_hit` reports the path taken.
pub fn evalCachedCjs(
    instance_id: i32,
    source: []const u8,
    filename: []const u8,
    cache_dir: []const u8,
    version: []const u8,
) CjsCacheResult {
    if (!@import("build_options").bytecode_cache) return plainCjs(instance_id, source, filename);
    // JSC/Escargot have no QJS-shaped CJS bytecode replay; Hermes .hbc is a different format
    // (hermesCompileBytecode / hermesRunBytecode). Bypass so stale or engine-native blobs cannot
    // block plain require()/evalAsCjs.
    if (backend.isJscApiBackend(backend.active_backend) or backend.isSpikeBackend(backend.active_backend))
        return plainCjs(instance_id, source, filename);
    // Small modules are cheaper to parse than to read/deserialize back.
    if (source.len < 4 * 1024) return plainCjs(instance_id, source, filename);
    if (!cache.isSafeVersion(version) or cache_dir.len == 0) return plainCjs(instance_id, source, filename);

    const gpa = std.heap.c_allocator;
    const srckey = cache.sha256Hex(source);
    if (srckey.len == 0) return plainCjs(instance_id, source, filename);
    defer gpa.free(srckey);
    const namekey = cache.sha256Hex(filename);
    if (namekey.len == 0) return plainCjs(instance_id, source, filename);
    defer gpa.free(namekey);

    const path = cache.cachePath(gpa, cache_dir, version, srckey, namekey) orelse
        return plainCjs(instance_id, source, filename);
    defer gpa.free(path);

    // Cache hit: read + run the bytecode as a CJS wrapper function.
    if (cache.readBytes(path)) |cached| {
        defer gpa.free(cached);
        var res = runCommonJS(instance_id, cached, filename);
        if (res.err == null) {
            res.cache_hit = true;
            return res;
        }
        const rebuildable = res.decode_failed;
        const is_stale = rebuildable;
        const err = res.err;
        const err_is_heap = res.err_is_heap;
        const result_str = res.result;
        if (is_stale) {
            freeCjsResult(res);
            cache.deleteFile(path);
        } else {
            // Runtime exception from the cached run: keep the cache, hand the exception through unchanged (a side-effecting module is never executed twice).
            if (result_str) |r| gpa.free(@constCast(r));
            return .{ .result = null, .err = err, .err_is_heap = err_is_heap, .cache_hit = true };
        }
    }

    // Cache miss: compile the wrapper now, persist, run.
    const compiled = compileCommonJS(instance_id, source, filename);
    defer bytecode.freeCompileResult(compiled);
    if (compiled.bytes) |bytes| {
        cache.writeBytes(path, bytes);
        const res = runCommonJS(instance_id, bytes, filename);
        if (res.err == null) return res;
        if (res.result) |r| gpa.free(@constCast(r));
        return res;
    }
    // Compile failed (syntax error): surface it the way evalAsCjs would.
    return plainCjs(instance_id, source, filename);
}

fn plainCjs(instance_id: i32, source: []const u8, filename: []const u8) CjsCacheResult {
    const res = evalAsCjs(instance_id, source, filename);
    return .{
        .result = res.result,
        .err = res.err,
        .err_is_heap = res.err_is_heap,
        .cache_hit = false,
    };
}

fn freeCjsResult(res: CjsCacheResult) void {
    if (res.result) |r| std.heap.c_allocator.free(@constCast(r));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

fn registerGlobalRequire(ctx: ActiveEngine.Context) bool {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const global = qjs_mod.qjs.JS_GetGlobalObject(ctx);
            defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);
            const fn_val = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, &qjsRequireCb, "require", 1);
            _ = qjs_mod.qjs.JS_SetPropertyStr(ctx, global, "require", fn_val);
            return true;
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const jsc_ctx: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const global = jsc_mod.jsc.JSContextGetGlobalObject(jsc_ctx);
            const fn_obj = jsc_mod.JscBackend.makeFunction(jsc_ctx, "require", jscRequireCb);
            jsc_mod.JscBackend.setProperty(jsc_ctx, global, "require", @ptrCast(fn_obj));
            return true;
        },
        .escargot, .hermes => {
            const fn_obj = ActiveEngine.makeNativeFunction(ctx, "require", &spikeRequireCb, null) orelse return false;
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            ActiveEngine.setPropertyStr(ctx, global, "require", fn_obj);
            return true;
        },
    }
}

fn getGlobalRequire(ctx: ActiveEngine.Context) ActiveEngine.Value {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const global = qjs_mod.qjs.JS_GetGlobalObject(ctx);
            defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);
            return qjs_mod.qjs.JS_GetPropertyStr(ctx, global, "require");
        },
        .jsc => {
            const jsc_mod = @import("../backend/jsc.zig");
            const jsc_ctx: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const global = jsc_mod.jsc.JSContextGetGlobalObject(jsc_ctx);
            const js_name = jsc_mod.jsc.JSStringCreateWithUTF8CString("require");
            defer jsc_mod.jsc.JSStringRelease(js_name);
            var exc: jsc_mod.jsc.JSValueRef = null;
            const val = jsc_mod.jsc.JSObjectGetProperty(jsc_ctx, global, js_name, &exc);
            if (val != null) jsc_mod.jsc.JSValueProtect(jsc_ctx, val);
            return val;
        },
        .escargot, .hermes => {
            const global = ActiveEngine.getGlobalObject(ctx);
            defer ActiveEngine.freeValue(ctx, global);
            // getPropertyVal returns ?Value; Value is already optional-pointer.
            return ActiveEngine.getPropertyVal(ctx, global, "require") orelse null;
        },
    }
}

// --------------------------------------------------------------------------
// Native require callbacks (one per backend ABI)
// --------------------------------------------------------------------------

fn qjsRequireCb(
    ctx: ?*@import("../backend.zig").ActiveEngineModule.qjs.JSContext,
    _this: @import("../backend.zig").ActiveEngineModule.qjs.JSValue,
    argc: c_int,
    argv: [*c]@import("../backend.zig").ActiveEngineModule.qjs.JSValue,
) callconv(.c) @import("../backend.zig").ActiveEngineModule.qjs.JSValue {
    _ = _this;
    const qjs_mod = @import("../backend.zig").ActiveEngineModule;
    if (argc < 1) {
        return qjs_mod.qjs.JS_ThrowTypeError(ctx, "require: specifier required");
    }
    const state = stateFromCtx(ctx) orelse {
        return qjs_mod.qjs.JS_ThrowReferenceError(ctx, "require: not installed");
    };
    const spec_cstr = qjs_mod.jsbay_qjs_JS_ToCString(ctx, argv[0]) orelse {
        return qjs_mod.qjs.JS_ThrowTypeError(ctx, "require: specifier must be a string");
    };
    defer qjs_mod.jsbay_qjs_JS_FreeCString(ctx, spec_cstr);
    const spec = std.mem.span(spec_cstr);

    const loaded = doRequire(state, spec, "<cjs>") catch |e| {
        return qjsThrowRequireError(ctx, spec, e);
    };
    // doRequire returned a duped value; hand it off to QJS as the function result — the caller (JS `require(x)` site) now owns the reference.
    return loaded;
}

fn qjsThrowRequireError(
    ctx: ?*@import("../backend.zig").ActiveEngineModule.qjs.JSContext,
    specifier: []const u8,
    e: DoRequireError,
) @import("../backend.zig").ActiveEngineModule.qjs.JSValue {
    const qjs_mod = @import("../backend.zig").ActiveEngineModule;
    switch (e) {
        error.NotFound => {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrintSentinel(&msg_buf, "Cannot find module '{s}'", .{specifier}, 0) catch
                return qjs_mod.qjs.JS_ThrowReferenceError(ctx, "Cannot find module");
            return qjs_mod.qjs.JS_ThrowInternalError(ctx, "%s", msg.ptr);
        },
        error.CompileFailed => return qjs_mod.qjs.JS_ThrowSyntaxError(ctx, "require: failed to compile module '%s'", @as([*:0]const u8, @ptrCast(specifier.ptr))),
        error.CallFailed => {
            // The underlying exception is already parked in ctx — let it propagate by returning JS_EXCEPTION.
            return qjs_mod.JS_EXCEPTION;
        },
        error.OutOfMemory => return qjs_mod.qjs.JS_ThrowOutOfMemory(ctx),
    }
}

fn jscRequireCb(
    ctx_ref: @import("../backend/jsc.zig").jsc.JSContextRef,
    _f: @import("../backend/jsc.zig").jsc.JSObjectRef,
    _t: @import("../backend/jsc.zig").jsc.JSObjectRef,
    argc: usize,
    argv: [*c]const @import("../backend/jsc.zig").jsc.JSValueRef,
    exception: [*c]@import("../backend/jsc.zig").jsc.JSValueRef,
) callconv(.c) @import("../backend/jsc.zig").jsc.JSValueRef {
    _ = _f;
    _ = _t;
    const jsc_mod = @import("../backend/jsc.zig");
    if (argc < 1) {
        return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: specifier required");
    }
    const ctx: ActiveEngine.Context = @constCast(ctx_ref);
    const state = stateFromCtx(ctx) orelse {
        return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: not installed");
    };
    const spec_owned = jsc_mod.JscBackend.valueToString(ctx_ref, argv[0]) orelse {
        return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: specifier must be a string");
    };
    defer std.heap.c_allocator.free(@constCast(spec_owned));

    const loaded = doRequire(state, spec_owned, "<cjs>") catch |e| {
        return jscThrowRequireError(ctx_ref, spec_owned, e, exception);
    };
    return loaded;
}

fn jscThrowRequireError(
    ctx_ref: @import("../backend/jsc.zig").jsc.JSContextRef,
    specifier: []const u8,
    e: DoRequireError,
    exception: [*c]@import("../backend/jsc.zig").jsc.JSValueRef,
) @import("../backend/jsc.zig").jsc.JSValueRef {
    const jsc_mod = @import("../backend/jsc.zig");
    switch (e) {
        error.NotFound => {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Cannot find module '{s}'", .{specifier}) catch
                "Cannot find module";
            return jsc_mod.JscBackend.throwError(ctx_ref, exception, msg);
        },
        error.CompileFailed => return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: failed to compile module"),
        error.CallFailed => {
            // The module's own exception is captured in `exception[0]` via throwError below — give a generic message since the real one was already consumed during the call.
            return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: module threw during evaluation");
        },
        error.OutOfMemory => return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: out of memory"),
    }
}

fn spikeRequireCb(
    ctx: ActiveEngine.Context,
    _this: ActiveEngine.Value,
    args_ptr: ?[*]const ActiveEngine.Value,
    argc: usize,
    _: ?*anyopaque,
) callconv(.c) ActiveEngine.Value {
    _ = _this;
    if (argc < 1) {
        _ = ActiveEngine.throwError(ctx, "require: specifier required");
        return null;
    }
    const state = stateFromCtx(ctx) orelse {
        _ = ActiveEngine.throwError(ctx, "require: not installed");
        return null;
    };
    const argv = args_ptr orelse {
        _ = ActiveEngine.throwError(ctx, "require: specifier required");
        return null;
    };
    const spec_owned = ActiveEngine.valueToString(ctx, argv[0]) orelse {
        _ = ActiveEngine.throwError(ctx, "require: specifier must be a string");
        return null;
    };
    defer std.heap.c_allocator.free(@constCast(spec_owned));

    const loaded = doRequire(state, spec_owned, "<cjs>") catch |e| {
        return spikeThrowRequireError(ctx, spec_owned, e);
    };
    return loaded;
}

fn spikeThrowRequireError(ctx: ActiveEngine.Context, specifier: []const u8, e: DoRequireError) ActiveEngine.Value {
    switch (e) {
        error.NotFound => {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Cannot find module '{s}'", .{specifier}) catch
                "Cannot find module";
            _ = ActiveEngine.throwError(ctx, msg);
            return null;
        },
        error.CompileFailed => {
            _ = ActiveEngine.throwError(ctx, "require: failed to compile module");
            return null;
        },
        error.CallFailed => {
            _ = ActiveEngine.throwError(ctx, "require: module threw during evaluation");
            return null;
        },
        error.OutOfMemory => {
            _ = ActiveEngine.throwError(ctx, "require: out of memory");
            return null;
        },
    }
}

// --------------------------------------------------------------------------
// Shared require implementation (backend-neutral)
// --------------------------------------------------------------------------

const DoRequireError = error{
    NotFound,
    CompileFailed,
    CallFailed,
    OutOfMemory,
};

/// Resolve + load + evaluate `specifier` (given `referrer`), returning the module's `module.exports` pinned via dupValue. Caller owns the returned value (it's returned to JS via the function-return path which transfers ownership to the engine).
fn doRequire(
    state: *CjsState,
    specifier: []const u8,
    referrer: []const u8,
) DoRequireError!ActiveEngine.Value {
    // Step 1: resolve → canonical id. resolve() may be null on the loader; fall back to specifier as-is.
    const canonical = resolveSpecifier(state, specifier, referrer) catch return error.OutOfMemory;
    // `canonical` is owned by the arena (or equal to specifier when we copy it). Re-duped below if first use.
    defer canonical.deinit();

    // Step 2: cache lookup by canonical id.
    if (state.cache.get(canonical.id)) |cached| {
        return ActiveEngine.dupValue(state.ctx, cached.exports);
    }

    // Step 3: load via the user vtable.
    const src = loadSource(state, canonical.id) orelse return error.NotFound;
    defer std.heap.c_allocator.free(src);

    // Step 4: intern canonical id so it outlives this call as the cache key.
    const interned_id = state.arena.allocator().dupe(u8, canonical.id) catch return error.OutOfMemory;

    // Pre-cache an empty exports so cyclic requires see the partial object (matches Node's semantics). We'll overwrite with the final after the wrapper runs.
    const initial_exports = ActiveEngine.newObject(state.ctx);
    const pinned_initial = ActiveEngine.dupValue(state.ctx, initial_exports);
    state.cache.put(interned_id, .{ .id = interned_id, .exports = pinned_initial }) catch {
        ActiveEngine.freeValue(state.ctx, initial_exports);
        ActiveEngine.freeValue(state.ctx, pinned_initial);
        return error.OutOfMemory;
    };
    ActiveEngine.freeValue(state.ctx, initial_exports);

    // Step 5: wrap and evaluate.
    const dirname = dirnameOf(interned_id);
    const call = runWrappedSource(state, src, interned_id, dirname) catch |e| {
        // Evict the placeholder so a retry doesn't return a stale empty object.
        if (state.cache.fetchRemove(interned_id)) |kv| {
            ActiveEngine.freeValue(state.ctx, kv.value.exports);
        }
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.Compile => error.CompileFailed,
            error.CallFailed => error.CallFailed,
        };
    };

    // Step 6: update cache with the final module.exports.
    const final_pinned = ActiveEngine.dupValue(state.ctx, call.exports);
    if (state.cache.getPtr(interned_id)) |entry_ptr| {
        ActiveEngine.freeValue(state.ctx, entry_ptr.exports);
        entry_ptr.exports = final_pinned;
    } else {
        // Shouldn't happen, but if someone cleared the cache mid-call, put it back so later requires still hit.
        state.cache.put(interned_id, .{ .id = interned_id, .exports = final_pinned }) catch {
            ActiveEngine.freeValue(state.ctx, final_pinned);
        };
    }

    // `call.exports` ownership moves to the caller; `final_pinned` now lives in the cache and is refcounted independently.
    return call.exports;
}

const ResolvedId = struct {
    /// Canonical id slice. Points into `buf` (c_allocator-owned) when resolve() returned a string, or into `specifier_src` (borrowed) when we fell through to identity.
    id: []const u8,
    buf: ?[]u8 = null, // owned by c_allocator when non-null

    fn deinit(self: ResolvedId) void {
        if (self.buf) |b| std.heap.c_allocator.free(b);
    }
};

fn resolveSpecifier(
    state: *CjsState,
    specifier: []const u8,
    referrer: []const u8,
) !ResolvedId {
    const loader = state.loader;
    const resolve = loader.vtable.resolve orelse {
        return .{ .id = specifier, .buf = null };
    };

    const ref_z = try std.heap.c_allocator.dupeSentinel(u8, referrer, 0);
    defer std.heap.c_allocator.free(ref_z);
    const spec_z = try std.heap.c_allocator.dupeSentinel(u8, specifier, 0);
    defer std.heap.c_allocator.free(spec_z);

    const user_out = resolve(loader.user_data, ref_z.ptr, spec_z.ptr);
    if (user_out == null) {
        return .{ .id = specifier, .buf = null };
    }
    const out_slice = std.mem.span(user_out.?);
    // Copy into c_allocator memory so we own the lifetime, then hand the original back to the user's free_resolved (if provided).
    const buf = try std.heap.c_allocator.dupe(u8, out_slice);
    if (loader.vtable.free_resolved) |fr| fr(loader.user_data, user_out.?);
    return .{ .id = buf, .buf = buf };
}

fn loadSource(state: *CjsState, canonical_id: []const u8) ?[]u8 {
    const loader = state.loader;
    const id_z = std.heap.c_allocator.dupeSentinel(u8, canonical_id, 0) catch return null;
    defer std.heap.c_allocator.free(id_z);

    var out: types.ModuleLoadResult = .{ .source = undefined, .source_len = 0 };
    if (!loader.vtable.load(loader.user_data, id_z.ptr, &out)) return null;

    // Copy into c_allocator memory so the caller can free uniformly.
    const src = std.heap.c_allocator.alloc(u8, out.source_len) catch return null;
    if (out.source_len > 0) {
        @memcpy(src, out.source[0..out.source_len]);
    }
    return src;
}

// --------------------------------------------------------------------------
// Small helpers
// --------------------------------------------------------------------------

fn dirnameOf(path: []const u8) []const u8 {
    // Use the last '/' or '\\' as the separator. On "no separator found", Node returns ".", so mirror that.
    var i: usize = path.len;
    while (i > 0) : (i -= 1) {
        const c = path[i - 1];
        if (c == '/' or c == '\\') {
            if (i == 1) return path[0..1]; // preserve root "/"
            return path[0 .. i - 1];
        }
    }
    return ".";
}

/// Stringify a JS value for the EvalResult. Matches engine.evalScript's behaviour: JSON.stringify for objects, String(v) for primitives, null for undefined/null.
fn stringifyValue(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?[]const u8 {
    if (ActiveEngine.isUndefined(ctx, val) or ActiveEngine.isNull(ctx, val)) return null;
    if (ActiveEngine.isObjectVal(ctx, val)) {
        return ActiveEngine.jsonStringifyVal(ctx, val);
    }
    return ActiveEngine.valueToStringVal(ctx, val);
}

// --------------------------------------------------------------------------
// Global `__jsbay_cjsCache` registration — bytecode-cached CommonJS
// --------------------------------------------------------------------------

/// Register a JS-callable global `__jsbay_cjsCache(source, requireFn, filename, cacheDir?)` on the QuickJS context. The host's `loadModuleExports` uses this INSTEAD of `new Function("module","exports", "require", source)` so a widget/system-app body that costs hundreds of milliseconds to compile is compiled once and replayed from bytecode.
///
/// Unlike `evalCachedCjs` (which returns a string and uses the engine's global `require`), this callback:
/// * preserves the caller's injected `require` (the widget runtime's restricted `requireSharedWidgetModule`) by passing the JS `requireFn` straight into the wrapper's argument list;
/// * returns the *live* `module.exports` JS value, so the mount path keeps real object identity + functions (a JSON round-trip would drop them).
///
/// Persistence: when `cacheDir` is provided, bytes are stored under a shared cache key containing both the source and filename hashes. Without it (or on any cache failure) the callback degrades to a per-process cache keyed by the same pair, then finally to a plain wrapper compile.
fn registerGlobalCjsCache(ctx: ActiveEngine.Context) bool {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../backend.zig").ActiveEngineModule;
            const global = qjs_mod.qjs.JS_GetGlobalObject(ctx);
            defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);
            const fn_val = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, &qjsCjsCacheCb, "__jsbay_cjsCache", 4);
            // JS_SetPropertyStr consumes fn_val's reference.
            _ = qjs_mod.qjs.JS_SetPropertyStr(ctx, global, "__jsbay_cjsCache", fn_val);
            return true;
        },
        .jsc => return false,
        .escargot, .hermes => return false,
    }
}

const CjsCacheCbError = error{ OutOfMemory, CompileFailed, CallFailed };

/// Backend for the global `__jsbay_cjsCache` callback. See `registerGlobalCjsCache` for semantics.
fn qjsCjsCacheCb(
    ctx: ?*@import("../backend.zig").ActiveEngineModule.qjs.JSContext,
    _this: @import("../backend.zig").ActiveEngineModule.qjs.JSValue,
    argc: c_int,
    argv: [*c]@import("../backend.zig").ActiveEngineModule.qjs.JSValue,
) callconv(.c) @import("../backend.zig").ActiveEngineModule.qjs.JSValue {
    _ = _this;
    const qjs_mod = @import("../backend.zig").ActiveEngineModule;
    if (argc < 1) {
        return qjs_mod.qjs.JS_ThrowTypeError(ctx, "__jsbay_cjsCache: source required");
    }
    const state = stateFromCtx(ctx) orelse {
        return qjs_mod.qjs.JS_ThrowReferenceError(ctx, "__jsbay_cjsCache: not installed");
    };
    // argv[0] source (string, required)
    const src_cstr = qjs_mod.jsbay_qjs_JS_ToCString(ctx, argv[0]) orelse {
        return qjs_mod.qjs.JS_ThrowTypeError(ctx, "__jsbay_cjsCache: source must be a string");
    };
    defer qjs_mod.jsbay_qjs_JS_FreeCString(ctx, src_cstr);
    const source = std.mem.span(src_cstr);

    // argv[1] requireFn (callable, required)
    if (argc < 2 or qjs_mod.jsbay_qjs_JS_IsFunction(ctx, argv[1]) == 0) {
        return qjs_mod.qjs.JS_ThrowTypeError(ctx, "__jsbay_cjsCache: require function required");
    }
    const require_fn = qjs_mod.jsbay_qjs_JS_DupValue(ctx, argv[1]);
    defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, require_fn);

    // argv[2] filename (string, optional; default "<cjs>")
    var filename_buf: ?[*:0]const u8 = null;
    defer if (filename_buf) |f| qjs_mod.jsbay_qjs_JS_FreeCString(ctx, f);
    var filename: []const u8 = "<cjs>";
    if (argc >= 3 and qjs_mod.jsbay_qjs_JS_IsString(argv[2]) != 0) {
        filename_buf = qjs_mod.jsbay_qjs_JS_ToCString(ctx, argv[2]);
        if (filename_buf) |f| filename = std.mem.span(f);
    }

    // argv[3] cacheDir (string, optional; empty ⇒ in-memory only)
    var cdir_buf: ?[*:0]const u8 = null;
    defer if (cdir_buf) |d| qjs_mod.jsbay_qjs_JS_FreeCString(ctx, d);
    var cache_dir: []const u8 = "";
    if (argc >= 4 and qjs_mod.jsbay_qjs_JS_IsString(argv[3]) != 0) {
        cdir_buf = qjs_mod.jsbay_qjs_JS_ToCString(ctx, argv[3]);
        if (cdir_buf) |d| cache_dir = std.mem.span(d);
    }

    const exports_val = runCjsCacheBundledBody(
        state,
        source,
        require_fn,
        filename,
        cache_dir,
    ) catch |e| {
        return switch (e) {
            error.OutOfMemory => qjs_mod.qjs.JS_ThrowOutOfMemory(ctx),
            error.CompileFailed => qjs_mod.qjs.JS_ThrowSyntaxError(ctx, "__jsbay_cjsCache: failed to compile module"),
            error.CallFailed => qjs_mod.JS_EXCEPTION,
        };
    };
    // `exports_val` is duped by runCjsCacheBundledBody; hand to QJS via the return path so the JS caller owns the reference.
    return exports_val;
}

/// Compile + run a module body through the CJS cache, returning the pinned `module.exports` JS value (caller owns the returned reference).
///
/// Order:
///   1. disk cache (cache_dir provided + file present) → run
///   2. in-process bytecode cache → run
/// 3. compile wrapper now; persist to disk (best-effort), memoize in process, run.
fn runCjsCacheBundledBody(
    state: *CjsState,
    source: []const u8,
    require_fn: @import("../backend.zig").ActiveEngineModule.qjs.JSValue,
    filename: []const u8,
    cache_dir: []const u8,
) CjsCacheCbError!@import("../backend.zig").ActiveEngineModule.qjs.JSValue {
    const qjs_mod = @import("../backend.zig").ActiveEngineModule;
    const gpa = std.heap.c_allocator;

    const srckey = cache.sha256Hex(source);
    if (srckey.len == 0) return error.OutOfMemory;
    defer gpa.free(srckey);
    const namekey = cache.sha256Hex(filename);
    if (namekey.len == 0) return error.OutOfMemory;
    defer gpa.free(namekey);
    const inproc_key = std.fmt.allocPrint(gpa, "{s}-{s}", .{ srckey, namekey }) catch return error.OutOfMemory;
    var inproc_key_owned = true;
    defer if (inproc_key_owned) gpa.free(inproc_key);

    var disk_path: ?[]u8 = null;
    var version_buf: ?[]const u8 = null;
    if (@import("build_options").bytecode_cache and cache_dir.len > 0 and cache.isSafeVersion(CJS_CACHE_VERSION)) {
        if (cache.cachePath(gpa, cache_dir, CJS_CACHE_VERSION, srckey, namekey)) |p| {
            disk_path = p;
            version_buf = CJS_CACHE_VERSION;
        }
    }
    defer if (disk_path) |p| gpa.free(p);

    // 1. disk hit.
    if (disk_path) |path| {
        if (cache.readBytes(path)) |cached| {
            // runCommonJS executes via the wrapper and returns a string — we need the live object, so drive the low-level path here instead.
            const fn_result = qjs_mod.qjsRunBytecodeToFn(state.ctx, cached);
            gpa.free(cached);
            if (!fn_result.decode_failed and fn_result.err == null) {
                if (fn_result.fn_value) |fnv| {
                    const exports_val = runWrapperWithRequire(state, fnv, require_fn, filename) catch |e| {
                        qjs_mod.jsbay_qjs_JS_FreeValue(state.ctx, fnv);
                        return e;
                    };
                    qjs_mod.jsbay_qjs_JS_FreeValue(state.ctx, fnv);
                    return exports_val;
                }
            }
            // Stale/undecodable: drop and rebuild once.
            if (fn_result.err_is_heap) {
                if (fn_result.err) |e| gpa.free(@constCast(e));
            }
            cache.deleteFile(path);
        }
    }

    // 2. in-process hit.
    if (state.bytecode_cache.get(inproc_key)) |inproc| {
        const fn_result = qjs_mod.qjsRunBytecodeToFn(state.ctx, inproc);
        if (!fn_result.decode_failed and fn_result.err == null) {
            if (fn_result.fn_value) |fnv| {
                const exports_val = runWrapperWithRequire(state, fnv, require_fn, filename) catch |e| {
                    qjs_mod.jsbay_qjs_JS_FreeValue(state.ctx, fnv);
                    return e;
                };
                qjs_mod.jsbay_qjs_JS_FreeValue(state.ctx, fnv);
                return exports_val;
            }
        }
        if (fn_result.err_is_heap) {
            if (fn_result.err) |e| gpa.free(@constCast(e));
        }
    }

    // 3. compile + memoize (+ persist best-effort).
    const compiled = compileCommonJS(state.instance_id, source, filename);
    defer bytecode.freeCompileResult(compiled);
    if (compiled.bytes == null) return error.CompileFailed;

    // Own a copy for the in-process map + disk write.
    const owned = gpa.alloc(u8, compiled.bytes.?.len) catch return error.OutOfMemory;
    @memcpy(owned, compiled.bytes.?);
    const inproc_entry = state.bytecode_cache.getOrPut(inproc_key) catch {
        gpa.free(owned);
        return error.OutOfMemory;
    };
    if (inproc_entry.found_existing) {
        // A prior in-process decode failed. Keep its owned key, replace only the stale payload, and release this temporary duplicate key.
        gpa.free(inproc_key);
        inproc_key_owned = false;
        std.heap.c_allocator.free(inproc_entry.value_ptr.*);
    } else {
        inproc_key_owned = false;
    }
    inproc_entry.value_ptr.* = owned;
    // `owned` now lives in the map (freed by uninstall); do NOT free it here.

    if (disk_path) |path| {
        cache.writeBytes(path, owned);
    }

    const fn_result = qjs_mod.qjsRunBytecodeToFn(state.ctx, owned);
    if (fn_result.err_is_heap) {
        if (fn_result.err) |e| gpa.free(@constCast(e));
    }
    if (fn_result.decode_failed or fn_result.err != null or fn_result.fn_value == null) {
        return error.CallFailed;
    }
    const fnv = fn_result.fn_value.?;
    const exports_val = runWrapperWithRequire(state, fnv, require_fn, filename) catch |e| {
        qjs_mod.jsbay_qjs_JS_FreeValue(state.ctx, fnv);
        return e;
    };
    // fnv is the recovered wrapper function; release it now that the call is done (runWrapperWithRequire returns a duped exports the caller owns).
    qjs_mod.jsbay_qjs_JS_FreeValue(state.ctx, fnv);
    return exports_val;
}

/// Invoke an already-compiled CJS wrapper *function* with a fresh module environment where `require` is the caller-supplied JS function value. Returns the resulting `module.exports` *pinned* (duped) — the caller owns the returned reference.
fn runWrapperWithRequire(
    state: *CjsState,
    wrapper_fn: @import("../backend.zig").ActiveEngineModule.qjs.JSValue,
    require_fn: @import("../backend.zig").ActiveEngineModule.qjs.JSValue,
    filename: []const u8,
) CjsCacheCbError!@import("../backend.zig").ActiveEngineModule.qjs.JSValue {
    const exports_obj = ActiveEngine.newObject(state.ctx);
    const module_obj = ActiveEngine.newObject(state.ctx);
    const exp_for_module = ActiveEngine.dupValue(state.ctx, exports_obj);
    ActiveEngine.setPropertyStr(state.ctx, module_obj, "exports", exp_for_module);

    const dirname = dirnameOf(filename);
    const filename_val = ActiveEngine.newStringVal(state.ctx, filename);
    const dirname_val = ActiveEngine.newStringVal(state.ctx, dirname);

    // `ActiveEngine.Value` is the raw JSValue on the QuickJS backend; dup the argv entries so freeing the locals below is balanced, exactly like `runWrappedSource` does.
    const argv = [_]ActiveEngine.Value{
        ActiveEngine.dupValue(state.ctx, exports_obj),
        ActiveEngine.dupValue(state.ctx, module_obj),
        ActiveEngine.dupValue(state.ctx, require_fn),
        filename_val,
        dirname_val,
    };
    defer {
        ActiveEngine.freeValue(state.ctx, argv[0]);
        ActiveEngine.freeValue(state.ctx, argv[1]);
        ActiveEngine.freeValue(state.ctx, argv[2]);
        ActiveEngine.freeValue(state.ctx, argv[3]);
        ActiveEngine.freeValue(state.ctx, argv[4]);
    }

    const undef = ActiveEngine.undefinedValue();
    const call_result = ActiveEngine.callFunction(state.ctx, wrapper_fn, undef, &argv) orelse {
        ActiveEngine.freeValue(state.ctx, exports_obj);
        ActiveEngine.freeValue(state.ctx, module_obj);
        return error.CallFailed;
    };
    ActiveEngine.freeValue(state.ctx, call_result);

    const current_exports = ActiveEngine.getPropertyVal(state.ctx, module_obj, "exports") orelse
        ActiveEngine.dupValue(state.ctx, exports_obj);

    ActiveEngine.freeValue(state.ctx, exports_obj);
    ActiveEngine.freeValue(state.ctx, module_obj);
    return current_exports;
}

/// Cache version salt for `__jsbay_cjsCache` persisted artifacts. Bump with the engine whenever the QuickJS bytecode format changes, so stale files are dropped and rebuilt rather than replayed.
const CJS_CACHE_VERSION = "jsbay-cjs-1";
