//! CommonJS `require()` support.
//!
//! Sits entirely in Zig userspace on top of the existing backend primitives. Reuses the same `ModuleLoader` vtable users configure for ES modules via `EngineConfig.module_loader` — there is no separate loader type.
//!
//! Semantics:
//! * `require(spec)` resolves `spec` through the loader (`resolve` if supplied, else identity), loads source via `load`, wraps it as `(function (exports, module, require, __filename, __dirname) { ... })`, evaluates, and calls the wrapper with a fresh `{}` for `exports` and `{ exports }` for `module`. The final `module.exports` is cached and returned.
//! * Module-local require closures resolve from the current canonical filename; the global require keeps "<cjs>" as its fallback. Injected require functions keep their caller-provided policy unchanged.
//! * Cached entries are keyed by canonical id (the string returned by `resolve`, or the original specifier when `resolve` is null).
//! * The cached JS value is pinned via `ActiveEngine.dupValue` so repeated `require(id)` yields the same object identity (same as Node).
//! * Cyclic require chains see the live module.exports, initially the same object passed as exports; reassignment does not rewrite previously returned aliases.
//!
//! Thread safety: all operations on a given `instance_id` MUST happen on the owning thread — the per-instance state is stored behind a global mutex but the JS context itself is single-threaded.

const std = @import("std");
const sync = @import("zev");
const types = @import("../../types.zig");
const engine = @import("../../engine.zig");
const bytecode = @import("../bytecode.zig");
const cache = @import("../cache.zig");
const instance_map = @import("../../runtime/instance_map.zig");
const backend = @import("../../backend.zig");
const OwnedValue = @import("../../value/root.zig").OwnedValue;

const ActiveEngine = backend.ActiveEngine;

// -------------------------------------------------------------------------- Per-instance state --------------------------------------------------------------------------

const loader_bridge = @import("loader_bridge.zig");
const commonjs = @import("commonjs");
const compile_cache = @import("compile_cache.zig");
const wrapper_execution = @import("wrapper_execution.zig");
const ValueOps = struct {
    pub const Context = ActiveEngine.Context;
    pub const Value = ActiveEngine.Value;
    pub const newExports = wrapper_execution.newExports;
    pub const retain = ActiveEngine.dupValue;
    pub const release = ActiveEngine.freeValue;
    pub const newModule = wrapper_execution.newModule;
    pub fn readExports(ctx: Context, module: Value) error{CallFailed}!Value {
        return wrapper_execution.readFinalExports(ctx, module, captureException);
    }
};
const ModuleRegistry = commonjs.Registry(ValueOps);

const CjsState = struct {
    instance_id: i32,
    allocator: std.mem.Allocator,
    ctx: ActiveEngine.Context,
    loader: *const types.ModuleLoader,
    registry: ModuleRegistry,
    /// Tracks whether the global `require` has been registered on the JS context — prevents duplicate registration on repeat install() calls.
    require_installed: bool = false,
    /// Tracks whether the global `__jsbay_cjsCache` has been registered.
    cjs_cache_installed: bool = false,
    compiled: compile_cache.Memory,
    pending_exception: ?OwnedValue = null,
    require_factory: ?ActiveEngine.Value = null,
};

var cjs_states: std.AutoHashMap(i32, *CjsState) = std.AutoHashMap(i32, *CjsState).init(std.heap.c_allocator);
var cjs_mutex: sync.Mutex = .{};

