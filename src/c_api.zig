//! C API export layer for foreign consumers (Swift, JNI, NAPI).
//!
//! The public typed C ABI uses length-delimited UTF-8 and owned Value handles.

const std = @import("std");
const builtin = @import("builtin");
const engine = @import("engine.zig");
const types = @import("types.zig");
const value_mod = @import("value/root.zig");
const backend = @import("backend.zig");
const cache_mod = @import("script/cache.zig");
const runtime_control = @import("runtime/runtime_control.zig");
const engine_thread = @import("runtime/engine_thread.zig");
const inspector_mod = @import("inspector/root.zig");
const api_value = @import("abi/api_value.zig");
const packed_api_value = @import("abi/packed_api_value.zig");
const typed_eval = @import("script/typed_eval.zig");
const api_backend = @import("abi/api_backend.zig");
const api_bind = @import("abi/api_bind.zig");
const typed_bytecode = @import("script/typed_bytecode.zig");
const native_sync = @import("js_event_loop").native_sync;
const host_wake = @import("js_event_loop").host_wake;

const ActiveEngine = backend.ActiveEngine;

// ---- Library identity (compile-time -Dbackend; no instance) ----

pub const BackendC = backend.BackendC;
pub const CapabilityFlags = backend.CapabilityFlags;

pub const EngineCapabilitiesC = extern struct {
    struct_size: u32,
    backend: BackendC = .quickjs_ng,
    flags: u32 = 0,
};

/// Which `-Dbackend` was compiled into this linked library.
pub export fn jsbay_library_backend() c_int {
    return @backingInt(backend.libraryBackendC());
}

/// Fill capability bits for this linked build. No instance required.
pub export fn jsbay_library_capabilities(out_caps: ?*EngineCapabilitiesC) bool {
    const out = out_caps orelse return false;
    const caller_size = out.struct_size;
    if (caller_size < 4) return false;
    var filled = EngineCapabilitiesC{
        .struct_size = caller_size,
        .backend = backend.libraryBackendC(),
        .flags = backend.libraryCapabilityFlags(),
    };
    const copy_len = @min(caller_size, @sizeOf(EngineCapabilitiesC));
    const src: [*]const u8 = @ptrCast(&filled);
    const dst: [*]u8 = @ptrCast(out);
    @memset(dst[0..caller_size], 0);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    out.struct_size = caller_size;
    return true;
}

test "c_api: library_backend and capabilities match compile-time backend" {
    const tag = jsbay_library_backend();
    switch (backend.active_backend) {
        .quickjs_ng => try std.testing.expectEqual(@as(c_int, @backingInt(BackendC.quickjs_ng)), tag),
        .quickjs => try std.testing.expectEqual(@as(c_int, @backingInt(BackendC.quickjs)), tag),
        .jsc => try std.testing.expectEqual(@as(c_int, @backingInt(BackendC.jsc)), tag),
        .escargot => try std.testing.expectEqual(@as(c_int, @backingInt(BackendC.escargot)), tag),
        .hermes => try std.testing.expectEqual(@as(c_int, @backingInt(BackendC.hermes)), tag),
    }

    try std.testing.expect(!jsbay_library_capabilities(null));
    var too_small = EngineCapabilitiesC{ .struct_size = 0 };
    try std.testing.expect(!jsbay_library_capabilities(&too_small));

    var caps = EngineCapabilitiesC{ .struct_size = @sizeOf(EngineCapabilitiesC) };
    try std.testing.expect(jsbay_library_capabilities(&caps));
    try std.testing.expectEqual(backend.libraryBackendC(), caps.backend);
    try std.testing.expectEqual(backend.libraryCapabilityFlags(), caps.flags);

    const F = CapabilityFlags;
    // Interrupt/deadline exist for QJS/JSC; spike backends report bit-only / create-time limits.
    if (!backend.isSpikeBackend(backend.active_backend)) {
        try std.testing.expect((caps.flags & F.interrupt_deadline) != 0);
    }
    if (backend.isQuickJsApiBackend(backend.active_backend)) {
        try std.testing.expect((caps.flags & F.heap_stack_limit) != 0);
        try std.testing.expect((caps.flags & F.heap_usage_snapshot) != 0);
        try std.testing.expect((caps.flags & F.explicit_bytecode) != 0);
        if (@import("build_options").bytecode_cache) {
            try std.testing.expect((caps.flags & F.persistent_bytecode_cache) != 0);
        } else {
            try std.testing.expect((caps.flags & F.persistent_bytecode_cache) == 0);
        }
        try std.testing.expect((caps.flags & F.safari_web_inspector) == 0);
    } else {
        try std.testing.expect((caps.flags & F.heap_stack_limit) == 0);
        try std.testing.expect((caps.flags & F.heap_usage_snapshot) == 0);
        try std.testing.expect((caps.flags & F.explicit_bytecode) == 0);
        try std.testing.expect((caps.flags & F.persistent_bytecode_cache) == 0);
        try std.testing.expect((caps.flags & F.safari_web_inspector) != 0);
    }
    if (backend.supportsDebugger(backend.active_backend) and @import("build_options").inspector) {
        try std.testing.expect((caps.flags & F.cdp_source_debugger) != 0);
    } else {
        try std.testing.expect((caps.flags & F.cdp_source_debugger) == 0);
    }
}

const multi_pack = @import("multi_pack.zig");

pub const EngineCreateOptionsC = extern struct {
    struct_size: u32,
    backend: BackendC = .primary,
    log_handler: ?types.LogHandler = null,
    log_user_data: ?*anyopaque = null,
    /// Create-time heap cap in bytes (Hermes MaxHeapSize). Ignored by other backends when zero.
    max_heap_size: u64 = 0,
};

/// Packed backends in this artifact (create-time select candidates). Writes up to `cap` tags into `out` when non-NULL; always returns the packed count (required capacity). Callers must clamp iteration to `min(returned, cap)`.
pub export fn jsbay_available_backends(out_backends: ?[*]BackendC, cap: usize) usize {
    var buf: [8]multi_pack.Backend = undefined;
    const n = multi_pack.availableBackends(&buf);
    if (out_backends) |out| {
        const write_n = @min(n, cap);
        var i: usize = 0;
        while (i < write_n) : (i += 1) {
            out[i] = backend.backendToC(buf[i]);
        }
    }
    return n;
}

/// Create-time engine select. `backend == .primary` (0) selects the pack primary. Any packed backend (including non-primary) creates an instance; non-packed tags fail. Non-primary packed instances support create/eval/destroy plus the typed Value surface wired through packed_api_value; bytecode cache and bind/inspector remain primary-only.
pub export fn jsbay_engine_create_with_options(
    instance_id: c_int,
    options_arg: ?*const EngineCreateOptionsC,
) bool {
    const options = options_arg orelse return false;
    if (options.struct_size < @sizeOf(u32)) return false;
    if (options.struct_size < 8) return false;

    const raw_backend: c_int = @backingInt(options.backend);
    const requested = backend.backendFromC(raw_backend) orelse return false;
    if (!backend.isPacked(requested)) return false;

    const log_handler: ?types.LogHandler = if (options.struct_size >= @offsetOf(EngineCreateOptionsC, "log_handler") + @sizeOf(?types.LogHandler))
        options.log_handler
    else
        null;
    const log_user_data: ?*anyopaque = if (options.struct_size >= @sizeOf(EngineCreateOptionsC))
        options.log_user_data
    else
        null;

    if (host_wake.isNotifying()) return false;
    const id: i32 = @intCast(instance_id);
    var config = cApiEngineConfig(log_handler, log_user_data, resource_limits.Limits{});
    if (options.struct_size >= @offsetOf(EngineCreateOptionsC, "max_heap_size") + @sizeOf(u64)) {
        config.max_heap_size = @intCast(options.max_heap_size);
    }
    if (!engine.createWithBackend(id, config, requested)) return false;
    // runtime_control is mono-only; packed-alt skips it inside createWithBackend.
    if (requested == backend.active_backend) {
        if (!runtime_control.init(id)) {
            engine.destroy(id);
            return false;
        }
    }
    if (!api_value.noteCreated(id)) {
        engine.destroy(id);
        return false;
    }
    if (log_handler) |lh| lh(id, .info, "jsbay create ok", log_user_data);
    return true;
}

test "c_api: available_backends matches packed bits" {
    const n = jsbay_available_backends(null, 0);
    try std.testing.expectEqual(multi_pack.packedCount(), n);
    try std.testing.expect(n >= 1);

    var buf: [8]BackendC = undefined;
    const written = jsbay_available_backends(&buf, buf.len);
    try std.testing.expectEqual(n, written);
    var i: usize = 0;
    while (i < written) : (i += 1) {
        const tag = backend.backendFromC(@backingInt(buf[i])) orelse return error.BadBackendTag;
        try std.testing.expect(backend.isPacked(tag));
        try std.testing.expect(buf[i] != .primary);
    }

    // Cap smaller than packed count still returns full count.
    if (n >= 1) {
        var one: [1]BackendC = undefined;
        const reported = jsbay_available_backends(&one, 1);
        try std.testing.expectEqual(n, reported);
        try std.testing.expect(one[0] != .primary);
    }
}

test "c_api: create_with_options primary packed succeeds; non-packed fails" {
    const helpers = @import("tests/test_helpers.zig");

    // Default / primary tag → full create.
    {
        const id = helpers.nextInstanceId();
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = .primary,
        };
        try std.testing.expect(jsbay_engine_create_with_options(id, &opts));
        defer jsbay_engine_destroy(id);
    }
    {
        const id = helpers.nextInstanceId();
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = backend.libraryBackendC(),
        };
        try std.testing.expect(jsbay_engine_create_with_options(id, &opts));
        defer jsbay_engine_destroy(id);
    }

    try std.testing.expect(!jsbay_engine_create_with_options(helpers.nextInstanceId(), null));
    var too_small = EngineCreateOptionsC{ .struct_size = 0, .backend = .primary };
    try std.testing.expect(!jsbay_engine_create_with_options(helpers.nextInstanceId(), &too_small));

    // Pick a backend that is not packed in this artifact.
    const candidates = [_]BackendC{ .quickjs_ng, .quickjs, .jsc };
    var found_unpacked = false;
    for (candidates) |cand| {
        const tag = backend.backendFromC(@backingInt(cand)).?;
        if (backend.isPacked(tag)) continue;
        found_unpacked = true;
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = cand,
        };
        try std.testing.expect(!jsbay_engine_create_with_options(helpers.nextInstanceId(), &opts));
        break;
    }
    // With a single packed engine, at least one of the three tags is unpacked.
    try std.testing.expect(found_unpacked);

    // Unknown backend enum value.
    var bogus = EngineCreateOptionsC{
        .struct_size = @sizeOf(EngineCreateOptionsC),
        .backend = @fromBackingInt(@intCast(99)),
    };
    try std.testing.expect(!jsbay_engine_create_with_options(helpers.nextInstanceId(), &bogus));
}

test "c_api: create_with_options non-primary packed create eval destroy" {
    // When multi-pack includes a non-primary engine, create/eval/destroy must work (Apple NG+JSC).
    var buf: [8]BackendC = undefined;
    const n = jsbay_available_backends(&buf, buf.len);
    const primary = backend.libraryBackendC();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == primary) continue;
        const id = @import("tests/test_helpers.zig").nextInstanceId();
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = buf[i],
        };
        try std.testing.expect(jsbay_engine_create_with_options(id, &opts));
        defer jsbay_engine_destroy(id);
        const tag = backend.backendFromC(@backingInt(buf[i])).?;
        const ev = engine.evalScript(id, "1+1", "<c-api-alt>");
        defer {
            if (ev.result) |s| std.heap.c_allocator.free(@constCast(s));
            if (ev.err_is_heap) {
                if (ev.err) |e| std.heap.c_allocator.free(@constCast(e));
            }
        }
        try std.testing.expect(ev.err == null);
        try std.testing.expectEqualStrings("2", ev.result.?);
        _ = tag;
    }
    // Single-pack Linux: loop body skipped; dual pack (Apple NG+JSC) exercises create/eval/destroy here.
}

test "c_api: packed-alt typed evaluate number + retain/release (real non-primary when packed)" {
    var buf: [8]BackendC = undefined;
    const n = jsbay_available_backends(&buf, buf.len);
    const primary = backend.libraryBackendC();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == primary) continue;
        const id = @import("tests/test_helpers.zig").nextInstanceId();
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = buf[i],
        };
        try std.testing.expect(jsbay_engine_create_with_options(id, &opts));
        defer jsbay_engine_destroy(id);
        var value: u64 = 0;
        var exception: u64 = 0;
        const source = "40+2";
        const filename = "<alt-eval>";
        try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, null, &value, &exception));
        defer _ = jsbay_value_release(value);
        try std.testing.expectEqual(@as(u64, 0), exception);
        try std.testing.expect(packed_api_value.isPackedHandle(value));
        var kind: c_int = -1;
        try std.testing.expectEqual(API_OK, jsbay_value_type(value, &kind));
        try std.testing.expectEqual(@as(c_int, 3), kind); // number
        var number: f64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_to_number(value, &number));
        try std.testing.expectEqual(@as(f64, 42), number);
        var retained: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_retain(value, &retained));
        defer _ = jsbay_value_release(retained);
        try std.testing.expectEqual(API_OK, jsbay_value_to_number(retained, &number));
        try std.testing.expectEqual(@as(f64, 42), number);
    }
}

test "c_api: forced packed_alt typed value (Linux primary-tag)" {
    // Build EngineInstance.packed_alt for the pack primary without a second real engine.
    const helpers = @import("tests/test_helpers.zig");
    const instance_map = @import("runtime/instance_map.zig");
    const event_loop = @import("js_event_loop");
    const timers = @import("runtime/timers.zig");
    const backend_dispatch = @import("backend_dispatch.zig");
    const id = helpers.nextInstanceId();
    const tag = backend.active_backend;
    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    const handles = backend_dispatch.createPacked(tag) orelse {
        loop.destroy();
        return error.CreatePackedFailed;
    };
    backend_dispatch.finishCreate(tag, handles, id, 256 * 1024);
    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        return error.Oom;
    };
    const resources = @import("runtime/resource_limits.zig").Budget.create(.{}) orelse {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        std.heap.c_allocator.destroy(instance);
        return error.BudgetFailed;
    };
    instance.* = .{
        .resources = resources,
        .instance_id = id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
    };
    if (!instance_map.insert(instance)) {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        resources.deinit();
        instance.deinitSynchronization();
        std.heap.c_allocator.destroy(instance);
        return error.InsertFailed;
    }
    try std.testing.expect(api_value.noteCreated(id));
    defer jsbay_engine_destroy(id);

    var value: u64 = 0;
    var exception: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "40+2", .len = 4 }, .{ .data = "<forced-alt>", .len = 12 }, null, &value, &exception));
    defer _ = jsbay_value_release(value);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expect(packed_api_value.isPackedHandle(value));
    var kind: c_int = -1;
    try std.testing.expectEqual(API_OK, jsbay_value_type(value, &kind));
    try std.testing.expectEqual(@as(c_int, 3), kind);
    var number: f64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(value, &number));
    try std.testing.expectEqual(@as(f64, 42), number);

    var obj: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "({n:7,s:'hi'})", .len = 14 }, .{ .data = "<forced-obj>", .len = 12 }, null, &obj, &exception));
    defer _ = jsbay_value_release(obj);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var prop: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_get(obj, .{ .data = "n", .len = 1 }, &prop, &exception));
    defer _ = jsbay_value_release(prop);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(prop, &number));
    try std.testing.expectEqual(@as(f64, 7), number);

    var sprop: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_get(obj, .{ .data = "s", .len = 1 }, &sprop, &exception));
    defer _ = jsbay_value_release(sprop);
    var bytes: Bytes = .{ .data = null, .len = 0 };
    var to_exc: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_to_utf8(sprop, &bytes, &to_exc));
    defer jsbay_free_bytes(bytes);
    try std.testing.expectEqualStrings("hi", bytes.data.?[0..bytes.len]);
}

test "c_api: forced packed_alt set/call/construct/new_* (Linux primary-tag proof)" {
    const helpers = @import("tests/test_helpers.zig");
    const instance_map = @import("runtime/instance_map.zig");
    const event_loop = @import("js_event_loop");
    const timers = @import("runtime/timers.zig");
    const backend_dispatch = @import("backend_dispatch.zig");
    const id = helpers.nextInstanceId();
    const tag = backend.active_backend;
    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    const handles = backend_dispatch.createPacked(tag) orelse {
        loop.destroy();
        return error.CreatePackedFailed;
    };
    backend_dispatch.finishCreate(tag, handles, id, 256 * 1024);
    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        return error.Oom;
    };
    const resources = @import("runtime/resource_limits.zig").Budget.create(.{}) orelse {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        std.heap.c_allocator.destroy(instance);
        return error.BudgetFailed;
    };
    instance.* = .{
        .resources = resources,
        .instance_id = id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
    };
    if (!instance_map.insert(instance)) {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        resources.deinit();
        instance.deinitSynchronization();
        std.heap.c_allocator.destroy(instance);
        return error.InsertFailed;
    }
    try std.testing.expect(api_value.noteCreated(id));
    defer jsbay_engine_destroy(id);

    var exception: u64 = 0;

    // new_object + new_number + set + get
    var obj: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &obj));
    defer _ = jsbay_value_release(obj);
    try std.testing.expect(packed_api_value.isPackedHandle(obj));
    var num: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 99, &num));
    defer _ = jsbay_value_release(num);
    try std.testing.expectEqual(API_OK, jsbay_value_set(obj, .{ .data = "x", .len = 1 }, num, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    var got: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_get(obj, .{ .data = "x", .len = 1 }, &got, &exception));
    defer _ = jsbay_value_release(got);
    var number: f64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(got, &number));
    try std.testing.expectEqual(@as(f64, 99), number);

    // new_string / bool / null / undefined / array / global
    var s: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_string(id, .{ .data = "hi", .len = 2 }, &s));
    defer _ = jsbay_value_release(s);
    var flag: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_bool(id, true, &flag));
    defer _ = jsbay_value_release(flag);
    var kind: c_int = -1;
    try std.testing.expectEqual(API_OK, jsbay_value_type(flag, &kind));
    try std.testing.expectEqual(@as(c_int, 2), kind);
    var und: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_undefined(id, &und));
    defer _ = jsbay_value_release(und);
    var nul: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_null(id, &nul));
    defer _ = jsbay_value_release(nul);
    var arr: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_array(id, &arr));
    defer _ = jsbay_value_release(arr);
    try std.testing.expectEqual(API_OK, jsbay_value_type(arr, &kind));
    try std.testing.expectEqual(@as(c_int, 6), kind);
    var global: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_global(id, &global));
    defer _ = jsbay_value_release(global);

    // call: eval function, call with number arg
    var fn_val: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "(function(a){ return a + 3; })", .len = 30 }, .{ .data = "<fn>", .len = 4 }, null, &fn_val, &exception));
    defer _ = jsbay_value_release(fn_val);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var arg: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 7, &arg));
    defer _ = jsbay_value_release(arg);
    var call_result: u64 = 0;
    const args = [_]u64{arg};
    try std.testing.expectEqual(API_OK, jsbay_value_call(fn_val, und, &args, 1, &call_result, &exception));
    defer _ = jsbay_value_release(call_result);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(call_result, &number));
    try std.testing.expectEqual(@as(f64, 10), number);

    // construct: new Number(5) style via evaluated constructor
    var ctor: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "(function Point(x){ this.x = x; })", .len = 34 }, .{ .data = "<ctor>", .len = 6 }, null, &ctor, &exception));
    defer _ = jsbay_value_release(ctor);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var cx: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 5, &cx));
    defer _ = jsbay_value_release(cx);
    var constructed: u64 = 0;
    const cargs = [_]u64{cx};
    try std.testing.expectEqual(API_OK, jsbay_value_construct(ctor, &cargs, 1, &constructed, &exception));
    defer _ = jsbay_value_release(constructed);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var px: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_get(constructed, .{ .data = "x", .len = 1 }, &px, &exception));
    defer _ = jsbay_value_release(px);
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(px, &number));
    try std.testing.expectEqual(@as(f64, 5), number);

    // ArrayBuffer
    const payload = [_]u8{ 1, 2, 3, 4 };
    var buf: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_array_buffer(id, &payload, payload.len, &buf));
    defer _ = jsbay_value_release(buf);
}

