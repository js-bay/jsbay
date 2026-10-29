//! Native-function bridge for the typed public C ABI.
//!
//! Bindings deliberately survive replacement of their global property: an old function can still be held by JavaScript.  They are released only during runtime teardown, after no callback can remain on the JS stack.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const api_value = @import("api_value.zig");
const qjs = backend.ActiveEngineModule.qjs;
const jsc = @import("../backend/jsc/jsc_c.zig");

pub const Callback = *const fn (i32, ?*anyopaque, u64, usize, ?[*]const u64, *u64, *u64) callconv(.c) c_int;
pub const Finalize = *const fn (?*anyopaque) callconv(.c) void;

pub const Binding = struct {
    instance_id: i32,
    callback: Callback,
    user_data: ?*anyopaque,
    finalize: ?Finalize,
    name: [:0]u8,
    alive: bool = true,
    committed: bool = false,
    aborted: bool = false,
    retired: bool = false,
    function_key: usize = 0,
    // JSC bindings own a root distinct from the caller-owned return Value.
    jsc_ctx: ?backend.ActiveEngine.Context = null,
    jsc_root: ?backend.ActiveEngine.Value = null,
};

pub const Installed = struct { function: backend.ActiveEngine.Value, binding: *Binding };
pub const InstallResult = union(enum) { installed: Installed, exception: backend.ActiveEngine.Value, out_of_memory };

var mutex: sync.Mutex = .{};
var bindings: std.ArrayList(?*Binding) = .empty;

fn statusException(ctx: backend.ActiveEngine.Context, message: [*:0]const u8) backend.ActiveEngine.Value {
    const m = backend.ActiveEngineModule;
    _ = m.qjs.JS_ThrowTypeError(ctx, message);
    return m.c_api.JS_EXCEPTION;
}

pub fn install(id: i32, ctx: backend.ActiveEngine.Context, name: []const u8, callback: Callback, user_data: ?*anyopaque, finalize: ?Finalize) InstallResult {
    if (comptime !backend.isQuickJsApiBackend(backend.active_backend)) {
        return jscInstall(id, ctx, name, callback, user_data, finalize);
    }
    const m = backend.ActiveEngineModule;
    const name_z = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch return .out_of_memory;
    const binding = std.heap.c_allocator.create(Binding) catch {
        std.heap.c_allocator.free(name_z);
        return .out_of_memory;
    };
    binding.* = .{ .instance_id = id, .callback = callback, .user_data = user_data, .finalize = finalize, .name = name_z };
    mutex.lock();
    const slot = bindings.items.len;
    if (slot > std.math.maxInt(i32)) {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return .out_of_memory;
    }
    bindings.append(std.heap.c_allocator, binding) catch {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return .out_of_memory;
    };
    mutex.unlock();

    const data = m.c_api.jsbay_qjs_JS_NewInt32(ctx, @intCast(slot));
    if (m.c_api.jsIsException(data)) {
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, m.qjs.JS_GetException(ctx));
        kill(slot);
        return .out_of_memory;
    }
    defer m.c_api.jsbay_qjs_JS_FreeValue(ctx, data);
    const function = m.c_api.jsbay_qjs_JS_NewCFunctionData(ctx, &trampoline, name_z.ptr, 0, data);
    if (m.c_api.jsIsException(function)) {
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, m.qjs.JS_GetException(ctx));
        kill(slot);
        return .out_of_memory;
    }
    const global = m.qjs.JS_GetGlobalObject(ctx);
    const function_copy = m.c_api.jsbay_qjs_JS_DupValue(ctx, function);
    if (m.qjs.JS_SetPropertyStr(ctx, global, name_z.ptr, function_copy) < 0) {
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, global);
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, function);
        kill(slot);
        return .{ .exception = m.qjs.JS_GetException(ctx) };
    }
    const published = m.qjs.JS_GetPropertyStr(ctx, global, name_z.ptr);
    if (m.c_api.jsIsException(published)) {
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, global);
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, function);
        kill(slot);
        return .{ .exception = m.qjs.JS_GetException(ctx) };
    }
    const matches = m.weak.jsbay_qjsStrictEqual(ctx, published, function);
    m.c_api.jsbay_qjs_JS_FreeValue(ctx, published);
    if (!matches) {
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, global);
        m.c_api.jsbay_qjs_JS_FreeValue(ctx, function);
        kill(slot);
        _ = m.qjs.JS_ThrowTypeError(ctx, "native binding was not published");
        return .{ .exception = m.qjs.JS_GetException(ctx) };
    }
    m.c_api.jsbay_qjs_JS_FreeValue(ctx, global);
    return .{ .installed = .{ .function = function, .binding = binding } };
}

