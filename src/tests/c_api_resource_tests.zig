//! Tests for C API resource limits, admission classes, no-copy ArrayBuffers, GC posting, and nanbox values.
const std = @import("std");
const c_api = @import("../c_api.zig");
const api_value = @import("../abi/api_value.zig");
const value_mod = @import("../value/root.zig");
const helpers = @import("test_helpers.zig");

const API_OK: c_int = 0;
const API_EXCEPTION: c_int = 1;
const API_INVALID_ARGUMENT: c_int = 2;
const API_WRONG_THREAD: c_int = 3;
const API_INSTANCE_NOT_FOUND: c_int = 4;
const API_STALE_VALUE: c_int = 5;
const API_OUT_OF_MEMORY: c_int = 6;
const API_UNSUPPORTED: c_int = 7;
const API_LOOP_FAILED: c_int = 8;

test "c_api: create_with_limits rejects excess timers and reports usage" {
    const id = helpers.nextInstanceId();
    var limits = c_api.ResourceLimitsC{
        .struct_size = @sizeOf(c_api.ResourceLimitsC),
        .max_timers = 1,
        .max_tsfn_handles = 256,
        .max_pending_calls = 4096,
        .max_pending_bytes = 8 * 1024 * 1024,
        .max_pending_tasks = 4096,
    };
    try std.testing.expect(c_api.jsbay_engine_create_with_limits(id, null, null, &limits));
    defer c_api.jsbay_engine_destroy(id);

    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(id, "setTimeout(()=>{},2147483647)");

    var usage = c_api.ResourceUsageC{ .struct_size = @sizeOf(c_api.ResourceUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    try std.testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try std.testing.expectEqual(@as(usize, 1), usage.timers);
    try std.testing.expectEqual(@as(usize, 1), usage.max_timers);

    var global = c_api.ResourceGlobalUsageC{ .struct_size = @sizeOf(c_api.ResourceGlobalUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_native_tasks = 0, .max_script_tasks = 0, .max_pending_bytes = 0 };
    try std.testing.expect(c_api.jsbay_resource_global_usage(&global));
    try std.testing.expect(global.timers >= 1);
    try std.testing.expectEqual(@as(usize, 65536), global.max_timers);
}

test "c_api: independent instance budgets coexist under the process cap" {
    const a = helpers.nextInstanceId();
    const b = helpers.nextInstanceId();
    var limits_a = c_api.ResourceLimitsC{
        .struct_size = @sizeOf(c_api.ResourceLimitsC),
        .max_timers = 1,
        .max_tsfn_handles = 256,
        .max_pending_calls = 4096,
        .max_pending_bytes = 8 * 1024 * 1024,
        .max_pending_tasks = 4096,
    };
    var limits_b = limits_a;
    limits_b.max_timers = 2;
    try std.testing.expect(c_api.jsbay_engine_create_with_limits(a, null, null, &limits_a));
    defer c_api.jsbay_engine_destroy(a);
    try std.testing.expect(c_api.jsbay_engine_create_with_limits(b, null, null, &limits_b));
    defer c_api.jsbay_engine_destroy(b);

    try helpers.evalOk(a, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(a, "setTimeout(()=>{},2147483647)");
    try helpers.evalOk(b, "setTimeout(()=>{},2147483647)");
    try helpers.evalOk(b, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(b, "setTimeout(()=>{},2147483647)");

    var usage_a = c_api.ResourceUsageC{ .struct_size = @sizeOf(c_api.ResourceUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    var usage_b = usage_a;
    try std.testing.expect(c_api.jsbay_engine_get_resource_usage(a, &usage_a));
    try std.testing.expect(c_api.jsbay_engine_get_resource_usage(b, &usage_b));
    try std.testing.expectEqual(@as(usize, 1), usage_a.timers);
    try std.testing.expectEqual(@as(usize, 2), usage_b.timers);

    limits_b.max_timers = 1;
    try std.testing.expect(c_api.jsbay_engine_set_resource_limits(b, &limits_b));
    try helpers.evalErr(b, "setTimeout(()=>{},2147483647)");
}

test "c_api: admission class defaults to FOREGROUND and mid-flight set keeps usage" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var cls: c_api.AdmissionClassC = .background;
    try std.testing.expect(c_api.jsbay_engine_get_admission_class(id, &cls));
    try std.testing.expectEqual(c_api.AdmissionClassC.foreground, cls);

    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
    try std.testing.expect(c_api.jsbay_engine_set_admission_class(id, @backingInt(c_api.AdmissionClassC.background)));
    try std.testing.expect(c_api.jsbay_engine_get_admission_class(id, &cls));
    try std.testing.expectEqual(c_api.AdmissionClassC.background, cls);

    var usage = c_api.ResourceUsageC{ .struct_size = @sizeOf(c_api.ResourceUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    try std.testing.expect(c_api.jsbay_engine_get_resource_usage(id, &usage));
    try std.testing.expectEqual(@as(usize, 1), usage.timers);

    try std.testing.expect(!c_api.jsbay_engine_set_admission_class(id, 99));
    try std.testing.expect(!c_api.jsbay_engine_get_admission_class(id, null));
    try std.testing.expect(!c_api.jsbay_engine_set_admission_class(helpers.nextInstanceId(), 0));

    var global = std.mem.zeroes(c_api.ResourceGlobalUsageC);
    global.struct_size = @sizeOf(c_api.ResourceGlobalUsageC);
    try std.testing.expect(c_api.jsbay_resource_global_usage(&global));
    try std.testing.expectEqual(@as(usize, 16384), global.fg_headroom_timers);
    try std.testing.expectEqual(@as(usize, 49152), global.bg_effective_max_timers);
    try std.testing.expectEqual(@as(usize, 1024), global.fg_headroom_tsfn_handles);

    var legacy = std.mem.zeroes(c_api.ResourceGlobalUsageC);
    legacy.struct_size = @intCast(c_api.resource_global_usage_legacy_size);
    try std.testing.expect(c_api.jsbay_resource_global_usage(&legacy));
    try std.testing.expectEqual(@as(u32, @intCast(c_api.resource_global_usage_legacy_size)), legacy.struct_size);
}

const NoCopyTestState = struct {
    dealloc_calls: usize = 0,
    last_user_data: ?*anyopaque = null,
    last_bytes: ?*anyopaque = null,
    last_len: usize = 0,

    fn dealloc(ud: ?*anyopaque, b: ?*anyopaque, l: usize) callconv(.c) void {
        const state: *NoCopyTestState = @ptrCast(@alignCast(ud orelse return));
        state.dealloc_calls += 1;
        state.last_user_data = ud;
        state.last_bytes = b;
        state.last_len = l;
    }
};

test "c_api: jsbay_value_new_array_buffer_no_copy lifecycle and failure guarantees" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));

    // 1. Normal buffer
    var state = NoCopyTestState{};
    var payload = [_]u8{ 11, 22, 33, 44 };
    var out_val: u64 = 0;
    const status = c_api.jsbay_value_new_array_buffer_no_copy(id, &payload, payload.len, NoCopyTestState.dealloc, &state, &out_val);
    try std.testing.expectEqual(API_OK, status);
    try std.testing.expect(out_val != 0);

    var copied: c_api.Bytes = .{ .data = null, .len = 0 };
    var exception: u64 = 0;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_copy_buffer(out_val, &copied, &exception));
    defer c_api.jsbay_free_bytes(copied);
    try std.testing.expectEqualSlices(u8, &payload, copied.data.?[0..copied.len]);

    // Release value and destroy engine to ensure collection across all backends
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_release(out_val));
    _ = c_api.jsbay_engine_run_gc(id);
    c_api.jsbay_engine_destroy(id);
    try std.testing.expectEqual(@as(usize, 1), state.dealloc_calls);
    try std.testing.expectEqual(payload.len, state.last_len);

    const id2 = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id2, null, null));
    defer c_api.jsbay_engine_destroy(id2);

    // 2. len == 0 fires deallocator immediately and returns an empty ArrayBuffer
    var state_zero = NoCopyTestState{};
    var out_zero: u64 = 0;
    const status_zero = c_api.jsbay_value_new_array_buffer_no_copy(id2, null, 0, NoCopyTestState.dealloc, &state_zero, &out_zero);
    try std.testing.expectEqual(API_OK, status_zero);
    try std.testing.expect(out_zero != 0);
    try std.testing.expectEqual(@as(usize, 1), state_zero.dealloc_calls);
    defer _ = c_api.jsbay_value_release(out_zero);

    // 3. len > 0 with data == null fires deallocator immediately and returns INVALID_ARGUMENT
    var state_bad = NoCopyTestState{};
    var out_bad: u64 = 0;
    const status_bad = c_api.jsbay_value_new_array_buffer_no_copy(id2, null, 10, NoCopyTestState.dealloc, &state_bad, &out_bad);
    try std.testing.expectEqual(API_INVALID_ARGUMENT, status_bad);
    try std.testing.expectEqual(@as(u64, 0), out_bad);
    try std.testing.expectEqual(@as(usize, 1), state_bad.dealloc_calls);

    // 4. Missing instance fires deallocator immediately and returns INSTANCE_NOT_FOUND
    var state_missing = NoCopyTestState{};
    var out_missing: u64 = 0;
    const status_missing = c_api.jsbay_value_new_array_buffer_no_copy(999999, &payload, payload.len, NoCopyTestState.dealloc, &state_missing, &out_missing);
    try std.testing.expectEqual(API_INSTANCE_NOT_FOUND, status_missing);
    try std.testing.expectEqual(@as(u64, 0), out_missing);
    try std.testing.expectEqual(@as(usize, 1), state_missing.dealloc_calls);
}

test "c_api: jsbay_engine_post_gc accepts and coalesces" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    const snapshot = @import("../runtime/instance_map.zig").getInstance(id).?;
    try std.testing.expect(c_api.jsbay_engine_post_gc(id, snapshot.generation));
    // Concurrent/repeated calls coalesce and return true
    try std.testing.expect(c_api.jsbay_engine_post_gc(id, snapshot.generation));

    // Stale generation or missing instance rejects
    try std.testing.expect(!c_api.jsbay_engine_post_gc(id, snapshot.generation + 1));
    try std.testing.expect(!c_api.jsbay_engine_post_gc(999999, 0));
}