test "c_api: packed-alt set/call/new when real non-primary packed" {
    var buf: [8]BackendC = undefined;
    const n = jsbay_available_backends(&buf, buf.len);
    const primary = backend.libraryBackendC();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == primary) continue;
        const id = @import("tests/test_helpers.zig").nextInstanceId();
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = buf[i],
        };
        try std.testing.expect(jsbay_engine_create_with_options(id, &opts));
        defer jsbay_engine_destroy(id);
        var exception: u64 = 0;
        var obj: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &obj));
        defer _ = jsbay_value_release(obj);
        try std.testing.expect(packed_api_value.isPackedHandle(obj));
        var num: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 3, &num));
        defer _ = jsbay_value_release(num);
        try std.testing.expectEqual(API_OK, jsbay_value_set(obj, .{ .data = "n", .len = 1 }, num, &exception));
        try std.testing.expectEqual(@as(u64, 0), exception);
        var fn_val: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "(function(a,b){ return a*b; })", .len = 30 }, .{ .data = "<alt-fn>", .len = 8 }, null, &fn_val, &exception));
        defer _ = jsbay_value_release(fn_val);
        var a: u64 = 0;
        var b: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 6, &a));
        defer _ = jsbay_value_release(a);
        try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 7, &b));
        defer _ = jsbay_value_release(b);
        var und: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_undefined(id, &und));
        defer _ = jsbay_value_release(und);
        var result: u64 = 0;
        const args = [_]u64{ a, b };
        try std.testing.expectEqual(API_OK, jsbay_value_call(fn_val, und, &args, 2, &result, &exception));
        defer _ = jsbay_value_release(result);
        var number: f64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_to_number(result, &number));
        try std.testing.expectEqual(@as(f64, 42), number);
    }
}

test "c_api: forced packed_alt to_bool/has/delete/keys/instanceof/json/buffer/new_error" {
    const helpers = @import("tests/test_helpers.zig");
    const instance_map = @import("runtime/instance_map.zig");
    const event_loop = @import("js_event_loop");
    const timers = @import("runtime/timers.zig");
    const backend_dispatch = @import("backend_dispatch.zig");
    const id = helpers.nextInstanceId();
    const tag = backend.active_backend;
    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    const handles = backend_dispatch.createPacked(tag) orelse {
        loop.destroy();
        return error.CreatePackedFailed;
    };
    backend_dispatch.finishCreate(tag, handles, id, 256 * 1024);
    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        return error.Oom;
    };
    const resources = @import("runtime/resource_limits.zig").Budget.create(.{}) orelse {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        std.heap.c_allocator.destroy(instance);
        return error.BudgetFailed;
    };
    instance.* = .{
        .resources = resources,
        .instance_id = id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
    };
    if (!instance_map.insert(instance)) {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        resources.deinit();
        instance.deinitSynchronization();
        std.heap.c_allocator.destroy(instance);
        return error.InsertFailed;
    }
    try std.testing.expect(api_value.noteCreated(id));
    defer jsbay_engine_destroy(id);

    var exception: u64 = 0;

    // to_bool
    var flag_v: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_bool(id, true, &flag_v));
    defer _ = jsbay_value_release(flag_v);
    var flag: bool = false;
    try std.testing.expectEqual(API_OK, jsbay_value_to_bool(flag_v, &flag));
    try std.testing.expect(flag);

    // has / set / delete / keys
    var obj: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &obj));
    defer _ = jsbay_value_release(obj);
    var num: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 1, &num));
    defer _ = jsbay_value_release(num);
    try std.testing.expectEqual(API_OK, jsbay_value_set(obj, .{ .data = "k", .len = 1 }, num, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    var has: bool = false;
    try std.testing.expectEqual(API_OK, jsbay_value_has(obj, .{ .data = "k", .len = 1 }, &has, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expect(has);
    var keys_arr: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_keys(obj, &keys_arr, &exception));
    defer _ = jsbay_value_release(keys_arr);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var kind: c_int = -1;
    try std.testing.expectEqual(API_OK, jsbay_value_type(keys_arr, &kind));
    try std.testing.expectEqual(@as(c_int, 6), kind); // array
    var deleted: bool = false;
    try std.testing.expectEqual(API_OK, jsbay_value_delete(obj, .{ .data = "k", .len = 1 }, &deleted, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expect(deleted);
    try std.testing.expectEqual(API_OK, jsbay_value_has(obj, .{ .data = "k", .len = 1 }, &has, &exception));
    try std.testing.expect(!has);

    // instanceof
    var err: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_error(id, .{ .data = "boom", .len = 4 }, &err));
    defer _ = jsbay_value_release(err);
    try std.testing.expect(packed_api_value.isPackedHandle(err));
    var ctor: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "Error", .len = 5 }, .{ .data = "<Error>", .len = 7 }, null, &ctor, &exception));
    defer _ = jsbay_value_release(ctor);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var is_err: bool = false;
    try std.testing.expectEqual(API_OK, jsbay_value_instance_of(err, ctor, &is_err, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expect(is_err);

    // JSON round-trip
    const json_in = "{\"a\":2}";
    var parsed: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_json(id, .{ .data = json_in.ptr, .len = json_in.len }, &parsed, &exception));
    defer _ = jsbay_value_release(parsed);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var json_bytes: Bytes = .{ .data = null, .len = 0 };
    try std.testing.expectEqual(API_OK, jsbay_value_to_json(parsed, &json_bytes, &exception));
    defer jsbay_free_bytes(json_bytes);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqualStrings(json_in, json_bytes.data.?[0..json_bytes.len]);

    // copy_buffer from ArrayBuffer
    const payload = [_]u8{ 9, 8, 7 };
    var buf_v: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_array_buffer(id, &payload, payload.len, &buf_v));
    defer _ = jsbay_value_release(buf_v);
    var copied: Bytes = .{ .data = null, .len = 0 };
    try std.testing.expectEqual(API_OK, jsbay_value_copy_buffer(buf_v, &copied, &exception));
    defer jsbay_free_bytes(copied);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqualSlices(u8, &payload, copied.data.?[0..copied.len]);
}

test "c_api: packed-alt to_bool/has/json/buffer when real non-primary packed" {
    var buf: [8]BackendC = undefined;
    const n = jsbay_available_backends(&buf, buf.len);
    const primary = backend.libraryBackendC();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (buf[i] == primary) continue;
        const id = @import("tests/test_helpers.zig").nextInstanceId();
        var opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = buf[i],
        };
        try std.testing.expect(jsbay_engine_create_with_options(id, &opts));
        defer jsbay_engine_destroy(id);
        var exception: u64 = 0;

        var flag_v: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_bool(id, false, &flag_v));
        defer _ = jsbay_value_release(flag_v);
        var flag: bool = true;
        try std.testing.expectEqual(API_OK, jsbay_value_to_bool(flag_v, &flag));
        try std.testing.expect(!flag);

        var obj: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &obj));
        defer _ = jsbay_value_release(obj);
        var num: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 4, &num));
        defer _ = jsbay_value_release(num);
        try std.testing.expectEqual(API_OK, jsbay_value_set(obj, .{ .data = "z", .len = 1 }, num, &exception));
        var has: bool = false;
        try std.testing.expectEqual(API_OK, jsbay_value_has(obj, .{ .data = "z", .len = 1 }, &has, &exception));
        try std.testing.expect(has);

        const json_in = "[1,2]";
        var parsed: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_json(id, .{ .data = json_in.ptr, .len = json_in.len }, &parsed, &exception));
        defer _ = jsbay_value_release(parsed);
        var json_bytes: Bytes = .{ .data = null, .len = 0 };
        try std.testing.expectEqual(API_OK, jsbay_value_to_json(parsed, &json_bytes, &exception));
        defer jsbay_free_bytes(json_bytes);
        try std.testing.expectEqualStrings(json_in, json_bytes.data.?[0..json_bytes.len]);

        const payload = [_]u8{ 5, 6 };
        var buf_v: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_array_buffer(id, &payload, payload.len, &buf_v));
        defer _ = jsbay_value_release(buf_v);
        var copied: Bytes = .{ .data = null, .len = 0 };
        try std.testing.expectEqual(API_OK, jsbay_value_copy_buffer(buf_v, &copied, &exception));
        defer jsbay_free_bytes(copied);
        try std.testing.expectEqualSlices(u8, &payload, copied.data.?[0..copied.len]);

        var err: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_error(id, .{ .data = "x", .len = 1 }, &err));
        defer _ = jsbay_value_release(err);
        try std.testing.expect(packed_api_value.isPackedHandle(err));
    }
}

test "c_api: packed-alt adversarial get exception / bind / empty options / destroy stale" {
    const helpers = @import("tests/test_helpers.zig");
    const instance_map = @import("runtime/instance_map.zig");
    const event_loop = @import("js_event_loop");
    const timers = @import("runtime/timers.zig");
    const backend_dispatch = @import("backend_dispatch.zig");
    const id = helpers.nextInstanceId();
    const tag = backend.active_backend;
    const loop = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    const handles = backend_dispatch.createPacked(tag) orelse {
        loop.destroy();
        return error.CreatePackedFailed;
    };
    backend_dispatch.finishCreate(tag, handles, id, 256 * 1024);
    const instance = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        return error.Oom;
    };
    const resources = @import("runtime/resource_limits.zig").Budget.create(.{}) orelse {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        std.heap.c_allocator.destroy(instance);
        return error.BudgetFailed;
    };
    instance.* = .{
        .resources = resources,
        .instance_id = id,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles.runtime_addr, .ctx_addr = handles.ctx_addr } },
        .loop = loop,
        .timers = timers.TimerRegistry.init(),
    };
    if (!instance_map.insert(instance)) {
        backend_dispatch.destroyPacked(tag, handles);
        loop.destroy();
        resources.deinit();
        instance.deinitSynchronization();
        std.heap.c_allocator.destroy(instance);
        return error.InsertFailed;
    }
    try std.testing.expect(api_value.noteCreated(id));
    defer {
        if (instance_map.getInstance(id) != null) jsbay_engine_destroy(id);
    }

    var exception: u64 = 0;

    // Empty evaluate options must not be rejected as UNSUPPORTED on packed-alt.
    var empty_opts = EvalOptions{
        .struct_size = @sizeOf(EvalOptions),
        .cache_dir = .{ .data = null, .len = 0 },
        .cache_version = .{ .data = null, .len = 0 },
        .out_cache_hit = null,
    };
    var value: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "1", .len = 1 }, .{ .data = "<adv>", .len = 5 }, &empty_opts, &value, &exception));
    defer _ = jsbay_value_release(value);
    try std.testing.expectEqual(@as(u64, 0), exception);

    // Getter throw must surface as status 1 + exception handle (not silent undefined).
    var toxic: u64 = 0;
    const toxic_src = "({ get boom() { throw new Error('nope'); } })";
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = toxic_src.ptr, .len = toxic_src.len }, .{ .data = "<toxic>", .len = 7 }, null, &toxic, &exception));
    defer _ = jsbay_value_release(toxic);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var got: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 1), jsbay_value_get(toxic, .{ .data = "boom", .len = 4 }, &got, &exception));
    try std.testing.expectEqual(@as(u64, 0), got);
    try std.testing.expect(packed_api_value.isPackedHandle(exception));
    _ = jsbay_value_release(exception);
    exception = 0;

    // null/undefined receiver must TypeError (ToObject), not crash.
    var nul: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_null(id, &nul));
    defer _ = jsbay_value_release(nul);
    try std.testing.expectEqual(@as(c_int, 1), jsbay_value_get(nul, .{ .data = "x", .len = 1 }, &got, &exception));
    try std.testing.expectEqual(@as(u64, 0), got);
    try std.testing.expect(exception != 0);
    _ = jsbay_value_release(exception);
    exception = 0;

    // Number primitive boxes via ToObject; missing prop is undefined (not a throw, not a crash).
    var num: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 3, &num));
    defer _ = jsbay_value_release(num);
    try std.testing.expectEqual(API_OK, jsbay_value_get(num, .{ .data = "x", .len = 1 }, &got, &exception));
    defer _ = jsbay_value_release(got);
    try std.testing.expectEqual(@as(u64, 0), exception);
    var prim_kind: c_int = -1;
    try std.testing.expectEqual(API_OK, jsbay_value_type(got, &prim_kind));
    try std.testing.expectEqual(@as(c_int, 0), prim_kind);

    // Throwing toString must surface via to_utf8 exception path.
    var bad_str: u64 = 0;
    const bad_src = "({ toString() { throw new Error('bad'); } })";
    try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = bad_src.ptr, .len = bad_src.len }, .{ .data = "<bad>", .len = 5 }, null, &bad_str, &exception));
    defer _ = jsbay_value_release(bad_str);
    var utf8: Bytes = .{ .data = null, .len = 0 };
    try std.testing.expectEqual(@as(c_int, 1), jsbay_value_to_utf8(bad_str, &utf8, &exception));
    try std.testing.expect(utf8.data == null);
    try std.testing.expect(exception != 0);
    _ = jsbay_value_release(exception);
    exception = 0;

    // bind / platform-loop attach on packed-alt must be honest UNSUPPORTED (not INSTANCE_NOT_FOUND).
    var fn_out: u64 = 0;
    try std.testing.expectEqual(API_UNSUPPORTED, jsbay_engine_bind(id, .{ .data = "host", .len = 4 }, &bindOomCallback, null, null, &fn_out, &exception));
    try std.testing.expectEqual(@as(u64, 0), fn_out);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqual(API_UNSUPPORTED, jsbay_engine_attach_loop(id, &noopLoopSchedule, &noopLoopCancel, null));
    try std.testing.expectEqual(API_UNSUPPORTED, jsbay_engine_detach_loop(id));
    try std.testing.expectEqual(API_UNSUPPORTED, jsbay_engine_run_loop(id));

    // keys content: length === 1 after one own enumerable string key.
    var obj: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &obj));
    defer _ = jsbay_value_release(obj);
    var one: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 1, &one));
    defer _ = jsbay_value_release(one);
    try std.testing.expectEqual(API_OK, jsbay_value_set(obj, .{ .data = "k", .len = 1 }, one, &exception));
    var keys_arr: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_keys(obj, &keys_arr, &exception));
    defer _ = jsbay_value_release(keys_arr);
    var len_v: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_get(keys_arr, .{ .data = "length", .len = 6 }, &len_v, &exception));
    defer _ = jsbay_value_release(len_v);
    var len_n: f64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(len_v, &len_n));
    try std.testing.expectEqual(@as(f64, 1), len_n);

    // Empty keys array length === 0
    var empty_obj: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &empty_obj));
    defer _ = jsbay_value_release(empty_obj);
    var empty_keys: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_keys(empty_obj, &empty_keys, &exception));
    defer _ = jsbay_value_release(empty_keys);
    var empty_len_v: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_get(empty_keys, .{ .data = "length", .len = 6 }, &empty_len_v, &exception));
    defer _ = jsbay_value_release(empty_len_v);
    var empty_len_n: f64 = -1;
    try std.testing.expectEqual(API_OK, jsbay_value_to_number(empty_len_v, &empty_len_n));
    try std.testing.expectEqual(@as(f64, 0), empty_len_n);

    // Invalid JSON → status 1 + owned exception
    var bad_json: u64 = 0;
    try std.testing.expectEqual(@as(c_int, 1), jsbay_value_new_json(id, .{ .data = "{", .len = 1 }, &bad_json, &exception));
    try std.testing.expectEqual(@as(u64, 0), bad_json);
    try std.testing.expect(exception != 0);
    _ = jsbay_value_release(exception);
    exception = 0;

    // Zero-length ArrayBuffer copy_buffer
    var zbuf: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_array_buffer(id, &[_]u8{}, 0, &zbuf));
    defer _ = jsbay_value_release(zbuf);
    var zcopied: Bytes = .{ .data = null, .len = 0 };
    try std.testing.expectEqual(API_OK, jsbay_value_copy_buffer(zbuf, &zcopied, &exception));
    defer jsbay_free_bytes(zcopied);
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqual(@as(usize, 0), zcopied.len);

    // Cross-instance set must reject (STALE), not mix backends/ctx.
    const id2 = helpers.nextInstanceId();
    const loop2 = event_loop.Driver.create(std.heap.c_allocator) catch return error.LoopCreateFailed;
    const handles2 = backend_dispatch.createPacked(tag) orelse {
        loop2.destroy();
        return error.CreatePackedFailed;
    };
    backend_dispatch.finishCreate(tag, handles2, id2, 256 * 1024);
    const instance2 = std.heap.c_allocator.create(instance_map.EngineInstance) catch {
        backend_dispatch.destroyPacked(tag, handles2);
        loop2.destroy();
        return error.Oom;
    };
    const resources2 = @import("runtime/resource_limits.zig").Budget.create(.{}) orelse {
        backend_dispatch.destroyPacked(tag, handles2);
        loop2.destroy();
        std.heap.c_allocator.destroy(instance2);
        return error.BudgetFailed;
    };
    instance2.* = .{
        .resources = resources2,
        .instance_id = id2,
        .engine_handles = .{ .packed_alt = .{ .tag = tag, .runtime_addr = handles2.runtime_addr, .ctx_addr = handles2.ctx_addr } },
        .loop = loop2,
        .timers = timers.TimerRegistry.init(),
    };
    if (!instance_map.insert(instance2)) {
        backend_dispatch.destroyPacked(tag, handles2);
        loop2.destroy();
        resources2.deinit();
        instance2.deinitSynchronization();
        std.heap.c_allocator.destroy(instance2);
        return error.InsertFailed;
    }
    try std.testing.expect(api_value.noteCreated(id2));
    defer jsbay_engine_destroy(id2);
    var obj2: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_object(id2, &obj2));
    defer _ = jsbay_value_release(obj2);
    var foreign: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 9, &foreign));
    defer _ = jsbay_value_release(foreign);
    try std.testing.expectEqual(API_STALE_VALUE, jsbay_value_set(obj2, .{ .data = "k", .len = 1 }, foreign, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);

    // Double-release after single release
    var once: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 2, &once));
    try std.testing.expectEqual(API_OK, jsbay_value_release(once));
    try std.testing.expectEqual(API_STALE_VALUE, jsbay_value_release(once));

    // Retain a handle, destroy engine, then ops must be STALE (registry dropInstance).
    var live: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_bool(id, true, &live));
    try std.testing.expect(packed_api_value.isPackedHandle(live));
    jsbay_engine_destroy(id);
    var kind: c_int = -1;
    try std.testing.expectEqual(API_STALE_VALUE, jsbay_value_type(live, &kind));
    try std.testing.expectEqual(API_STALE_VALUE, jsbay_value_release(live));
}

