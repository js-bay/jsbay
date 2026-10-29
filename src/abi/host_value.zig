//! Shared layout for host callbacks invoked from JavaScript.
//!
//! The bytes match the C struct in the engine-thread ABI: tag 0 is undefined, tag 1 is a number, tag 2 is a string of `len` bytes. Input strings live for the callback; output storage must remain valid for the engine's copy after callback return.

const std = @import("std");

pub const tag_undefined: u32 = 0;
pub const tag_number: u32 = 1;
pub const tag_string: u32 = 2;

pub const HostValue = extern struct {
    tag: u32,
    reserved: u32,
    number: f64,
    ptr: ?[*]const u8,
    len: usize,
};

pub const HostFn = *const fn (
    instance_id: c_int,
    user_data: ?*anyopaque,
    argc: u32,
    argv: ?[*]const HostValue,
    out: *HostValue,
) callconv(.c) c_int;

pub fn clear(out: *HostValue) void {
    out.* = .{
        .tag = tag_undefined,
        .reserved = 0,
        .number = 0,
        .ptr = null,
        .len = 0,
    };
}

pub fn dupeCString(slice: []const u8) ?[*:0]u8 {
    const z = std.heap.c_allocator.allocSentinel(u8, slice.len, 0) catch return null;
    @memcpy(z, slice);
    return z.ptr;
}