test "c_api: nanbox hyper_box primitive fast paths bypass lock without engine handles" {
    const HV = value_mod.HyperValue;

    // Numbers (Float and Int32)
    const float_val = HV.fromFloat(123.456).raw;
    var out_num: f64 = 0;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_to_number(float_val, &out_num));
    try std.testing.expectEqual(@as(f64, 123.456), out_num);

    var kind: c_int = -1;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_type(float_val, &kind));
    try std.testing.expectEqual(@as(c_int, 3), kind);

    var out_bool: bool = true;
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_bool(float_val, &out_bool));

    var retained_float: u64 = 0;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_retain(float_val, &retained_float));
    try std.testing.expectEqual(float_val, retained_float);
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_release(float_val));

    // Booleans
    const bool_val = HV.fromBool(true).raw;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_to_bool(bool_val, &out_bool));
    try std.testing.expectEqual(true, out_bool);
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_type(bool_val, &kind));
    try std.testing.expectEqual(@as(c_int, 2), kind);
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_number(bool_val, &out_num));

    // Special: undefined & null
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_type(HV.undefinedValue().raw, &kind));
    try std.testing.expectEqual(@as(c_int, 0), kind);
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_type(HV.nullValue().raw, &kind));
    try std.testing.expectEqual(@as(c_int, 1), kind);

    // SSO String
    const sso_val = (HV.fromSso("hello") orelse return error.TestUnexpectedResult).raw;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_type(sso_val, &kind));
    try std.testing.expectEqual(@as(c_int, 4), kind);

    var out_bytes: c_api.Bytes = .{ .data = null, .len = 0 };
    var out_exc: u64 = 0;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_to_utf8(sso_val, &out_bytes, &out_exc));
    defer c_api.jsbay_free_bytes(out_bytes);
    try std.testing.expectEqual(@as(usize, 5), out_bytes.len);
    try std.testing.expectEqualStrings("hello", out_bytes.data.?[0..out_bytes.len]);

    // Non-string unboxed primitives reject to_utf8 as invalid argument
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_utf8(float_val, &out_bytes, &out_exc));
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_utf8(bool_val, &out_bytes, &out_exc));

    // Empty value returns stale
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_retain(HV.empty().raw, &retained_float));
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_release(HV.empty().raw));
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_type(HV.empty().raw, &kind));

    // Corrupt SSO handle (length 7 in bits 47..40) is rejected as stale handle
    const corrupt_sso: u64 = 0xFFFE_0700_0000_0000;
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_to_utf8(corrupt_sso, &out_bytes, &out_exc));
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_type(corrupt_sso, &kind));
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_retain(corrupt_sso, &retained_float));
    try std.testing.expectEqual(API_STALE_VALUE, c_api.jsbay_value_release(corrupt_sso));

    // Direct register SSO string creation and zero-copy extraction
    var created_sso: u64 = 0;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_new_sso_string("abc", 3, &created_sso));
    var extracted_buf: [6]u8 = undefined;
    var extracted_len: usize = 0;
    try std.testing.expectEqual(API_OK, c_api.jsbay_value_to_sso_utf8(created_sso, &extracted_buf, &extracted_len));
    try std.testing.expectEqual(@as(usize, 3), extracted_len);
    try std.testing.expectEqualStrings("abc", extracted_buf[0..extracted_len]);

    // Null safety guards for SSO C APIs
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_new_sso_string("abc", 3, null));
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_new_sso_string(null, 1, &created_sso));
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_sso_utf8(created_sso, null, &extracted_len));
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_sso_utf8(created_sso, &extracted_buf, null));

    // Reject SSO creation for strings longer than 6 bytes
    var overflow_sso: u64 = 0;
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_new_sso_string("toolong", 7, &overflow_sso));

    // Reject non-SSO value in to_sso_utf8
    try std.testing.expectEqual(API_INVALID_ARGUMENT, c_api.jsbay_value_to_sso_utf8(float_val, &extracted_buf, &extracted_len));
}