pub fn getState(instance_id: i32) ?*CjsState {
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

// -------------------------------------------------------------------------- Public API --------------------------------------------------------------------------

/// Install a global `require(specifier)` on the instance, tied to the given module loader. Idempotent — subsequent calls on the same instance are no-ops and return `true`.
///
/// The `loader` pointer must outlive the engine instance (same contract as `EngineConfig.module_loader`). Pass the same pointer you configured via `EngineConfig` so ES-module and CommonJS paths share loader state.
///
/// Returns `false` if the instance is unknown or native-function registration fails.
pub fn install(instance_id: i32, loader: *const types.ModuleLoader) bool {
    if (getState(instance_id)) |_| return true; // already installed
    const ctx = engine.getContext(instance_id) orelse return false;
    const inst = instance_map.getInstance(instance_id) orelse return false;
    const alloc = inst.allocator;

    const state = alloc.create(CjsState) catch return false;
    state.* = .{
        .instance_id = instance_id,
        .allocator = alloc,
        .ctx = ctx,
        .loader = loader,
        .registry = ModuleRegistry.init(alloc),
        .compiled = compile_cache.Memory.init(alloc),
    };
    putState(state) catch {
        state.registry.arena.deinit();
        state.registry.entries.deinit();
        alloc.destroy(state);
        return false;
    };

    if (!registerGlobalRequire(ctx)) {
        // State is now registered but require didn't install — roll back so callers see a clean "failure" outcome.
        _ = removeState(instance_id);
        state.registry.arena.deinit();
        state.registry.entries.deinit();
        alloc.destroy(state);
        return false;
    }

    state.require_installed = true;
    // Register the bytecode-cached CommonJS helper on supported backends. Registration is best-effort and does not determine whether the global require installation succeeds.
    state.cjs_cache_installed = registerGlobalCjsCache(ctx);
    return true;
}

/// Evaluate `source` as a CommonJS script — `require`, `module`, `exports`, `__filename`, `__dirname` are in scope. The script's `module.exports` drives the return value.
///
/// Returned `result` is JSON-stringified (objects) or toString'd (primitives), matching `engine.evalScript`'s contract. `err` is populated on exception.
pub fn evalAsCjs(instance_id: i32, source: []const u8, filename: []const u8) types.EvalResult {
    const lease = @import("../../runtime/engine_thread.zig").beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return .{ .err = "Engine is unavailable", .err_is_heap = false };
    var execution = @import("../../runtime/js_scheduler.zig").beginExecution(instance_id) orelse
        return .{ .err = "Engine is unavailable", .err_is_heap = false };
    defer {
        execution.end();
        if (instance_map.getPtrs(instance_id)) |ptrs| @import("../../runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    }

    const state = getState(instance_id) orelse
        return .{ .result = null, .err = "cjs.install not called for this instance", .err_is_heap = false };

    // Compute dirname from filename (strip trailing basename). Mirrors Node's Path.dirname: "/a/b/c.js" → "/a/b"; "foo.js" → ".".
    const dirname = dirnameOf(filename);

    // Pre-create module/exports/require so we can expose `module.exports` to the caller after the wrapper runs.
    const call = runWrappedSource(state.ctx, state.allocator, source, filename, dirname, null) catch |e| {
        discardCapturedException(state.ctx);
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
    state.registry.clear(state.ctx);
}

/// Uninstall and free per-instance state. Idempotent. `engine.destroy` invokes this automatically after active JavaScript has unwound and before it frees the context. Direct callers may explicitly uninstall only on the owning thread while no JavaScript entry is active.
pub fn uninstall(instance_id: i32) void {
    const state = removeState(instance_id) orelse return;
    const alloc = state.allocator;
    clearCacheState(state);
    if (state.pending_exception) |*exception| exception.deinit();
    if (state.require_factory) |factory| ActiveEngine.freeValue(state.ctx, factory);
    state.compiled.deinit();
    state.registry.deinitStorage();
    alloc.destroy(state);
    // We intentionally do NOT remove the global `require` from the JS context — the context may be mid-teardown. After uninstall, native callbacks report that the state is not installed.
}

// -------------------------------------------------------------------------- require() core --------------------------------------------------------------------------

const RequireError = commonjs.ExecutionError;
const CallResult = wrapper_execution.CallResult;

/// Evaluate wrapped source + invoke wrapper with freshly-minted exports/ module/require. Returns the resulting `module.exports` pinned via `dupValue` — caller owns and must `freeValue`.
fn runWrappedSource(ctx: ActiveEngine.Context, allocator: std.mem.Allocator, source: []const u8, filename: []const u8, dirname: []const u8, environment: ?wrapper_execution.Environment) RequireError!CallResult {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try wrapper_execution.appendSource(allocator, &buf, source);
    var wrapper_fn = OwnedValue.init(ctx, try compileWrapper(ctx, buf.items, filename));
    defer wrapper_fn.deinit();
    return wrapper_execution.invoke(ctx, wrapper_fn.borrow(), .{ .module_local = getModuleRequire }, filename, dirname, environment, captureException);
}

fn compileWrapper(
    ctx: ActiveEngine.Context,
    source: []const u8,
    filename: []const u8,
) RequireError!ActiveEngine.Value {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
            var err_out: ?[]const u8 = null;
            const val = qjs_mod.qjsCjsEvalToValue(ctx, source, filename, &err_out);
            if (qjs_mod.Backend.jsIsException(val)) {
                if (err_out) |e| std.heap.c_allocator.free(@constCast(e));
                return error.Compile;
            }
            return val;
        },
        .jsc => {
            const jsc_mod = @import("../../backend/jsc.zig");
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

// -------------------------------------------------------------------------- Global `require` registration --------------------------------------------------------------------------

/// Wrap a module body in the same `(function (exports, module, require, __filename, __dirname) { ... })` form `runWrappedSource` compiles. Returns the wrapper source in a caller-owned buffer.
fn wrapModuleSource(alloc: std.mem.Allocator, source: []const u8) ![]u8 {
    return wrapper_execution.wrapSource(alloc, source);
}

/// Execute an already-compiled CommonJS wrapper *function* with a fresh `exports`/`module`/`require`/`filename`/`dirname` environment (the same environment `runWrappedSource` builds) and return the resulting `module.exports`, pinned via `dupValue` — caller owns and must `freeValue`. `wrapper_fn` must be a callable function value; the caller keeps ownership of it.
fn runModuleFn(state: *CjsState, wrapper_fn: ActiveEngine.Value, filename: []const u8, dirname: []const u8) RequireError!CallResult {
    return wrapper_execution.invoke(state.ctx, wrapper_fn, .{ .module_local = getModuleRequire }, filename, dirname, null, captureException);
}

// -------------------------------------------------------------------------- Cached CommonJS evaluation (bytecode-compiled module bodies) --------------------------------------------------------------------------

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
    const lease = @import("../../runtime/engine_thread.zig").beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) return .{ .err = "Engine is unavailable", .err_is_heap = false };
    var execution = @import("../../runtime/js_scheduler.zig").beginExecution(instance_id) orelse
        return .{ .err = "Engine is unavailable", .err_is_heap = false };
    defer {
        execution.end();
        if (instance_map.getPtrs(instance_id)) |ptrs| @import("../../runtime/js_scheduler.zig").checkpoint(instance_id, ptrs.ctx);
    }

    const state = getState(instance_id) orelse
        return .{ .result = null, .err = "cjs.install not called for this instance", .err_is_heap = false };
    const dirname = dirnameOf(filename);

    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
            const tofn = qjs_mod.qjsRunBytecodeToFn(state.ctx, bytes);
            if (tofn.decode_failed or tofn.err != null) {
                // Transfer any heap error to the caller. Do not free it and then return the same pointer.
                if (tofn.decode_failed and tofn.err == null) {
                    return .{ .err = "stale or corrupt bytecode", .err_is_heap = false, .decode_failed = true };
                }
                return .{ .err = tofn.err, .err_is_heap = tofn.err_is_heap, .decode_failed = tofn.decode_failed };
            }
            const fn_val = tofn.fn_value orelse return .{ .err = "no function value", .err_is_heap = false };
            const call = runModuleFn(state, fn_val, filename, dirname) catch |e| {
                discardCapturedException(state.ctx);
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
            // No stable bytecode blob on Escargot; Hermes .hbc path is separate (hermesCompileBytecode). Text CJS goes through require()/evalAsCjs + evalValue.
            return .{ .err = "runCommonJS bytecode path not supported on Escargot/Hermes", .err_is_heap = false };
        },
    }
}

// JSC getter exceptions are explicitly protected while crossing Zig error unions; host-returning APIs release them rather than leaving a stale capture.
fn captureException(ctx: ActiveEngine.Context, exception: OwnedValue) void {
    const state = stateFromCtx(ctx) orelse {
        var owned = exception;
        owned.deinit();
        return;
    };
    if (state.pending_exception) |*previous| previous.deinit();
    state.pending_exception = exception;
}

fn discardCapturedException(ctx: ActiveEngine.Context) void {
    if (stateFromCtx(ctx)) |state| {
        if (state.pending_exception) |*exception| exception.deinit();
        state.pending_exception = null;
    }
}

fn exportsToCjsCache(state: *CjsState, call: CallResult) CjsCacheResult {
    defer ActiveEngine.freeValue(state.ctx, call.exports);
    const str = stringifyValue(state.ctx, call.exports);
    return .{ .result = str, .cache_hit = false };
}

/// Bytecode-cache a CommonJS module body, mirroring `cache.evalCached`'s content-keyed persistence + atomic-write contract but for the CJS wrapper path. `source` must be a deterministic module body (same bytes ⇒ same module); keying is content + filename + caller version + the library build fingerprint, exactly like `cache.evalCached`.
///
/// A disk hit runs cached bytecode through `runCommonJS`; a miss or decode failure compiles the wrapper, persists it best-effort, then runs it. `version` is the caller's invalidation string (see `cache.evalCached`). Disabled or unsupported cache paths and compilation failures use `evalAsCjs`; source errors still propagate. Runtime exceptions are returned without executing the module again, and `cache_hit` is true for a decoded disk hit even when execution throws.
pub fn evalCachedCjs(
    instance_id: i32,
    source: []const u8,
    filename: []const u8,
    cache_dir: []const u8,
    version: []const u8,
) CjsCacheResult {
    if (!@import("build_options").bytecode_cache) return plainCjs(instance_id, source, filename);
    // JSC/Escargot have no QJS-shaped CJS bytecode replay; Hermes .hbc is a different format (hermesCompileBytecode / hermesRunBytecode). Bypass so stale or engine-native blobs cannot block plain require()/evalAsCjs.
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
            const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
            const global = qjs_mod.qjs.JS_GetGlobalObject(ctx);
            defer qjs_mod.jsbay_qjs_JS_FreeValue(ctx, global);
            const fn_val = qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, &qjsRequireCb, "require", 1);
            _ = qjs_mod.qjs.JS_SetPropertyStr(ctx, global, "require", fn_val);
            return true;
        },
        .jsc => {
            const jsc_mod = @import("../../backend/jsc.zig");
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

/// Each wrapper receives a JS-owned closure, so saved require functions keep their canonical filename even across nested evaluation and cache eviction. The injected-require path deliberately bypasses this factory.
fn getModuleRequire(ctx: ActiveEngine.Context, filename: []const u8) error{ Compile, CallFailed }!ActiveEngine.Value {
    const state = stateFromCtx(ctx) orelse return error.CallFailed;
    // Compile the constant factory once per installation, not on every bytecode cache replay. Its lifetime is independent of the module instance cache.
    const factory = state.require_factory orelse factory: {
        const value = compileWrapper(ctx, "(function(nativeRequire, referrer) { return function require(specifier) { return nativeRequire(specifier, referrer); }; })", "<cjs-require>") catch return error.Compile;
        state.require_factory = value;
        break :factory value;
    };
    var native = OwnedValue.init(ctx, newNativeRequire(ctx));
    defer native.deinit();
    var referrer = OwnedValue.init(ctx, ActiveEngine.newStringVal(ctx, if (filename.len == 0) "<cjs>" else filename));
    defer referrer.deinit();
    const args = [_]ActiveEngine.Value{ native.borrow(), referrer.borrow() };
    return ActiveEngine.callFunction(ctx, factory, ActiveEngine.undefinedValue(), &args) orelse error.CallFailed;
}

// This callback is captured privately, not read back from mutable globalThis. Creating a function transfers no raw state/arena pointer into JavaScript.
fn newNativeRequire(ctx: ActiveEngine.Context) ActiveEngine.Value {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = backend.ActiveEngineModule;
            return qjs_mod.jsbay_qjs_JS_NewCFunction(ctx, &qjsModuleRequireCb, "require", 1);
        },
        .jsc => {
            const jsc_mod = @import("../../backend/jsc.zig");
            const ctx_ref: jsc_mod.jsc.JSContextRef = @ptrCast(ctx);
            const value = jsc_mod.JscBackend.makeFunction(ctx_ref, "require", jscModuleRequireCb);
            if (value != null) jsc_mod.jsc.JSValueProtect(ctx_ref, value);
            return value;
        },
        .escargot, .hermes => return ActiveEngine.makeNativeFunction(ctx, "require", &spikeModuleRequireCb, null) orelse null,
    }
}

