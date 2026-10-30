//! FFI declarations for the native Hermes C bridge (Hermes/JSI; not JavaScriptCore).
const std = @import("std");

pub const Runtime = opaque {};
pub const Context = opaque {};
pub const Value = ?*anyopaque;

pub const EvalResultC = extern struct {
    result: ?[*:0]u8,
    err: ?[*:0]u8,
};

pub extern fn hermes_globals_ensure() void;
/// max_heap_bytes==0 → Hermes default MaxHeapSize. Create-time only (no runtime setMemoryLimit).
pub extern fn hermes_runtime_new(max_heap_bytes: u64) ?*Runtime;
pub extern fn hermes_runtime_free(rt: ?*Runtime) void;
pub extern fn hermes_runtime_gc(rt: ?*Runtime) void;
pub extern fn hermes_runtime_allocated_bytes(rt: ?*Runtime) u64;
pub extern fn hermes_runtime_heap_size(rt: ?*Runtime) u64;
pub extern fn hermes_runtime_async_trigger_timeout(rt: ?*Runtime) void;
pub extern fn hermes_runtime_watch_time_limit(rt: ?*Runtime, timeout_ms: u32) void;
pub extern fn hermes_runtime_unwatch_time_limit(rt: ?*Runtime) void;
pub extern fn hermes_runtime_drain_async_timeout(rt: ?*Runtime) void;
pub extern fn hermes_context_new(rt: ?*Runtime) ?*Context;
pub extern fn hermes_context_free(ctx: ?*Context) void;
pub extern fn hermes_context_set_opaque(ctx: ?*Context, opaque_ptr: ?*anyopaque) void;
pub extern fn hermes_context_get_opaque(ctx: ?*Context) ?*anyopaque;
pub extern fn hermes_eval(ctx: ?*Context, src: [*]const u8, src_len: usize, filename: [*]const u8, filename_len: usize) EvalResultC;
pub extern fn hermes_eval_result_free(r: EvalResultC) void;
pub extern fn hermes_undefined() Value;
pub extern fn hermes_null() Value;
pub extern fn hermes_new_bool(ctx: ?*Context, v: bool) Value;
pub extern fn hermes_new_int32(ctx: ?*Context, v: i32) Value;
pub extern fn hermes_new_float64(ctx: ?*Context, v: f64) Value;
pub extern fn hermes_new_string(ctx: ?*Context, utf8: [*]const u8, len: usize) Value;
pub extern fn hermes_new_object(ctx: ?*Context) Value;
pub extern fn hermes_new_array(ctx: ?*Context, len: u32) Value;
pub extern fn hermes_dup(ctx: ?*Context, v: Value) Value;
pub extern fn hermes_free_value(ctx: ?*Context, v: Value) void;
pub extern fn hermes_is_undefined(v: Value) bool;
pub extern fn hermes_is_null(v: Value) bool;
pub extern fn hermes_is_bool(v: Value) bool;
pub extern fn hermes_is_number(v: Value) bool;
pub extern fn hermes_is_string(v: Value) bool;
pub extern fn hermes_is_symbol(v: Value) bool;
pub extern fn hermes_is_object(v: Value) bool;
pub extern fn hermes_is_array(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_is_function(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_is_constructor(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_to_bool(v: Value) bool;
pub extern fn hermes_to_int32(v: Value) i32;
pub extern fn hermes_to_float64(v: Value) f64;
pub extern fn hermes_value_to_utf8(ctx: ?*Context, v: Value) ?[*:0]u8;
pub extern fn hermes_value_to_utf8_n(ctx: ?*Context, v: Value, out_len: *usize) ?[*]u8;
pub extern fn hermes_json_stringify(ctx: ?*Context, v: Value) ?[*:0]u8;
pub extern fn hermes_json_parse(ctx: ?*Context, utf8: [*]const u8, len: usize) Value;
pub extern fn hermes_get_global(ctx: ?*Context) Value;
pub extern fn hermes_get_property(ctx: ?*Context, obj: Value, key: [*:0]const u8) Value;
pub extern fn hermes_set_property(ctx: ?*Context, obj: Value, key: [*:0]const u8, val: Value) bool;
pub extern fn hermes_has_property(ctx: ?*Context, obj: Value, key: [*:0]const u8) bool;
pub extern fn hermes_call(ctx: ?*Context, fn_val: Value, this_val: Value, args: ?[*]const Value, argc: usize, out_err: *?[*:0]u8) Value;
pub extern fn hermes_process_pending_jobs(ctx: ?*Context) void;

pub const ValueResultC = extern struct {
    value: Value,
    err: ?[*:0]u8,
};

pub const NativeFn = *const fn (ctx: ?*Context, this_val: Value, args: ?[*]const Value, argc: usize, user_data: ?*anyopaque) callconv(.c) Value;
pub const MapForEachCFn = *const fn (ctx: ?*Context, cb_ctx: ?*anyopaque, key: Value, val: Value) callconv(.c) bool;
pub const SetForEachCFn = *const fn (ctx: ?*Context, cb_ctx: ?*anyopaque, val: Value) callconv(.c) bool;
pub const BufferDeleter = *const fn (user_data: ?*anyopaque) callconv(.c) void;

pub extern fn hermes_eval_value(ctx: ?*Context, src: [*]const u8, src_len: usize, filename: [*]const u8, filename_len: usize) ValueResultC;
pub extern fn hermes_value_result_free_err(r: ValueResultC) void;
pub extern fn hermes_get_index(ctx: ?*Context, obj: Value, index: u32) Value;
pub extern fn hermes_get_length(ctx: ?*Context, obj: Value) u32;
pub extern fn hermes_set_index(ctx: ?*Context, obj: Value, index: u32, val: Value) bool;
pub extern fn hermes_set_length(ctx: ?*Context, obj: Value, length: u32) bool;
pub extern fn hermes_define_data_property(ctx: ?*Context, obj: Value, key: [*:0]const u8, val: Value, writable: bool) bool;
pub extern fn hermes_strict_equal(ctx: ?*Context, a: Value, b: Value) bool;
pub extern fn hermes_new_symbol(ctx: ?*Context, desc: ?[*]const u8, desc_len: usize) Value;
pub extern fn hermes_symbol_for(ctx: ?*Context, key: ?[*]const u8, key_len: usize) Value;

pub extern fn hermes_is_date(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_date_to_ms(ctx: ?*Context, v: Value) i64;
pub extern fn hermes_new_date(ctx: ?*Context, ms: i64) Value;
pub extern fn hermes_is_bigint(v: Value) bool;
pub extern fn hermes_new_bigint_i64(ctx: ?*Context, v: i64) Value;
pub extern fn hermes_new_bigint_u64(ctx: ?*Context, v: u64) Value;
pub extern fn hermes_bigint_to_i64(v: Value, out: *i64) bool;
pub extern fn hermes_bigint_to_u64(v: Value, out: *u64) bool;
pub extern fn hermes_bigint_to_i64_ctx(ctx: ?*Context, v: Value, out: *i64) bool;
pub extern fn hermes_bigint_to_u64_ctx(ctx: ?*Context, v: Value, out: *u64) bool;
pub extern fn hermes_is_map(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_is_set(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_new_map(ctx: ?*Context) Value;
pub extern fn hermes_new_set(ctx: ?*Context) Value;
pub extern fn hermes_map_set(ctx: ?*Context, map: Value, key: Value, val: Value) bool;
pub extern fn hermes_set_add(ctx: ?*Context, set: Value, val: Value) bool;
pub extern fn hermes_map_size(ctx: ?*Context, map: Value) usize;
pub extern fn hermes_set_size(ctx: ?*Context, set: Value) usize;
pub extern fn hermes_map_to_json(ctx: ?*Context, map: Value) ?[*:0]u8;
pub extern fn hermes_set_to_json(ctx: ?*Context, set: Value) ?[*:0]u8;
pub extern fn hermes_new_map_from_json(ctx: ?*Context, json: [*]const u8, len: usize) Value;
pub extern fn hermes_new_set_from_json(ctx: ?*Context, json: [*]const u8, len: usize) Value;
pub extern fn hermes_map_foreach(ctx: ?*Context, map: Value, cb_ctx: ?*anyopaque, cb: MapForEachCFn) bool;
pub extern fn hermes_set_foreach(ctx: ?*Context, set: Value, cb_ctx: ?*anyopaque, cb: SetForEachCFn) bool;
pub extern fn hermes_is_array_buffer(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_is_typed_array(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_is_data_view(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_new_array_buffer_copy(ctx: ?*Context, bytes: [*]const u8, len: usize) Value;
pub extern fn hermes_new_array_buffer_no_copy(ctx: ?*Context, bytes: [*]u8, len: usize, deleter: ?BufferDeleter, user_data: ?*anyopaque) Value;
pub extern fn hermes_array_buffer_data(ctx: ?*Context, ab: Value, out_len: *usize) ?[*]u8;
pub extern fn hermes_new_typed_array(ctx: ?*Context, ab: Value, kind: c_int, byte_offset: usize, length: usize) Value;
pub extern fn hermes_typed_array_data(ctx: ?*Context, ta: Value, byte_offset: *usize, byte_length: *usize, kind: *c_int) ?[*]u8;
pub extern fn hermes_new_data_view(ctx: ?*Context, ab: Value, byte_offset: usize, byte_length: usize) Value;
pub extern fn hermes_data_view_data(ctx: ?*Context, dv: Value, byte_offset: *usize, byte_length: *usize) ?[*]u8;
pub extern fn hermes_make_function(ctx: ?*Context, name: [*:0]const u8, fn_ptr: NativeFn, user_data: ?*anyopaque) Value;
pub extern fn hermes_throw(ctx: ?*Context, message: [*:0]const u8) void;
pub extern fn hermes_atom_new(ctx: ?*Context, utf8: [*]const u8, len: usize) ?*anyopaque;
pub extern fn hermes_atom_free(atom: ?*anyopaque) void;
pub extern fn hermes_atom_to_utf8(ctx: ?*Context, atom: ?*anyopaque) ?[*:0]u8;
pub extern fn hermes_get_property_atom(ctx: ?*Context, obj: Value, atom: ?*anyopaque) Value;
pub extern fn hermes_set_property_atom(ctx: ?*Context, obj: Value, atom: ?*anyopaque, val: Value) bool;
pub extern fn hermes_has_property_atom(ctx: ?*Context, obj: Value, atom: ?*anyopaque) bool;

pub const OpResult = extern struct {
    value: Value,
    exception: Value,
};
pub const BoolOpResult = extern struct {
    value: bool,
    exception: Value,
};

pub const ExternalFinalizer = *const fn (?*anyopaque) callconv(.c) void;
pub const WeakFinalizer = *const fn (?*anyopaque) callconv(.c) void;

pub extern fn hermes_call_result(ctx: ?*Context, fn_val: Value, this_val: Value, args: ?[*]const Value, argc: usize) OpResult;
pub extern fn hermes_throw_value(ctx: ?*Context, exception: Value) void;
pub extern fn hermes_get_property_result(ctx: ?*Context, obj: Value, key: [*:0]const u8) OpResult;
pub extern fn hermes_json_parse_result(ctx: ?*Context, utf8: [*]const u8, len: usize) OpResult;
pub extern fn hermes_json_stringify_result(ctx: ?*Context, v: Value) OpResult;
pub extern fn hermes_set_property_result(ctx: ?*Context, obj: Value, key: [*:0]const u8, val: Value) OpResult;
pub extern fn hermes_construct(ctx: ?*Context, ctor: Value, args: ?[*]const Value, argc: usize) OpResult;
pub extern fn hermes_has_in(ctx: ?*Context, obj: Value, key: [*:0]const u8) BoolOpResult;
pub extern fn hermes_delete_property(ctx: ?*Context, obj: Value, key: [*:0]const u8) BoolOpResult;
pub extern fn hermes_own_keys(ctx: ?*Context, obj: Value) OpResult;
pub extern fn hermes_instance_of(ctx: ?*Context, value: Value, ctor: Value) BoolOpResult;

pub extern fn hermes_promise_create(ctx: ?*Context, out_promise: *Value, out_resolve: *Value, out_reject: *Value) bool;
pub extern fn hermes_is_promise(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_promise_state(ctx: ?*Context, v: Value) c_int;
pub extern fn hermes_promise_result(ctx: ?*Context, v: Value) Value;
pub extern fn hermes_promise_note_settled(ctx: ?*Context, promise: Value, state: c_int, result: Value) void;
pub extern fn hermes_promise_forget(ctx: ?*Context, promise: Value) void;
pub extern fn hermes_object_identity(ctx: ?*Context, v: Value) u64;

pub extern fn hermes_new_external(ctx: ?*Context, ptr: ?*anyopaque, fin: ?ExternalFinalizer) Value;
pub extern fn hermes_get_external(ctx: ?*Context, v: Value) ?*anyopaque;
pub extern fn hermes_is_external(ctx: ?*Context, v: Value) bool;

pub const NhFinalize = *const fn (?*anyopaque) callconv(.c) void;
pub extern fn hermes_native_handle_create(ctx: ?*Context, handle_data: ?*anyopaque, call_fn: ?NativeFn, finalize: ?NhFinalize) Value;
pub extern fn hermes_native_handle_get(ctx: ?*Context, v: Value) ?*anyopaque;
pub extern fn hermes_native_handle_is(ctx: ?*Context, v: Value) bool;

pub extern fn hermes_weak_attach_finalizer(ctx: ?*Context, target: Value, user_data: ?*anyopaque, cb: WeakFinalizer) bool;

pub fn cStringToOwned(ptr: ?[*:0]u8) ?[]u8 {
    const p = ptr orelse return null;
    const slice = std.mem.span(p);
    const out = std.heap.c_allocator.dupe(u8, slice) catch {
        std.heap.c_allocator.free(slice);
        // pointer from malloc in bridge — free via c free
        _ = std.c.free(p);
        return null;
    };
    _ = std.c.free(p);
    return out;
}

pub extern fn hermes_is_error(ctx: ?*Context, v: Value) bool;
pub extern fn hermes_new_error(ctx: ?*Context, kind: c_int, message: [*:0]const u8) Value;

pub const HostValueC = extern struct {
    tag: u32,
    reserved: u32,
    number: f64,
    ptr: ?[*]const u8,
    len: usize,
};

pub const HostGetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: [*]const u8, name_len: usize, out: *HostValueC) callconv(.c) ?[*:0]const u8;
pub const HostSetFn = *const fn (instance_id: i32, user_data: ?*anyopaque, name: [*]const u8, name_len: usize, value: *const HostValueC) callconv(.c) ?[*:0]const u8;
pub const HostNamesFn = *const fn (instance_id: i32, user_data: ?*anyopaque, out_names: *?[*]const [*]const u8, out_lens: *?[*]const usize, out_count: *usize) callconv(.c) void;
pub const HostFinalizeFn = *const fn (user_data: ?*anyopaque) callconv(.c) void;

pub extern fn hermes_host_object_create(
    ctx: ?*Context,
    instance_id: i32,
    user_data: ?*anyopaque,
    get_fn: ?HostGetFn,
    set_fn: ?HostSetFn,
    names_fn: ?HostNamesFn,
    finalize_fn: ?HostFinalizeFn,
) Value;

pub const RejectionTrackerFn = *const fn (
    instance_id: i32,
    handled: bool,
    reason: [*]const u8,
    reason_len: usize,
    userdata: ?*anyopaque,
) callconv(.c) void;

pub extern fn hermes_set_rejection_tracker(
    ctx: ?*Context,
    instance_id: i32,
    fn_ptr: ?RejectionTrackerFn,
    userdata: ?*anyopaque,
) bool;
