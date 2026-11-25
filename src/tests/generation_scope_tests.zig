const std = @import("std");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const api_value = @import("../abi/api_value.zig");
const instance_map = @import("../runtime/instance_map.zig");
const value_operation = @import("../abi/value_operation.zig");

const api_ok: c_int = 0;
const api_instance_not_found: c_int = 4;

const GenerationScopeProbe = struct {
    called: bool = false,

    fn callback(user_data: ?*anyopaque) callconv(.c) void {
        const self: *GenerationScopeProbe = @ptrCast(@alignCast(user_data.?));
        self.called = true;
    }
};

test "c_api: generation scope and destroy refuse a reused instance id" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    var original_snapshot: c_api.InstanceSnapshotC = undefined;
    original_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &original_snapshot));
    var live_probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        api_ok,
        c_api.jsbay_engine_with_generation_scope(id, original_snapshot.generation, GenerationScopeProbe.callback, &live_probe),
    );
    try std.testing.expect(live_probe.called);

    c_api.jsbay_engine_destroy(id);
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var replacement_snapshot: c_api.InstanceSnapshotC = undefined;
    replacement_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &replacement_snapshot));
    try std.testing.expect(original_snapshot.generation != replacement_snapshot.generation);

    var stale_probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        api_instance_not_found,
        c_api.jsbay_engine_with_generation_scope(id, original_snapshot.generation, GenerationScopeProbe.callback, &stale_probe),
    );
    try std.testing.expect(!stale_probe.called);
    c_api.jsbay_engine_destroy_generation(id, original_snapshot.generation);
    var after_stale_destroy: c_api.InstanceSnapshotC = undefined;
    after_stale_destroy.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &after_stale_destroy));
    try std.testing.expectEqual(replacement_snapshot.generation, after_stale_destroy.generation);
}

test "c_api: stale generation scope rejects a replacement owned by another thread" {
    const CreateReplacement = struct {
        id: i32,
        created: bool = false,

        fn run(self: *@This()) void {
            self.created = c_api.jsbay_engine_create(self.id, null, null);
        }
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var original_snapshot: c_api.InstanceSnapshotC = undefined;
    original_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &original_snapshot));
    c_api.jsbay_engine_destroy_generation(id, original_snapshot.generation);

    var replacement = CreateReplacement{ .id = id };
    const thread = try std.Thread.spawn(.{}, CreateReplacement.run, .{&replacement});
    thread.join();
    try std.testing.expect(replacement.created);

    var probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        api_instance_not_found,
        c_api.jsbay_engine_with_generation_scope(id, original_snapshot.generation, GenerationScopeProbe.callback, &probe),
    );
    try std.testing.expect(!probe.called);
}

test "c_api: generation scope reports teardown when owner admission races teardown" {
    const TeardownAtOwnerCheck = struct {
        id: i32,
        generation: u64,
        called: bool = false,
        marked: bool = false,

        fn run(user_data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.called = true;
            self.marked = instance_map.markTeardownPendingForGeneration(self.id, self.generation);
            if (self.marked) api_value.dropInstance(self.id);
        }
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var snapshot: c_api.InstanceSnapshotC = undefined;
    snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &snapshot));

    var race = TeardownAtOwnerCheck{ .id = id, .generation = snapshot.generation };
    value_operation.setBeforeOwnerCheckHookForTesting(TeardownAtOwnerCheck.run, &race);
    defer value_operation.setBeforeOwnerCheckHookForTesting(null, null);
    var probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        api_instance_not_found,
        c_api.jsbay_engine_with_generation_scope(id, snapshot.generation, GenerationScopeProbe.callback, &probe),
    );
    try std.testing.expect(race.called);
    try std.testing.expect(race.marked);
    try std.testing.expect(!probe.called);
}

test "c_api: stale mono generation is rejected before backend entry" {
    const ReplaceAtOwnerCheck = struct {
        id: i32,
        generation: u64,
        called: bool = false,
        replacement_created: bool = false,

        fn run(user_data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.called = true;
            c_api.jsbay_engine_destroy_generation(self.id, self.generation);
            self.replacement_created = c_api.jsbay_engine_create(self.id, null, null);
        }
    };
    const BackendEntryProbe = struct {
        called: bool = false,

        fn run(user_data: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(user_data.?));
            self.called = true;
        }
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var original_snapshot: c_api.InstanceSnapshotC = undefined;
    original_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &original_snapshot));
    var replacement = ReplaceAtOwnerCheck{ .id = id, .generation = original_snapshot.generation };
    var backend_entry = BackendEntryProbe{};
    value_operation.setBeforeOwnerCheckHookForTesting(ReplaceAtOwnerCheck.run, &replacement);
    defer value_operation.setBeforeOwnerCheckHookForTesting(null, null);
    value_operation.setBeforeBackendEnterHookForTesting(BackendEntryProbe.run, &backend_entry);
    defer value_operation.setBeforeBackendEnterHookForTesting(null, null);

    var callback_probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        api_instance_not_found,
        c_api.jsbay_engine_with_generation_scope(id, original_snapshot.generation, GenerationScopeProbe.callback, &callback_probe),
    );
    try std.testing.expect(replacement.called);
    try std.testing.expect(replacement.replacement_created);
    try std.testing.expect(!backend_entry.called);
    try std.testing.expect(!callback_probe.called);
}

test "c_api: generation scope preserves wrong-thread status for the live generation" {
    const WrongThreadCall = struct {
        id: i32,
        generation: u64,
        status: c_int = -1,

        fn run(self: *@This()) void {
            var probe = GenerationScopeProbe{};
            self.status = c_api.jsbay_engine_with_generation_scope(
                self.id,
                self.generation,
                GenerationScopeProbe.callback,
                &probe,
            );
        }
    };
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    var snapshot: c_api.InstanceSnapshotC = undefined;
    snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &snapshot));

    var call = WrongThreadCall{ .id = id, .generation = snapshot.generation };
    const thread = try std.Thread.spawn(.{}, WrongThreadCall.run, .{&call});
    thread.join();
    try std.testing.expectEqual(@as(c_int, 3), call.status);
}