test "api_value: native callback returning unboxed double synthesizes float without error" {
    const id = helpers.nextInstanceId();
    try std.testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    // IEEE-754 double
    const dbl_val = value_mod.HyperValue.fromFloat(3.1415926535);
    const dbl_entry = api_value.takeOwnedOrSynthesize(id, dbl_val.raw);
    try std.testing.expect(dbl_entry != null);
    try std.testing.expectEqual(id, dbl_entry.?.instance_id);
    api_value.freeTaken(dbl_entry.?);

    // Negative zero double
    const neg_zero = value_mod.HyperValue.fromFloat(-0.0);
    const neg_entry = api_value.takeOwnedOrSynthesize(id, neg_zero.raw);
    try std.testing.expect(neg_entry != null);
    api_value.freeTaken(neg_entry.?);

    // Int32
    const int_val = value_mod.HyperValue.fromInt32(42);
    const int_entry = api_value.takeOwnedOrSynthesize(id, int_val.raw);
    try std.testing.expect(int_entry != null);
    api_value.freeTaken(int_entry.?);

    // Boolean
    const bool_val = value_mod.HyperValue.fromBool(true);
    const bool_entry = api_value.takeOwnedOrSynthesize(id, bool_val.raw);
    try std.testing.expect(bool_entry != null);
    api_value.freeTaken(bool_entry.?);

    // Empty value returns null
    try std.testing.expect(api_value.takeOwnedOrSynthesize(id, 0) == null);
}
