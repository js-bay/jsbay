//! Optional JS-thread sample callback. Interrupt trampolines call `hook` without importing the profiler, so the two sides do not form a cycle.

const std = @import("std");

pub const Hook = *const fn (instance_id: i32) void;
var hook: std.atomic.Value(?Hook) = .init(null);

pub fn load() ?Hook {
    return hook.load(.seq_cst);
}

pub fn store(value: ?Hook) void {
    hook.store(value, .seq_cst);
}

test "sample hook publication is safe to load and clear concurrently" {
    const test_hook: Hook = struct {
        fn call(_: i32) void {}
    }.call;
    store(test_hook);
    try std.testing.expect(load() == test_hook);
    store(null);
    try std.testing.expect(load() == null);
}
