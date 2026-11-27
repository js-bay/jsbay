//! Tests for C API capabilities queries and OOM / thread-reuse error paths.
const std = @import("std");
const testing = std.testing;

const c_api = @import("../c_api.zig");
const backend = @import("../backend.zig");
const helpers = @import("test_helpers.zig");
const instance_map = @import("../runtime/instance_map.zig");
const engine_thread_mod = @import("../runtime/engine_thread.zig");
const build_options = @import("build_options");

test "c_api: instance capabilities follow the selected packed backend" {
    const F = c_api.CapabilityFlags;
    var too_small = c_api.EngineCapabilitiesC{ .struct_size = 0 };
    try testing.expect(!c_api.jsbay_engine_capabilities(helpers.nextInstanceId(), null));
    try testing.expect(!c_api.jsbay_engine_capabilities(helpers.nextInstanceId(), &too_small));
    var missing_caps = c_api.EngineCapabilitiesC{ .struct_size = @sizeOf(c_api.EngineCapabilitiesC) };
    try testing.expect(!c_api.jsbay_engine_capabilities(helpers.nextInstanceId(), &missing_caps));

    const partial_id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(partial_id, null, null));
    defer c_api.jsbay_engine_destroy(partial_id);
    var partial_storage: [@sizeOf(c_api.EngineCapabilitiesC)]u8 align(@alignOf(c_api.EngineCapabilitiesC)) = @splat(0xa5);
    const partial: *c_api.EngineCapabilitiesC = @ptrCast(&partial_storage);
    partial.struct_size = @sizeOf(u32);
    try testing.expect(c_api.jsbay_engine_capabilities(partial_id, partial));
    try testing.expectEqual(@as(u32, @sizeOf(u32)), partial.struct_size);
    const untouched: [@sizeOf(c_api.EngineCapabilitiesC) - @sizeOf(u32)]u8 = @splat(0xa5);
    try testing.expectEqualSlices(u8, &untouched, partial_storage[@sizeOf(u32)..]);

    const closing_id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(closing_id, null, null));
    defer c_api.jsbay_engine_destroy(closing_id);
    instance_map.markTeardownPending(closing_id);
    var closing_caps = c_api.EngineCapabilitiesC{ .struct_size = @sizeOf(c_api.EngineCapabilitiesC) };
    try testing.expect(!c_api.jsbay_engine_capabilities(closing_id, &closing_caps));

    var available: [8]c_api.BackendC = undefined;
    const count = c_api.jsbay_available_backends(&available, available.len);
    try testing.expect(count > 0);
    for (available[0..count]) |tag| {
        const selected = backend.backendFromC(@backingInt(tag)) orelse return error.InvalidBackendTag;
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{
            .struct_size = @sizeOf(c_api.EngineCreateOptionsC),
            .backend = tag,
        };
        try testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        var caps = c_api.EngineCapabilitiesC{ .struct_size = @sizeOf(c_api.EngineCapabilitiesC) };
        try testing.expect(c_api.jsbay_engine_capabilities(id, &caps));
        try testing.expectEqual(tag, caps.backend);

        var foreign_caps = c_api.EngineCapabilitiesC{ .struct_size = @sizeOf(c_api.EngineCapabilitiesC) };
        var foreign_success = false;
        const Query = struct {
            fn run(instance_id: i32, result: *c_api.EngineCapabilitiesC, success: *bool) void {
                success.* = c_api.jsbay_engine_capabilities(instance_id, result);
            }
        };
        const worker = try std.Thread.spawn(.{}, Query.run, .{ id, &foreign_caps, &foreign_success });
        worker.join();
        try testing.expect(foreign_success);
        try testing.expectEqual(tag, foreign_caps.backend);
        try testing.expectEqual(caps.flags, foreign_caps.flags);

        const primary = selected == backend.active_backend;
        const quickjs = backend.isQuickJsApiBackend(selected);
        const interrupt = !backend.isSpikeBackend(selected);
        try testing.expectEqual(quickjs, (caps.flags & F.heap_stack_limit) != 0);
        try testing.expectEqual(quickjs, (caps.flags & F.heap_usage_snapshot) != 0);
        try testing.expectEqual(interrupt, (caps.flags & F.interrupt_deadline) != 0);
        try testing.expectEqual(primary and quickjs, (caps.flags & F.explicit_bytecode) != 0);
        try testing.expectEqual(primary and quickjs and build_options.bytecode_cache, (caps.flags & F.persistent_bytecode_cache) != 0);
        try testing.expectEqual(primary and (backend.supportsDebugger(selected) or backend.isHermesBackend(selected)) and build_options.inspector, (caps.flags & F.cdp_source_debugger) != 0);
        try testing.expectEqual(primary and selected == .jsc, (caps.flags & F.safari_web_inspector) != 0);

        const memory_limit_supported = c_api.jsbay_engine_set_memory_limit(id, 1024);
        try testing.expectEqual(quickjs, memory_limit_supported);
        if (memory_limit_supported) try testing.expect(c_api.jsbay_engine_set_memory_limit(id, 0));
        const interrupt_supported = c_api.jsbay_engine_request_interrupt(id);
        try testing.expectEqual(interrupt, interrupt_supported);
        if (interrupt_supported) try testing.expect(c_api.jsbay_engine_clear_interrupt(id));

        c_api.jsbay_engine_destroy(id);
        try testing.expect(!c_api.jsbay_engine_capabilities(id, &caps));
    }
}

