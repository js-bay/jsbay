//! C++ eval bridge failures must be converted to result states before crossing into Zig.

const std = @import("std");
const testing = std.testing;
const backend = @import("../backend.zig");
const engine = @import("../engine.zig");
const instance_map = @import("../runtime/instance_map.zig");
const helpers = @import("test_helpers.zig");

const EvalFaultProbe = extern struct {
    escaped_exception: c_int,
    status: c_int,
    has_result: c_int,
};

extern "c" fn escargot_test_probe_eval_fault(
    ctx: ?*anyopaque,
    discard_result: c_int,
    fault: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
) EvalFaultProbe;
extern "c" fn escargot_test_arm_eval_fault(fault: c_int) void;

const EvalApi = enum { normal, discarding };
const EvalFault = enum(c_int) { parser_oom = 1, error_text_allocation = 2, native_exception = 3, native_error_conversion_oom = 4 };
const EvalStatus = enum(c_int) { success = 0, javascript_error = 1, out_of_memory = 2, native_error = 3 };

fn expectFailureWithoutEscaping(api: EvalApi, fault: EvalFault, source: []const u8) !void {
    if (comptime backend.active_backend != .escargot) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = (instance_map.getPtrs(id) orelse return error.InstanceMissing).ctx;
    const discard_result: c_int = if (api == .discarding) 1 else 0;
    const probe = escargot_test_probe_eval_fault(
        ctx,
        discard_result,
        @backingInt(fault),
        source.ptr,
        source.len,
        "eval-fault.js",
        "eval-fault.js".len,
    );
    try testing.expectEqual(@as(c_int, 0), probe.escaped_exception);
    const expected_status: EvalStatus = switch (fault) {
        .parser_oom, .error_text_allocation => .out_of_memory,
        .native_exception => .native_error,
        .native_error_conversion_oom => unreachable,
    };
    try testing.expectEqual(@backingInt(expected_status), probe.status);
    try testing.expectEqual(@as(c_int, 0), probe.has_result);

    escargot_test_arm_eval_fault(@backingInt(fault));
    const mapped = switch (api) {
        .normal => @import("../backend/escargot/lifecycle.zig").eval(ctx, source, "eval-fault.js"),
        .discarding => @import("../backend/escargot/lifecycle.zig").evalDiscardingResult(ctx, source, "eval-fault.js"),
    };
    defer if (mapped.err_is_heap) {
        if (mapped.err) |message| std.heap.c_allocator.free(@constCast(message));
    };
    try testing.expect(mapped.result == null);
    try testing.expect(mapped.err != null);
    try testing.expectEqual(expected_status != .out_of_memory, mapped.err_is_heap);
    const expected_message = if (expected_status == .out_of_memory)
        "Out of memory"
    else
        "injected native evaluation failure";
    try testing.expectEqualStrings(expected_message, mapped.err.?);
}

fn expectNativeErrorConversionDoesNotEscape(api: EvalApi) !void {
    if (comptime backend.active_backend != .escargot) return error.SkipZigTest;

    const id = helpers.nextInstanceId();
    try testing.expect(engine.create(id, .{}));
    defer engine.destroy(id);
    const ctx = (instance_map.getPtrs(id) orelse return error.InstanceMissing).ctx;
    const discard_result: c_int = if (api == .discarding) 1 else 0;
    const probe = escargot_test_probe_eval_fault(
        ctx,
        discard_result,
        @backingInt(EvalFault.native_error_conversion_oom),
        "1 + 1",
        "1 + 1".len,
        "eval-fault.js",
        "eval-fault.js".len,
    );
    try testing.expectEqual(@as(c_int, 0), probe.escaped_exception);
    try testing.expectEqual(@as(c_int, @backingInt(EvalStatus.out_of_memory)), probe.status);
    try testing.expectEqual(@as(c_int, 0), probe.has_result);

    escargot_test_arm_eval_fault(@backingInt(EvalFault.native_error_conversion_oom));
    const mapped = switch (api) {
        .normal => @import("../backend/escargot/lifecycle.zig").eval(ctx, "1 + 1", "eval-fault.js"),
        .discarding => @import("../backend/escargot/lifecycle.zig").evalDiscardingResult(ctx, "1 + 1", "eval-fault.js"),
    };
    defer if (mapped.err_is_heap) {
        if (mapped.err) |message| std.heap.c_allocator.free(@constCast(message));
    };
    try testing.expect(mapped.result == null);
    try testing.expectEqualStrings("Out of memory", mapped.err.?);
    try testing.expect(!mapped.err_is_heap);
}

test "Escargot eval boundary catches parser allocation failure" {
    try expectFailureWithoutEscaping(.normal, .parser_oom, "1 + 1");
}

test "Escargot discard eval boundary catches parser allocation failure" {
    try expectFailureWithoutEscaping(.discarding, .parser_oom, "1 + 1");
}

test "Escargot eval boundary reports error text allocation failure" {
    try expectFailureWithoutEscaping(.normal, .error_text_allocation, "@");
}

test "Escargot discard eval boundary reports error text allocation failure" {
    try expectFailureWithoutEscaping(.discarding, .error_text_allocation, "@");
}

test "Escargot eval boundary catches native exceptions" {
    try expectFailureWithoutEscaping(.normal, .native_exception, "1 + 1");
}

test "Escargot discard eval boundary catches native exceptions" {
    try expectFailureWithoutEscaping(.discarding, .native_exception, "1 + 1");
}

test "Escargot eval boundary catches native error conversion allocation failure" {
    try expectNativeErrorConversionDoesNotEscape(.normal);
}

test "Escargot discard eval boundary catches native error conversion allocation failure" {
    try expectNativeErrorConversionDoesNotEscape(.discarding);
}
