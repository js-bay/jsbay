//! ES module loader support for the JSC backend.
//!
//! Bridged to JavaScriptCore's Objective-C `JSModuleLoaderDelegate` protocol via `src/backend/jsc/module_loader.m`. The ObjC layer reaches back into a user-supplied `ModuleLoaderVTable` (see src/types.zig) through plain C function pointers, so the Zig side stays ABI-clean.
//!
//! Lifecycle:
//! * engine.create calls `installModuleLoader(ctx, loader)` when the user configured a loader — the call stashes the loader pointer in a side table keyed by ctx AND attaches the ObjC delegate to the wrapped JSContext.
//! * jscEvalModule / jscImportModule forward to the ObjC bridge, which runs the evaluation and captures any exception or stringified result into malloc'd C strings we then dupe into c_allocator memory.

const std = @import("std");
const sync = @import("zev");
const types = @import("../../types.zig");
const types_mod = types;
const common = @import("common.zig");

const jsc = common.jsc;

pub const Context = jsc.JSGlobalContextRef;

// Function-pointer types that mirror the C decls in module_loader.m.
const CLoadFn = *const fn (
    user_data: ?*anyopaque,
    canonical_id: [*:0]const u8,
    out_src: *[*]const u8,
    out_len: *usize,
) callconv(.c) bool;

const CResolveFn = *const fn (
    user_data: ?*anyopaque,
    referrer: [*:0]const u8,
    specifier: [*:0]const u8,
) callconv(.c) ?[*:0]u8;

const CFreeResolvedFn = *const fn (
    user_data: ?*anyopaque,
    ptr: [*:0]u8,
) callconv(.c) void;

extern fn jsbay_jsc_install_module_loader(
    c_ctx: ?*anyopaque,
    user_data: ?*anyopaque,
    resolve_cb: ?CResolveFn,
    load_cb: CLoadFn,
    free_cb: ?CFreeResolvedFn,
) void;