test "c_api: value API reports out of memory when engine thread state allocation fails" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    engine_thread_mod.failNextStateAllocationForTesting();
    var output: u64 = 99;
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_value_new_number(id, 42, &output));
    try testing.expectEqual(@as(u64, 0), output);
}

test "c_api: evaluate reports out of memory when engine thread state allocation fails" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    engine_thread_mod.failNextStateAllocationForTesting();
    var value: u64 = 99;
    var exception: u64 = 99;
    try testing.expectEqual(@as(c_int, 6), c_api.jsbay_engine_evaluate(id, .{ .data = "42", .len = 2 }, .{ .data = "allocation.js", .len = 13 }, null, &value, &exception));
    try testing.expectEqual(@as(u64, 0), value);
    try testing.expectEqual(@as(u64, 0), exception);
}

test "c_api: packed value reports out of memory when engine thread state allocation fails" {
    if (!backend.multi_pack) return error.SkipZigTest;
    var available: [8]c_api.BackendC = undefined;
    const count = c_api.jsbay_available_backends(&available, available.len);
    for (available[0..count]) |tag| {
        if (backend.backendFromC(@backingInt(tag)) == backend.active_backend) continue;
        const id = helpers.nextInstanceId();
        const options = c_api.EngineCreateOptionsC{ .struct_size = @sizeOf(c_api.EngineCreateOptionsC), .backend = tag };
        try testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        defer c_api.jsbay_engine_destroy(id);

        engine_thread_mod.failNextStateAllocationForTesting();
        var output: u64 = 99;
        try testing.expectEqual(@as(c_int, 6), c_api.jsbay_value_new_number(id, 42, &output));
        try testing.expectEqual(@as(u64, 0), output);
    }
}

const EscargotCreateDestroyProbe = struct {
    instance_id: i32,
    success: std.atomic.Value(bool) = .init(true),

    fn run(self: *@This()) void {
        for (0..24) |_| {
            if (!c_api.jsbay_engine_create(self.instance_id, null, null)) {
                self.success.store(false, .seq_cst);
                return;
            }
            c_api.jsbay_engine_destroy(self.instance_id);
        }
    }
};

test "c_api: Escargot reuses thread state across repeated engine lifetimes" {
    if (comptime backend.active_backend != .escargot) return error.SkipZigTest;

    var probe = EscargotCreateDestroyProbe{ .instance_id = helpers.nextInstanceId() };
    const worker = try std.Thread.spawn(.{}, EscargotCreateDestroyProbe.run, .{&probe});
    worker.join();
    try testing.expect(probe.success.load(.seq_cst));
}