// -------------------------------------------------------------------------- Native require callbacks (one per backend ABI) --------------------------------------------------------------------------

fn qjsRequireCb(
    ctx: ?*backend.ActiveEngineModule.qjs.JSContext,
    this: backend.ActiveEngineModule.qjs.JSValue,
    argc: c_int,
    argv: [*c]backend.ActiveEngineModule.qjs.JSValue,
) callconv(.c) backend.ActiveEngineModule.qjs.JSValue {
    return qjsModuleRequireCb(ctx, this, @min(argc, 1), argv);
}

fn qjsModuleRequireCb(
    ctx: ?*@import("../../backend.zig").ActiveEngineModule.qjs.JSContext,
    _this: @import("../../backend.zig").ActiveEngineModule.qjs.JSValue,
    argc: c_int,
    argv: [*c]@import("../../backend.zig").ActiveEngineModule.qjs.JSValue,
) callconv(.c) @import("../../backend.zig").ActiveEngineModule.qjs.JSValue {
    _ = _this;
    const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
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

    // The per-module JS closure supplies the canonical referrer as the second argument. Root calls without it use the <cjs> resolution context.
    const referrer_cstr = if (argc >= 2 and qjs_mod.jsbay_qjs_JS_IsString(argv[1]) != 0)
        qjs_mod.jsbay_qjs_JS_ToCString(ctx, argv[1]) orelse return qjs_mod.JS_EXCEPTION
    else
        null;
    defer if (referrer_cstr) |text| qjs_mod.jsbay_qjs_JS_FreeCString(ctx, text);
    const loaded = doRequire(state, spec, if (referrer_cstr) |text| std.mem.span(text) else "<cjs>") catch |e| {
        return qjsThrowRequireError(ctx, spec, e);
    };
    // doRequire returned a duped value; hand it off to QJS as the function result — the caller (JS `require(x)` site) now owns the reference.
    return loaded;
}