test "c_api: packed-alt adversarial when real non-primary packed" {
    var backends_buf: [8]BackendC = undefined;
    const n = jsbay_available_backends(&backends_buf, backends_buf.len);
    const primary = backend.libraryBackendC();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (backends_buf[i] == primary) continue;
        const alt_id = @import("tests/test_helpers.zig").nextInstanceId();
        var create_opts = EngineCreateOptionsC{
            .struct_size = @sizeOf(EngineCreateOptionsC),
            .backend = backends_buf[i],
        };
        try std.testing.expect(jsbay_engine_create_with_options(alt_id, &create_opts));
        defer jsbay_engine_destroy(alt_id);
        var exception: u64 = 0;
        var toxic: u64 = 0;
        const toxic_src = "({ get boom() { throw new Error('alt-nope'); } })";
        try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(alt_id, .{ .data = toxic_src.ptr, .len = toxic_src.len }, .{ .data = "<alt-toxic>", .len = 11 }, null, &toxic, &exception));
        defer _ = jsbay_value_release(toxic);
        var got: u64 = 0;
        try std.testing.expectEqual(@as(c_int, 1), jsbay_value_get(toxic, .{ .data = "boom", .len = 4 }, &got, &exception));
        try std.testing.expect(exception != 0);
        defer _ = jsbay_value_release(exception);
        try std.testing.expectEqual(@as(u64, 0), got);

        var released: u64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_new_bool(alt_id, true, &released));
        try std.testing.expectEqual(API_OK, jsbay_value_release(released));
        var flag: bool = false;
        try std.testing.expectEqual(API_STALE_VALUE, jsbay_value_to_bool(released, &flag));

        try std.testing.expectEqual(API_UNSUPPORTED, jsbay_engine_bind(alt_id, .{ .data = "host", .len = 4 }, &bindOomCallback, null, null, &got, &exception));
    }
}

/// One-shot fault for the next property-key copy shared by set/has/delete.
const key_fault = if (builtin.is_test) struct {
    var fail_next_allocation = false;

    fn request() void {
        fail_next_allocation = true;
    }

    fn consume() bool {
        if (!fail_next_allocation) return false;
        fail_next_allocation = false;
        return true;
    }
} else struct {
    fn consume() bool {
        return false;
    }
};

/// Test-only C-string helpers support Zig regression suites. Production imports receive an empty namespace and only expose the typed execution API.
pub const test_only = if (builtin.is_test) struct {
    pub const advance = testAdvance;
    pub const setWakeHandler = testSetWakeHandler;
    pub const evalCStringUtf8 = testEvalCStringUtf8;
    pub const evalCString = testEvalCString;
    pub const evalCStringBytes = testEvalCStringBytes;
    pub const evalCStringFile = testEvalCStringFile;
    pub const evalCStringCached = testEvalCStringCached;
    pub const freeCString = testFreeCString;
    pub const threadId = testThreadId;
    pub const threadPost = testThreadPost;
    pub const threadWait = testThreadWait;
    pub const threadBarrier = testThreadBarrier;
    pub const threadRun = testThreadRun;
    pub const threadEvalCString = testThreadEvalCString;
    pub const dispatchCString = testDispatchCString;
    pub const failNextKeyAllocation = key_fault.request;
} else struct {};

// QuickJS measures this budget against the native stack pointer, so it must stay below common host thread stack sizes.
const C_API_ENGINE_MAX_STACK_SIZE: usize = 1 * 1024 * 1024;

const resource_limits = @import("runtime/resource_limits.zig");

pub const ResourceLimitsC = extern struct {
    struct_size: u32,
    max_timers: usize,
    max_tsfn_handles: usize,
    max_pending_calls: usize,
    max_pending_bytes: usize,
    max_pending_tasks: usize,
};

pub const ResourceUsageC = extern struct {
    struct_size: u32,
    timers: usize,
    tsfn_handles: usize,
    pending_calls: usize,
    native_tasks: usize,
    script_tasks: usize,
    pending_bytes: usize,
    max_timers: usize,
    max_tsfn_handles: usize,
    max_pending_calls: usize,
    max_pending_bytes: usize,
    max_pending_tasks: usize,
};

pub const ResourceGlobalUsageC = extern struct {
    struct_size: u32,
    timers: usize,
    tsfn_handles: usize,
    pending_calls: usize,
    native_tasks: usize,
    script_tasks: usize,
    pending_bytes: usize,
    max_timers: usize,
    max_tsfn_handles: usize,
    max_pending_calls: usize,
    max_native_tasks: usize,
    max_script_tasks: usize,
    max_pending_bytes: usize,
    fg_headroom_timers: usize = 0,
    fg_headroom_tsfn_handles: usize = 0,
    fg_headroom_pending_calls: usize = 0,
    fg_headroom_native_tasks: usize = 0,
    fg_headroom_script_tasks: usize = 0,
    fg_headroom_pending_bytes: usize = 0,
    bg_effective_max_timers: usize = 0,
    bg_effective_max_tsfn_handles: usize = 0,
    bg_effective_max_pending_calls: usize = 0,
    bg_effective_max_native_tasks: usize = 0,
    bg_effective_max_script_tasks: usize = 0,
    bg_effective_max_pending_bytes: usize = 0,
};

/// Legacy C layout ended at max_pending_bytes (before FG headroom fields).
pub const resource_global_usage_legacy_size = @offsetOf(ResourceGlobalUsageC, "fg_headroom_timers");

pub const AdmissionClassC = enum(c_int) {
    foreground = 0,
    background = 1,
    _,
};

pub const InstanceSnapshotC = extern struct {
    struct_size: u32,
    instance_id: c_int,
    generation: u64,
    owner_thread_id: u64,
    loop_mode: u8,
    flags: u8,
    admission_class: AdmissionClassC,
    timers_reserved: usize,
    timers_registered: usize,
    script_tasks_queued: usize,
    native_tasks_queued: usize,
    pending_bytes: usize,
    max_timers: usize,
    max_pending_tasks: usize,
    max_pending_bytes: usize,
};

fn limitsFromC(limits: ?*const ResourceLimitsC) ?resource_limits.Limits {
    const l = limits orelse return resource_limits.Limits{};
    if (l.struct_size < @sizeOf(ResourceLimitsC)) return null;
    return .{
        .max_timers = l.max_timers,
        .max_tsfn_handles = l.max_tsfn_handles,
        .max_pending_calls = l.max_pending_calls,
        .max_pending_bytes = l.max_pending_bytes,
        .max_pending_tasks = l.max_pending_tasks,
    };
}

fn cApiEngineConfig(
    log_handler: ?types.LogHandler,
    log_user_data: ?*anyopaque,
    limits: resource_limits.Limits,
) types.EngineConfig {
    return .{
        .log_handler = log_handler,
        .log_user_data = log_user_data,
        .max_stack_size = C_API_ENGINE_MAX_STACK_SIZE,
        .resource_limits = limits,
    };
}

// ---- Lifecycle ----

pub const VersionInfo = extern struct {
    struct_size: u32,
    version: ?[*:0]const u8 = null,
    commit: ?[*:0]const u8 = null,
    backend: ?[*:0]const u8 = null,
};

const version_z: [:0]const u8 = @import("build_options").package_version ++ "\x00";
const commit_z: [:0]const u8 = @import("build_options").git_commit ++ "\x00";
const backend_z: [:0]const u8 = @import("build_options").backend_name ++ "\x00";

/// Fill `out` with process-wide build identity. See `include/jsbay.h`.
pub export fn jsbay_engine_version(out: ?*VersionInfo) bool {
    const info = out orelse return false;
    // Do not touch fields when struct_size is too small: a C caller may have allocated only the prefix.
    if (info.struct_size < @sizeOf(VersionInfo)) return false;
    info.version = version_z.ptr;
    info.commit = commit_z.ptr;
    info.backend = backend_z.ptr;
    return true;
}

test "c_api: engine version reports package backend and stable pointers" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(VersionInfo, "struct_size"));
    try std.testing.expectEqual(@alignOf(?[*:0]const u8), @offsetOf(VersionInfo, "version"));
    try std.testing.expectEqual(@offsetOf(VersionInfo, "version") + @sizeOf(?[*:0]const u8), @offsetOf(VersionInfo, "commit"));
    try std.testing.expectEqual(@offsetOf(VersionInfo, "commit") + @sizeOf(?[*:0]const u8), @offsetOf(VersionInfo, "backend"));
    var info = VersionInfo{ .struct_size = @sizeOf(VersionInfo) };
    try std.testing.expect(jsbay_engine_version(&info));
    const version = info.version orelse return error.MissingVersion;
    const commit = info.commit orelse return error.MissingCommit;
    const backend_name = info.backend orelse return error.MissingBackend;
    try std.testing.expectEqualStrings(@import("build_options").package_version, std.mem.span(version));
    try std.testing.expectEqualStrings(@import("build_options").git_commit, std.mem.span(commit));
    try std.testing.expectEqualStrings(@import("build_options").backend_name, std.mem.span(backend_name));
    try std.testing.expectEqualStrings(@tagName(backend.active_backend), std.mem.span(backend_name));

    var again = VersionInfo{ .struct_size = @sizeOf(VersionInfo) };
    try std.testing.expect(jsbay_engine_version(&again));
    try std.testing.expect(info.version == again.version);
    try std.testing.expect(info.commit == again.commit);
    try std.testing.expect(info.backend == again.backend);

    var too_small = VersionInfo{ .struct_size = 0 };
    try std.testing.expect(!jsbay_engine_version(&too_small));
    try std.testing.expect(!jsbay_engine_version(null));
}

pub export fn jsbay_engine_create(
    instance_id: c_int,
    log_handler: ?types.LogHandler,
    log_user_data: ?*anyopaque,
) bool {
    return jsbay_engine_create_with_limits(instance_id, log_handler, log_user_data, null);
}

pub export fn jsbay_engine_create_with_limits(
    instance_id: c_int,
    log_handler: ?types.LogHandler,
    log_user_data: ?*anyopaque,
    limits: ?*const ResourceLimitsC,
) bool {
    if (host_wake.isNotifying()) return false;
    const parsed = limitsFromC(limits) orelse return false;
    const id: i32 = @intCast(instance_id);
    if (!engine.create(id, cApiEngineConfig(log_handler, log_user_data, parsed))) return false;
    if (!runtime_control.init(id)) {
        engine.destroy(id);
        return false;
    }
    if (!api_value.noteCreated(id)) {
        engine.destroy(id);
        return false;
    }
    if (log_handler) |lh| lh(id, .info, "jsbay create ok", log_user_data);
    return true;
}

test "c_api: engine creation keeps recursion below native stack limits" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return error.SkipZigTest;
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    try std.testing.expect(jsbay_engine_create(id, null, null));
    defer jsbay_engine_destroy(id);

    var stack_error: ?[*:0]const u8 = null;
    const recursive_result = testEvalCString(
        id,
        "(function recurse(){ return recurse(); })()",
        "<c-api-stack>",
        &stack_error,
    );
    defer if (recursive_result) |result| testFreeCString(result);
    defer if (stack_error) |message| testFreeCString(message);
    try std.testing.expect(recursive_result == null);
    const message = stack_error orelse return error.ExpectedStackOverflow;
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(message), "stack") != null);

    var recovery_error: ?[*:0]const u8 = null;
    const recovery_result = testEvalCString(id, "40+2", "<c-api-recovery>", &recovery_error);
    defer if (recovery_result) |result| testFreeCString(result);
    defer if (recovery_error) |error_message| testFreeCString(error_message);
    try std.testing.expect(recovery_error == null);
    const result = recovery_result orelse return error.ExpectedRecoveryResult;
    try std.testing.expectEqualStrings("42", std.mem.span(result));
}

pub export fn jsbay_engine_destroy(instance_id: c_int) void {
    if (host_wake.isNotifying()) return;
    const id: i32 = @intCast(instance_id);
    // Owner-thread destroy is the common path (release values first, then destroy). A non-owner
    // may also destroy: it closes admission and joins teardown so "destroy then Worker.terminate"
    // does not kill an owner still inside run_loop or deferred cleanup. Attached-loop detach
    // stays on the owner when this is the owner thread; destroyRuntime detaches after loop
    // scopes have drained when destroy runs elsewhere.
    if (api_value.isOwner(id)) {
        engine.detachLoop(id);
    } else if (!api_value.hasOwner(id) and engine.getContext(id) == null) {
        // No live public instance. Still enter engine.destroy so a racer can join a deferred
        // teardown whose owners were already dropped.
        engine.destroy(id);
        return;
    }
    // Runtime destruction can be deferred until a host callback unwinds, but foreign hosts may release notification userdata as soon as this returns.
    host_wake.drop(id);
    // Engine.destroy defers physical teardown while a native callback is on the JS stack. Close the public ABI immediately so its outer operation cannot publish a just-created Value after that callback returns.
    @import("runtime/instance_map.zig").markTeardownPending(id);
    // destroy may be deferred until this callback unwinds, so wake a sync native wait now rather than waiting for engine.destroyNow().
    native_sync.cancelForInstance(id);
    engine.destroy(id);
}

/// Listen for a DevTools connection. `port` 0 picks an ephemeral port. On success, `out_port` receives the bound port when it is non-NULL. A connected client sends Debugger.enable to arm `debugger;` statements. Returns false when the instance is missing or an inspector is already up.
pub export fn jsbay_engine_inspector_start(instance_id: c_int, port: u16, out_port: ?*u16) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    if (engine.getContext(id) == null) return false;
    const handle = inspector_mod.start(id, .{ .port = port }) catch return false;
    if (out_port) |slot| slot.* = inspector_mod.boundPort(handle);
    return true;
}

/// Close the inspector for this instance. Safe if none is running.
pub export fn jsbay_engine_inspector_stop(instance_id: c_int) void {
    if (!api_value.isOwner(@intCast(instance_id))) return;
    inspector_mod.dropInstance(@intCast(instance_id));
}

pub const LoopTask = *const fn (?*anyopaque) callconv(.c) void;
pub const LoopSchedule = *const fn (?*anyopaque, u64, LoopTask, ?*anyopaque) callconv(.c) bool;
pub const LoopCancel = *const fn (?*anyopaque) callconv(.c) void;

pub export fn jsbay_engine_attach_loop(instance_id: c_int, schedule: ?LoopSchedule, cancel: ?LoopCancel, user_data: ?*anyopaque) c_int {
    const id: i32 = @intCast(instance_id);
    if (schedule == null or cancel == null) return API_INVALID_ARGUMENT;
    if (packedTagOf(id) != null) return API_UNSUPPORTED;
    if (engine.getContext(id) == null or @import("runtime/instance_map.zig").isTeardownPending(id)) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    engine.attachLoop(id, .{ .context = user_data, .schedule = schedule.?, .cancel = cancel.? }) catch |err| {
        if (err == error.ScheduleFailed) {
            @import("runtime/engine_events.zig").fireLoopFailed(id);
            return API_LOOP_FAILED;
        }
        return API_INVALID_ARGUMENT;
    };
    return API_OK;
}

pub export fn jsbay_engine_detach_loop(instance_id: c_int) c_int {
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) return API_UNSUPPORTED;
    if (engine.getContext(id) == null) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    engine.detachLoop(id);
    return API_OK;
}

pub export fn jsbay_engine_loop_status(instance_id: c_int) c_int {
    const id: i32 = @intCast(instance_id);
    const inst = @import("runtime/instance_map.zig").getInstance(id) orelse return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    // LOOP_FAILED events are emitted from attach/run failure paths to avoid per-poll spam.
    return if (inst.loop.lastError() != null) API_LOOP_FAILED else API_OK;
}

pub export fn jsbay_engine_run_loop(instance_id: c_int) c_int {
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) return API_UNSUPPORTED;
    if (engine.getContext(id) == null or @import("runtime/instance_map.zig").isTeardownPending(id)) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    const inst = @import("runtime/instance_map.zig").getInstance(id) orelse return API_INSTANCE_NOT_FOUND;
    if (inst.loop.lastError() != null) return API_LOOP_FAILED;
    if (inst.loop.isAttached()) return API_INVALID_ARGUMENT;
    engine.runEventLoopChecked(id) catch |err| {
        if (err == error.ScheduleFailed) {
            @import("runtime/engine_events.zig").fireLoopFailed(id);
            return API_LOOP_FAILED;
        }
        return API_INVALID_ARGUMENT;
    };
    return API_OK;
}

pub export fn jsbay_engine_stop_loop(instance_id: c_int) bool {
    // Control-plane lease: refuse teardown_pending and keep Driver alive until this returns.
    // requestStop only touches Driver state (no Host callbacks); still operate outside the registry mutex.
    const lease = @import("runtime/instance_map.zig").beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    lease.ptrs.loop.requestStop();
    return true;
}

/// Thread-safe keep-alive pause. Soft-cancels a pending platform schedule (Host.cancel must remain reusable) without detaching or clearing timers/tasks/VM state.
pub export fn jsbay_engine_suspend(instance_id: c_int) bool {
    // R2/R3: control-plane lease refuses teardown; never hold the instance-map mutex across Host.cancel.
    const lease = @import("runtime/instance_map.zig").beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    lease.ptrs.loop.suspendScheduling();
    return true;
}

/// Thread-safe resume after `jsbay_engine_suspend`. Re-schedules attached work for monotonic catch-up; does not recreate the engine.
pub export fn jsbay_engine_resume(instance_id: c_int) bool {
    // R2/R3: resume may Host.schedule; lease keeps Driver alive off the registry mutex.
    const lease = @import("runtime/instance_map.zig").beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    lease.ptrs.loop.resumeScheduling();
    return true;
}

/// Thread-safe. Returns false when the instance is missing, teardown-pending, or not suspended.
pub export fn jsbay_engine_is_suspended(instance_id: c_int) bool {
    const lease = @import("runtime/instance_map.zig").beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    return lease.ptrs.loop.isSuspended();
}

fn testSetWakeHandler(instance_id: c_int, handler: ?host_wake.Handler, user_data: ?*anyopaque) c_int {
    if (host_wake.isNotifying()) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    if (@import("runtime/instance_map.zig").isTeardownPending(id) or engine.getContext(id) == null) return API_INSTANCE_NOT_FOUND;
    if (!api_value.isOwner(id)) return API_WRONG_THREAD;
    host_wake.set(id, handler, user_data) catch return API_OUT_OF_MEMORY;
    return API_OK;
}

/// Thread-safe control-plane request. The engine owner observes the flag from its backend interrupt handler and turns the running evaluation into an exception; this function never waits for the JavaScript thread.
pub export fn jsbay_engine_request_interrupt(instance_id: c_int) bool {
    const id: i32 = @intCast(instance_id);
    const accepted = runtime_control.requestInterrupt(id);
    if (accepted) {
        native_sync.cancelForInstance(id);
        @import("runtime/engine_events.zig").fireInterrupted(id, 0, "interrupt requested");
    }
    return accepted;
}

/// Clear a previously requested interrupt before evaluating more JavaScript.
pub export fn jsbay_engine_clear_interrupt(instance_id: c_int) bool {
    if (!api_value.isOwner(@intCast(instance_id))) return false;
    return runtime_control.clearInterrupt(@intCast(instance_id));
}

/// Arm a relative execution limit without blocking the caller. Zero disables the limit. The backend interrupt handler owns enforcement.
pub export fn jsbay_engine_set_execution_time_limit(instance_id: c_int, millis: u64) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    const accepted = runtime_control.setExecutionTimeLimit(id, millis);
    if (accepted) if (runtime_control.executionDeadlineMillis(id)) |deadline| {
        native_sync.tightenDeadlinesForInstance(id, deadline);
    };
    return accepted;
}

