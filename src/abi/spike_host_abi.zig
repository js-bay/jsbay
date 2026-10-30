//! Install pointer+length host functions on Escargot/Hermes globals (engine_thread hostInstall).
//! Same HostValue ABI as QuickJS/JSC host_abi; trampoline uses ActiveEngine makeNativeFunction.
//!
//! Escargot: Context is thread-affine (Shell creates VM per worker thread). Creating
//! Context on the calling thread then evaluating host globals on the engine thread
//! SEGV's in AtomicString/GC. hostInstall is same-thread only on Escargot: refuse when
//! the engine thread is already running; threadStart refuses if hosts are already installed.
//! Full "create Context on ET" would be a large lifecycle refactor — diminishing returns.

const std = @import("std");
const sync = @import("zev");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const host_value = @import("host_value.zig");

const Binding = struct {
    instance_id: i32,
    func: host_value.HostFn,
    user_data: ?*anyopaque,
    name: [:0]u8,
    alive: bool,
};

var mutex: sync.Mutex = .{};
var slots: std.ArrayList(?*Binding) = .empty;

/// True when this instance still has a live spike_host_abi binding.
pub fn hasBindings(instance_id: i32) bool {
    mutex.lock();
    defer mutex.unlock();
    for (slots.items) |entry| {
        const binding = entry orelse continue;
        if (binding.instance_id == instance_id and binding.alive) return true;
    }
    return false;
}

pub fn install(
    instance_id: i32,
    name: []const u8,
    func: host_value.HostFn,
    user_data: ?*anyopaque,
) bool {
    if (comptime !backend.isSpikeBackend(backend.active_backend)) return false;
    // Escargot: refuse cross-thread install once the engine thread owns the Context.
    if (comptime backend.active_backend == .escargot) {
        const et = @import("../runtime/engine_thread.zig");
        if (et.threadId(instance_id) != 0) return false;
    }
    const ptrs = instance_map.getPtrs(instance_id) orelse return false;
    const ctx = ptrs.ctx;

    const name_z = std.heap.c_allocator.allocSentinel(u8, name.len, 0) catch return false;
    @memcpy(name_z, name);

    const binding = std.heap.c_allocator.create(Binding) catch {
        std.heap.c_allocator.free(name_z);
        return false;
    };
    binding.* = .{
        .instance_id = instance_id,
        .func = func,
        .user_data = user_data,
        .name = name_z,
        .alive = true,
    };

    mutex.lock();
    const slot = slots.items.len;
    if (slot > std.math.maxInt(usize) - 2) {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return false;
    }
    slots.append(std.heap.c_allocator, binding) catch {
        mutex.unlock();
        std.heap.c_allocator.free(name_z);
        std.heap.c_allocator.destroy(binding);
        return false;
    };
    mutex.unlock();

    const ud: ?*anyopaque = @ptrFromInt(slot + 1);
    const js_fn = backend.ActiveEngine.makeNativeFunction(ctx, name, &trampoline, ud) orelse {
        killSlot(slot);
        return false;
    };
    const global = backend.ActiveEngine.getGlobalObject(ctx);
    if (comptime backend.active_backend == .escargot) {
        // Match Shell/cctest: defineDataProperty on globalObject.
        _ = backend.ActiveEngine.defineDataProperty(ctx, global, name_z.ptr, js_fn, true);
        backend.ActiveEngine.freeValue(ctx, js_fn);
    } else {
        backend.ActiveEngine.setPropertyStr(ctx, global, name_z.ptr, js_fn);
    }
    backend.ActiveEngine.freeValue(ctx, global);
    return true;
}

pub fn releaseInstance(instance_id: i32) void {
    mutex.lock();
    defer mutex.unlock();
    for (slots.items) |*entry| {
        const binding = entry.* orelse continue;
        if (binding.instance_id != instance_id) continue;
        binding.alive = false;
        std.heap.c_allocator.free(binding.name);
        std.heap.c_allocator.destroy(binding);
        entry.* = null;
    }
}

fn killSlot(slot: usize) void {
    mutex.lock();
    defer mutex.unlock();
    if (slot >= slots.items.len) return;
    const binding = slots.items[slot] orelse return;
    binding.alive = false;
    std.heap.c_allocator.free(binding.name);
    std.heap.c_allocator.destroy(binding);
    slots.items[slot] = null;
}

const CopiedCall = struct {
    func: host_value.HostFn,
    user_data: ?*anyopaque,
    instance_id: i32,
};