fn qjsThrowRequireError(
    ctx: ?*@import("../../backend.zig").ActiveEngineModule.qjs.JSContext,
    specifier: []const u8,
    e: DoRequireError,
) @import("../../backend.zig").ActiveEngineModule.qjs.JSValue {
    const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
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
    ctx_ref: @import("../../backend/jsc.zig").jsc.JSContextRef,
    function: @import("../../backend/jsc.zig").jsc.JSObjectRef,
    this: @import("../../backend/jsc.zig").jsc.JSObjectRef,
    argc: usize,
    argv: [*c]const @import("../../backend/jsc.zig").jsc.JSValueRef,
    exception: [*c]@import("../../backend/jsc.zig").jsc.JSValueRef,
) callconv(.c) @import("../../backend/jsc.zig").jsc.JSValueRef {
    return jscModuleRequireCb(ctx_ref, function, this, @min(argc, 1), argv, exception);
}

fn jscModuleRequireCb(
    ctx_ref: @import("../../backend/jsc.zig").jsc.JSContextRef,
    _f: @import("../../backend/jsc.zig").jsc.JSObjectRef,
    _t: @import("../../backend/jsc.zig").jsc.JSObjectRef,
    argc: usize,
    argv: [*c]const @import("../../backend/jsc.zig").jsc.JSValueRef,
    exception: [*c]@import("../../backend/jsc.zig").jsc.JSValueRef,
) callconv(.c) @import("../../backend/jsc.zig").jsc.JSValueRef {
    _ = _f;
    _ = _t;
    const jsc_mod = @import("../../backend/jsc.zig");
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

    const referrer_owned = if (argc >= 2 and jsc_mod.jsc.JSValueIsString(ctx_ref, argv[1]))
        jsc_mod.JscBackend.valueToString(ctx_ref, argv[1])
    else
        null;
    defer if (referrer_owned) |text| std.heap.c_allocator.free(@constCast(text));
    const loaded = doRequire(state, spec_owned, referrer_owned orelse "<cjs>") catch |e| {
        return jscThrowRequireError(ctx_ref, spec_owned, e, exception);
    };
    return loaded;
}