/// Cap the runtime's heap at `bytes` (0 = unlimited). QuickJS enforces it via JS_SetMemoryLimit. JSC has no public heap-cap API and returns false (same contract as `runtime_control.setMemoryLimit` / the C header).
pub export fn jsbay_engine_set_memory_limit(instance_id: c_int, bytes: u64) bool {
    if (!api_value.isOwner(@intCast(instance_id))) return false;
    return runtime_control.setMemoryLimit(@intCast(instance_id), bytes);
}

pub export fn jsbay_engine_set_resource_limits(instance_id: c_int, limits: ?*const ResourceLimitsC) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    const parsed = limitsFromC(limits) orelse return false;
    // limitsFromC(null) yields defaults; set requires an explicit struct.
    if (limits == null) return false;
    const inst = @import("runtime/instance_map.zig").getInstance(id) orelse return false;
    inst.resources.setLimits(parsed);
    return true;
}

pub export fn jsbay_engine_get_resource_usage(instance_id: c_int, out: ?*ResourceUsageC) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    const slot = out orelse return false;
    if (slot.struct_size < @sizeOf(ResourceUsageC)) return false;
    const inst = @import("runtime/instance_map.zig").getInstance(id) orelse return false;
    const snap = inst.resources.usage();
    slot.* = .{
        .struct_size = @sizeOf(ResourceUsageC),
        .timers = snap.counts[@backingInt(resource_limits.Kind.timer)],
        .tsfn_handles = snap.counts[@backingInt(resource_limits.Kind.tsfn_handle)],
        .pending_calls = snap.counts[@backingInt(resource_limits.Kind.tsfn_call)],
        .native_tasks = snap.counts[@backingInt(resource_limits.Kind.native_task)],
        .script_tasks = snap.counts[@backingInt(resource_limits.Kind.script_task)],
        .pending_bytes = snap.bytes,
        .max_timers = snap.limits.max_timers,
        .max_tsfn_handles = snap.limits.max_tsfn_handles,
        .max_pending_calls = snap.limits.max_pending_calls,
        .max_pending_bytes = snap.limits.max_pending_bytes,
        .max_pending_tasks = snap.limits.max_pending_tasks,
    };
    return true;
}

pub export fn jsbay_resource_global_usage(out: ?*ResourceGlobalUsageC) bool {
    const slot = out orelse return false;
    if (slot.struct_size < resource_global_usage_legacy_size) return false;
    const snap = resource_limits.globalUsage();
    const want_headroom = slot.struct_size >= @sizeOf(ResourceGlobalUsageC);
    const written_size: u32 = if (want_headroom) @sizeOf(ResourceGlobalUsageC) else @intCast(resource_global_usage_legacy_size);
    // Fill legacy fields first (always).
    slot.timers = snap.counts[@backingInt(resource_limits.Kind.timer)];
    slot.tsfn_handles = snap.counts[@backingInt(resource_limits.Kind.tsfn_handle)];
    slot.pending_calls = snap.counts[@backingInt(resource_limits.Kind.tsfn_call)];
    slot.native_tasks = snap.counts[@backingInt(resource_limits.Kind.native_task)];
    slot.script_tasks = snap.counts[@backingInt(resource_limits.Kind.script_task)];
    slot.pending_bytes = snap.bytes;
    slot.max_timers = snap.caps[@backingInt(resource_limits.Kind.timer)];
    slot.max_tsfn_handles = snap.caps[@backingInt(resource_limits.Kind.tsfn_handle)];
    slot.max_pending_calls = snap.caps[@backingInt(resource_limits.Kind.tsfn_call)];
    slot.max_native_tasks = snap.caps[@backingInt(resource_limits.Kind.native_task)];
    slot.max_script_tasks = snap.caps[@backingInt(resource_limits.Kind.script_task)];
    slot.max_pending_bytes = snap.byte_cap;
    if (want_headroom) {
        slot.fg_headroom_timers = snap.fg_headrooms[@backingInt(resource_limits.Kind.timer)];
        slot.fg_headroom_tsfn_handles = snap.fg_headrooms[@backingInt(resource_limits.Kind.tsfn_handle)];
        slot.fg_headroom_pending_calls = snap.fg_headrooms[@backingInt(resource_limits.Kind.tsfn_call)];
        slot.fg_headroom_native_tasks = snap.fg_headrooms[@backingInt(resource_limits.Kind.native_task)];
        slot.fg_headroom_script_tasks = snap.fg_headrooms[@backingInt(resource_limits.Kind.script_task)];
        slot.fg_headroom_pending_bytes = snap.fg_byte_headroom;
        slot.bg_effective_max_timers = snap.bg_effective_caps[@backingInt(resource_limits.Kind.timer)];
        slot.bg_effective_max_tsfn_handles = snap.bg_effective_caps[@backingInt(resource_limits.Kind.tsfn_handle)];
        slot.bg_effective_max_pending_calls = snap.bg_effective_caps[@backingInt(resource_limits.Kind.tsfn_call)];
        slot.bg_effective_max_native_tasks = snap.bg_effective_caps[@backingInt(resource_limits.Kind.native_task)];
        slot.bg_effective_max_script_tasks = snap.bg_effective_caps[@backingInt(resource_limits.Kind.script_task)];
        slot.bg_effective_max_pending_bytes = snap.bg_effective_byte_cap;
    }
    slot.struct_size = written_size;
    return true;
}

/// Any thread. Future admissions only; does not drop live reservations. Does not auto-flip on suspend/resume.
pub export fn jsbay_engine_set_admission_class(instance_id: c_int, cls: c_int) bool {
    const class: resource_limits.AdmissionClass = switch (cls) {
        @backingInt(AdmissionClassC.foreground) => .foreground,
        @backingInt(AdmissionClassC.background) => .background,
        else => return false,
    };
    const lease = @import("runtime/instance_map.zig").beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    lease.inst.resources.setAdmissionClass(class);
    return true;
}

pub export fn jsbay_engine_get_admission_class(instance_id: c_int, out: ?*AdmissionClassC) bool {
    const slot = out orelse return false;
    const lease = @import("runtime/instance_map.zig").beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    slot.* = switch (lease.inst.resources.admissionClass()) {
        .foreground => .foreground,
        .background => .background,
    };
    return true;
}

/// Any thread. Returns total live instances; writes up to `cap` ids when `out_ids` is non-null.
pub export fn jsbay_engine_list(out_ids: ?[*]c_int, cap: usize) usize {
    const instance_map = @import("runtime/instance_map.zig");
    if (out_ids) |buf| return instance_map.listIds(@ptrCast(buf), cap);
    return instance_map.listIds(null, 0);
}

/// Any thread. Control-plane lease refuses teardown_pending and keeps Driver alive for the scalar copy.
pub export fn jsbay_engine_snapshot(instance_id: c_int, out: ?*InstanceSnapshotC) bool {
    const slot = out orelse return false;
    if (slot.struct_size < @sizeOf(InstanceSnapshotC)) return false;
    const instance_map = @import("runtime/instance_map.zig");
    const lease = instance_map.beginControlPlane(@intCast(instance_id)) orelse return false;
    defer lease.end();
    const inst = lease.inst;
    const ctrl = lease.ptrs.loop.controlSnapshot();
    // bit2 teardown_pending is intentionally unused: beginControlPlane refuses teardown, so it is never observable here.
    const flags = ctrl.flags;

    inst.task_mutex.lock();
    const script_queued = inst.task_queue.items.items.len;
    inst.task_mutex.unlock();

    inst.native_task_queue.mutex.lock();
    const native_queued = inst.native_task_queue.items.items.len;
    inst.native_task_queue.mutex.unlock();

    // Timer HashMap put/remove/cancelAll mutate under the instance-map registry mutex (withInstance). Sample under that lock.
    const timers_reg = instance_map.withInstanceReturn(@as(i32, @intCast(instance_id)), struct {
        pub fn call(_: @This(), sample: *instance_map.EngineInstance) ?usize {
            return sample.timers.entries.count();
        }
    }{}) orelse 0;
    const usage = inst.resources.usage();
    const owner_tid = api_value.ownerThreadId(@intCast(instance_id)) orelse 0;
    const class: AdmissionClassC = switch (inst.resources.admissionClass()) {
        .foreground => .foreground,
        .background => .background,
    };

    slot.* = .{
        .struct_size = @sizeOf(InstanceSnapshotC),
        .instance_id = instance_id,
        .generation = inst.generation,
        .owner_thread_id = owner_tid,
        .loop_mode = ctrl.mode,
        .flags = flags,
        .admission_class = class,
        .timers_reserved = usage.counts[@backingInt(resource_limits.Kind.timer)],
        .timers_registered = timers_reg,
        .script_tasks_queued = script_queued,
        .native_tasks_queued = native_queued,
        .pending_bytes = usage.bytes,
        .max_timers = usage.limits.max_timers,
        .max_pending_tasks = usage.limits.max_pending_tasks,
        .max_pending_bytes = usage.limits.max_pending_bytes,
    };
    return true;
}

/// Owner-thread memory snapshot. Fills zeros first; false when missing, wrong thread, or null out.
pub const MemoryUsageC = extern struct {
    struct_size: u32,
    malloc_count: u64 = 0,
    malloc_size: u64 = 0,
    malloc_limit: u64 = 0,
    memory_used_count: u64 = 0,
    memory_used_size: u64 = 0,
    atom_count: u64 = 0,
    atom_size: u64 = 0,
    obj_count: u64 = 0,
    obj_size: u64 = 0,
    shape_count: u64 = 0,
};

pub export fn jsbay_engine_get_memory_usage(instance_id: c_int, out_usage: ?*MemoryUsageC) bool {
    const out = out_usage orelse return false;
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    const caller_size = out.struct_size;
    if (caller_size < 4) return false;
    const snap = runtime_control.getMemoryUsage(id) orelse return false;
    var filled = MemoryUsageC{
        .struct_size = caller_size,
        .malloc_count = snap.malloc_count,
        .malloc_size = snap.malloc_size,
        .malloc_limit = snap.malloc_limit,
        .memory_used_count = snap.memory_used_count,
        .memory_used_size = snap.memory_used_size,
        .atom_count = snap.atom_count,
        .atom_size = snap.atom_size,
        .obj_count = snap.obj_count,
        .obj_size = snap.obj_size,
        .shape_count = snap.shape_count,
    };
    const copy_len = @min(caller_size, @sizeOf(MemoryUsageC));
    const src: [*]const u8 = @ptrCast(&filled);
    const dst: [*]u8 = @ptrCast(out);
    @memset(dst[0..caller_size], 0);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    out.struct_size = caller_size;
    return true;
}

/// Owner-thread forced GC. Returns false when missing or wrong thread.
pub export fn jsbay_engine_run_gc(instance_id: c_int) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    return runtime_control.runGc(id);
}

const engine_events = @import("runtime/engine_events.zig");

/// Owner-thread telemetry handler registration. Pass null handler to clear.
pub export fn jsbay_engine_set_event_handler(
    instance_id: c_int,
    handler: ?types.EngineEventHandler,
    user_data: ?*anyopaque,
) bool {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return false;
    if (@import("runtime/instance_map.zig").getInstance(id) == null) return false;
    return engine_events.setHandler(id, handler, user_data);
}

fn maybeFireInterrupted(id: i32) void {
    if (runtime_control.isInterruptRequested(id)) {
        engine_events.fireInterrupted(id, 0, "interrupt requested");
        return;
    }
    if (runtime_control.remainingExecutionLimitMillis(id)) |remaining| {
        if (remaining == 0) engine_events.fireInterrupted(id, 0, "execution time limit");
    }
}

fn maybeFireMemoryLimit(id: i32, status: c_int) void {
    const usage = runtime_control.getMemoryUsage(id) orelse return;
    if (usage.malloc_limit == 0) return;
    engine_events.fireMemoryLimit(id, usage.malloc_limit, @intCast(status));
}

// ---- Evaluation ----

/// Copy an `EvalResult` into the malloc'd C-string contract used by `testEvalCString`. The caller frees both strings with `testFreeCString`.
fn publishEvalResult(result: types.EvalResult, out_error: ?*?[*:0]const u8) ?[*:0]const u8 {
    if (out_error) |ep| ep.* = null;
    if (result.err) |err_slice| {
        if (out_error) |ep| {
            ep.* = sliceToCString(err_slice);
        }
        if (result.err_is_heap) {
            std.heap.c_allocator.free(@constCast(err_slice));
        }
        return null;
    }

    if (result.result) |res_slice| {
        const cstr = sliceToCString(res_slice);
        std.heap.c_allocator.free(@constCast(res_slice));
        return cstr;
    }

    return null;
}

fn publishCachedEvalResult(result: cache_mod.CachedEvalResult, out_error: ?*?[*:0]const u8) ?[*:0]const u8 {
    return publishEvalResult(.{ .result = result.result, .err = result.err, .err_is_heap = result.err_is_heap }, out_error);
}

fn scriptBytes(script: [*]const u8, script_len: usize) []const u8 {
    if (script_len == 0) return "";
    return script[0..script_len];
}

pub const Utf8 = extern struct {
    data: ?[*]const u8,
    len: usize,
};
pub const Bytes = extern struct {
    data: ?[*]u8,
    len: usize,
};

pub const EvalOptions = extern struct {
    struct_size: u32,
    cache_dir: Utf8,
    cache_version: Utf8,
    out_cache_hit: ?*bool,
};

fn checkedUtf8(value: Utf8) ?[]const u8 {
    if (value.data) |data| return data[0..value.len];
    return if (value.len == 0) "" else null;
}

fn invalidEvalArguments(out_error: ?*?[*:0]const u8, message: []const u8) ?[*:0]const u8 {
    if (out_error) |slot| slot.* = sliceToCString(message);
    return null;
}

/// The canonical C evaluation entry point. `options` is optional; when it enables caching, cache directory and cache version must be supplied together.
fn testEvalCStringUtf8(
    instance_id: c_int,
    source_arg: Utf8,
    filename_arg: Utf8,
    options: ?*const EvalOptions,
    out_error: ?*?[*:0]const u8,
) ?[*:0]const u8 {
    if (out_error) |slot| slot.* = null;
    const source = checkedUtf8(source_arg) orelse return invalidEvalArguments(out_error, "source.data is null with non-zero length");
    const filename = checkedUtf8(filename_arg) orelse return invalidEvalArguments(out_error, "filename.data is null with non-zero length");

    if (options) |opts| {
        if (opts.out_cache_hit) |hit| hit.* = false;
        if (opts.struct_size < @sizeOf(EvalOptions)) return invalidEvalArguments(out_error, "eval options struct_size is too small");
        const cache_dir = checkedUtf8(opts.cache_dir) orelse return invalidEvalArguments(out_error, "cache_dir.data is null with non-zero length");
        const cache_version = checkedUtf8(opts.cache_version) orelse return invalidEvalArguments(out_error, "cache_version.data is null with non-zero length");
        const cache_enabled = cache_dir.len != 0 or cache_version.len != 0;
        if (cache_enabled and (cache_dir.len == 0 or cache_version.len == 0)) return invalidEvalArguments(out_error, "cache_dir and cache_version must both be non-empty");
        if (cache_enabled) {
            const result = cache_mod.evalCached(@intCast(instance_id), source, filename, cache_dir, cache_version);
            if (opts.out_cache_hit) |hit| hit.* = result.cache_hit;
            return publishCachedEvalResult(result, out_error);
        }
    }
    return publishEvalResult(engine.evalScript(@intCast(instance_id), source, filename), out_error);
}

/// Evaluate a script and return the result as a null-terminated C string. On success: returns the result string (caller must free with `testFreeCString`). On error: returns null and writes the error message to `out_error` (also must be freed). If both result and error are null, the script returned undefined/void.
fn testEvalCString(
    instance_id: c_int,
    script: [*:0]const u8,
    filename: [*:0]const u8,
    out_error: ?*?[*:0]const u8,
) callconv(.c) ?[*:0]const u8 {
    return testEvalCStringUtf8(instance_id, .{ .data = script, .len = std.mem.len(script) }, .{ .data = filename, .len = std.mem.len(filename) }, null, out_error);
}

/// Evaluate a pointer+length script buffer. `script` need not be NUL-terminated; only `script_len` bytes are the program. `filename` is a display name. Result contract matches `testEvalCString` (free with `testFreeCString`).
fn testEvalCStringBytes(
    instance_id: c_int,
    script: [*]const u8,
    script_len: usize,
    filename: [*:0]const u8,
    out_error: ?*?[*:0]const u8,
) ?[*:0]const u8 {
    return testEvalCStringUtf8(instance_id, .{ .data = script, .len = script_len }, .{ .data = filename, .len = std.mem.len(filename) }, null, out_error);
}

/// Evaluate the script stored at a filesystem path via `engine.evalFile`. Result contract matches `testEvalCString` (free with `testFreeCString`).
fn testEvalCStringFile(
    instance_id: c_int,
    path: [*:0]const u8,
    out_error: ?*?[*:0]const u8,
) ?[*:0]const u8 {
    const result = engine.evalFile(@intCast(instance_id), std.mem.span(path));
    return publishEvalResult(result, out_error);
}

/// Evaluate `script` (a named engine-level script such as an asset bundle) via the engine-side bytecode cache at `cache_dir`.
///
/// Compiles once, persists `<version>-<sha256(script)>.bc` under `cache_dir`, and replays the bytes on later calls — skipping re-parse. Deterministic (named) scripts only: content-addressed, so anything with per-call-variant content would never hit and only bloat the dir.
///
/// On any cache/compile failure it degrades to a plain eval, so enabling this can never break cold start. `out_cache_hit` reports whether the cached variant ran (for telemetry); `out_error` carries the eval error message, same contract as `testEvalCString`.
fn testEvalCStringCached(
    instance_id: c_int,
    script: [*]const u8,
    script_len: usize,
    filename: [*:0]const u8,
    cache_dir: [*]const u8,
    cache_dir_len: usize,
    version: [*]const u8,
    version_len: usize,
    out_error: ?*?[*:0]const u8,
    out_cache_hit: ?*bool,
) callconv(.c) ?[*:0]const u8 {
    var options = EvalOptions{ .struct_size = @sizeOf(EvalOptions), .cache_dir = .{ .data = cache_dir, .len = cache_dir_len }, .cache_version = .{ .data = version, .len = version_len }, .out_cache_hit = out_cache_hit };
    return testEvalCStringUtf8(instance_id, .{ .data = script, .len = script_len }, .{ .data = filename, .len = std.mem.len(filename) }, &options, out_error);
}

// ---- Memory ----

/// Free a string returned by `testEvalCString`, `testEvalCStringBytes`, or `testEvalCStringFile`.
fn testFreeCString(s: ?[*:0]const u8) callconv(.c) void {
    if (s) |ptr| {
        // Recover the full sentinel-terminated slice from the pointer
        const slice = std.mem.span(ptr);
        // Free the allocation (len + 1 for sentinel)
        std.heap.c_allocator.free(@constCast(slice[0 .. slice.len + 1]));
    }
}

fn testAdvance(instance_id: c_int, now_ms: i64) i64 {
    const id: i32 = @intCast(instance_id);
    if (!api_value.isOwner(id)) return -1;
    return engine.testing.advance(id, now_ms);
}

const API_OK: c_int = 0;
const API_EXCEPTION: c_int = 1;
const API_INVALID_ARGUMENT: c_int = 2;
const API_WRONG_THREAD: c_int = 3;
const API_INSTANCE_NOT_FOUND: c_int = 4;
const API_STALE_VALUE: c_int = 5;
const API_OUT_OF_MEMORY: c_int = 6;
const API_UNSUPPORTED: c_int = 7;
const API_LOOP_FAILED: c_int = 8;

