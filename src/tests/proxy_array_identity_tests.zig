//! Public value_type classifies only native arrays. Proxies remain objects so classification cannot resolve a revoked Proxy or observe its target.

const testing = @import("std").testing;
const c_api = @import("../c_api.zig");

const api_ok: c_int = 0;
const kind_object: c_int = 5;
const kind_array: c_int = 6;

fn evalValue(id: i32, source: []const u8) !u64 {
    var value: u64 = 0;
    var exception: u64 = 0;
    try testing.expectEqual(api_ok, c_api.jsbay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = "proxy-array.js", .len = 14 }, null, &value, &exception));
    errdefer {
        if (value != 0) _ = c_api.jsbay_value_release(value);
        if (exception != 0) _ = c_api.jsbay_value_release(exception);
    }
    try testing.expectEqual(@as(u64, 0), exception);
    return value;
}

fn expectKind(id: i32, source: []const u8, expected: c_int) !void {
    const value = try evalValue(id, source);
    defer _ = c_api.jsbay_value_release(value);
    var actual: c_int = -1;
    try testing.expectEqual(api_ok, c_api.jsbay_value_type(value, &actual));
    try testing.expectEqual(expected, actual);
}

test "value_type keeps array proxies and revoked proxies as objects" {
    const id = @import("test_helpers.zig").nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    try expectKind(id, "[]", kind_array);
    try expectKind(id, "new Proxy([], {})", kind_object);
    try expectKind(id, "(()=>{const pair=Proxy.revocable([], {});pair.revoke();return pair.proxy})()", kind_object);

    const is_array = try evalValue(id, "Array.isArray(new Proxy([], {}))");
    defer _ = c_api.jsbay_value_release(is_array);
    var result = false;
    try testing.expectEqual(api_ok, c_api.jsbay_value_to_bool(is_array, &result));
    try testing.expect(result);

    const recovery = try evalValue(id, "40 + 2");
    defer _ = c_api.jsbay_value_release(recovery);
    var number: f64 = 0;
    try testing.expectEqual(api_ok, c_api.jsbay_value_to_number(recovery, &number));
    try testing.expectEqual(@as(f64, 42), number);
}