extern fn jsbay_jsc_eval_module(
    c_ctx: ?*anyopaque,
    source: [*]const u8,
    source_len: usize,
    module_name: [*:0]const u8,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int;

extern fn jsbay_jsc_import_module(
    c_ctx: ?*anyopaque,
    specifier: [*:0]const u8,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int;

extern fn jsbay_jsc_uninstall_module_loader(c_ctx: ?*anyopaque) void;

// The C stdlib free() — we pair it with the ObjC bridge's malloc'd out strings to avoid any allocator mismatch.
extern fn free(ptr: ?*anyopaque) void;

// Side table: JSGlobalContextRef address → user-supplied *ModuleLoader. Keeps Zig-side loader pointers reachable from the bridge trampolines.
var jsc_module_loader_map: std.AutoHashMap(usize, *const types_mod.ModuleLoader) =
    std.AutoHashMap(usize, *const types_mod.ModuleLoader).init(std.heap.c_allocator);
var jsc_module_loader_mutex: sync.Mutex = .{};

fn jscModuleLoaderGet(ctx: Context) ?*const types_mod.ModuleLoader {
    jsc_module_loader_mutex.lock();
    defer jsc_module_loader_mutex.unlock();
    return jsc_module_loader_map.get(@intFromPtr(ctx));
}

fn jscModuleLoaderPut(ctx: Context, loader: *const types_mod.ModuleLoader) void {
    jsc_module_loader_mutex.lock();
    defer jsc_module_loader_mutex.unlock();
    jsc_module_loader_map.put(@intFromPtr(ctx), loader) catch {};
}

fn jscModuleLoaderRemove(ctx: Context) void {
    jsc_module_loader_mutex.lock();
    defer jsc_module_loader_mutex.unlock();
    _ = jsc_module_loader_map.remove(@intFromPtr(ctx));
}

// Trampoline: ObjC bridge → Zig ModuleLoader.load.
fn jscBridgeLoad(
    user_data: ?*anyopaque,
    canonical_id: [*:0]const u8,
    out_src: *[*]const u8,
    out_len: *usize,
) callconv(.c) bool {
    const loader_ptr = user_data orelse return false;
    const loader: *const types_mod.ModuleLoader = @ptrCast(@alignCast(loader_ptr));
    var out: types_mod.ModuleLoadResult = .{ .source = undefined, .source_len = 0 };
    if (!loader.vtable.load(loader.user_data, canonical_id, &out)) return false;
    out_src.* = out.source;
    out_len.* = out.source_len;
    return true;
}

fn jscBridgeResolve(
    user_data: ?*anyopaque,
    referrer: [*:0]const u8,
    specifier: [*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const loader_ptr = user_data orelse return null;
    const loader: *const types_mod.ModuleLoader = @ptrCast(@alignCast(loader_ptr));
    const resolve = loader.vtable.resolve orelse return null;
    return resolve(loader.user_data, referrer, specifier);
}

fn jscBridgeFreeResolved(
    user_data: ?*anyopaque,
    ptr: [*:0]u8,
) callconv(.c) void {
    const loader_ptr = user_data orelse return;
    const loader: *const types_mod.ModuleLoader = @ptrCast(@alignCast(loader_ptr));
    if (loader.vtable.free_resolved) |fr| fr(loader.user_data, ptr);
}

/// Install the user's module loader for `ctx`. Called from engine.create when `EngineConfig.module_loader != null` under the JSC backend.
pub fn installModuleLoader(ctx: Context, loader: *const types_mod.ModuleLoader) void {
    jscModuleLoaderPut(ctx, loader);
    // Hand the loader pointer (as user_data) + trampolines to the ObjC bridge.
    const user_data: ?*anyopaque = @ptrCast(@constCast(loader));
    jsbay_jsc_install_module_loader(
        @ptrCast(ctx),
        user_data,
        jscBridgeResolve,
        jscBridgeLoad,
        jscBridgeFreeResolved,
    );
}

/// Tear down the loader delegate. Safe to call even if no loader was installed.
pub fn uninstallModuleLoader(ctx: Context) void {
    jsbay_jsc_uninstall_module_loader(@ptrCast(ctx));
    jscModuleLoaderRemove(ctx);
}

// Dupe a malloc'd C string into c_allocator memory, then free the original. Returns null if src is null; the caller owns the returned slice.
fn jscDupeAndFree(src_opt: ?[*:0]u8) ?[]const u8 {
    const src = src_opt orelse return null;
    const slice = std.mem.span(src);
    const owned = std.heap.c_allocator.dupe(u8, slice) catch {
        free(@ptrCast(src));
        return null;
    };
    free(@ptrCast(src));
    return owned;
}

pub fn jscEvalModule(
    ctx: Context,
    source: []const u8,
    filename: []const u8,
) types.EvalResult {
    // A loader is NOT strictly required for evalModule to produce a value (module source with no `import` runs fine), but installing one is the only way `import` statements in the source can resolve. The tests always configure a loader when they exercise imports.
    _ = jscModuleLoaderGet(ctx);

    const fname_z = std.heap.c_allocator.dupeSentinel(u8, filename, 0) catch {
        return .{ .result = null, .err = "Failed to allocate filename", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(fname_z);

    var out_result: ?[*:0]u8 = null;
    var out_error: ?[*:0]u8 = null;
    const ok = jsbay_jsc_eval_module(
        @ptrCast(ctx),
        source.ptr,
        source.len,
        fname_z.ptr,
        &out_result,
        &out_error,
    );

    if (ok == 0) {
        const err = jscDupeAndFree(out_error) orelse "JSC module evaluation failed";
        // The corresponding result (if any) must also be freed to avoid leaks — the ObjC side clears it on error but be defensive.
        if (out_result) |r| free(@ptrCast(r));
        const is_heap = out_error != null;
        return .{ .result = null, .err = err, .err_is_heap = is_heap };
    }

    if (out_error) |e| free(@ptrCast(e));
    const result_opt = jscDupeAndFree(out_result);
    return .{ .result = result_opt, .err = null };
}

pub fn jscImportModule(
    ctx: Context,
    specifier: []const u8,
) types.EvalResult {
    _ = jscModuleLoaderGet(ctx);

    const spec_z = std.heap.c_allocator.dupeSentinel(u8, specifier, 0) catch {
        return .{ .result = null, .err = "Failed to allocate specifier", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(spec_z);

    var out_result: ?[*:0]u8 = null;
    var out_error: ?[*:0]u8 = null;
    const ok = jsbay_jsc_import_module(
        @ptrCast(ctx),
        spec_z.ptr,
        &out_result,
        &out_error,
    );

    if (ok == 0) {
        const err = jscDupeAndFree(out_error) orelse "JSC module import failed";
        if (out_result) |r| free(@ptrCast(r));
        const is_heap = out_error != null;
        return .{ .result = null, .err = err, .err_is_heap = is_heap };
    }

    if (out_error) |e| free(@ptrCast(e));
    const result_opt = jscDupeAndFree(out_result);
    return .{ .result = result_opt, .err = null };
}