const ApiOp = struct {
    id: i32,
    ctx: ActiveEngine.Context,
    lease: engine_thread.EvalLease,
    entered_js: bool,
    execution: ?@import("js_event_loop").Scheduler.Execution = null,

    fn endExecution(self: *ApiOp) void {
        if (self.execution) |*guard| guard.end();
        self.execution = null;
    }

    fn deinit(self: *ApiOp) void {
        if (self.execution != null) {
            self.endExecution();
            @import("runtime/js_scheduler.zig").checkpoint(self.id, self.ctx);
        }
        // Raw typed operations below use backend C APIs directly.  Keep the QuickJS stack anchor around the entire admission lease, including re-entrant getter/toString/native-callback execution.
        if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
            if (self.entered_js) backend.ActiveEngineModule.lifecycle.leaveJs(self.ctx);
        }
        engine.finishEvalEntry(self.id, self.lease);
    }
};

fn beginApiOp(id: i32) union(enum) { ok: ApiOp, status: c_int } {
    if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
    if (@import("runtime/instance_map.zig").isTeardownPending(id)) return .{ .status = API_INSTANCE_NOT_FOUND };
    if (!api_value.isOwner(id)) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    if (@import("runtime/instance_map.zig").getInstance(id)) |inst| {
        if (inst.loop.lastError() != null) return .{ .status = API_LOOP_FAILED };
    }
    const lease = engine_thread.beginEval(id);
    if (!lease.allowed) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    const ctx = engine.getContext(id) orelse {
        engine.finishEvalEntry(id, lease);
        return .{ .status = API_INSTANCE_NOT_FOUND };
    };
    const entered_js = if (comptime backend.isQuickJsApiBackend(backend.active_backend)) backend.ActiveEngineModule.lifecycle.enterJs(ctx) else true;
    if (!entered_js) {
        engine.finishEvalEntry(id, lease);
        return .{ .status = API_WRONG_THREAD };
    }
    return .{ .ok = .{ .id = id, .ctx = ctx, .lease = lease, .entered_js = entered_js, .execution = @import("runtime/js_scheduler.zig").beginExecution(id) } };
}

fn apiContext(instance_id: i32) union(enum) { ok: ActiveEngine.Context, status: c_int } {
    const ptrs = @import("runtime/instance_map.zig").getPtrs(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
    if (!api_value.isOwner(instance_id)) return .{ .status = API_WRONG_THREAD };
    return .{ .ok = ptrs.ctx };
}

/// Resolve a public handle while keeping the runtime admitted for the whole operation.  A handle lookup alone is not sufficient: a callback may ask to destroy its engine and otherwise leave the remainder of this API call with a freed context.
const ValueOp = struct {
    op: ApiOp,
    value: ActiveEngine.Value,

    fn deinit(self: *ValueOp) void {
        ActiveEngine.freeValue(self.op.ctx, self.value);
        self.op.deinit();
    }
};

fn beginValueOp(handle: u64) union(enum) { ok: ValueOp, status: c_int } {
    const entry = api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
    var op = switch (beginApiOp(entry.instance_id)) {
        .status => |status| return .{ .status = status },
        .ok => |value| value,
    };
    // Re-read while admitted, then pin a backend reference. A getter/toString can re-enter the C ABI and release the public handle being operated on.
    const live = api_value.get(handle) orelse {
        op.deinit();
        return .{ .status = API_STALE_VALUE };
    };
    if (live.instance_id != op.id) {
        op.deinit();
        return .{ .status = API_STALE_VALUE };
    }
    return .{ .ok = .{ .op = op, .value = ActiveEngine.dupValue(op.ctx, live.value) } };
}

fn pinValue(op: ApiOp, handle: u64) union(enum) { ok: ActiveEngine.Value, status: c_int } {
    const entry = api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
    if (entry.instance_id != op.id) return .{ .status = API_STALE_VALUE };
    return .{ .ok = ActiveEngine.dupValue(op.ctx, entry.value) };
}

fn apiStore(instance_id: i32, value: ActiveEngine.Value, out: *u64) c_int {
    out.* = 0;
    // A getter/native callback may request destroy while raw backend work is re-entered. Never publish a value that is invalid as soon as this C call returns; retain the backend ownership only long enough to release it.
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) {
        if (@import("runtime/instance_map.zig").getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, value);
        return API_INSTANCE_NOT_FOUND;
    }
    out.* = api_value.putOwned(instance_id, value) orelse {
        if (@import("runtime/instance_map.zig").getPtrs(instance_id)) |ptrs| ActiveEngine.freeValue(ptrs.ctx, value);
        return API_OUT_OF_MEMORY;
    };
    return API_OK;
}

fn drainApiJobs(op: *ApiOp) bool {
    op.endExecution();
    const map = @import("runtime/instance_map.zig");
    if (!map.isTeardownPending(op.id)) @import("runtime/js_scheduler.zig").checkpoint(op.id, op.ctx);
    return !map.isTeardownPending(op.id);
}

fn discardBackendResult(ctx: ActiveEngine.Context, result: api_backend.Result) void {
    if (result.value) |value| ActiveEngine.freeValue(ctx, value);
    if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
}

fn discardBytesResult(ctx: ActiveEngine.Context, result: api_backend.BytesResult) void {
    if (result.bytes) |bytes| std.heap.c_allocator.free(bytes);
    if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
}

fn discardTypedBytecodeResult(ctx: ActiveEngine.Context, result: typed_bytecode.Result) void {
    if (result.bytes) |bytes| typed_bytecode.freeBytes(bytes);
    if (result.value) |value| ActiveEngine.freeValue(ctx, value);
    if (result.exception) |exception| ActiveEngine.freeValue(ctx, exception);
}

