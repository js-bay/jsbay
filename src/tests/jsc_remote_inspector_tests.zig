//! Tests for src/backend/jsc/remote_inspector.zig — JSC WebKit Inspector enable/disable.
//!
//! These tests run only under `-Dbackend=jsc`; the aggregator (all_tests.zig) gates this file behind `backend.active_backend == .jsc`.
//!
//! We cannot drive Safari from a unit test, so coverage focuses on the Zig-side contract: null-instance handling, idempotency, enable/disable round-trips, and clean teardown when the engine is destroyed with inspection still enabled.

const std = @import("std");
const testing = std.testing;

const helpers = @import("test_helpers.zig");
const engine = @import("../engine.zig");
const jri = @import("../backend/jsc/remote_inspector.zig");

// 1. startListener is idempotent.
test "jsc_remote_inspector: startListener is idempotent" {
    try testing.expect(jri.startListener());
    try testing.expect(jri.startListener());
    try testing.expect(jri.startListener());
}

// 2. enable on a live instance returns true.
test "jsc_remote_inspector: enable on live instance returns true" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(jri.startListener());
            try testing.expect(jri.enable(id, "unit-test-target"));
            _ = jri.disable(id);
        }
    }.run);
}

// 3. enable on a bogus instance id returns false without crashing.
test "jsc_remote_inspector: enable on unknown id returns false" {
    try testing.expect(jri.startListener());
    try testing.expect(!jri.enable(999_991, "nope"));
    try testing.expect(!jri.enable(999_991, null));
}

// 4. disable undoes enable; subsequent disable on the same id is a no-op ok.
test "jsc_remote_inspector: disable after enable toggles cleanly" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(jri.startListener());
            try testing.expect(jri.enable(id, "toggle-target"));
            try testing.expect(jri.disable(id));
            // Re-enable and re-disable to prove the toggle isn't one-shot.
            try testing.expect(jri.enable(id, null));
            try testing.expect(jri.disable(id));
            // Disable on a bogus id is also a cheap false, not a crash.
            try testing.expect(!jri.disable(999_992));
        }
    }.run);
}

// 5. enable + destroy engine is clean — the engine teardown path must not trip over a context with remote-inspection still active.
test "jsc_remote_inspector: enable + engine.destroy is clean" {
    const id = helpers.nextInstanceId();
    if (!engine.create(id, .{})) return error.EngineCreateFailed;
    // Intentionally no `disable` before `destroy`. The JSGlobalContext going away is supposed to reclaim the inspector agent on its own; verify we don't hang or assert.
    try testing.expect(jri.startListener());
    try testing.expect(jri.enable(id, "destroy-while-enabled"));
    engine.destroy(id);
}

// 6. startAndEnable is equivalent to startListener + enable (smoke test).
test "jsc_remote_inspector: startAndEnable is a valid one-shot" {
    try helpers.withDefaultEngine(struct {
        fn run(id: i32) !void {
            try testing.expect(jri.startAndEnable(id, "one-shot"));
            try testing.expect(jri.disable(id));
            // Null name path.
            try testing.expect(jri.startAndEnable(id, null));
            try testing.expect(jri.disable(id));
        }
    }.run);
}