fn releaseJscRoot(binding: *Binding) void {
    if (comptime backend.active_backend != .jsc) return;
    const ctx = binding.jsc_ctx orelse return;
    const root = binding.jsc_root orelse return;
    binding.jsc_root = null;
    @import("../backend/jsc.zig").jsc.JSValueUnprotect(@ptrCast(ctx), root);
}

fn destroyBinding(binding: *Binding, run_finalize: bool) void {
    releaseJscRoot(binding);
    if (run_finalize and binding.committed) if (binding.finalize) |finalize| finalize(binding.user_data);
    std.heap.c_allocator.free(binding.name);
    std.heap.c_allocator.destroy(binding);
}

fn addBinding(binding: *Binding) ?usize {
    mutex.lock();
    defer mutex.unlock();
    const slot = bindings.items.len;
    if (slot > std.math.maxInt(i32)) return null;
    bindings.append(std.heap.c_allocator, binding) catch return null;
    return slot;
}

fn jscInstall(id: i32, ctx: backend.ActiveEngine.Context, name: []const u8, callback: Callback, user_data: ?*anyopaque, finalize: ?Finalize) InstallResult {
    const m = @import("../backend/jsc.zig");
    const ctx_ref: m.jsc.JSContextRef = @ptrCast(ctx);
    const name_z = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch return .out_of_memory;
    const js_name = @import("../backend/jsc/common.zig").jsStringFromSlice(name) orelse {
        std.heap.c_allocator.free(name_z);
        return .out_of_memory;
    };
    defer m.jsc.JSStringRelease(js_name);
    const function = m.jsc.JSObjectMakeFunctionWithCallback(ctx_ref, js_name, &jscTrampoline) orelse {
        std.heap.c_allocator.free(name_z);
        return .out_of_memory;
    };
    const binding = std.heap.c_allocator.create(Binding) catch {
        std.heap.c_allocator.free(name_z);
        return .out_of_memory;
    };
    // The binding table must root the function independently of the Value returned to the C caller. A released public handle must not make an escaped global function collectible or let its address be reused.
    m.jsc.JSValueProtect(ctx_ref, function);
    binding.* = .{ .instance_id = id, .callback = callback, .user_data = user_data, .finalize = finalize, .name = name_z, .function_key = @intFromPtr(function), .jsc_ctx = ctx, .jsc_root = function };
    _ = addBinding(binding) orelse {
        releaseJscRoot(binding);
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return .out_of_memory;
    };
    const global = m.jsc.JSContextGetGlobalObject(ctx_ref);
    var exception: m.jsc.JSValueRef = null;
    m.jsc.JSObjectSetProperty(ctx_ref, global, js_name, function, 0, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        killFunction(binding.function_key);
        return .{ .exception = exception };
    }
    const published = m.jsc.JSObjectGetProperty(ctx_ref, global, js_name, &exception);
    if (exception != null) {
        m.jsc.JSValueProtect(ctx_ref, exception);
        killFunction(binding.function_key);
        return .{ .exception = exception };
    }
    if (published == null) {
        killFunction(binding.function_key);
        return .out_of_memory;
    }
    if (!@import("../backend/jsc/weak.zig").jsbay_qjsStrictEqual(ctx_ref, published, function)) {
        // JSObjectSetProperty is intentionally non-strict.  A readonly global can therefore ignore the assignment without throwing.  Use JSC's direct Error constructor, rather than a mutable global constructor.
        const failed = @import("../backend/jsc/common.zig").throwError(ctx_ref, &exception, "native binding was not published");
        m.jsc.JSValueProtect(ctx_ref, failed);
        killFunction(binding.function_key);
        return .{ .exception = failed };
    }
    // Transfer a second root to apiStore()/the returned public Value.
    m.jsc.JSValueProtect(ctx_ref, function);
    return .{ .installed = .{ .function = function, .binding = binding } };
}

