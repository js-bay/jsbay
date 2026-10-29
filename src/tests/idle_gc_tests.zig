//! Idle GC: noteIdle collects only a requested, cooled-down pass, and a queued request does not keep the runtime alive across engine.destroy.

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const rc = @import("../runtime/runtime_control.zig");

test "idle gc: noteIdle does not collect without a request" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expectEqual(@as(u64, 0), rc.idleCollectionCount(id));
            try testing.expect(rc.noteIdle(id));
            try testing.expect(rc.noteIdle(id));
            try testing.expectEqual(@as(u64, 0), rc.idleCollectionCount(id));
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "idle gc: one request collects once then cooldown blocks noteIdle" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(rc.requestIdleGc(id));
            // Queued extras still produce a single collection.
            try testing.expect(rc.requestIdleGc(id));
            try testing.expect(rc.noteIdle(id));
            try testing.expectEqual(@as(u64, 1), rc.idleCollectionCount(id));

            // A new request during the cooldown must not collect.
            try testing.expect(rc.requestIdleGc(id));
            try testing.expect(rc.noteIdle(id));
            try testing.expect(rc.noteIdle(id));
            try testing.expectEqual(@as(u64, 1), rc.idleCollectionCount(id));
            try helpers.expectEvalEquals(id, "1+1", "2");
        }
    }.run);
}

test "idle gc: noteIdle after destroy returns false" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    try testing.expect(rc.requestIdleGc(id));
    engine.destroy(id);
    try testing.expect(!rc.noteIdle(id));
    try testing.expect(!rc.requestIdleGc(id));
}

test "idle gc: a queued idle request does not keep the runtime alive" {
    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    try testing.expect(rc.requestIdleGc(id));
    try testing.expectEqual(@as(u64, 0), rc.idleCollectionCount(id));
    // Destroy while the request is still queued. The slot must not retain the runtime, so the same id can be created again.
    engine.destroy(id);
    try testing.expect(!rc.noteIdle(id));
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    try helpers.expectEvalEquals(id, "1+1", "2");
    try testing.expectEqual(@as(u64, 0), rc.idleCollectionCount(id));
}
