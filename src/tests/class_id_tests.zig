//! QuickJS class ids live in process-wide cells but are handed out per runtime on quickjs-ng. A cell must keep one id everywhere, or two classes collide in a runtime that registers both.

const helpers = @import("native_handle_test_helpers.zig");

const c = helpers.c;
const c_api = helpers.c_api;
const testing = helpers.testing;

fn classDef(name: [*:0]const u8) c.JSClassDef {
    return .{ .class_name = name, .finalizer = null, .gc_mark = null, .call = null, .exotic = null };
}

test "class ids stay distinct when two runtimes first use different classes" {
    const rt_a = c.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer c.JS_FreeRuntime(rt_a);
    const rt_b = c.JS_NewRuntime() orelse return error.RuntimeCreationFailed;
    defer c.JS_FreeRuntime(rt_b);

    var first: c.JSClassID = 0;
    var second: c.JSClassID = 0;
    _ = c_api.JS_NewClassID(rt_a, &first);
    _ = c_api.JS_NewClassID(rt_b, &second);
    try testing.expect(first != 0 and second != 0);
    try testing.expect(first != second);

    // Both classes must register in a runtime that uses the pair.
    var def_first = classDef("JsBayClassIdTestFirst");
    var def_second = classDef("JsBayClassIdTestSecond");
    try testing.expectEqual(@as(c_int, 0), c.JS_NewClass(rt_a, first, &def_first));
    _ = c_api.JS_NewClassID(rt_a, &second);
    try testing.expectEqual(@as(c_int, 0), c.JS_NewClass(rt_a, second, &def_second));
}