pub fn commit(binding: *Binding) void {
    mutex.lock();
    defer mutex.unlock();
    if (binding.alive) binding.committed = true;
}

/// Failed C API binding does not transfer user_data. Leave any function that escaped through an accessor as a tombstone so it rejects safely.
pub fn abort(binding: *Binding) void {
    mutex.lock();
    if (binding.retired) {
        mutex.unlock();
        std.heap.c_allocator.free(binding.name);
        std.heap.c_allocator.destroy(binding);
        return;
    }
    if (!binding.alive) {
        mutex.unlock();
        return;
    }
    binding.alive = false;
    binding.aborted = true;
    mutex.unlock();
}

fn copy(slot: usize) ?Binding {
    mutex.lock();
    defer mutex.unlock();
    const binding = if (slot < bindings.items.len) bindings.items[slot] else null;
    const live = binding orelse return null;
    if (!live.alive) return null;
    return live.*;
}

fn kill(slot: usize) void {
    mutex.lock();
    const binding = if (slot < bindings.items.len) bindings.items[slot] else null;
    if (slot < bindings.items.len) bindings.items[slot] = null;
    mutex.unlock();
    if (binding) |item| destroyBinding(item, false);
}

fn killFunction(key: usize) void {
    mutex.lock();
    var retired: ?*Binding = null;
    for (bindings.items) |*entry| {
        const binding = entry.* orelse continue;
        if (binding.function_key == key) {
            retired = binding;
            entry.* = null;
            break;
        }
    }
    mutex.unlock();
    if (retired) |item| destroyBinding(item, false);
}

pub fn dropInstance(id: i32) void {
    // Detach one binding at a time so teardown never allocates.  A finalizer is arbitrary host code and therefore always runs after releasing the registry lock.
    while (true) {
        mutex.lock();
        var retired: ?*Binding = null;
        var provisional: ?*Binding = null;
        for (bindings.items) |*entry| {
            const binding = entry.* orelse continue;
            if (binding.instance_id != id) continue;
            entry.* = null;
            // An accessor can request destroy while install() is still waiting to publish its function handle.  The caller will shortly abort that provisional binding, so preserve its allocation until then.
            if (!binding.committed and !binding.aborted) {
                binding.alive = false;
                binding.retired = true;
                provisional = binding;
                continue;
            }
            retired = binding;
            break;
        }
        mutex.unlock();
        if (provisional) |binding| releaseJscRoot(binding);
        const binding = retired orelse {
            if (provisional != null) continue;
            break;
        };
        destroyBinding(binding, true);
    }
}

fn trampoline(ctx: ?*qjs.JSContext, this_value: qjs.JSValue, argc: c_int, argv: [*c]qjs.JSValue, _: c_int, func_data: [*c]qjs.JSValue) callconv(.c) qjs.JSValue {
    const m = backend.ActiveEngineModule;
    var slot_i64: i64 = 0;
    if (m.qjs.JS_ToInt64(ctx, &slot_i64, func_data[0]) < 0 or slot_i64 < 0) return m.c_api.JS_EXCEPTION;
    const binding = copy(@intCast(slot_i64)) orelse return statusException(ctx, "native binding is gone");
    const count: usize = if (argc > 0) @intCast(argc) else 0;
    var handles = std.ArrayList(u64).empty;
    defer handles.deinit(std.heap.c_allocator);
    handles.ensureTotalCapacity(std.heap.c_allocator, count) catch return m.qjs.JS_ThrowOutOfMemory(ctx);
    const borrowed_this = api_value.putBorrowed(binding.instance_id, this_value) orelse return m.qjs.JS_ThrowOutOfMemory(ctx);
    defer api_value.revokeBorrowed(borrowed_this);
    defer for (handles.items) |handle| api_value.revokeBorrowed(handle);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const handle = api_value.putBorrowed(binding.instance_id, argv[i]) orelse return m.qjs.JS_ThrowOutOfMemory(ctx);
        handles.appendAssumeCapacity(handle);
    }
    var result: u64 = 0;
    var exception: u64 = 0;
    const rc = binding.callback(binding.instance_id, binding.user_data, borrowed_this, count, if (count == 0) null else handles.items.ptr, &result, &exception);
    if (rc == 0 and result != 0 and exception == 0) {
        const value = api_value.takeOwned(result) orelse return statusException(ctx, "invalid native callback result");
        if (value.instance_id != binding.instance_id) {
            api_value.freeTaken(value);
            return statusException(ctx, "native callback returned foreign value");
        }
        return value.value;
    }
    if (rc == 1 and result == 0 and exception != 0) {
        const thrown = api_value.takeOwned(exception) orelse return statusException(ctx, "invalid native callback exception");
        if (thrown.instance_id != binding.instance_id) {
            api_value.freeTaken(thrown);
            return statusException(ctx, "native callback returned foreign exception");
        }
        return m.qjs.JS_Throw(ctx, thrown.value);
    }
    return statusException(ctx, "native callback returned invalid status");
}

