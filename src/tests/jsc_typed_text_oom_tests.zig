//! JSC typed text conversion must fail before a failed UTF-16 allocation can turn a requested key into the empty string.

const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const engine = @import("../engine.zig");

const api_ok: c_int = 0;
const api_out_of_memory: c_int = 6;

test "JSC typed text conversion OOM does not read or write the empty key" {
    if (comptime !backend.isJscApiBackend(backend.active_backend)) return error.SkipZigTest;
    const common = @import("../backend/jsc/common.zig");
    const id = @import("test_helpers.zig").nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);
    {
        const ctx = engine.getContext(id) orelse return error.MissingContext;
        common.failNextTypedStringForTesting();
        try testing.expect(backend.ActiveEngine.newStringVal(ctx, "x") == null);

        var object: u64 = 0;
        var marker: u64 = 0;
        var value: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(api_ok, c_api.jsbay_value_new_object(id, &object));
        defer _ = c_api.jsbay_value_release(object);
        try testing.expectEqual(api_ok, c_api.jsbay_value_new_number(id, 7, &marker));
        defer _ = c_api.jsbay_value_release(marker);
        try testing.expectEqual(api_ok, c_api.jsbay_value_set(object, .{ .data = "", .len = 0 }, marker, &exception));

        common.failNextTypedStringForTesting();
        try testing.expect(common.jsStringFromSlice("x") == null);

        common.failNextTypedStringForTesting();
        try testing.expectEqual(api_out_of_memory, c_api.jsbay_value_get(object, .{ .data = "x", .len = 1 }, &value, &exception));
        try testing.expectEqual(@as(u64, 0), value);
        try testing.expectEqual(@as(u64, 0), exception);

        {
            try testing.expectEqual(api_ok, c_api.jsbay_value_get(object, .{ .data = "", .len = 0 }, &value, &exception));
            defer _ = c_api.jsbay_value_release(value);
            var number: f64 = 0;
            try testing.expectEqual(api_ok, c_api.jsbay_value_to_number(value, &number));
            try testing.expectEqual(@as(f64, 7), number);
        }
        value = 0;

        common.failNextTypedStringForTesting();
        try testing.expectEqual(api_out_of_memory, c_api.jsbay_value_set(object, .{ .data = "x", .len = 1 }, marker, &exception));
        try testing.expectEqual(@as(u64, 0), exception);

        {
            try testing.expectEqual(api_ok, c_api.jsbay_value_get(object, .{ .data = "", .len = 0 }, &value, &exception));
            defer _ = c_api.jsbay_value_release(value);
            var number: f64 = 0;
            try testing.expectEqual(api_ok, c_api.jsbay_value_to_number(value, &number));
            try testing.expectEqual(@as(f64, 7), number);
        }
        value = 0;

        common.failNextTypedStringForTesting();
        try testing.expectEqual(api_out_of_memory, c_api.jsbay_value_new_json(id, .{ .data = "{}", .len = 2 }, &value, &exception));
        try testing.expectEqual(@as(u64, 0), value);
        try testing.expectEqual(@as(u64, 0), exception);

        common.failNextTypedStringForTesting();
        try testing.expectEqual(api_out_of_memory, c_api.jsbay_value_new_error(id, .{ .data = "x", .len = 1 }, &value));
        try testing.expectEqual(@as(u64, 0), value);

        common.failNextTypedStringForTesting();
        try testing.expectEqual(api_out_of_memory, c_api.jsbay_value_new_string(id, .{ .data = "x", .len = 1 }, &value));
        try testing.expectEqual(@as(u64, 0), value);

        try testing.expectEqual(api_ok, c_api.jsbay_value_new_string(id, .{ .data = "", .len = 0 }, &value));
        try testing.expect(value != 0);
        try testing.expectEqual(api_ok, c_api.jsbay_value_release(value));
        value = 0;

        const empty = common.jsStringFromSlice("") orelse return error.MissingEmptyString;
        defer common.jsc.JSStringRelease(empty);
    }
}
