//! Escargot host object — Zig trampolines into createExposableObject bridge.

const std = @import("std");
const host_value = @import("../../abi/host_value.zig");
const c_api = @import("c_api.zig");
const value_mod = @import("value.zig");

pub const GetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, out: *host_value.HostValue) ?[*:0]const u8;
pub const SetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: []const u8, value: host_value.HostValue) ?[*:0]const u8;
pub const NamesFn = *const fn (instance_id: i32, user_data: ?*anyopaque, out_names: *[]const []const u8) void;
pub const FinalizeFn = *const fn (user_data: ?*anyopaque) void;

const Box = struct {
    instance_id: i32,
    user_data: ?*anyopaque,
    get_fn: ?GetFn,
    set_fn: ?SetFn,
    names_fn: ?NamesFn,
    finalize_fn: ?FinalizeFn,
    // Scratch for names trampoline (pointers into caller's slices).
    name_ptrs: [][*]const u8 = &.{},
    name_lens: []usize = &.{},
};

fn cGet(instance_id: i32, user_data: ?*anyopaque, name: [*]const u8, name_len: usize, out: *c_api.HostValueC) callconv(.c) ?[*:0]const u8 {
    const box: *Box = @ptrCast(@alignCast(user_data.?));
    var hv: host_value.HostValue = undefined;
    host_value.clear(&hv);
    const err = if (box.get_fn) |f| f(instance_id, box.user_data, name[0..name_len], &hv) else null;
    out.* = .{
        .tag = hv.tag,
        .reserved = 0,
        .number = hv.number,
        .ptr = hv.ptr,
        .len = hv.len,
    };
    return err;
}

fn cSet(instance_id: i32, user_data: ?*anyopaque, name: [*]const u8, name_len: usize, value: *const c_api.HostValueC) callconv(.c) ?[*:0]const u8 {
    const box: *Box = @ptrCast(@alignCast(user_data.?));
    const set_fn = box.set_fn orelse return "TypeError: cannot set property";
    const hv = host_value.HostValue{
        .tag = value.tag,
        .reserved = 0,
        .number = value.number,
        .ptr = value.ptr,
        .len = value.len,
    };
    return set_fn(instance_id, box.user_data, name[0..name_len], hv);
}

fn cNames(instance_id: i32, user_data: ?*anyopaque, out_names: *?[*]const [*]const u8, out_lens: *?[*]const usize, out_count: *usize) callconv(.c) void {
    out_names.* = null;
    out_lens.* = null;
    out_count.* = 0;
    const box: *Box = @ptrCast(@alignCast(user_data.?));
    var list: []const []const u8 = &.{};
    if (box.names_fn) |f| f(instance_id, box.user_data, &list);
    if (list.len == 0) return;
    // Reuse / grow scratch on the box (stable for the duration of the C++ enumeration call).
    if (box.name_ptrs.len < list.len) {
        if (box.name_ptrs.len > 0) {
            std.heap.c_allocator.free(box.name_ptrs);
            std.heap.c_allocator.free(box.name_lens);
        }
        box.name_ptrs = std.heap.c_allocator.alloc([*]const u8, list.len) catch return;
        box.name_lens = std.heap.c_allocator.alloc(usize, list.len) catch return;
    }
    for (list, 0..) |n, i| {
        box.name_ptrs[i] = n.ptr;
        box.name_lens[i] = n.len;
    }
    out_names.* = box.name_ptrs.ptr;
    out_lens.* = box.name_lens.ptr;
    out_count.* = list.len;
}

fn cFinalize(user_data: ?*anyopaque) callconv(.c) void {
    const box: *Box = @ptrCast(@alignCast(user_data.?));
    const fin = box.finalize_fn;
    box.finalize_fn = null;
    if (fin) |f| f(box.user_data);
    if (box.name_ptrs.len > 0) {
        std.heap.c_allocator.free(box.name_ptrs);
        std.heap.c_allocator.free(box.name_lens);
    }
    std.heap.c_allocator.destroy(box);
}

pub fn create(ctx: value_mod.Context, instance_id: i32, user_data: ?*anyopaque, get_fn: ?GetFn, set_fn: ?SetFn, names_fn: ?NamesFn, finalize_fn: ?FinalizeFn) value_mod.Value {
    const box = std.heap.c_allocator.create(Box) catch return null;
    box.* = .{
        .instance_id = instance_id,
        .user_data = user_data,
        .get_fn = get_fn,
        .set_fn = set_fn,
        .names_fn = names_fn,
        .finalize_fn = finalize_fn,
    };
    const v = c_api.escargot_host_object_create(
        ctx,
        instance_id,
        box,
        if (get_fn != null) cGet else null,
        if (set_fn != null) cSet else null,
        if (names_fn != null) cNames else null,
        cFinalize,
    );
    if (v == null) {
        std.heap.c_allocator.destroy(box);
        return null;
    }
    return v;
}