fn jscTrampoline(ctx: jsc.JSContextRef, function: jsc.JSObjectRef, this_value: jsc.JSObjectRef, argc: usize, argv: [*c]const jsc.JSValueRef, exception: [*c]jsc.JSValueRef) callconv(.c) jsc.JSValueRef {
    const m = @import("../backend/jsc.zig");
    const common = @import("../backend/jsc/common.zig");
    const key = @intFromPtr(function orelse return common.throwError(ctx, exception, "native binding is gone"));
    var binding: ?Binding = null;
    mutex.lock();
    for (bindings.items) |entry| {
        const item = entry orelse continue;
        if (item.function_key == key and item.alive) {
            binding = item.*;
            break;
        }
    }
    mutex.unlock();
    const live = binding orelse return common.throwError(ctx, exception, "native binding is gone");
    const borrowed_this = api_value.putBorrowed(live.instance_id, this_value) orelse return common.throwError(ctx, exception, "out of memory");
    defer api_value.revokeBorrowed(borrowed_this);
    var handles = std.ArrayList(u64).empty;
    defer handles.deinit(std.heap.c_allocator);
    handles.ensureTotalCapacity(std.heap.c_allocator, argc) catch return common.throwError(ctx, exception, "out of memory");
    defer for (handles.items) |handle| api_value.revokeBorrowed(handle);
    var i: usize = 0;
    while (i < argc) : (i += 1) {
        const handle = api_value.putBorrowed(live.instance_id, argv[i]) orelse return common.throwError(ctx, exception, "out of memory");
        handles.appendAssumeCapacity(handle);
    }
    var result: u64 = 0;
    var thrown: u64 = 0;
    const rc = live.callback(live.instance_id, live.user_data, borrowed_this, argc, if (argc == 0) null else handles.items.ptr, &result, &thrown);
    if (rc == 0 and result != 0 and thrown == 0) {
        const owned = api_value.takeOwned(result) orelse return common.throwError(ctx, exception, "invalid native callback result");
        if (owned.instance_id != live.instance_id) {
            api_value.freeTaken(owned);
            return common.throwError(ctx, exception, "native callback returned foreign value");
        }
        const raw = common.liftValue(ctx, owned.value);
        backend.ActiveEngine.freeValue(@ptrCast(@constCast(ctx)), owned.value);
        return raw;
    }
    if (rc == 1 and result == 0 and thrown != 0) {
        const owned = api_value.takeOwned(thrown) orelse return common.throwError(ctx, exception, "invalid native callback exception");
        if (owned.instance_id != live.instance_id) {
            api_value.freeTaken(owned);
            return common.throwError(ctx, exception, "native callback returned foreign exception");
        }
        exception.* = common.liftValue(ctx, owned.value);
        backend.ActiveEngine.freeValue(@ptrCast(@constCast(ctx)), owned.value);
        return m.jsc.JSValueMakeUndefined(ctx);
    }
    return common.throwError(ctx, exception, "native callback returned invalid status");
}