fn jscThrowRequireError(
    ctx_ref: @import("../../backend/jsc.zig").jsc.JSContextRef,
    specifier: []const u8,
    e: DoRequireError,
    exception: [*c]@import("../../backend/jsc.zig").jsc.JSValueRef,
) @import("../../backend/jsc.zig").jsc.JSValueRef {
    const jsc_mod = @import("../../backend/jsc.zig");
    switch (e) {
        error.NotFound => {
            var msg_buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "Cannot find module '{s}'", .{specifier}) catch
                "Cannot find module";
            return jsc_mod.JscBackend.throwError(ctx_ref, exception, msg);
        },
        error.CompileFailed => return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: failed to compile module"),
        error.CallFailed => {
            const ctx: ActiveEngine.Context = @constCast(ctx_ref);
            if (stateFromCtx(ctx)) |state| {
                if (state.pending_exception) |value| {
                    state.pending_exception = null;
                    var owned = value;
                    const raw = owned.release();
                    const result = jsc_mod.jsc.JSValueMakeUndefined(ctx_ref);
                    exception[0] = raw;
                    // No potentially allocating JSC operation follows release; the callback out-param hands the value back to JSC.
                    ActiveEngine.freeValue(ctx, raw);
                    return result;
                }
            }
            return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: module threw during evaluation");
        },
        error.OutOfMemory => return jsc_mod.JscBackend.throwError(ctx_ref, exception, "require: out of memory"),
    }
}

