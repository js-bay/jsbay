//! Public C ABI contract for jsbay_value_copy_buffer. The cases here intentionally use only the exported C API: the returned bytes must be an independent copy of a live ArrayBuffer/View window.

const std = @import("std");
const testing = std.testing;
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");

const ok: c_int = 0;
const invalid: c_int = 2;

fn evaluate(id: i32, source: []const u8, out: *u64) !void {
    var exception: u64 = 0;
    const status = c_api.jsbay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = "copy.js", .len = 7 }, null, out, &exception);
    if (status != ok) {
        if (exception != 0) _ = c_api.jsbay_value_release(exception);
        try testing.expectEqual(ok, status);
    }
    try testing.expectEqual(@as(u64, 0), exception);
}

fn evaluateDiscard(id: i32, source: []const u8) !void {
    var value: u64 = 0;
    defer {
        if (value != 0) _ = c_api.jsbay_value_release(value);
    }
    try evaluate(id, source, &value);
}

fn expectNumber(value: u64, expected: f64) !void {
    var actual: f64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_to_number(value, &actual));
    try testing.expectEqual(expected, actual);
}

fn expectBytes(value: u64, expected: []const u8) !void {
    var bytes = c_api.Bytes{ .data = null, .len = 0 };
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_copy_buffer(value, &bytes, &exception));
    defer c_api.jsbay_free_bytes(bytes);
    try testing.expectEqual(@as(u64, 0), exception);
    try testing.expectEqualSlices(u8, expected, bytes.data.?[0..bytes.len]);
}

fn expectInvalid(value: u64) !void {
    var bytes = c_api.Bytes{ .data = @ptrFromInt(1), .len = 99 };
    var exception: u64 = 99;
    try testing.expectEqual(invalid, c_api.jsbay_value_copy_buffer(value, &bytes, &exception));
    try testing.expect(bytes.data == null and bytes.len == 0 and exception == 0);
}

fn expectEvalNumber(id: i32, source: []const u8, expected: f64) !void {
    var value: u64 = 0;
    defer {
        if (value != 0) _ = c_api.jsbay_value_release(value);
    }
    try evaluate(id, source, &value);
    try expectNumber(value, expected);
}

fn expectTransferCopy(setup: []const u8, selected: []const u8, expected: []const u8, comptime assert_detached: bool) !void {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var value: u64 = 0;
    defer {
        if (value != 0) _ = c_api.jsbay_value_release(value);
    }
    try evaluateDiscard(id, setup);
    try evaluate(id, selected, &value);

    var bytes = c_api.Bytes{ .data = null, .len = 0 };
    defer c_api.jsbay_free_bytes(bytes);
    var exception: u64 = 0;
    try testing.expectEqual(ok, c_api.jsbay_value_copy_buffer(value, &bytes, &exception));
    try testing.expectEqual(@as(u64, 0), exception);

    const transfer_assertion = if (assert_detached)
        "if(ab.detached!==true||ab.byteLength!==0||new Uint8Array(moved).join(',')!=='1,2,3,4')throw new Error('transfer state');"
    else
        "if(new Uint8Array(moved).join(',')!=='1,2,3,4')throw new Error('transfer failed');";
    try evaluateDiscard(id, "globalThis.moved=ab.transfer();" ++ transfer_assertion ++ "new Uint8Array(moved).set([9,9,9,9]);");
    try testing.expectEqualSlices(u8, expected, bytes.data.?[0..bytes.len]);
    try expectEvalNumber(id, "40+2", 42);
}

test "C copy buffer keeps ordinary ArrayBuffer transferable" {
    try expectTransferCopy("globalThis.ab=new ArrayBuffer(4);new Uint8Array(ab).set([1,2,3,4]);", "ab", &.{ 1, 2, 3, 4 }, true);
}

