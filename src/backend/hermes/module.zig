//! Hermes ES module loader — host-side ESM→CJS shim via C bridge (see hermes_esm.cpp).
//! Hermes pin disables native module codegen; this mirrors Escargot's ModuleLoaderVTable surface.

const std = @import("std");
const types = @import("../../types.zig");

const Context = ?*anyopaque;

const HermesEvalResult = extern struct {
    result: ?[*:0]u8,
    err: ?[*:0]u8,
};

extern fn hermes_install_module_loader(
    ctx: ?*anyopaque,
    user_data: ?*anyopaque,
    resolve: ?*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?[*:0]u8,
    load: ?*const fn (?*anyopaque, [*:0]const u8, *[*]const u8, *usize) callconv(.c) bool,
    free_resolved: ?*const fn (?*anyopaque, ?[*:0]u8) callconv(.c) void,
) void;

extern fn hermes_uninstall_module_loader(ctx: ?*anyopaque) void;
extern fn hermes_eval_module(ctx: ?*anyopaque, src: [*]const u8, src_len: usize, filename: [*]const u8, filename_len: usize) HermesEvalResult;
extern fn hermes_import_module(ctx: ?*anyopaque, specifier: [*:0]const u8) HermesEvalResult;
extern fn free(ptr: ?*anyopaque) void;

fn bridgeResolve(
    ud: ?*anyopaque,
    referrer: [*:0]const u8,
    specifier: [*:0]const u8,
) callconv(.c) ?[*:0]u8 {
    const loader: *const types.ModuleLoader = @ptrCast(@alignCast(ud orelse return null));
    const resolve = loader.vtable.resolve orelse return null;
    return resolve(loader.user_data, referrer, specifier);
}

fn bridgeLoad(
    ud: ?*anyopaque,
    canonical_id: [*:0]const u8,
    out_src: *[*]const u8,
    out_len: *usize,
) callconv(.c) bool {
    const loader: *const types.ModuleLoader = @ptrCast(@alignCast(ud orelse return false));
    var result: types.ModuleLoadResult = .{ .source = undefined, .source_len = 0 };
    if (!loader.vtable.load(loader.user_data, canonical_id, &result)) return false;
    out_src.* = result.source;
    out_len.* = result.source_len;
    return true;
}

fn bridgeFreeResolved(ud: ?*anyopaque, ptr: ?[*:0]u8) callconv(.c) void {
    const p = ptr orelse return;
    const loader: *const types.ModuleLoader = @ptrCast(@alignCast(ud orelse return));
    if (loader.vtable.free_resolved) |fr| fr(loader.user_data, p);
}

pub fn installModuleLoader(ctx: Context, loader: *const types.ModuleLoader) void {
    hermes_install_module_loader(
        ctx,
        @ptrCast(@constCast(loader)),
        bridgeResolve,
        bridgeLoad,
        bridgeFreeResolved,
    );
}

pub fn uninstallModuleLoader(ctx: Context) void {
    hermes_uninstall_module_loader(ctx);
}

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

pub fn hermesEvalModule(ctx: Context, source: []const u8, filename: []const u8) types.EvalResult {
    const r = hermes_eval_module(ctx, source.ptr, source.len, filename.ptr, filename.len);
    if (r.err != null) {
        const err = dupeAndFree(r.err) orelse "module evaluation failed";
        if (r.result) |p| free(@ptrCast(p));
        return .{ .result = null, .err = err, .err_is_heap = true };
    }
    return .{ .result = dupeAndFree(r.result), .err = null };
}

pub fn hermesImportModule(ctx: Context, specifier: []const u8) types.EvalResult {
    const spec_z = std.heap.c_allocator.dupeSentinel(u8, specifier, 0) catch {
        return .{ .result = null, .err = "Failed to allocate specifier", .err_is_heap = false };
    };
    defer std.heap.c_allocator.free(spec_z);
    const r = hermes_import_module(ctx, spec_z.ptr);
    if (r.err != null) {
        const err = dupeAndFree(r.err) orelse "module import failed";
        if (r.result) |p| free(@ptrCast(p));
        return .{ .result = null, .err = err, .err_is_heap = true };
    }
    return .{ .result = dupeAndFree(r.result), .err = null };
}