fn lookup(slot: usize) ?CopiedCall {
    mutex.lock();
    defer mutex.unlock();
    if (slot >= slots.items.len) return null;
    const binding = slots.items[slot] orelse return null;
    if (!binding.alive) return null;
    return .{
        .func = binding.func,
        .user_data = binding.user_data,
        .instance_id = binding.instance_id,
    };
}

fn throwMsg(ctx: backend.ActiveEngine.Context, message: [*:0]const u8) backend.ActiveEngine.Value {
    if (comptime backend.active_backend == .escargot) {
        @import("../backend/escargot/c_api.zig").escargot_throw(ctx, message);
        return null;
    }
    if (comptime backend.active_backend == .hermes) {
        @import("../backend/hermes/c_api.zig").hermes_throw(ctx, message);
        return null;
    }
    return null;
}

fn trampoline(
    ctx: backend.ActiveEngine.Context,
    _: backend.ActiveEngine.Value,
    args: ?[*]const backend.ActiveEngine.Value,
    argc: usize,
    user_data: ?*anyopaque,
) callconv(.c) backend.ActiveEngine.Value {
    const slot_addr = @intFromPtr(user_data orelse return throwMsg(ctx, "host binding is gone"));
    if (slot_addr == 0) return throwMsg(ctx, "host binding is gone");
    const call = lookup(slot_addr - 1) orelse return throwMsg(ctx, "host binding is gone");

    var small: [8]host_value.HostValue = undefined;
    var owned_strings: [8]?[]u8 = @splat(null);
    var heap_args: ?[]host_value.HostValue = null;
    var heap_strs: ?[]?[]u8 = null;
    defer {
        if (heap_strs) |hs| {
            for (hs) |s| if (s) |b| std.heap.c_allocator.free(b);
            std.heap.c_allocator.free(hs);
        } else {
            for (owned_strings) |s| if (s) |b| std.heap.c_allocator.free(b);
        }
        if (heap_args) |ha| std.heap.c_allocator.free(ha);
    }

    const hv: []host_value.HostValue = if (argc <= small.len)
        small[0..argc]
    else blk: {
        heap_args = std.heap.c_allocator.alloc(host_value.HostValue, argc) catch
            return throwMsg(ctx, "out of memory");
        break :blk heap_args.?;
    };
    const strs: []?[]u8 = if (argc <= owned_strings.len)
        owned_strings[0..argc]
    else blk: {
        heap_strs = std.heap.c_allocator.alloc(?[]u8, argc) catch
            return throwMsg(ctx, "out of memory");
        @memset(heap_strs.?, null);
        break :blk heap_strs.?;
    };

    var i: usize = 0;
    while (i < argc) : (i += 1) {
        host_value.clear(&hv[i]);
        strs[i] = null;
        const val = if (args) |a| a[i] else null;
        if (backend.ActiveEngine.isNumber(ctx, val)) {
            if (backend.ActiveEngine.toFloat64(ctx, val)) |number| {
                hv[i] = .{
                    .tag = host_value.tag_number,
                    .reserved = 0,
                    .number = number,
                    .ptr = null,
                    .len = 0,
                };
            }
        } else if (backend.ActiveEngine.isString(ctx, val)) {
            if (backend.ActiveEngine.valueToStringVal(ctx, val)) |bytes| {
                strs[i] = @constCast(bytes);
                hv[i] = .{
                    .tag = host_value.tag_string,
                    .reserved = 0,
                    .number = 0,
                    .ptr = bytes.ptr,
                    .len = bytes.len,
                };
            }
        }
    }

    var out: host_value.HostValue = undefined;
    host_value.clear(&out);
    const argv_ptr: ?[*]const host_value.HostValue = if (argc == 0) null else hv.ptr;
    const rc = call.func(call.instance_id, call.user_data, @intCast(argc), argv_ptr, &out);
    if (rc != 0) return throwMsg(ctx, "host function failed");

    // See runtime_control.softRearmHermesStopAfterHost — peel destroy-defer on Hermes.
    @import("../runtime/runtime_control.zig").softRearmHermesStopAfterHost(call.instance_id);

    return switch (out.tag) {
        host_value.tag_undefined => backend.ActiveEngine.undefinedValue(),
        host_value.tag_number => backend.ActiveEngine.newFloat64Val(ctx, out.number),
        host_value.tag_string => blk: {
            const slice: []const u8 = if (out.len == 0 or out.ptr == null)
                ""
            else
                out.ptr.?[0..out.len];
            break :blk backend.ActiveEngine.newStringVal(ctx, slice);
        },
        else => backend.ActiveEngine.undefinedValue(),
    };
}
