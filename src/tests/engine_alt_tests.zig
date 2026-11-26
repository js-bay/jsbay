//! Tests for packed_alt engine instance creation, evaluation, timers, and allocator discipline.
const std = @import("std");
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const event_loop = @import("js_event_loop");
const instance_map = @import("../runtime/instance_map.zig");
const timers = @import("../runtime/timers.zig");
const helpers = @import("test_helpers.zig");

test "engine: packed_alt EngineInstance create/eval/destroy for primary tag (Linux dispatch proof)" {
    const id = helpers.nextInstanceId();
    const tag = backend.active_backend;
    const backend_dispatch = @import("../backend_dispatch.zig");
    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    errdefer loop.destroy();
    const handles = backend_dispatch.createPacked(tag) orelse return error.CreatePackedFailed;
    errdefer backend_dispatch.destroyPacked(tag, handles);
    backend_dispatch.finishCreate(tag, handles, id, 256 * 1024);
    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch return error.Oom;
    errdefer std.heap.c_allocator.destroy(instance);
    const resources = @import("../runtime/resource_limits.zig").Budget.create(std.heap.c_allocator, .{}) orelse return error.BudgetFailed;
    errdefer resources.deinit();
    const execution_cpu = @import("../runtime/execution_cpu.zig").Ledger.create(std.heap.c_allocator) orelse return error.Oom;
    errdefer execution_cpu.close();
    instance.* = .{
        .allocator = std.heap.c_allocator,
        .resources = resources,
        .execution_cpu = execution_cpu,
        .instance_id = id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
    };
    errdefer instance.deinitSynchronization();
    if (!instance_map.insert(instance)) return error.InsertFailed;
    defer engine.destroy(id);

    try std.testing.expect(!instance_map.getInstance(id).?.isPrimaryBackend());
    try std.testing.expectEqual(tag, instance_map.getInstance(id).?.backendTag());
    const res = engine.evalScript(id, "40+2", "<packed-alt-proof>");
    defer {
        if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
        if (res.err_is_heap) {
            if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }
    try std.testing.expect(res.err == null);
    try std.testing.expectEqualStrings("42", res.result.?);

    const timed = engine.evalScript(
        id,
        "var __packedAltTimer__ = 0; setTimeout(function () { __packedAltTimer__ = 7; }, 0); __packedAltTimer__;",
        "<packed-alt-timer-arm>",
    );
    defer {
        if (timed.result) |s| std.heap.c_allocator.free(@constCast(s));
        if (timed.err_is_heap) {
            if (timed.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }
    try std.testing.expect(timed.err == null);
    try std.testing.expectEqualStrings("0", timed.result.?);
    engine.runEventLoopOnce(id);
    const after = engine.evalScript(id, "__packedAltTimer__", "<packed-alt-timer-check>");
    defer {
        if (after.result) |s| std.heap.c_allocator.free(@constCast(s));
        if (after.err_is_heap) {
            if (after.err) |e| std.heap.c_allocator.free(@constCast(e));
        }
    }
    try std.testing.expect(after.err == null);
    try std.testing.expectEqualStrings("7", after.result.?);
}

test "engine: create with testing.allocator succeeds and frees cleanly" {
    const id = helpers.nextInstanceId();
    try engine.createWithBackend(id, .{ .allocator = std.testing.allocator }, backend.active_backend);
    defer engine.destroy(id);

    const inst = instance_map.getInstance(id) orelse return error.InstanceNotFound;
    try std.testing.expectEqual(std.testing.allocator, inst.allocator);
    const res = engine.evalScript(id, "1 + 1", "<alloc-test>");
    defer helpers.freeEvalResult(res);
    try std.testing.expect(res.err == null);
}

test "engine: create duplicate instance returns InstanceAlreadyExists error" {
    const id = helpers.nextInstanceId();
    try engine.createWithBackend(id, .{}, backend.active_backend);
    defer engine.destroy(id);

    try std.testing.expectError(error.InstanceAlreadyExists, engine.createWithBackend(id, .{}, backend.active_backend));
}