test "C copy buffer keeps resizable ArrayBuffer transferable" {
    // Each resizable case owns its own engine and backing store. A successful copy must not pin the ArrayBuffer behind a TypedArray or DataView.
    try expectTransferCopy("globalThis.ab=new ArrayBuffer(4,{maxByteLength:8});new Uint8Array(ab).set([1,2,3,4]);", "ab", &.{ 1, 2, 3, 4 }, true);
}

test "C copy buffer keeps resizable TypedArray transferable" {
    try expectTransferCopy("globalThis.ab=new ArrayBuffer(4,{maxByteLength:8});new Uint8Array(ab).set([1,2,3,4]);globalThis.view=new Uint8Array(ab,1,2);", "view", &.{ 2, 3 }, true);
}

test "C copy buffer keeps resizable DataView transferable" {
    try expectTransferCopy("globalThis.ab=new ArrayBuffer(4,{maxByteLength:8});new Uint8Array(ab).set([1,2,3,4]);globalThis.view=new DataView(ab,2,2);", "view", &.{ 3, 4 }, true);
}

test "C copy buffer follows resizable TypedArray windows across shrink and grow" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var fixed: u64 = 0;
    var tracking: u64 = 0;
    var end: u64 = 0;
    defer {
        for ([_]*u64{ &fixed, &tracking, &end }) |value| {
            if (value.* != 0) _ = c_api.jsbay_value_release(value.*);
        }
    }

    try evaluateDiscard(
        id,
        "globalThis.rab=new ArrayBuffer(4,{maxByteLength:8});" ++
            "new Uint8Array(rab).set([1,2,3,4]);" ++
            "globalThis.fixed=new Uint8Array(rab,2,2);" ++
            "globalThis.tracking=new Uint8Array(rab,2);" ++
            "globalThis.end=new Uint8Array(rab,1,0);rab.resize(1);",
    );
    try evaluate(id, "fixed", &fixed);
    try evaluate(id, "tracking", &tracking);
    try evaluate(id, "end", &end);
    try expectInvalid(fixed);
    try expectInvalid(tracking);
    try expectBytes(end, "");

    try evaluateDiscard(id, "rab.resize(8);");
    try expectEvalNumber(id, "tracking.byteLength", 6);
    try expectBytes(fixed, &.{ 0, 0 });
    try expectBytes(tracking, &.{ 0, 0, 0, 0, 0, 0 });
    try expectEvalNumber(id, "40+2", 42);
}

test "C copy buffer rounds tracking multi-byte TypedArrays down to whole elements" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var u16_tracking: u64 = 0;
    var u16_fixed: u64 = 0;
    var u32_tracking: u64 = 0;
    var u32_fixed: u64 = 0;
    defer {
        for ([_]*u64{ &u16_tracking, &u16_fixed, &u32_tracking, &u32_fixed }) |value| {
            if (value.* != 0) _ = c_api.jsbay_value_release(value.*);
        }
    }

    try evaluateDiscard(
        id,
        "globalThis.r16=new ArrayBuffer(7,{maxByteLength:9});new Uint8Array(r16).set([1,2,3,4,5,6,7]);" ++
            "globalThis.u16tracking=new Uint16Array(r16,2);globalThis.u16fixed=new Uint16Array(r16,2,2);r16.resize(9);" ++
            "globalThis.r32=new ArrayBuffer(8,{maxByteLength:15});new Uint8Array(r32).set([1,2,3,4,5,6,7,8]);" ++
            "globalThis.u32tracking=new Uint32Array(r32,4);globalThis.u32fixed=new Uint32Array(r32,4,1);r32.resize(15);",
    );
    try evaluate(id, "u16tracking", &u16_tracking);
    try evaluate(id, "u16fixed", &u16_fixed);
    try evaluate(id, "u32tracking", &u32_tracking);
    try evaluate(id, "u32fixed", &u32_fixed);

    try expectBytes(u16_tracking, &.{ 3, 4, 5, 6, 7, 0 });
    try expectBytes(u16_fixed, &.{ 3, 4, 5, 6 });
    try expectBytes(u32_tracking, &.{ 5, 6, 7, 8, 0, 0, 0, 0 });
    try expectBytes(u32_fixed, &.{ 5, 6, 7, 8 });
    try expectEvalNumber(id, "u16tracking.byteLength*100+u32tracking.byteLength", 608);
    try expectEvalNumber(id, "40+2", 42);
}

