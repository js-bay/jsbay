const std = @import("std");
const common = @import("common.zig");
const value = @import("value.zig");
const jsc = common.jsc;

test "JSC context intrinsics remain usable when BigInt is absent" {
    const testing = std.testing;
    if (!@import("polling_config.zig").prepareBeforeVm()) return error.RuntimeCreationFailed;
    const group = jsc.JSContextGroupCreate() orelse return error.OutOfMemory;
    defer jsc.JSContextGroupRelease(group);
    const ctx = jsc.JSGlobalContextCreateInGroup(group, null) orelse return error.OutOfMemory;
    defer jsc.JSGlobalContextRelease(ctx);
    const remove = common.jsStringFromSlice("delete globalThis.BigInt") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(remove);
    var exception: jsc.JSValueRef = null;
    _ = jsc.JSEvaluateScript(ctx, remove, null, null, 1, &exception);
    try testing.expect(exception == null);
    try testing.expect(value.captureFunctionApply(ctx));
    defer value.releaseFunctionApply(ctx);
    const ordinary = common.jsStringFromSlice("40 + 2") orelse return error.OutOfMemory;
    defer jsc.JSStringRelease(ordinary);
    exception = null;
    const result = jsc.JSEvaluateScript(ctx, ordinary, null, null, 1, &exception);
    try testing.expect(exception == null and result != null);
    try testing.expectEqual(@as(f64, 42), jsc.JSValueToNumber(ctx, result, &exception));
}
