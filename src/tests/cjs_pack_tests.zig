//! CommonJS companion tests for exports, memoization, and exception transfer.

const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const types = @import("../types.zig");
const instance_map = @import("../runtime/instance_map.zig");
const cjs = @import("../script/cjs.zig");
const helpers = @import("test_helpers.zig");

const testing = std.testing;

const CjsLoaderCtx = struct {
    modules: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CjsLoaderCtx {
        return .{
            .modules = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinit(self: *CjsLoaderCtx) void {
        self.modules.deinit();
    }
};

fn cjsLoad(user_data: ?*anyopaque, specifier: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
    const ctx: *CjsLoaderCtx = @ptrCast(@alignCast(user_data.?));
    const spec = std.mem.span(specifier);
    if (ctx.modules.get(spec)) |source| {
        out.* = .{ .source = source.ptr, .source_len = source.len };
        return true;
    }
    return false;
}

const cjs_vtable = types.ModuleLoaderVTable{ .load = cjsLoad };

test "cjs: final exports preserve undefined and nested getter exceptions" {
    var context = CjsLoaderCtx.init(testing.allocator);
    defer context.deinit();
    try context.modules.put("explicit-undefined", "globalThis.explicitRuns++; module.exports = undefined;");
    try context.modules.put("deleted-exports", "globalThis.deletedRuns++; delete module.exports;");
    try context.modules.put("getter-object", "globalThis.objectGetterReads++; Object.defineProperty(module, 'exports', { get() { return globalThis.getterObject; } });");
    try context.modules.put("throw-undefined", "globalThis.undefinedRuns++; Object.defineProperty(module, 'exports', { get() { globalThis.undefinedReads++; throw undefined; } });");
    try context.modules.put("b", "globalThis.bRuns++; Object.defineProperty(module, 'exports', { get() { globalThis.bReads++; throw globalThis.nestedMarker; } });");
    try context.modules.put("a",
        \\globalThis.aRuns++;
        \\let identities = 0;
        \\for (let i = 0; i < 2; i++) {
        \\  try { require('b'); }
        \\  catch (e) { if (e === nestedMarker) identities++; }
        \\}
        \\module.exports = identities;
    );
    try context.modules.put("a2", "globalThis.a2Runs++; module.exports = require('b');");
    const loader = types.ModuleLoader{ .vtable = &cjs_vtable, .user_data = &context };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    defer cjs.uninstall(id);

    try helpers.expectEvalEquals(id,
        \\globalThis.explicitRuns = 0;
        \\globalThis.deletedRuns = 0;
        \\globalThis.objectGetterReads = 0;
        \\globalThis.undefinedRuns = 0;
        \\globalThis.undefinedReads = 0;
        \\globalThis.bRuns = 0;
        \\globalThis.bReads = 0;
        \\globalThis.aRuns = 0;
        \\globalThis.a2Runs = 0;
        \\globalThis.getterObject = { marker: 'getter-object' };
        \\globalThis.nestedMarker = { marker: 'nested-error' };
        \\const explicit = require('explicit-undefined');
        \\const deleted = require('deleted-exports');
        \\const getterObject = require('getter-object');
        \\let undefinedCaught = 0;
        \\for (let i = 0; i < 2; i++) {
        \\  try { require('throw-undefined'); }
        \\  catch (e) { if (e === undefined) undefinedCaught++; }
        \\}
        \\const nested = require('a');
        \\let outerIdentities = 0;
        \\for (let i = 0; i < 2; i++) {
        \\  try { require('a2'); }
        \\  catch (e) { if (e === nestedMarker) outerIdentities++; }
        \\}
        \\JSON.stringify([
        \\  explicit === undefined,
        \\  require('explicit-undefined') === undefined,
        \\  deleted === undefined,
        \\  require('deleted-exports') === undefined,
        \\  getterObject === require('getter-object') && getterObject === globalThis.getterObject && getterObject.marker === 'getter-object',
        \\  undefinedCaught,
        \\  nested,
        \\  outerIdentities,
        \\  [explicitRuns, deletedRuns, objectGetterReads, undefinedRuns, undefinedReads, aRuns, a2Runs, bRuns, bReads]
        \\]);
    , "[true,true,true,true,true,2,2,2,[1,1,1,2,2,1,2,4,4]]");
}

test "Hermes CJS exception transfer consumes owned retain of shared handle" {
    if (comptime backend.active_backend != .hermes) return error.SkipZigTest;
    const api = @import("../backend/hermes/c_api.zig");
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = (instance_map.getPtrs(id) orelse return error.InstanceMissing).ctx;
    const value = backend.ActiveEngine.newObject(ctx);
    try testing.expect(value != null);
    const duplicate = backend.ActiveEngine.dupValue(ctx, value);
    var duplicate_owned = true;
    defer if (duplicate_owned) backend.ActiveEngine.freeValue(ctx, duplicate);

    try testing.expect(api.hermes_take_throw_value(ctx, value));
    try testing.expect(backend.ActiveEngine.isObjectVal(ctx, duplicate));

    backend.ActiveEngine.freeValue(ctx, duplicate);
    duplicate_owned = false;
}

test "cjs: clearing instances does not clear memoized compiled bytes" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const loader_impl = struct {
        fn load(_: ?*anyopaque, _: [*:0]const u8, out: *types.ModuleLoadResult) callconv(.c) bool {
            out.* = .{ .source = "module.exports = 123;", .source_len = 21 };
            return true;
        }
    };
    const vtable = types.ModuleLoaderVTable{ .load = loader_impl.load };
    const loader = types.ModuleLoader{ .vtable = &vtable };
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try testing.expect(cjs.install(id, &loader));
    try helpers.evalOk(id, "require('module'); __jsbay_cjsCache('module.exports=1;', () => 0, 'bundle.js');");
    const state = @import("../script/cjs/adapter.zig").getState(id) orelse return error.MissingState;
    try testing.expectEqual(@as(usize, 1), state.registry.entries.count());
    try testing.expectEqual(@as(usize, 1), state.compiled.entries.count());
    @import("../script/cjs/adapter.zig").clearCache(id);
    try testing.expectEqual(@as(usize, 0), state.registry.entries.count());
    try testing.expectEqual(@as(usize, 1), state.compiled.entries.count());
}
