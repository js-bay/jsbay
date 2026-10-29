//! Contract: callback-borrowed handles may be upgraded with retain; release on borrowed fails.
const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");

const Probe = struct {
    retain_status: c_int = -1,
    release_status: c_int = -1,
    saw_nonzero_arg: bool = false,

    fn callback(_: i32, data: ?*anyopaque, _: u64, argc: usize, args: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
        out_value.* = 0;
        out_exception.* = 0;
        const self: *Probe = @ptrCast(@alignCast(data.?));
        if (argc == 0 or args == null) return 2;
        const borrowed = args.?[0];
        self.saw_nonzero_arg = borrowed != 0;
        var owned: u64 = 0;
        self.retain_status = c_api.jsbay_value_retain(borrowed, &owned);
        // Releasing the borrowed handle itself must not succeed (VM still owns it).
        self.release_status = c_api.jsbay_value_release(borrowed);
        if (self.retain_status != 0 or owned == 0) return 6;
        // Transfer the owned duplicate as the callback result; engine consumes it.
        out_value.* = owned;
        return 0;
    }
};

test "c_api: retain upgrades a callback-borrowed arg; release on borrowed fails" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var probe = Probe{};
    var function: u64 = 0;
    var exception: u64 = 0;
    const name = "retainBorrowed";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_bind(
        id,
        .{ .data = name.ptr, .len = name.len },
        Probe.callback,
        &probe,
        null,
        &function,
        &exception,
    ));
    defer _ = c_api.jsbay_value_release(function);

    var value: u64 = 0;
    var ex: u64 = 0;
    const source = "retainBorrowed(123)";
    try testing.expectEqual(@as(c_int, 0), c_api.jsbay_engine_evaluate(
        id,
        .{ .data = source.ptr, .len = source.len },
        .{ .data = "borrowed-retain.js", .len = 18 },
        null,
        &value,
        &ex,
    ));
    defer if (value != 0) {
        _ = c_api.jsbay_value_release(value);
    };
    defer if (ex != 0) {
        _ = c_api.jsbay_value_release(ex);
    };

    try testing.expect(probe.saw_nonzero_arg);
    try testing.expectEqual(@as(c_int, 0), probe.retain_status);
    try testing.expect(probe.release_status != 0);
}
