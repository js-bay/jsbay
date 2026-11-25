const std = @import("std");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");

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
    var original_snapshot: c_api.InstanceSnapshotC = undefined;
    original_snapshot.struct_size = @sizeOf(c_api.InstanceSnapshotC);
    try std.testing.expect(c_api.jsbay_engine_snapshot(id, &original_snapshot));
    c_api.jsbay_engine_destroy_generation(id, original_snapshot.generation);

    var replacement = CreateReplacement{ .id = id };
    const thread = try std.Thread.spawn(.{}, CreateReplacement.run, .{&replacement});
    thread.join();
    try std.testing.expect(replacement.created);
    defer c_api.jsbay_engine_destroy(id);

    var probe = GenerationScopeProbe{};
    try std.testing.expectEqual(
        api_instance_not_found,
        c_api.jsbay_engine_with_generation_scope(id, original_snapshot.generation, GenerationScopeProbe.callback, &probe),
    );
    try std.testing.expect(!probe.called);
}