pub export fn jsbay_value_retain(value: u64, out_value: *u64) c_int {
    out_value.* = 0;
    if (packed_api_value.isPackedHandle(value)) {
        const instance_id = packed_api_value.instanceFor(value) orelse return API_STALE_VALUE;
        if (!api_value.isOwner(instance_id)) return API_WRONG_THREAD;
        const entry = packed_api_value.get(value) orelse return API_STALE_VALUE;
        var packed_js = switch (beginPackedJsOp(entry.instance_id, entry.tag, entry.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        out_value.* = packed_api_value.retain(value) orelse return API_OUT_OF_MEMORY;
        return API_OK;
    }
    const instance_id = api_value.instanceFor(value) orelse return API_STALE_VALUE;
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    out_value.* = api_value.retain(value) orelse return API_OUT_OF_MEMORY;
    return API_OK;
}

pub export fn jsbay_value_release(value: u64) c_int {
    if (host_string_values.take(value)) |entry| {
        std.heap.c_allocator.free(entry.bytes);
        return API_OK;
    }
    if (packed_api_value.isPackedHandle(value)) {
        const instance_id = packed_api_value.instanceFor(value) orelse return API_STALE_VALUE;
        if (!api_value.isOwner(instance_id)) return API_WRONG_THREAD;
        const entry = packed_api_value.get(value) orelse return API_STALE_VALUE;
        var packed_js = switch (beginPackedJsOp(entry.instance_id, entry.tag, entry.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        return if (packed_api_value.release(value)) API_OK else API_STALE_VALUE;
    }
    const instance_id = api_value.instanceFor(value) orelse return API_STALE_VALUE;
    // Release keeps a beginApiOp lease so freeValue cannot race destroyRuntime's freeContext.
    // When teardown is already pending, beginApiOp fails and destroy's dropInstance frees the
    // handle; hosts should release before destroy (embed checklist).
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return if (api_value.release(value)) API_OK else API_STALE_VALUE;
}

pub export fn jsbay_engine_global(instance_id_raw: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const instance_id: i32 = @intCast(instance_id_raw);
    if (packedTagOf(instance_id) != null) {
        const ready = switch (packedInstanceReady(instance_id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(instance_id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueGetGlobal(ready.tag, ready.ctx_addr);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublish(instance_id, ready.tag, ready.ctx_addr, result, out_value, null);
    }
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(instance_id, ActiveEngine.getGlobalObject(op.ctx), out_value);
}

fn apiNewSimple(instance_id_raw: c_int, out_value: *u64, comptime make: anytype) c_int {
    out_value.* = 0;
    const instance_id: i32 = @intCast(instance_id_raw);
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(instance_id, make(op.ctx), out_value);
}

fn packedNewFromResult(instance_id: i32, result: @import("backend_dispatch.zig").EvalValueResult, tag: backend.BackendType, ctx_addr: usize, out_value: *u64) c_int {
    return packedPublish(instance_id, tag, ctx_addr, result, out_value, null);
}

pub export fn jsbay_value_undefined(instance_id: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewUndefined(ready.tag, ready.ctx_addr);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    return apiNewSimple(instance_id, out_value, struct {
        fn make(_: ActiveEngine.Context) ActiveEngine.Value {
            return ActiveEngine.undefinedValue();
        }
    }.make);
}

pub export fn jsbay_value_null(instance_id: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewNull(ready.tag, ready.ctx_addr);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    return apiNewSimple(instance_id, out_value, struct {
        fn make(_: ActiveEngine.Context) ActiveEngine.Value {
            return ActiveEngine.nullValue();
        }
    }.make);
}

pub export fn jsbay_value_new_bool(instance_id: c_int, input: bool, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewBool(ready.tag, ready.ctx_addr, input);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(id, ActiveEngine.newBoolVal(op.ctx, input), out_value);
}

pub export fn jsbay_value_new_number(instance_id: c_int, input: f64, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewNumber(ready.tag, ready.ctx_addr, input);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    return apiStore(id, ActiveEngine.newFloat64Val(op.ctx, input), out_value);
}

pub export fn jsbay_value_new_string(instance_id: c_int, input: Utf8, out_value: *u64) c_int {
    out_value.* = 0;
    const bytes = checkedUtf8(input) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(bytes)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewString(ready.tag, ready.ctx_addr, bytes);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newString(op.ctx, bytes);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

pub export fn jsbay_value_new_array_buffer(instance_id: c_int, data: ?[*]const u8, len: usize, out_value: *u64) c_int {
    out_value.* = 0;
    const bytes: []const u8 = if (data) |ptr| ptr[0..len] else if (len == 0) "" else return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewArrayBuffer(ready.tag, ready.ctx_addr, bytes);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        var exc: u64 = 0;
        const status = packedPublish(id, ready.tag, ready.ctx_addr, result, out_value, &exc);
        if (status == 1) {
            // ArrayBuffer ctor failure as exception → treat as OOM for this API (no out_exception).
            _ = jsbay_value_release(exc);
            return API_OUT_OF_MEMORY;
        }
        return status;
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newArrayBuffer(op.ctx, bytes);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

pub export fn jsbay_value_type(value: u64, out_kind: *c_int) c_int {
    out_kind.* = 0;
    if (host_string_values.get(value) != null) {
        out_kind.* = 4; // JSBAY_VALUE_STRING
        return API_OK;
    }
    if (packed_api_value.isPackedHandle(value)) {
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        out_kind.* = @import("backend_dispatch.zig").valueTypeKind(data.js.tag, data.js.ctx_addr, data.bytes());
        return API_OK;
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    out_kind.* = if (ActiveEngine.isUndefined(data.op.ctx, data.value)) 0 else if (ActiveEngine.isNull(data.op.ctx, data.value)) 1 else if (ActiveEngine.isBool(data.op.ctx, data.value)) 2 else if (ActiveEngine.isNumber(data.op.ctx, data.value)) 3 else if (ActiveEngine.isString(data.op.ctx, data.value)) 4 else if (ActiveEngine.isArray(data.op.ctx, data.value)) 6 else if (ActiveEngine.isFunction(data.op.ctx, data.value)) 7 else if (ActiveEngine.isSymbol(data.op.ctx, data.value)) 8 else if (ActiveEngine.isBigInt(data.op.ctx, data.value)) 9 else 5;
    return API_OK;
}

pub export fn jsbay_value_to_bool(value: u64, out_value: *bool) c_int {
    out_value.* = false;
    if (packed_api_value.isPackedHandle(value)) {
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        if (!@import("backend_dispatch.zig").valueIsBool(data.js.tag, data.js.ctx_addr, data.bytes())) return API_INVALID_ARGUMENT;
        out_value.* = @import("backend_dispatch.zig").valueToBool(data.js.tag, data.js.ctx_addr, data.bytes()) orelse return API_INVALID_ARGUMENT;
        return API_OK;
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    if (!ActiveEngine.isBool(data.op.ctx, data.value)) return API_INVALID_ARGUMENT;
    out_value.* = ActiveEngine.toBool(data.op.ctx, data.value) orelse return API_INVALID_ARGUMENT;
    return API_OK;
}

pub export fn jsbay_value_to_number(value: u64, out_value: *f64) c_int {
    out_value.* = 0;
    if (packed_api_value.isPackedHandle(value)) {
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        if (!@import("backend_dispatch.zig").valueIsNumber(data.js.tag, data.js.ctx_addr, data.bytes())) return API_INVALID_ARGUMENT;
        out_value.* = @import("backend_dispatch.zig").valueToFloat64(data.js.tag, data.js.ctx_addr, data.bytes()) orelse return API_INVALID_ARGUMENT;
        return API_OK;
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    if (!ActiveEngine.isNumber(data.op.ctx, data.value)) return API_INVALID_ARGUMENT;
    out_value.* = ActiveEngine.toFloat64(data.op.ctx, data.value) orelse return API_INVALID_ARGUMENT;
    return API_OK;
}

pub export fn jsbay_value_new_object(instance_id: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewObject(ready.tag, ready.ctx_addr);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newObject(op.ctx);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

pub export fn jsbay_value_new_array(instance_id: c_int, out_value: *u64) c_int {
    out_value.* = 0;
    const id: i32 = @intCast(instance_id);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewArray(ready.tag, ready.ctx_addr);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = api_backend.newArray(op.ctx, 0);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

// The remaining Value operations are exported here while their backend-typed exception paths are being shared by all three engines. They clear every output before reporting unsupported so FFI callers never observe stale data.
fn noEmbeddedNul(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes, 0) == null;
}

fn duplicateKey(key: []const u8) ?[:0]u8 {
    if (key_fault.consume()) return null;
    return std.heap.c_allocator.dupeSentinel(u8, key, 0) catch null;
}

/// Host-owned UTF-8 results (legacy); packed-alt evaluate now publishes typed packed_api_value handles.
const host_string_values = struct {
    var mutex: @import("zev").Mutex = .{};
    var map = std.AutoHashMap(u64, Entry).init(std.heap.c_allocator);
    var next: u64 = 1;

    const Entry = struct {
        instance_id: i32,
        bytes: []u8,
    };

    fn put(instance_id: i32, text_bytes: []const u8) ?u64 {
        const owned = std.heap.c_allocator.dupe(u8, text_bytes) catch return null;
        mutex.lock();
        defer mutex.unlock();
        if (next == 0 or next > std.math.maxInt(i64)) {
            std.heap.c_allocator.free(owned);
            return null;
        }
        const handle = next;
        next += 1;
        map.put(handle, .{ .instance_id = instance_id, .bytes = owned }) catch {
            std.heap.c_allocator.free(owned);
            return null;
        };
        return handle;
    }

    fn take(handle: u64) ?Entry {
        mutex.lock();
        defer mutex.unlock();
        const kv = map.fetchRemove(handle) orelse return null;
        return kv.value;
    }

    fn get(handle: u64) ?Entry {
        mutex.lock();
        defer mutex.unlock();
        return map.get(handle);
    }

    fn dropInstance(instance_id: i32) void {
        mutex.lock();
        defer mutex.unlock();
        var to_free = std.ArrayList(u64).empty;
        defer to_free.deinit(std.heap.c_allocator);
        var it = map.iterator();
        while (it.next()) |item| {
            if (item.value_ptr.instance_id == instance_id) {
                to_free.append(std.heap.c_allocator, item.key_ptr.*) catch {};
            }
        }
        for (to_free.items) |h| {
            if (map.fetchRemove(h)) |kv| {
                std.heap.c_allocator.free(kv.value.bytes);
            }
        }
    }
};

fn packedHandlesOf(instance_id: i32) ?@import("backend_dispatch.zig").Handles {
    const inst = @import("runtime/instance_map.zig").getInstance(instance_id) orelse return null;
    return switch (inst.engine_handles) {
        .packed_alt => |a| .{ .runtime_addr = a.runtime_addr, .ctx_addr = a.ctx_addr },
        .mono => null,
    };
}

const PackedJsOp = struct {
    id: i32,
    tag: backend.BackendType,
    ctx_addr: usize,
    lease: engine_thread.EvalLease,
    entered_js: bool,
    execution: ?@import("js_event_loop").Scheduler.Execution = null,

    fn endExecution(self: *PackedJsOp) void {
        if (self.execution) |*guard| guard.end();
        self.execution = null;
    }

    fn deinit(self: *PackedJsOp) void {
        if (self.execution != null) {
            self.endExecution();
            @import("runtime/js_scheduler.zig").checkpointInstance(self.id);
        }
        if (self.entered_js) @import("backend_dispatch.zig").leaveJsPacked(self.tag, self.ctx_addr);
        engine.finishEvalEntry(self.id, self.lease);
    }
};

/// Admission lease for packed-alt value ops that may execute JavaScript (mirrors beginApiOp / beginValueOp).
fn beginPackedJsOp(instance_id: i32, tag: backend.BackendType, ctx_addr: usize) union(enum) { ok: PackedJsOp, status: c_int } {
    if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) return .{ .status = API_INSTANCE_NOT_FOUND };
    if (!api_value.isOwner(instance_id)) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    if (@import("runtime/instance_map.zig").getInstance(instance_id)) |inst| {
        if (inst.loop.lastError() != null) return .{ .status = API_LOOP_FAILED };
    }
    const lease = engine_thread.beginEval(instance_id);
    if (!lease.allowed) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    if (!@import("backend_dispatch.zig").enterJsPacked(tag, ctx_addr)) {
        engine.finishEvalEntry(instance_id, lease);
        return .{ .status = API_WRONG_THREAD };
    }
    return .{ .ok = .{
        .id = instance_id,
        .tag = tag,
        .ctx_addr = ctx_addr,
        .lease = lease,
        .entered_js = true,
        .execution = @import("runtime/js_scheduler.zig").beginExecution(instance_id),
    } };
}

const PackedValueOp = struct {
    js: PackedJsOp,
    value_buf: [@import("backend_dispatch.zig").value_storage_size]u8 = undefined,
    value_len: usize = 0,

    fn bytes(self: *const PackedValueOp) []const u8 {
        return self.value_buf[0..self.value_len];
    }

    fn deinit(self: *PackedValueOp) void {
        if (self.value_len != 0) {
            @import("backend_dispatch.zig").timerFreeValue(self.js.tag, self.js.ctx_addr, self.bytes());
            self.value_len = 0;
        }
        self.js.deinit();
    }
};

/// Pin a packed handle's backend value for the op lifetime (mirrors beginValueOp for primary).
fn beginPackedValueOp(handle: u64) union(enum) { ok: PackedValueOp, status: c_int } {
    const entry = packed_api_value.get(handle) orelse return .{ .status = API_STALE_VALUE };
    if (!api_value.isOwner(entry.instance_id)) {
        return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(entry.instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    }
    var js = switch (beginPackedJsOp(entry.instance_id, entry.tag, entry.ctx_addr)) {
        .status => |status| return .{ .status = status },
        .ok => |ok| ok,
    };
    // Re-read while admitted, then pin. A toPrimitive / getter can re-enter and release the public handle.
    const live = packed_api_value.get(handle) orelse {
        js.deinit();
        return .{ .status = API_STALE_VALUE };
    };
    if (live.instance_id != js.id or live.tag != js.tag) {
        js.deinit();
        return .{ .status = API_STALE_VALUE };
    }
    var op: PackedValueOp = .{ .js = js, .value_len = 0 };
    op.value_len = @import("backend_dispatch.zig").timerDupValue(live.tag, live.ctx_addr, live.bytes(), op.value_buf[0..]) orelse {
        op.js.deinit();
        return .{ .status = API_STALE_VALUE };
    };
    return .{ .ok = op };
}

fn drainPackedJobs(js: *PackedJsOp) bool {
    js.endExecution();
    const map = @import("runtime/instance_map.zig");
    if (!map.isTeardownPending(js.id)) @import("runtime/js_scheduler.zig").checkpointInstance(js.id);
    return !map.isTeardownPending(js.id);
}

fn discardPackedEvalResult(tag: backend.BackendType, ctx_addr: usize, result: @import("backend_dispatch.zig").EvalValueResult) void {
    if (result.value) |v| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, v.slice());
    if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
}

fn discardPackedBytesResult(tag: backend.BackendType, ctx_addr: usize, result: @import("backend_dispatch.zig").BytesValueResult) void {
    if (result.bytes) |b| std.heap.c_allocator.free(b);
    if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
}

fn discardPackedBoolResult(tag: backend.BackendType, ctx_addr: usize, result: @import("backend_dispatch.zig").BoolValueResult) void {
    if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
}

fn packedTagOf(instance_id: i32) ?backend.BackendType {
    const inst = @import("runtime/instance_map.zig").getInstance(instance_id) orelse return null;
    return switch (inst.engine_handles) {
        .packed_alt => |a| a.tag,
        .mono => null,
    };
}

fn packedStore(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, erased: @import("backend_dispatch.zig").ErasedValue, out: *u64) c_int {
    out.* = 0;
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) {
        @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, erased.slice());
        return API_INSTANCE_NOT_FOUND;
    }
    out.* = packed_api_value.putOwned(instance_id, tag, ctx_addr, erased.slice()) orelse {
        @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, erased.slice());
        return API_OUT_OF_MEMORY;
    };
    return API_OK;
}

fn packedPublish(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, result: @import("backend_dispatch.zig").EvalValueResult, out_value: *u64, out_exception: ?*u64) c_int {
    if (out_exception) |exc| exc.* = 0;
    if (result.out_of_memory) {
        if (result.value) |v| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, v.slice());
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        return API_OUT_OF_MEMORY;
    }
    if (result.exception) |exc| {
        if (out_exception) |slot| {
            const stored = packedStore(instance_id, tag, ctx_addr, exc, slot);
            return if (stored == API_OK) 1 else stored;
        }
        @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, exc.slice());
        return API_OUT_OF_MEMORY;
    }
    if (result.value) |value| return packedStore(instance_id, tag, ctx_addr, value, out_value);
    // set-style ops succeed with empty result
    out_value.* = 0;
    return API_OK;
}

fn packedPublishBool(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, result: @import("backend_dispatch.zig").BoolValueResult, out_flag: *bool, out_exception: *u64) c_int {
    out_exception.* = 0;
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) {
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) {
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        return API_OUT_OF_MEMORY;
    }
    if (result.exception) |exc| {
        const stored = packedStore(instance_id, tag, ctx_addr, exc, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    out_flag.* = result.value;
    return API_OK;
}

fn packedPublishBytes(instance_id: i32, tag: backend.BackendType, ctx_addr: usize, result: @import("backend_dispatch.zig").BytesValueResult, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_exception.* = 0;
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) {
        if (result.bytes) |b| std.heap.c_allocator.free(b);
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) {
        if (result.bytes) |b| std.heap.c_allocator.free(b);
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        return API_OUT_OF_MEMORY;
    }
    if (result.invalid_argument) {
        if (result.bytes) |b| std.heap.c_allocator.free(b);
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, ctx_addr, e.slice());
        return API_INVALID_ARGUMENT;
    }
    if (result.exception) |exc| {
        if (result.bytes) |b| std.heap.c_allocator.free(b);
        const stored = packedStore(instance_id, tag, ctx_addr, exc, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}

fn packedDupBytes(handle: u64, expect_instance: i32, expect_tag: backend.BackendType, out: []u8) ?usize {
    const entry = packed_api_value.get(handle) orelse return null;
    if (entry.instance_id != expect_instance or entry.tag != expect_tag) return null;
    return @import("backend_dispatch.zig").timerDupValue(entry.tag, entry.ctx_addr, entry.bytes(), out);
}

fn packedInstanceReady(instance_id: i32) union(enum) {
    ok: struct { tag: backend.BackendType, ctx_addr: usize },
    status: c_int,
} {
    if (host_wake.isNotifying()) return .{ .status = API_INVALID_ARGUMENT };
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) return .{ .status = API_INSTANCE_NOT_FOUND };
    if (!api_value.isOwner(instance_id)) return .{ .status = if (@import("runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD };
    const tag = packedTagOf(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
    const handles = packedHandlesOf(instance_id) orelse return .{ .status = API_INSTANCE_NOT_FOUND };
    if (@import("runtime/instance_map.zig").getInstance(instance_id)) |inst| {
        if (inst.loop.lastError() != null) return .{ .status = API_LOOP_FAILED };
    }
    return .{ .ok = .{ .tag = tag, .ctx_addr = handles.ctx_addr } };
}

fn evaluatePackedAlt(instance_id: i32, source: []const u8, filename: []const u8, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    if (!api_value.isOwner(instance_id)) {
        return if (@import("runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD;
    }
    const tag = packedTagOf(instance_id) orelse return API_INSTANCE_NOT_FOUND;
    const handles = packedHandlesOf(instance_id) orelse return API_INSTANCE_NOT_FOUND;
    const lease = engine_thread.beginEval(instance_id);
    defer engine.finishEvalEntry(instance_id, lease);
    if (!lease.allowed) {
        return if (@import("runtime/instance_map.zig").getPtrs(instance_id) == null) API_INSTANCE_NOT_FOUND else API_WRONG_THREAD;
    }
    if (@import("runtime/instance_map.zig").getInstance(instance_id)) |inst| {
        if (inst.loop.lastError() != null) return API_LOOP_FAILED;
    }
    var execution = @import("runtime/js_scheduler.zig").beginExecution(instance_id) orelse return API_INSTANCE_NOT_FOUND;
    @import("inspector/debugger.zig").noteScript(instance_id, filename, source);
    @import("inspector/debugger.zig").clearExceptionHold(instance_id);
    const result = @import("backend_dispatch.zig").evalValuePacked(tag, handles, source, filename);
    execution.end();
    @import("runtime/js_scheduler.zig").checkpointInstance(instance_id);
    if (@import("runtime/instance_map.zig").isTeardownPending(instance_id)) {
        if (result.value) |v| @import("backend_dispatch.zig").timerFreeValue(tag, handles.ctx_addr, v.slice());
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, handles.ctx_addr, e.slice());
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) {
        if (result.value) |v| @import("backend_dispatch.zig").timerFreeValue(tag, handles.ctx_addr, v.slice());
        if (result.exception) |e| @import("backend_dispatch.zig").timerFreeValue(tag, handles.ctx_addr, e.slice());
        return API_OUT_OF_MEMORY;
    }
    if (result.exception) |exc| {
        const stored = packedStore(instance_id, tag, handles.ctx_addr, exc, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    if (result.value) |value| return packedStore(instance_id, tag, handles.ctx_addr, value, out_value);
    return API_OUT_OF_MEMORY;
}

pub export fn jsbay_engine_evaluate(instance_id_raw: c_int, source_arg: Utf8, filename_arg: Utf8, options: ?*const EvalOptions, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const source = checkedUtf8(source_arg) orelse return API_INVALID_ARGUMENT;
    const filename = checkedUtf8(filename_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(filename) or !noEmbeddedNul(filename)) return API_INVALID_ARGUMENT;
    var cache_dir: []const u8 = "";
    var cache_version: []const u8 = "";
    if (options) |opts| {
        if (opts.struct_size < @sizeOf(EvalOptions)) return API_INVALID_ARGUMENT;
        if (opts.out_cache_hit) |hit| hit.* = false;
        cache_dir = checkedUtf8(opts.cache_dir) orelse return API_INVALID_ARGUMENT;
        cache_version = checkedUtf8(opts.cache_version) orelse return API_INVALID_ARGUMENT;
        if (!noEmbeddedNul(cache_dir) or !noEmbeddedNul(cache_version)) return API_INVALID_ARGUMENT;
        if ((cache_dir.len == 0) != (cache_version.len == 0)) return API_INVALID_ARGUMENT;
    }
    const id: i32 = @intCast(instance_id_raw);
    if (@import("runtime/instance_map.zig").getInstance(id)) |inst| {
        if (!inst.isPrimaryBackend()) {
            // Empty options (or all-empty cache fields) are accepted; bytecode cache itself is primary-only.
            if (cache_dir.len != 0 or cache_version.len != 0) return API_UNSUPPORTED;
            return evaluatePackedAlt(id, source, filename, out_value, out_exception);
        }
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |value| value,
    };
    defer op.deinit();
    var execution = @import("runtime/js_scheduler.zig").beginExecution(id) orelse return API_INSTANCE_NOT_FOUND;
    @import("inspector/debugger.zig").noteScript(id, filename, source);
    @import("inspector/debugger.zig").clearExceptionHold(id);
    const result = typed_eval.evaluate(op.ctx, source, filename, cache_dir, cache_version);
    execution.end();
    if (!drainApiJobs(&op)) {
        if (result.value) |value| ActiveEngine.freeValue(op.ctx, value);
        if (result.exception) |exception| ActiveEngine.freeValue(op.ctx, exception);
        return API_INSTANCE_NOT_FOUND;
    }
    if (options) |opts| {
        if (opts.out_cache_hit) |hit| hit.* = result.cache_hit;
    }
    if (result.out_of_memory) {
        maybeFireMemoryLimit(id, API_OUT_OF_MEMORY);
        return API_OUT_OF_MEMORY;
    }
    if (result.exception) |exception| {
        // Time-limit / requestInterrupt both surface as JS exceptions; memory-limit OOM may also.
        maybeFireInterrupted(id);
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    if (result.value) |value| return apiStore(id, value, out_value);
    maybeFireMemoryLimit(id, API_OUT_OF_MEMORY);
    return API_OUT_OF_MEMORY;
}
test "c_api: evaluation and cache preserve inspector source contract" {
    const testing = std.testing;
    const debugger = @import("inspector/debugger.zig");
    const instance_map = @import("runtime/instance_map.zig");
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    try testing.expect(jsbay_engine_create(id, null, null));
    defer jsbay_engine_destroy(id);
    const instance = instance_map.getInstance(id) orelse return error.MissingEngine;
    const inspector_enabled = @import("build_options").inspector;
    if (comptime inspector_enabled) {
        if (comptime !backend.supportsDebugger(backend.active_backend)) return error.SkipZigTest;
        try testing.expect(debugger.attach(id, @ptrCast(@constCast(instance.monoRuntime().?))));
    } else {
        try testing.expect(!debugger.attach(id, @ptrCast(@constCast(instance.monoRuntime().?))));
    }
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const directory = try temp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(directory);
    const source = "globalThis.apiDebugRuns=(globalThis.apiDebugRuns||0)+1;apiDebugRuns";
    const filename = "c-api-inspector-source.js";
    var hit = false;
    var options = EvalOptions{
        .struct_size = @sizeOf(EvalOptions),
        .cache_dir = .{ .data = directory.ptr, .len = directory.len },
        .cache_version = .{ .data = "v1", .len = 2 },
        .out_cache_hit = &hit,
    };
    try testing.expectEqual(@as(u32, 0), debugger.scriptIdForUrl(id, filename));
    for (0..3) |index| {
        var value: u64 = 0;
        var exception: u64 = 0;
        hit = false;
        try testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = source.ptr, .len = source.len }, .{ .data = filename.ptr, .len = filename.len }, if (index < 2) &options else null, &value, &exception));
        defer _ = jsbay_value_release(value);
        try testing.expectEqual(@as(u64, 0), exception);
        try testing.expectEqual(@import("build_options").bytecode_cache and backend.active_backend != .jsc and index == 1, hit);
        const script_id = debugger.scriptIdForUrl(id, filename);
        if (comptime inspector_enabled) {
            try testing.expect(script_id != 0);
            const script = debugger.scriptById(id, script_id) orelse return error.MissingDebuggerSource;
            defer debugger.freeScriptInfo(script);
            try testing.expectEqualStrings(source, script.source);
            try testing.expectEqualStrings(filename, script.url);
        } else {
            try testing.expectEqual(@as(u32, 0), script_id);
        }
        var runs: f64 = 0;
        try testing.expectEqual(API_OK, jsbay_value_to_number(value, &runs));
        try testing.expectEqual(@as(f64, @floatFromInt(index + 1)), runs);
    }
}

pub export fn jsbay_value_new_json(instance_id_raw: c_int, input_arg: Utf8, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const input = checkedUtf8(input_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(input)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id_raw);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewJson(ready.tag, ready.ctx_addr, input);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublish(id, ready.tag, ready.ctx_addr, result, out_value, out_exception);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |value| value,
    };
    defer op.deinit();
    const result = api_backend.parseJson(op.ctx, input);
    if (!drainApiJobs(&op)) {
        discardBackendResult(op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn jsbay_value_new_error(instance_id_raw: c_int, message_arg: Utf8, out_value: *u64) c_int {
    out_value.* = 0;
    const message = checkedUtf8(message_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(message)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id_raw);
    if (packedTagOf(id) != null) {
        const ready = switch (packedInstanceReady(id)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        var packed_js = switch (beginPackedJsOp(id, ready.tag, ready.ctx_addr)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer packed_js.deinit();
        const result = @import("backend_dispatch.zig").valueNewError(ready.tag, ready.ctx_addr, message);
        if (!drainPackedJobs(&packed_js)) {
            discardPackedEvalResult(ready.tag, ready.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedNewFromResult(id, result, ready.tag, ready.ctx_addr, out_value);
    }
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |value| value,
    };
    defer op.deinit();
    const result = api_backend.newError(op.ctx, message);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        // Constructors report an internal failure as a non-exception status; no out_exception exists on this API surface.
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn jsbay_value_to_utf8(value: u64, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    if (host_string_values.get(value)) |entry| {
        const duped = std.heap.c_allocator.dupe(u8, entry.bytes) catch return API_OUT_OF_MEMORY;
        out_bytes.* = .{ .data = duped.ptr, .len = duped.len };
        return API_OK;
    }
    if (packed_api_value.isPackedHandle(value)) {
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        const result = @import("backend_dispatch.zig").valueToUtf8(data.js.tag, data.js.ctx_addr, data.bytes());
        if (!drainPackedJobs(&data.js)) {
            discardPackedBytesResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        const status = packedPublishBytes(data.js.id, data.js.tag, data.js.ctx_addr, result, out_bytes, out_exception);
        if (status != API_OK) return status;
        // QuickJS may surface WTF-8; public ABI promises UTF-8.
        if (out_bytes.data) |ptr| {
            const bytes = ptr[0..out_bytes.len];
            if (!std.unicode.utf8ValidateSlice(bytes)) {
                std.unicode.wtf8ToUtf8Lossy(bytes, bytes) catch {
                    std.heap.c_allocator.free(bytes);
                    out_bytes.* = .{ .data = null, .len = 0 };
                    return API_INVALID_ARGUMENT;
                };
            }
        }
        return API_OK;
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.toUtf8(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBytesResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    // QuickJS exposes unpaired UTF-16 surrogates as WTF-8. The public ABI promises ordinary UTF-8, so rewrite each surrogate half to U+FFFD in place. Valid UTF-8 (including NUL and paired emoji) is untouched.
    if (!std.unicode.utf8ValidateSlice(bytes)) {
        std.unicode.wtf8ToUtf8Lossy(bytes, bytes) catch {
            std.heap.c_allocator.free(bytes);
            return API_INVALID_ARGUMENT;
        };
    }
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}
pub export fn jsbay_value_to_json(value: u64, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    if (packed_api_value.isPackedHandle(value)) {
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        const result = @import("backend_dispatch.zig").valueToJson(data.js.tag, data.js.ctx_addr, data.bytes());
        if (!drainPackedJobs(&data.js)) {
            discardPackedBytesResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublishBytes(data.js.id, data.js.tag, data.js.ctx_addr, result, out_bytes, out_exception);
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.toJson(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBytesResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}
pub export fn jsbay_value_copy_buffer(value: u64, out_bytes: *Bytes, out_exception: *u64) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    if (packed_api_value.isPackedHandle(value)) {
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        const result = @import("backend_dispatch.zig").valueCopyBuffer(data.js.tag, data.js.ctx_addr, data.bytes());
        if (!drainPackedJobs(&data.js)) {
            discardPackedBytesResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublishBytes(data.js.id, data.js.tag, data.js.ctx_addr, result, out_bytes, out_exception);
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.copyBuffer(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBytesResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}
pub export fn jsbay_free_bytes(bytes: Bytes) void {
    if (bytes.data) |data| std.heap.c_allocator.free(data[0..bytes.len]);
}
pub export fn jsbay_value_get(object: u64, key_arg: Utf8, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    if (packed_api_value.isPackedHandle(object)) {
        var data = switch (beginPackedValueOp(object)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        const key_z = std.heap.c_allocator.dupeSentinel(u8, key, 0) catch return API_OUT_OF_MEMORY;
        defer std.heap.c_allocator.free(key_z);
        const result = @import("backend_dispatch.zig").valueGetProperty(data.js.tag, data.js.ctx_addr, data.bytes(), key_z);
        if (!drainPackedJobs(&data.js)) {
            discardPackedEvalResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublish(data.js.id, data.js.tag, data.js.ctx_addr, result, out_value, out_exception);
    }
    var data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const key_z = std.heap.c_allocator.dupeSentinel(u8, key, 0) catch return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    const result = api_backend.get(data.op.ctx, data.value, key_z);
    if (!drainApiJobs(&data.op)) {
        discardBackendResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn jsbay_value_set(object: u64, key_arg: Utf8, value: u64, out_exception: *u64) c_int {
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    if (packed_api_value.isPackedHandle(object)) {
        // Acquire the eval lease before duplicating the value so Zig LIFO runs lease release after freeValue cleanup.
        var data = switch (beginPackedValueOp(object)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        if (!packed_api_value.isPackedHandle(value)) return API_STALE_VALUE;
        // Allocate before duplicating `value`: a key-allocation failure must not leave a duplicate without an owner.
        const key_z = duplicateKey(key) orelse return API_OUT_OF_MEMORY;
        defer std.heap.c_allocator.free(key_z);
        var value_buf: [@import("backend_dispatch.zig").value_storage_size]u8 = undefined;
        const value_len = packedDupBytes(value, data.js.id, data.js.tag, value_buf[0..]) orelse return API_STALE_VALUE;
        // valueSetProperty consumes the duplicated value.
        const result = @import("backend_dispatch.zig").valueSetProperty(data.js.tag, data.js.ctx_addr, data.bytes(), key_z, value_buf[0..value_len]);
        if (!drainPackedJobs(&data.js)) {
            discardPackedEvalResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        var dummy: u64 = 0;
        return packedPublish(data.js.id, data.js.tag, data.js.ctx_addr, result, &dummy, out_exception);
    }
    var object_data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer object_data.deinit();
    // Allocate before duplicating `value`: a key-allocation failure must not leave a protected/reference-counted duplicate without an owner.
    const key_z = duplicateKey(key) orelse return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    const pinned_value = switch (pinValue(object_data.op, value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    const result = api_backend.set(object_data.op.ctx, object_data.value, key_z, pinned_value);
    if (!drainApiJobs(&object_data.op)) {
        discardBackendResult(object_data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.exception) |exception| {
        const stored = apiStore(object_data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    return API_OK;
}
pub export fn jsbay_value_call(function: u64, this_value: u64, args: ?[*]const u64, argc: usize, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    if (args == null and argc != 0) return API_INVALID_ARGUMENT;
    if (packed_api_value.isPackedHandle(function)) {
        if (!packed_api_value.isPackedHandle(this_value)) return API_STALE_VALUE;
        // Acquire the eval lease before duplicating this/args so Zig LIFO runs lease release after freeValue cleanup.
        var data = switch (beginPackedValueOp(function)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        var this_buf: [@import("backend_dispatch.zig").value_storage_size]u8 = undefined;
        const this_len = packedDupBytes(this_value, data.js.id, data.js.tag, this_buf[0..]) orelse return API_STALE_VALUE;
        defer @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, this_buf[0..this_len]);

        var arg_storage = std.ArrayList([@import("backend_dispatch.zig").value_storage_size]u8).empty;
        defer arg_storage.deinit(std.heap.c_allocator);
        var arg_lens = std.ArrayList(usize).empty;
        defer arg_lens.deinit(std.heap.c_allocator);
        defer {
            var i: usize = 0;
            while (i < arg_storage.items.len) : (i += 1) {
                @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, arg_storage.items[i][0..arg_lens.items[i]]);
            }
        }
        if (args) |raw_args| for (raw_args[0..argc]) |handle| {
            if (!packed_api_value.isPackedHandle(handle)) return API_STALE_VALUE;
            var buf: [@import("backend_dispatch.zig").value_storage_size]u8 = undefined;
            const len = packedDupBytes(handle, data.js.id, data.js.tag, buf[0..]) orelse return API_STALE_VALUE;
            arg_storage.append(std.heap.c_allocator, buf) catch {
                @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, buf[0..len]);
                return API_OUT_OF_MEMORY;
            };
            arg_lens.append(std.heap.c_allocator, len) catch {
                @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, buf[0..len]);
                _ = arg_storage.pop();
                return API_OUT_OF_MEMORY;
            };
        };
        var arg_slices = std.ArrayList([]const u8).empty;
        defer arg_slices.deinit(std.heap.c_allocator);
        arg_slices.ensureTotalCapacityPrecise(std.heap.c_allocator, arg_storage.items.len) catch return API_OUT_OF_MEMORY;
        var ai: usize = 0;
        while (ai < arg_storage.items.len) : (ai += 1) {
            arg_slices.appendAssumeCapacity(arg_storage.items[ai][0..arg_lens.items[ai]]);
        }
        const result = @import("backend_dispatch.zig").valueCall(data.js.tag, data.js.ctx_addr, data.bytes(), this_buf[0..this_len], arg_slices.items);
        if (!drainPackedJobs(&data.js)) {
            discardPackedEvalResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublish(data.js.id, data.js.tag, data.js.ctx_addr, result, out_value, out_exception);
    }
    var function_data = switch (beginValueOp(function)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer function_data.deinit();
    const pinned_this = switch (pinValue(function_data.op, this_value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer ActiveEngine.freeValue(function_data.op.ctx, pinned_this);
    var values = std.ArrayList(ActiveEngine.Value).empty;
    defer values.deinit(std.heap.c_allocator);
    defer for (values.items) |item| ActiveEngine.freeValue(function_data.op.ctx, item);
    if (args) |raw_args| for (raw_args[0..argc]) |handle| {
        const item = switch (pinValue(function_data.op, handle)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        values.append(std.heap.c_allocator, item) catch {
            ActiveEngine.freeValue(function_data.op.ctx, item);
            return API_OUT_OF_MEMORY;
        };
    };
    const result = api_backend.call(function_data.op.ctx, function_data.value, pinned_this, values.items);
    if (!drainApiJobs(&function_data.op)) {
        discardBackendResult(function_data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(function_data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(function_data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}
pub export fn jsbay_value_construct(function: u64, args: ?[*]const u64, argc: usize, out_value: *u64, out_exception: *u64) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    if (args == null and argc != 0) return API_INVALID_ARGUMENT;
    if (packed_api_value.isPackedHandle(function)) {
        // Acquire the eval lease before duplicating args so Zig LIFO runs lease release after freeValue cleanup.
        var data = switch (beginPackedValueOp(function)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        var arg_storage = std.ArrayList([@import("backend_dispatch.zig").value_storage_size]u8).empty;
        defer arg_storage.deinit(std.heap.c_allocator);
        var arg_lens = std.ArrayList(usize).empty;
        defer arg_lens.deinit(std.heap.c_allocator);
        defer {
            var i: usize = 0;
            while (i < arg_storage.items.len) : (i += 1) {
                @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, arg_storage.items[i][0..arg_lens.items[i]]);
            }
        }
        if (args) |raw_args| for (raw_args[0..argc]) |handle| {
            if (!packed_api_value.isPackedHandle(handle)) return API_STALE_VALUE;
            var buf: [@import("backend_dispatch.zig").value_storage_size]u8 = undefined;
            const len = packedDupBytes(handle, data.js.id, data.js.tag, buf[0..]) orelse return API_STALE_VALUE;
            arg_storage.append(std.heap.c_allocator, buf) catch {
                @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, buf[0..len]);
                return API_OUT_OF_MEMORY;
            };
            arg_lens.append(std.heap.c_allocator, len) catch {
                @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, buf[0..len]);
                _ = arg_storage.pop();
                return API_OUT_OF_MEMORY;
            };
        };
        var arg_slices = std.ArrayList([]const u8).empty;
        defer arg_slices.deinit(std.heap.c_allocator);
        arg_slices.ensureTotalCapacityPrecise(std.heap.c_allocator, arg_storage.items.len) catch return API_OUT_OF_MEMORY;
        var ai: usize = 0;
        while (ai < arg_storage.items.len) : (ai += 1) {
            arg_slices.appendAssumeCapacity(arg_storage.items[ai][0..arg_lens.items[ai]]);
        }
        const result = @import("backend_dispatch.zig").valueConstruct(data.js.tag, data.js.ctx_addr, data.bytes(), arg_slices.items);
        if (!drainPackedJobs(&data.js)) {
            discardPackedEvalResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublish(data.js.id, data.js.tag, data.js.ctx_addr, result, out_value, out_exception);
    }
    var function_data = switch (beginValueOp(function)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer function_data.deinit();
    var values = std.ArrayList(ActiveEngine.Value).empty;
    defer values.deinit(std.heap.c_allocator);
    defer for (values.items) |item| ActiveEngine.freeValue(function_data.op.ctx, item);
    if (args) |raw_args| for (raw_args[0..argc]) |handle| {
        const item = switch (pinValue(function_data.op, handle)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        values.append(std.heap.c_allocator, item) catch {
            ActiveEngine.freeValue(function_data.op.ctx, item);
            return API_OUT_OF_MEMORY;
        };
    };
    const result = api_backend.construct(function_data.op.ctx, function_data.value, values.items);
    if (!drainApiJobs(&function_data.op)) {
        discardBackendResult(function_data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(function_data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(function_data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

/// Publish a boolean backend result, or its original throw value, once the microtask checkpoint has run. A checkpoint that tears the instance down publishes nothing.
fn finishBoolOp(op: *ApiOp, result: api_backend.BoolResult, out_flag: *bool, out_exception: *u64) c_int {
    if (!drainApiJobs(op)) {
        if (result.exception) |exception| ActiveEngine.freeValue(op.ctx, exception);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    out_flag.* = result.value;
    return API_OK;
}

fn keyedBoolOp(
    comptime backendOp: fn (ActiveEngine.Context, ActiveEngine.Value, [:0]const u8) api_backend.BoolResult,
    object: u64,
    key_arg: Utf8,
    out_flag: *bool,
    out_exception: *u64,
) c_int {
    out_flag.* = false;
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    var data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const key_z = duplicateKey(key) orelse return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    return finishBoolOp(&data.op, backendOp(data.op.ctx, data.value, key_z), out_flag, out_exception);
}

fn packedKeyedBoolOp(
    comptime which: enum { has, delete },
    object: u64,
    key_arg: Utf8,
    out_flag: *bool,
    out_exception: *u64,
) c_int {
    out_flag.* = false;
    out_exception.* = 0;
    const key = checkedUtf8(key_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(key) or !noEmbeddedNul(key)) return API_INVALID_ARGUMENT;
    var data = switch (beginPackedValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const key_z = duplicateKey(key) orelse return API_OUT_OF_MEMORY;
    defer std.heap.c_allocator.free(key_z);
    const result = switch (which) {
        .has => @import("backend_dispatch.zig").valueHas(data.js.tag, data.js.ctx_addr, data.bytes(), key_z),
        .delete => @import("backend_dispatch.zig").valueDelete(data.js.tag, data.js.ctx_addr, data.bytes(), key_z),
    };
    if (!drainPackedJobs(&data.js)) {
        discardPackedBoolResult(data.js.tag, data.js.ctx_addr, result);
        return API_INSTANCE_NOT_FOUND;
    }
    return packedPublishBool(data.js.id, data.js.tag, data.js.ctx_addr, result, out_flag, out_exception);
}
pub export fn jsbay_value_has(object: u64, key: Utf8, out_has: *bool, out_exception: *u64) c_int {
    if (packed_api_value.isPackedHandle(object)) return packedKeyedBoolOp(.has, object, key, out_has, out_exception);
    return keyedBoolOp(api_backend.has, object, key, out_has, out_exception);
}

pub export fn jsbay_value_delete(object: u64, key: Utf8, out_deleted: *bool, out_exception: *u64) c_int {
    if (packed_api_value.isPackedHandle(object)) return packedKeyedBoolOp(.delete, object, key, out_deleted, out_exception);
    return keyedBoolOp(api_backend.delete, object, key, out_deleted, out_exception);
}

pub export fn jsbay_value_keys(object: u64, out_array: *u64, out_exception: *u64) c_int {
    out_array.* = 0;
    out_exception.* = 0;
    if (packed_api_value.isPackedHandle(object)) {
        var data = switch (beginPackedValueOp(object)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        const result = @import("backend_dispatch.zig").valueKeys(data.js.tag, data.js.ctx_addr, data.bytes());
        if (!drainPackedJobs(&data.js)) {
            discardPackedEvalResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublish(data.js.id, data.js.tag, data.js.ctx_addr, result, out_array, out_exception);
    }
    var data = switch (beginValueOp(object)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const result = api_backend.keys(data.op.ctx, data.value);
    if (!drainApiJobs(&data.op)) {
        discardBackendResult(data.op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        const stored = apiStore(data.op.id, exception, out_exception);
        return if (stored == API_OK) 1 else stored;
    }
    return apiStore(data.op.id, result.value orelse return API_OUT_OF_MEMORY, out_array);
}

pub export fn jsbay_value_instance_of(value: u64, constructor: u64, out_result: *bool, out_exception: *u64) c_int {
    out_result.* = false;
    out_exception.* = 0;
    if (packed_api_value.isPackedHandle(value)) {
        if (!packed_api_value.isPackedHandle(constructor)) return API_STALE_VALUE;
        // Acquire the eval lease before duplicating the constructor so Zig LIFO runs lease release after freeValue cleanup.
        var data = switch (beginPackedValueOp(value)) {
            .status => |status| return status,
            .ok => |ok| ok,
        };
        defer data.deinit();
        var ctor_buf: [@import("backend_dispatch.zig").value_storage_size]u8 = undefined;
        const ctor_len = packedDupBytes(constructor, data.js.id, data.js.tag, ctor_buf[0..]) orelse return API_STALE_VALUE;
        defer @import("backend_dispatch.zig").timerFreeValue(data.js.tag, data.js.ctx_addr, ctor_buf[0..ctor_len]);
        const result = @import("backend_dispatch.zig").valueInstanceOf(data.js.tag, data.js.ctx_addr, data.bytes(), ctor_buf[0..ctor_len]);
        if (!drainPackedJobs(&data.js)) {
            discardPackedBoolResult(data.js.tag, data.js.ctx_addr, result);
            return API_INSTANCE_NOT_FOUND;
        }
        return packedPublishBool(data.js.id, data.js.tag, data.js.ctx_addr, result, out_result, out_exception);
    }
    var data = switch (beginValueOp(value)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer data.deinit();
    const pinned_constructor = switch (pinValue(data.op, constructor)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer ActiveEngine.freeValue(data.op.ctx, pinned_constructor);
    return finishBoolOp(&data.op, api_backend.instanceOf(data.op.ctx, data.value, pinned_constructor), out_result, out_exception);
}
test "c_api: set key allocation failure does not retain its value duplicate" {
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    try std.testing.expect(jsbay_engine_create(id, null, null));
    defer jsbay_engine_destroy(id);
    var object: u64 = 0;
    var value: u64 = 0;
    var exception: u64 = 0;
    try std.testing.expectEqual(API_OK, jsbay_value_new_object(id, &object));
    try std.testing.expectEqual(API_OK, jsbay_value_new_number(id, 1, &value));
    test_only.failNextKeyAllocation();
    try std.testing.expectEqual(API_OUT_OF_MEMORY, jsbay_value_set(object, .{ .data = "x", .len = 1 }, value, &exception));
    try std.testing.expectEqual(@as(u64, 0), exception);
    try std.testing.expectEqual(API_OK, jsbay_value_release(value));
    try std.testing.expectEqual(API_OK, jsbay_value_release(object));
}

fn noopLoopSchedule(_: ?*anyopaque, _: u64, _: LoopTask, _: ?*anyopaque) callconv(.c) bool {
    return false;
}

fn noopLoopCancel(_: ?*anyopaque) callconv(.c) void {}

fn bindOomCallback(_: i32, _: ?*anyopaque, _: u64, _: usize, _: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    return API_OK;
}

var bind_oom_finalize_count = std.atomic.Value(u32).init(0);

fn bindOomFinalize(_: ?*anyopaque) callconv(.c) void {
    _ = bind_oom_finalize_count.fetchAdd(1, .seq_cst);
}

test "c_api: bind OOM clears the pending QuickJS exception" {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) return;
    const id = @import("tests/test_helpers.zig").nextInstanceId();
    const m = backend.ActiveEngineModule;
    bind_oom_finalize_count.store(0, .seq_cst);
    try std.testing.expect(jsbay_engine_create(id, null, null));
    defer jsbay_engine_destroy(id);
    try std.testing.expect(jsbay_engine_set_memory_limit(id, 1));
    defer _ = jsbay_engine_set_memory_limit(id, 0);
    var held: [128]u64 = @splat(0);
    var count: usize = 0;
    while (count < held.len) : (count += 1) {
        var out: u64 = 99;
        var exception: u64 = 98;
        var name: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&name, "bind_oom_{d}", .{count});
        const status = jsbay_engine_bind(id, .{ .data = text.ptr, .len = text.len }, &bindOomCallback, null, &bindOomFinalize, &out, &exception);
        if (status == API_OK) {
            held[count] = out;
            continue;
        }
        try std.testing.expectEqual(API_OUT_OF_MEMORY, status);
        try std.testing.expect(out == 0 and exception == 0);
        try std.testing.expectEqual(@as(u32, 0), bind_oom_finalize_count.load(.seq_cst));
        const ctx = engine.getContext(id) orelse return error.NoContext;
        if (@TypeOf(m.qjs.JS_HasException(ctx)) == bool) {
            try std.testing.expect(!m.qjs.JS_HasException(ctx));
        } else {
            try std.testing.expect(m.qjs.JS_HasException(ctx) == 0);
        }
        for (held[0..count]) |value| try std.testing.expectEqual(API_OK, jsbay_value_release(value));
        try std.testing.expect(jsbay_engine_set_memory_limit(id, 0));
        var recovered: u64 = 0;
        exception = 0;
        try std.testing.expectEqual(API_OK, jsbay_engine_evaluate(id, .{ .data = "6*7", .len = 3 }, .{ .data = "bind.js", .len = 7 }, null, &recovered, &exception));
        try std.testing.expect(recovered != 0 and exception == 0);
        var number: f64 = 0;
        try std.testing.expectEqual(API_OK, jsbay_value_to_number(recovered, &number));
        try std.testing.expectEqual(@as(f64, 42), number);
        try std.testing.expectEqual(API_OK, jsbay_value_release(recovered));
        return;
    }
    return error.NoOom;
}

pub export fn jsbay_engine_bind(instance_id_raw: c_int, name_arg: Utf8, callback: ?api_bind.Callback, user_data: ?*anyopaque, finalize: ?api_bind.Finalize, out_function: *u64, out_exception: *u64) c_int {
    out_function.* = 0;
    out_exception.* = 0;
    const name = checkedUtf8(name_arg) orelse return API_INVALID_ARGUMENT;
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or !noEmbeddedNul(name)) return API_INVALID_ARGUMENT;
    const cb = callback orelse return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id_raw);
    if (packedTagOf(id) != null) return API_UNSUPPORTED;
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const installed = api_bind.install(id, op.ctx, name, cb, user_data, finalize);
    switch (installed) {
        .out_of_memory => return API_OUT_OF_MEMORY,
        .exception => |exception| {
            const stored = apiStore(id, exception, out_exception);
            return if (stored == API_OK) 1 else stored;
        },
        .installed => |ok| {
            const stored = apiStore(id, ok.function, out_function);
            if (stored == API_OK) api_bind.commit(ok.binding) else api_bind.abort(ok.binding);
            return stored;
        },
    }
}

pub const NativeSyncStart = *const fn (i32, ?*anyopaque, u64, u64, usize, ?[*]const u64) callconv(.c) void;

const SyncBinding = struct {
    start: NativeSyncStart,
    user_data: ?*anyopaque,
    finalize: ?api_bind.Finalize,
    timeout_ms: u64,
};

fn syncBindingFinalize(data: ?*anyopaque) callconv(.c) void {
    const binding: *SyncBinding = @ptrCast(@alignCast(data orelse return));
    if (binding.finalize) |finalize| finalize(binding.user_data);
    std.heap.c_allocator.destroy(binding);
}

fn syncError(instance_id: i32, message: []const u8, out_exception: *u64) c_int {
    const status = jsbay_value_new_error(instance_id, .{ .data = message.ptr, .len = message.len }, out_exception);
    return if (status == API_OK) API_EXCEPTION else status;
}

fn syncNewStringFromPayload(instance_id: i32, payload: []const u8, out_value: *u64) c_int {
    out_value.* = 0;
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    // UTF-8 already validated on the completer thread for STRING / EXCEPTION paths.
    const result = api_backend.newString(op.ctx, payload);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(instance_id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

fn syncAdoptOrCopyArrayBuffer(instance_id: i32, payload: []u8, out_value: *u64) c_int {
    out_value.* = 0;
    var op = switch (beginApiOp(instance_id)) {
        .status => |status| {
            std.heap.c_allocator.free(payload);
            return status;
        },
        .ok => |ok| ok,
    };
    defer op.deinit();

    if (comptime backend.isQuickJsApiBackend(backend.active_backend)) {
        const buffers = switch (comptime backend.active_backend) {
            .quickjs => @import("backend/quickjs/buffers.zig"),
            .quickjs_ng => @import("backend/quickjs_ng/buffers.zig"),
            .jsc, .escargot, .hermes => unreachable,
        };
        const freer = struct {
            fn f(_: ?*anyopaque, bytes: [*]u8, len: usize) callconv(.c) void {
                std.heap.c_allocator.free(bytes[0..len]);
            }
        }.f;
        const val = buffers.qjsNewArrayBufferFromBytes(op.ctx, payload.ptr, payload.len, freer, null);
        if (ActiveEngine.jsIsException(val)) return API_OUT_OF_MEMORY;
        return apiStore(instance_id, val, out_value);
    }

    const result = api_backend.newArrayBuffer(op.ctx, payload);
    std.heap.c_allocator.free(payload);
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.exception) |exception| {
        ActiveEngine.freeValue(op.ctx, exception);
        return API_OUT_OF_MEMORY;
    }
    return apiStore(instance_id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

fn syncTrampoline(instance_id: i32, data: ?*anyopaque, this_value: u64, argc: usize, args: ?[*]const u64, out_value: *u64, out_exception: *u64) callconv(.c) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const binding: *SyncBinding = @ptrCast(@alignCast(data orelse return API_INSTANCE_NOT_FOUND));
    // This covers the host start callback and the native wait. A host may receive queued work while here, but a reentrant tick must not execute it.
    var sync_wait = @import("runtime/js_scheduler.zig").beginSyncWait(instance_id) orelse return API_INSTANCE_NOT_FOUND;
    defer sync_wait.end();
    const started = native_sync.start(instance_id) orelse return API_OUT_OF_MEMORY;
    defer native_sync.finish(started.id, started.request);

    const started_at: u64 = @intCast(@import("platform/io.zig").monotonicMilliseconds());
    var deadline = std.math.add(u64, started_at, binding.timeout_ms) catch std.math.maxInt(u64);
    if (runtime_control.executionDeadlineMillis(instance_id)) |execution_deadline| deadline = @min(deadline, execution_deadline);
    native_sync.tightenDeadline(started.request, deadline);

    // The host start callback receives borrowed JS handles only while it is running. It may complete inline, but must otherwise hand only the ID to its system completion path.
    if (runtime_control.isInterruptRequested(instance_id) or runtime_control.isStopRequested(instance_id)) {
        native_sync.cancel(started.id);
    } else {
        binding.start(instance_id, binding.user_data, started.id, this_value, argc, args);
    }

    // A start callback can arm a shorter execution budget. Re-snapshot its absolute deadline after it returns, then tighten the request before waiting; a completion arriving after that deadline cannot win.
    if (runtime_control.executionDeadlineMillis(instance_id)) |execution_deadline| {
        deadline = @min(deadline, execution_deadline);
        native_sync.tightenDeadline(started.request, deadline);
    }
    const completed = native_sync.wait(started.request);
    switch (completed.outcome) {
        .ok, .exception => {
            const payload = native_sync.takePayload(started.request) orelse return syncError(instance_id, "native sync completion omitted payload", out_exception);
            switch (completed.kind) {
                .json => {
                    const utf8 = Utf8{ .data = payload.ptr, .len = payload.len };
                    var parsed: u64 = 0;
                    var parse_exception: u64 = 0;
                    const parsed_status = jsbay_value_new_json(instance_id, utf8, &parsed, &parse_exception);
                    std.heap.c_allocator.free(payload);
                    if (parsed_status != API_OK) {
                        out_exception.* = parse_exception;
                        return if (parsed_status == API_EXCEPTION) API_EXCEPTION else parsed_status;
                    }
                    if (completed.outcome == .ok) {
                        out_value.* = parsed;
                        return API_OK;
                    }
                    out_exception.* = parsed;
                    return API_EXCEPTION;
                },
                .utf8_string => {
                    if (completed.outcome == .exception) {
                        const status = syncError(instance_id, payload, out_exception);
                        std.heap.c_allocator.free(payload);
                        return status;
                    }
                    const status = syncNewStringFromPayload(instance_id, payload, out_value);
                    std.heap.c_allocator.free(payload);
                    return if (status == API_OK) API_OK else status;
                },
                .bytes => {
                    if (completed.outcome == .exception) {
                        const status = syncError(instance_id, payload, out_exception);
                        std.heap.c_allocator.free(payload);
                        return status;
                    }
                    // BYTES OK: prefer adopt (one engine-owned buffer) on QuickJS backends.
                    return syncAdoptOrCopyArrayBuffer(instance_id, payload, out_value);
                },
            }
        },
        .timeout => return syncError(instance_id, "native sync operation timed out", out_exception),
        .cancelled => return syncError(instance_id, "native sync operation cancelled", out_exception),
    }
}

/// Publish a native operation that synchronously waits for a data-only completion. See include/jsbay_sync.h for the cross-thread contract.
pub export fn jsbay_engine_bind_sync(instance_id_raw: c_int, name_arg: Utf8, start: ?NativeSyncStart, user_data: ?*anyopaque, finalize: ?api_bind.Finalize, timeout_ms: u64, out_function: *u64, out_exception: *u64) c_int {
    out_function.* = 0;
    out_exception.* = 0;
    const name = checkedUtf8(name_arg) orelse return API_INVALID_ARGUMENT;
    if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or !noEmbeddedNul(name) or timeout_ms == 0) return API_INVALID_ARGUMENT;
    const start_fn = start orelse return API_INVALID_ARGUMENT;
    const binding = std.heap.c_allocator.create(SyncBinding) catch return API_OUT_OF_MEMORY;
    binding.* = .{ .start = start_fn, .user_data = user_data, .finalize = finalize, .timeout_ms = timeout_ms };
    const status = jsbay_engine_bind(instance_id_raw, name_arg, &syncTrampoline, binding, &syncBindingFinalize, out_function, out_exception);
    if (status != API_OK) std.heap.c_allocator.destroy(binding);
    return status;
}

pub const SyncPayloadKindC = enum(c_int) {
    utf8_string = 0,
    bytes = 1,
    json = 2,
    _,
};

/// Typed data-only completion. Safe on a non-owner thread. Never enters a VM. Kind is required (no JSON-only alias).
pub export fn jsbay_sync_complete(request_id: u64, outcome_status: c_int, kind_raw: c_int, data_arg: Utf8) c_int {
    const data = checkedUtf8(data_arg) orelse return API_INVALID_ARGUMENT;
    const kind: native_sync.PayloadKind = switch (kind_raw) {
        @backingInt(SyncPayloadKindC.utf8_string) => .utf8_string,
        @backingInt(SyncPayloadKindC.bytes) => .bytes,
        @backingInt(SyncPayloadKindC.json) => .json,
        else => return API_INVALID_ARGUMENT,
    };
    const outcome: native_sync.Outcome = switch (outcome_status) {
        API_OK => .ok,
        API_EXCEPTION => .exception,
        else => return API_INVALID_ARGUMENT,
    };
    // UTF8_STRING and JSON always require valid UTF-8. BYTES+OK is opaque; EXCEPTION is always a UTF-8 error message.
    const needs_utf8 = kind != .bytes or outcome == .exception;
    if (needs_utf8 and !std.unicode.utf8ValidateSlice(data)) return API_INVALID_ARGUMENT;
    return switch (native_sync.complete(request_id, outcome, kind, data)) {
        .ok => API_OK,
        .stale => API_STALE_VALUE,
        .out_of_memory => API_OUT_OF_MEMORY,
    };
}

// ---- Event loop (optional, for platforms that need it) ----

fn testThreadRun_event_loop_once(instance_id: c_int) void {
    engine.runEventLoopOnce(@intCast(instance_id));
}

fn testThreadRun_event_loop(instance_id: c_int) void {
    engine.runEventLoop(@intCast(instance_id));
}

pub fn jsbay_engine_stop_event_loop(instance_id: c_int) void {
    engine.stopEventLoop(@intCast(instance_id));
}

fn testDispatchCString(instance_id: c_int, script: [*:0]const u8) bool {
    return engine.dispatchTask(@intCast(instance_id), script);
}

// ---- Internal helpers ----

fn sliceToCString(slice: []const u8) ?[*:0]const u8 {
    const z = std.heap.c_allocator.allocSentinel(u8, slice.len, 0) catch return null;
    @memcpy(z, slice);
    return z.ptr;
}

// ===========================================================================
// bytecode.zig
// ===========================================================================

pub export fn jsbay_engine_compile_bytecode(
    instance_id: c_int,
    source_arg: Utf8,
    filename_arg: Utf8,
    out_bytes: *Bytes,
    out_exception: *u64,
) c_int {
    out_bytes.* = .{ .data = null, .len = 0 };
    out_exception.* = 0;
    const source = checkedUtf8(source_arg) orelse return API_INVALID_ARGUMENT;
    const filename = checkedUtf8(filename_arg) orelse return API_INVALID_ARGUMENT;
    if (!std.unicode.utf8ValidateSlice(source) or !std.unicode.utf8ValidateSlice(filename) or !noEmbeddedNul(filename)) return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = typed_bytecode.compile(op.ctx, source, filename);
    if (!drainApiJobs(&op)) {
        discardTypedBytecodeResult(op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.unsupported) return API_UNSUPPORTED;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) API_EXCEPTION else stored;
    }
    const bytes = result.bytes orelse return API_OUT_OF_MEMORY;
    out_bytes.* = .{ .data = bytes.ptr, .len = bytes.len };
    return API_OK;
}

pub export fn jsbay_engine_run_bytecode(
    instance_id: c_int,
    bytes: ?[*]const u8,
    bytes_len: usize,
    out_value: *u64,
    out_exception: *u64,
) c_int {
    out_value.* = 0;
    out_exception.* = 0;
    const input: []const u8 = if (bytes) |ptr| ptr[0..bytes_len] else if (bytes_len == 0) "" else return API_INVALID_ARGUMENT;
    const id: i32 = @intCast(instance_id);
    var op = switch (beginApiOp(id)) {
        .status => |status| return status,
        .ok => |ok| ok,
    };
    defer op.deinit();
    const result = typed_bytecode.run(op.ctx, input);
    if (!drainApiJobs(&op)) {
        discardTypedBytecodeResult(op.ctx, result);
        return API_INSTANCE_NOT_FOUND;
    }
    if (result.out_of_memory) return API_OUT_OF_MEMORY;
    if (result.unsupported) return API_UNSUPPORTED;
    if (result.invalid_argument) return API_INVALID_ARGUMENT;
    if (result.exception) |exception| {
        const stored = apiStore(id, exception, out_exception);
        return if (stored == API_OK) API_EXCEPTION else stored;
    }
    return apiStore(id, result.value orelse return API_OUT_OF_MEMORY, out_value);
}

// ---------------------------------------------------------------------------
// Engine thread, host callbacks, and pointer+length eval.
// ---------------------------------------------------------------------------

fn bytesOf(ptr: [*]const u8, len: usize) []const u8 {
    if (len == 0) return "";
    return ptr[0..len];
}

fn testThreadId(instance_id: c_int) u64 {
    return engine_thread.threadId(@intCast(instance_id));
}

fn testThreadPost(
    instance_id: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
) u64 {
    return engine_thread.postScript(
        @intCast(instance_id),
        bytesOf(src, src_len),
        bytesOf(filename, filename_len),
    );
}

fn testThreadWait(
    instance_id: c_int,
    job_id: u64,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    return engine_thread.waitJob(@intCast(instance_id), job_id, timeout_ms, out_result, out_error);
}

fn testThreadBarrier(instance_id: c_int, timeout_ms: u64) c_int {
    return engine_thread.barrier(@intCast(instance_id), timeout_ms);
}

fn testThreadRun(
    instance_id: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    timeout_ms: u64,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    return engine_thread.runScript(
        @intCast(instance_id),
        bytesOf(src, src_len),
        bytesOf(filename, filename_len),
        timeout_ms,
        out_result,
        out_error,
    );
}

fn testThreadEvalCString(
    instance_id: c_int,
    src: [*]const u8,
    src_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    out_result: *?[*:0]u8,
    out_error: *?[*:0]u8,
) c_int {
    return engine_thread.evalBytes(
        @intCast(instance_id),
        bytesOf(src, src_len),
        bytesOf(filename, filename_len),
        out_result,
        out_error,
    );
}

test "c_api: create_with_limits rejects excess timers and reports usage" {
    const helpers = @import("tests/test_helpers.zig");
    const id = helpers.nextInstanceId();
    var limits = ResourceLimitsC{
        .struct_size = @sizeOf(ResourceLimitsC),
        .max_timers = 1,
        .max_tsfn_handles = 256,
        .max_pending_calls = 4096,
        .max_pending_bytes = 8 * 1024 * 1024,
        .max_pending_tasks = 4096,
    };
    try std.testing.expect(jsbay_engine_create_with_limits(id, null, null, &limits));
    defer jsbay_engine_destroy(id);

    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(id, "setTimeout(()=>{},2147483647)");

    var usage = ResourceUsageC{ .struct_size = @sizeOf(ResourceUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    try std.testing.expect(jsbay_engine_get_resource_usage(id, &usage));
    try std.testing.expectEqual(@as(usize, 1), usage.timers);
    try std.testing.expectEqual(@as(usize, 1), usage.max_timers);

    var global = ResourceGlobalUsageC{ .struct_size = @sizeOf(ResourceGlobalUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_native_tasks = 0, .max_script_tasks = 0, .max_pending_bytes = 0 };
    try std.testing.expect(jsbay_resource_global_usage(&global));
    try std.testing.expect(global.timers >= 1);
    try std.testing.expectEqual(@as(usize, 65536), global.max_timers);
}

test "c_api: independent instance budgets coexist under the process cap" {
    const helpers = @import("tests/test_helpers.zig");
    const a = helpers.nextInstanceId();
    const b = helpers.nextInstanceId();
    var limits_a = ResourceLimitsC{
        .struct_size = @sizeOf(ResourceLimitsC),
        .max_timers = 1,
        .max_tsfn_handles = 256,
        .max_pending_calls = 4096,
        .max_pending_bytes = 8 * 1024 * 1024,
        .max_pending_tasks = 4096,
    };
    var limits_b = limits_a;
    limits_b.max_timers = 2;
    try std.testing.expect(jsbay_engine_create_with_limits(a, null, null, &limits_a));
    defer jsbay_engine_destroy(a);
    try std.testing.expect(jsbay_engine_create_with_limits(b, null, null, &limits_b));
    defer jsbay_engine_destroy(b);

    try helpers.evalOk(a, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(a, "setTimeout(()=>{},2147483647)");
    try helpers.evalOk(b, "setTimeout(()=>{},2147483647)");
    try helpers.evalOk(b, "setTimeout(()=>{},2147483647)");
    try helpers.evalErr(b, "setTimeout(()=>{},2147483647)");

    var usage_a = ResourceUsageC{ .struct_size = @sizeOf(ResourceUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    var usage_b = usage_a;
    try std.testing.expect(jsbay_engine_get_resource_usage(a, &usage_a));
    try std.testing.expect(jsbay_engine_get_resource_usage(b, &usage_b));
    try std.testing.expectEqual(@as(usize, 1), usage_a.timers);
    try std.testing.expectEqual(@as(usize, 2), usage_b.timers);

    limits_b.max_timers = 1;
    try std.testing.expect(jsbay_engine_set_resource_limits(b, &limits_b));
    try helpers.evalErr(b, "setTimeout(()=>{},2147483647)");
}

test "c_api: resource limit helpers reject bad struct_size and null set" {
    const helpers = @import("tests/test_helpers.zig");
    const id = helpers.nextInstanceId();
    var bad = ResourceLimitsC{
        .struct_size = 4,
        .max_timers = 1,
        .max_tsfn_handles = 1,
        .max_pending_calls = 1,
        .max_pending_bytes = 1,
        .max_pending_tasks = 1,
    };
    try std.testing.expect(!jsbay_engine_create_with_limits(id, null, null, &bad));
    try std.testing.expect(jsbay_engine_create(id, null, null));
    defer jsbay_engine_destroy(id);
    try std.testing.expect(!jsbay_engine_set_resource_limits(id, null));
    var usage = ResourceUsageC{ .struct_size = 4, .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    try std.testing.expect(!jsbay_engine_get_resource_usage(id, &usage));
    var global = ResourceGlobalUsageC{ .struct_size = 4, .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_native_tasks = 0, .max_script_tasks = 0, .max_pending_bytes = 0 };
    try std.testing.expect(!jsbay_resource_global_usage(&global));
}

test "c_api: admission class defaults to FOREGROUND and mid-flight set keeps usage" {
    const helpers = @import("tests/test_helpers.zig");
    const id = helpers.nextInstanceId();
    try std.testing.expect(jsbay_engine_create(id, null, null));
    defer jsbay_engine_destroy(id);

    var cls: AdmissionClassC = .background;
    try std.testing.expect(jsbay_engine_get_admission_class(id, &cls));
    try std.testing.expectEqual(AdmissionClassC.foreground, cls);

    try helpers.evalOk(id, "setTimeout(()=>{},2147483647)");
    try std.testing.expect(jsbay_engine_set_admission_class(id, @backingInt(AdmissionClassC.background)));
    try std.testing.expect(jsbay_engine_get_admission_class(id, &cls));
    try std.testing.expectEqual(AdmissionClassC.background, cls);

    var usage = ResourceUsageC{ .struct_size = @sizeOf(ResourceUsageC), .timers = 0, .tsfn_handles = 0, .pending_calls = 0, .native_tasks = 0, .script_tasks = 0, .pending_bytes = 0, .max_timers = 0, .max_tsfn_handles = 0, .max_pending_calls = 0, .max_pending_bytes = 0, .max_pending_tasks = 0 };
    try std.testing.expect(jsbay_engine_get_resource_usage(id, &usage));
    try std.testing.expectEqual(@as(usize, 1), usage.timers);

    try std.testing.expect(!jsbay_engine_set_admission_class(id, 99));
    try std.testing.expect(!jsbay_engine_get_admission_class(id, null));
    try std.testing.expect(!jsbay_engine_set_admission_class(helpers.nextInstanceId(), 0));

    var global = std.mem.zeroes(ResourceGlobalUsageC);
    global.struct_size = @sizeOf(ResourceGlobalUsageC);
    try std.testing.expect(jsbay_resource_global_usage(&global));
    try std.testing.expectEqual(@as(usize, 16384), global.fg_headroom_timers);
    try std.testing.expectEqual(@as(usize, 49152), global.bg_effective_max_timers);
    try std.testing.expectEqual(@as(usize, 1024), global.fg_headroom_tsfn_handles);

    var legacy = std.mem.zeroes(ResourceGlobalUsageC);
    legacy.struct_size = @intCast(resource_global_usage_legacy_size);
    try std.testing.expect(jsbay_resource_global_usage(&legacy));
    try std.testing.expectEqual(@as(u32, @intCast(resource_global_usage_legacy_size)), legacy.struct_size);
}

// Test-only intentional native fault. Exported ONLY when built with `-Dfault-injection=true`.
// Never part of the published product ABI. See tests/process-isolation/ and docs/host-isolation.md.
comptime {
    if (@import("build_options").fault_injection) {
        const fault = struct {
            fn trigger(kind: c_int) callconv(.c) void {
                switch (kind) {
                    // 1: hard segfault via low-address store (kills same-process hosts).
                    1 => {
                        const p: *volatile u8 = @ptrFromInt(1);
                        p.* = 0x41;
                    },
                    // 2: Zig panic (typically abort / noreturn trap).
                    2 => std.debug.panic("jsbay intentional fault injection", .{}),
                    // 0 / default: process abort.
                    else => std.process.abort(),
                }
            }
        };
        @export(&fault.trigger, .{ .name = "jsbay_test_trigger_native_fault" });
    }
}