test "C copy buffer follows resizable DataView windows and detached empty state" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var fixed: u64 = 0;
    var tracking: u64 = 0;
    var end: u64 = 0;
    var empty: u64 = 0;
    var detached: u64 = 0;
    defer {
        for ([_]*u64{ &fixed, &tracking, &end, &empty, &detached }) |value| {
            if (value.* != 0) _ = c_api.jsbay_value_release(value.*);
        }
    }

    try evaluateDiscard(
        id,
        "globalThis.rab=new ArrayBuffer(4,{maxByteLength:8});" ++
            "new Uint8Array(rab).set([1,2,3,4]);" ++
            "globalThis.fixed=new DataView(rab,2,2);globalThis.tracking=new DataView(rab,2);" ++
            "globalThis.end=new DataView(rab,1,0);globalThis.empty=new DataView(new ArrayBuffer(0));" ++
            "globalThis.detached=new DataView(new ArrayBuffer(2));detached.buffer.transfer();rab.resize(1);",
    );
    try evaluate(id, "fixed", &fixed);
    try evaluate(id, "tracking", &tracking);
    try evaluate(id, "end", &end);
    try evaluate(id, "empty", &empty);
    try evaluate(id, "detached", &detached);
    try expectInvalid(fixed);
    try expectInvalid(tracking);
    try expectBytes(end, "");
    try expectBytes(empty, "");
    try expectInvalid(detached);

    try evaluateDiscard(id, "rab.resize(8);");
    try expectBytes(fixed, &.{ 0, 0 });
    try expectBytes(tracking, &.{ 0, 0, 0, 0, 0, 0 });
    try expectEvalNumber(id, "40+2", 42);
}

test "C copy buffer does not invoke JavaScript getters or constructors" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    var ab: u64 = 0;
    var ta: u64 = 0;
    var dv: u64 = 0;
    defer {
        for ([_]*u64{ &ab, &ta, &dv }) |value| {
            if (value.* != 0) _ = c_api.jsbay_value_release(value.*);
        }
    }

    try evaluateDiscard(
        id,
        "globalThis.calls=0;const NativeAB=ArrayBuffer,NativeU8=Uint8Array;" ++
            "globalThis.ab=new NativeAB(4);new NativeU8(ab).set([1,2,3,4]);" ++
            "globalThis.ta=new NativeU8(ab,1,2);globalThis.dv=new DataView(ab,2,2);" ++
            "for(const v of [ab,ta,dv])Object.defineProperties(v,{buffer:{get(){calls++;return ab}}," ++
            "byteOffset:{get(){calls++;return 0}},byteLength:{get(){calls++;return 0}}," ++
            "constructor:{get(){calls++;return NativeAB}}});" ++
            "Object.defineProperty(NativeAB,Symbol.species,{get(){calls++;return NativeAB}});" ++
            "Object.defineProperty(NativeU8,Symbol.species,{get(){calls++;return NativeU8}});" ++
            "NativeU8.prototype.set=NativeU8.prototype.values=function(){calls++;throw new Error('called')};" ++
            "globalThis.ArrayBuffer=globalThis.Uint8Array=globalThis.DataView=function(){calls++;throw new Error('called')};",
    );
    try evaluate(id, "ab", &ab);
    try evaluate(id, "ta", &ta);
    try evaluate(id, "dv", &dv);
    try expectBytes(ab, &.{ 1, 2, 3, 4 });
    try expectBytes(ta, &.{ 2, 3 });
    try expectBytes(dv, &.{ 3, 4 });
    try expectEvalNumber(id, "calls", 0);
    try expectEvalNumber(id, "40+2", 42);
}
