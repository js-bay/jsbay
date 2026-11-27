const std = @import("std");
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");
const generation_scope = @import("../abi/generation_scope.zig");
const instance_map = @import("../runtime/instance_map.zig");
const helpers = @import("test_helpers.zig");

const FailedLoopHost = struct {
    fn schedule(_: ?*anyopaque, _: u64, _: *const fn (?*anyopaque) callconv(.c) void, _: ?*anyopaque) callconv(.c) bool {
        return false;
    }

    fn cancel(_: ?*anyopaque) callconv(.c) void {}
};

const GenerationScopeProbe = struct {
    called: bool = false,

    fn callback(user_data: ?*anyopaque) callconv(.c) void {
        const self: *GenerationScopeProbe = @ptrCast(@alignCast(user_data.?));
        self.called = true;
    }
};

fn checkGenerationScopeAfterLoopFailure(tag: backend.BackendType, use_primary: bool) !void {
    const id = helpers.nextInstanceId();
    if (use_primary) {
        try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    } else {
        var options = c_api.EngineCreateOptionsC{
            .struct_size = @sizeOf(c_api.EngineCreateOptionsC),
            .backend = backend.backendToC(tag),
        };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
    }
    defer engine.destroy(id);

    try std.testing.expectError(error.ScheduleFailed, engine.attachLoop(id, .{
        .context = null,
        .schedule = FailedLoopHost.schedule,
        .cancel = FailedLoopHost.cancel,
    }));
    try std.testing.expectEqual(@as(c_int, 8), c_api.jsbay_engine_loop_status(id));

    const generation = instance_map.generationOf(id) orelse return error.MissingGeneration;
    var probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        @as(c_int, 0),
        c_api.jsbay_engine_with_generation_scope(id, generation, GenerationScopeProbe.callback, &probe),
    );
    try std.testing.expect(probe.called);
}

test "generation scope remains available after loop failure for mono and packed backends" {
    try checkGenerationScopeAfterLoopFailure(backend.active_backend, true);
    const candidates = [_]backend.BackendType{ .quickjs_ng, .quickjs, .jsc, .escargot, .hermes };
    for (candidates) |tag| {
        if (tag == backend.active_backend or !backend.isPacked(tag)) continue;
        try checkGenerationScopeAfterLoopFailure(tag, false);
    }
}

const PackedGenerationReplacement = struct {
    id: i32,
    old_generation: u64,
    tag: backend.BackendType,
    created: bool = false,
    new_generation: u64 = 0,

    fn replace(user_data: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(user_data.?));
        engine.destroyGeneration(self.id, self.old_generation);
        var options = c_api.EngineCreateOptionsC{
            .struct_size = @sizeOf(c_api.EngineCreateOptionsC),
            .backend = backend.backendToC(self.tag),
        };
        self.created = c_api.jsbay_engine_create_with_options(self.id, &options);
        if (self.created) self.new_generation = instance_map.generationOf(self.id) orelse 0;
    }
};

test "packed generation scope rejects replacement before entering the old context" {
    const candidates = [_]backend.BackendType{ .quickjs_ng, .quickjs, .jsc, .escargot, .hermes };
    for (candidates) |tag| {
        if (tag == backend.active_backend or !backend.isPacked(tag)) continue;
        const id = helpers.nextInstanceId();
        var options = c_api.EngineCreateOptionsC{
            .struct_size = @sizeOf(c_api.EngineCreateOptionsC),
            .backend = backend.backendToC(tag),
        };
        try std.testing.expect(c_api.jsbay_engine_create_with_options(id, &options));
        const old_generation = instance_map.generationOf(id) orelse return error.MissingGeneration;
        var replacement = PackedGenerationReplacement{
            .id = id,
            .old_generation = old_generation,
            .tag = tag,
        };
        generation_scope.setBeforePackedAdmissionHookForTesting(PackedGenerationReplacement.replace, &replacement);
        defer generation_scope.setBeforePackedAdmissionHookForTesting(null, null);
        var probe = GenerationScopeProbe{};
        try std.testing.expectEqual(
            @as(c_int, 4),
            c_api.jsbay_engine_with_generation_scope(id, old_generation, GenerationScopeProbe.callback, &probe),
        );
        try std.testing.expect(replacement.created);
        try std.testing.expect(replacement.new_generation != old_generation);
        try std.testing.expect(!probe.called);
        try std.testing.expectEqual(replacement.new_generation, instance_map.generationOf(id).?);
        engine.destroy(id);
    }
}