fn spikeRequireCb(
    ctx: ActiveEngine.Context,
    this: ActiveEngine.Value,
    args: ?[*]const ActiveEngine.Value,
    argc: usize,
    data: ?*anyopaque,
) callconv(.c) ActiveEngine.Value {
    return spikeModuleRequireCb(ctx, this, args, @min(argc, 1), data);
}

fn spikeModuleRequireCb(
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

    const referrer_owned = if (argc >= 2) ActiveEngine.valueToString(ctx, argv[1]) else null;
    defer if (referrer_owned) |text| std.heap.c_allocator.free(@constCast(text));
    const loaded = doRequire(state, spec_owned, referrer_owned orelse "<cjs>") catch |e| {
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
            if (stateFromCtx(ctx)) |state| {
                if (state.pending_exception) |exception| {
                    state.pending_exception = null;
                    var owned = exception;
                    if (throwSpikeException(ctx, &owned)) return null;
                    owned.deinit();
                    throwSpikeTransferFailure(ctx);
                    return null;
                }
            }
            _ = ActiveEngine.throwError(ctx, "require: module threw during evaluation");
            return null;
        },
        error.OutOfMemory => {
            _ = ActiveEngine.throwError(ctx, "require: out of memory");
            return null;
        },
    }
}

const spike_throw = @import("spike_throw.zig");
const throwSpikeException = spike_throw.throwSpikeException;
const throwSpikeTransferFailure = spike_throw.throwSpikeTransferFailure;

// -------------------------------------------------------------------------- Shared require implementation (backend-neutral) --------------------------------------------------------------------------

const DoRequireError = commonjs.RequireError;

/// Resolve + load + evaluate `specifier` (given `referrer`), returning the module's `module.exports` pinned via dupValue. Caller owns the returned value (it's returned to JS via the function-return path which transfers ownership to the engine).
fn doRequire(state: *CjsState, specifier: []const u8, referrer: []const u8) DoRequireError!ActiveEngine.Value {
    const bridge = loader_bridge.Bridge.init(state.loader);
    const loader = bridge.loader();
    return state.registry.require(state.ctx, std.heap.c_allocator, &loader, executeModule, specifier, referrer);
}

fn executeModule(ctx: ActiveEngine.Context, allocator: std.mem.Allocator, source: []const u8, filename: []const u8, dirname: []const u8, initial: ActiveEngine.Value, module: ActiveEngine.Value) RequireError!ActiveEngine.Value {
    const call = try runWrappedSource(ctx, allocator, source, filename, dirname, .{ .exports = initial, .module = module });
    return call.exports;
}

const dirnameOf = commonjs.dirnameOf;

/// Stringify a JS value for the EvalResult. Matches engine.evalScript's behaviour: JSON.stringify for objects, String(v) for primitives, null for undefined/null.
fn stringifyValue(ctx: ActiveEngine.Context, val: ActiveEngine.Value) ?[]const u8 {
    if (ActiveEngine.isUndefined(ctx, val) or ActiveEngine.isNull(ctx, val)) return null;
    if (ActiveEngine.isObjectVal(ctx, val)) {
        return ActiveEngine.jsonStringifyVal(ctx, val);
    }
    return ActiveEngine.valueToStringVal(ctx, val);
}

// -------------------------------------------------------------------------- Global `__jsbay_cjsCache` registration — bytecode-cached CommonJS --------------------------------------------------------------------------

/// Register `__jsbay_cjsCache(source, requireFn, filename, cacheDir?)` on QuickJS-family contexts. It caches compiled wrappers, not module instances; each invocation executes a wrapper with fresh exports and module objects.
///
/// Unlike `evalCachedCjs` (which returns a string and uses the engine's global `require`), this callback:
/// * passes the caller-provided `requireFn` directly into the wrapper, preserving the injected resolution and access policy;
/// * returns the live `module.exports` value without JSON serialization, preserving exported objects and functions.
///
/// When enabled and `cacheDir` is provided, persisted keys include source and filename hashes, cache version, and the build fingerprint. Missing or undecodable entries fall through to the in-process compiled-byte cache and then compilation. Wrapper exceptions propagate without another invocation.
fn registerGlobalCjsCache(ctx: ActiveEngine.Context) bool {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => {
            const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
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

const CjsCacheCbError = error{ OutOfMemory, CompileFailed, CallFailed, Compile };

/// Backend for the global `__jsbay_cjsCache` callback. See `registerGlobalCjsCache` for semantics.
fn qjsCjsCacheCb(
    ctx: ?*@import("../../backend.zig").ActiveEngineModule.qjs.JSContext,
    _this: @import("../../backend.zig").ActiveEngineModule.qjs.JSValue,
    argc: c_int,
    argv: [*c]@import("../../backend.zig").ActiveEngineModule.qjs.JSValue,
) callconv(.c) @import("../../backend.zig").ActiveEngineModule.qjs.JSValue {
    _ = _this;
    const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
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
            error.Compile, error.CompileFailed => qjs_mod.qjs.JS_ThrowSyntaxError(ctx, "__jsbay_cjsCache: failed to compile module"),
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
    require_fn: @import("../../backend.zig").ActiveEngineModule.qjs.JSValue,
    filename: []const u8,
    cache_dir: []const u8,
) CjsCacheCbError!@import("../../backend.zig").ActiveEngineModule.qjs.JSValue {
    const qjs_mod = @import("../../backend.zig").ActiveEngineModule;
    const gpa = state.allocator;

    const srckey = cache.sha256Hex(source);
    if (srckey.len == 0) return error.OutOfMemory;
    defer std.heap.c_allocator.free(srckey);
    const namekey = cache.sha256Hex(filename);
    if (namekey.len == 0) return error.OutOfMemory;
    defer std.heap.c_allocator.free(namekey);
    const inproc_key = compile_cache.makeKey(gpa, srckey, namekey) catch return error.OutOfMemory;
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
            defer std.heap.c_allocator.free(cached);
            // runCommonJS executes via the wrapper and returns a string — we need the live object, so drive the low-level path here instead.
            const fn_result = qjs_mod.qjsRunBytecodeToFn(state.ctx, cached);
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
                if (fn_result.err) |e| std.heap.c_allocator.free(@constCast(e));
            }
            cache.deleteFile(path);
        }
    }

    // 2. in-process hit.
    if (state.compiled.get(inproc_key)) |inproc| {
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
            if (fn_result.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }

    // 3. compile + memoize (+ persist best-effort).
    const compiled = compileCommonJS(state.instance_id, source, filename);
    defer bytecode.freeCompileResult(compiled);
    if (compiled.bytes == null) return error.CompileFailed;

    const owned = state.compiled.memoize(inproc_key, compiled.bytes.?) catch return error.OutOfMemory;
    inproc_key_owned = false;

    if (disk_path) |path| {
        cache.writeBytes(path, owned);
    }

    const fn_result = qjs_mod.qjsRunBytecodeToFn(state.ctx, owned);
    if (fn_result.err_is_heap) {
        if (fn_result.err) |e| std.heap.c_allocator.free(@constCast(e));
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
fn runWrapperWithRequire(state: *CjsState, wrapper_fn: @import("../../backend.zig").ActiveEngineModule.qjs.JSValue, require_fn: @import("../../backend.zig").ActiveEngineModule.qjs.JSValue, filename: []const u8) CjsCacheCbError!@import("../../backend.zig").ActiveEngineModule.qjs.JSValue {
    const result = try wrapper_execution.invoke(state.ctx, wrapper_fn, .{ .borrowed = require_fn }, filename, dirnameOf(filename), null, captureException);
    return result.exports;
}

/// Cache version salt for `__jsbay_cjsCache` persisted artifacts. Bump with the engine whenever the QuickJS bytecode format changes, so stale files are dropped and rebuilt rather than replayed.
const CJS_CACHE_VERSION = "jsbay-cjs-1";
