//! Cross-backend JavaScript timer scheduler. Loop owns the sole deadline heap.
const std = @import("std");
const async_stack = @import("../inspector/async_stack.zig");
const backend = @import("../backend.zig");
const instance_map = @import("instance_map.zig");
const event_loop = @import("js_event_loop");
const ActiveEngine = backend.ActiveEngine;

pub fn normalizeDelay(delay: f64) u64 {
    if (std.math.isNan(delay) or delay <= 0) return 0;
    const max: f64 = @floatFromInt(std.math.maxInt(i32));
    if (delay >= max) return std.math.maxInt(i32);
    return @intFromFloat(delay);
}
test "timer delay normalization handles zero, fractions, and the maximum delay" {
    const t = std.testing;
    const max: u64 = std.math.maxInt(i32);
    try t.expectEqual(@as(u64, 0), normalizeDelay(-1));
    try t.expectEqual(@as(u64, 0), normalizeDelay(0));
    try t.expectEqual(@as(u64, 0), normalizeDelay(0.9));
    try t.expectEqual(@as(u64, 1), normalizeDelay(1.9));
    try t.expectEqual(@as(u64, 0), normalizeDelay(std.math.nan(f64)));
    try t.expectEqual(max, normalizeDelay(@floatFromInt(max)));
    try t.expectEqual(max, normalizeDelay(@as(f64, @floatFromInt(max)) + 1));
    try t.expectEqual(max, normalizeDelay(std.math.inf(f64)));
}

pub const TimerData = struct {
    const ReadyState = enum { none, ready, firing };
    const dispatch = @import("../backend_dispatch.zig");
    timer: event_loop.Timer = .{},
    allocator: std.mem.Allocator,
    resources: *@import("resource_limits.zig").Budget,
    backend_tag: backend.BackendType,
    ctx_addr: usize,
    callback_storage: [dispatch.value_storage_size]u8 = undefined,
    callback_len: u8,
    timer_id: i32,
    delay_ms: u64,
    is_interval: bool,
    instance_id: i32,
    closing: bool = false,
    in_callback: bool = false,
    async_trace: ?async_stack.Trace = null,
    pending_next: ?*TimerData = null,
    pending_prev: ?*TimerData = null,
    pending_deadline_ms: ?u64 = null,
    ready_next: ?*TimerData = null,
    ready_prev: ?*TimerData = null,
    ready_state: ReadyState = .none,

    fn callbackBytes(self: *const TimerData) []const u8 {
        return self.callback_storage[0..self.callback_len];
    }

    fn storeCallback(self: *TimerData, bytes: []const u8) void {
        std.debug.assert(bytes.len <= self.callback_storage.len);
        @memcpy(self.callback_storage[0..bytes.len], bytes);
        self.callback_len = @intCast(bytes.len);
    }

    fn clearCallback(self: *TimerData) void {
        self.callback_len = @intCast(dispatch.timerStoreUndefined(self.backend_tag, self.callback_storage[0..]));
    }
};
pub const TimerRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMap(i32, *TimerData),
    next_id: i32 = 1,
    clock_now: ?u64 = null,
    is_ticking: bool = false,
    pending_head: ?*TimerData = null,
    pending_tail: ?*TimerData = null,
    ready_head: ?*TimerData = null,
    ready_tail: ?*TimerData = null,
    firing_head: ?*TimerData = null,
    firing_tail: ?*TimerData = null,
    current_callback: ?*TimerData = null,
    pub fn init() TimerRegistry {
        return initWithAllocator(std.heap.c_allocator);
    }
    pub fn initWithAllocator(allocator: std.mem.Allocator) TimerRegistry {
        return .{ .allocator = allocator, .entries = std.AutoHashMap(i32, *TimerData).init(allocator) };
    }
    pub fn deinit(self: *TimerRegistry) void {
        self.entries.deinit();
    }
    fn appendPending(self: *TimerRegistry, data: *TimerData) void {
        data.pending_prev = self.pending_tail;
        data.pending_next = null;
        if (self.pending_tail) |x| x.pending_next = data else self.pending_head = data;
        self.pending_tail = data;
    }
    fn removePending(self: *TimerRegistry, data: *TimerData) void {
        if (data.pending_prev) |x| x.pending_next = data.pending_next else if (self.pending_head == data) self.pending_head = data.pending_next;
        if (data.pending_next) |x| x.pending_prev = data.pending_prev else if (self.pending_tail == data) self.pending_tail = data.pending_prev;
        data.pending_prev = null;
        data.pending_next = null;
    }
    fn appendReady(self: *TimerRegistry, data: *TimerData) void {
        data.ready_prev = self.ready_tail;
        data.ready_next = null;
        if (self.ready_tail) |x| x.ready_next = data else self.ready_head = data;
        self.ready_tail = data;
        data.ready_state = .ready;
    }
    fn removeReady(self: *TimerRegistry, data: *TimerData) void {
        if (data.ready_state != .ready) return;
        if (data.ready_prev) |x| x.ready_next = data.ready_next else if (self.ready_head == data) self.ready_head = data.ready_next;
        if (data.ready_next) |x| x.ready_prev = data.ready_prev else if (self.ready_tail == data) self.ready_tail = data.ready_prev;
        data.ready_prev = null;
        data.ready_next = null;
        data.ready_state = .none;
    }
    fn appendFiring(self: *TimerRegistry, data: *TimerData) void {
        data.ready_prev = self.firing_tail;
        data.ready_next = null;
        if (self.firing_tail) |x| x.ready_next = data else self.firing_head = data;
        self.firing_tail = data;
        data.ready_state = .firing;
    }
    fn removeFiring(self: *TimerRegistry, data: *TimerData) void {
        if (data.ready_state != .firing) return;
        if (data.ready_prev) |x| x.ready_next = data.ready_next else if (self.firing_head == data) self.firing_head = data.ready_next;
        if (data.ready_next) |x| x.ready_prev = data.ready_prev else if (self.firing_tail == data) self.firing_tail = data.ready_prev;
        data.ready_prev = null;
        data.ready_next = null;
        data.ready_state = .none;
    }
    fn armPending(self: *TimerRegistry) void {
        const now = self.clock_now orelse return;
        var data = self.pending_head;
        while (data) |item| : (data = item.pending_next) {
            if (item.pending_deadline_ms == null) {
                item.pending_deadline_ms = std.math.add(u64, now, item.delay_ms) catch std.math.maxInt(u64);
            }
        }
        data = self.pending_head;
        while (data) |item| : (data = item.pending_next) item.timer.reserve() catch return;
        data = self.pending_head;
        while (data) |item| {
            const next = item.pending_next;
            const deadline = item.pending_deadline_ms.?;
            item.timer.startAt(deadline) catch return;
            self.removePending(item);
            item.pending_deadline_ms = null;
            data = next;
        }
    }
};
fn nextId(id: i32) i32 {
    return if (id == std.math.maxInt(i32)) 1 else id + 1;
}
fn allocateId(registry: *const TimerRegistry) ?i32 {
    var id = registry.next_id;
    if (id <= 0) id = 1;
    var checked: usize = 0;
    while (checked <= registry.entries.count()) : (checked += 1) {
        if (!registry.entries.contains(id)) return id;
        id = nextId(id);
    }
    return null;
}
test "timer ID allocation skips live IDs across wraparound" {
    var registry = TimerRegistry.initWithAllocator(std.testing.allocator);
    defer registry.deinit();
    const placeholder: *TimerData = undefined;
    try registry.entries.put(1, placeholder);
    registry.next_id = 1;
    try std.testing.expectEqual(@as(?i32, 2), allocateId(&registry));
    try registry.entries.put(std.math.maxInt(i32), placeholder);
    registry.next_id = std.math.maxInt(i32);
    try std.testing.expectEqual(@as(?i32, 2), allocateId(&registry));
}

fn ctxToAddr(ctx: ActiveEngine.Context) usize {
    switch (@typeInfo(ActiveEngine.Context)) {
        .optional => {
            const p = ctx orelse return 0;
            return @intFromPtr(p);
        },
        .pointer => return @intFromPtr(ctx),
        else => @compileError("ActiveEngine.Context must be a pointer or optional pointer"),
    }
}


/// Type-erased schedule for primary and packed-alt timer bridges.
/// `callback_bytes` must match `valueByteSize(instance.backendTag())`.
pub fn scheduleOpaque(
    instance_id: i32,
    ctx_addr: usize,
    callback_bytes: []const u8,
    delay_ms: u64,
    is_interval: bool,
    async_trace: ?async_stack.Trace,
) ?i32 {
    const dispatch = @import("../backend_dispatch.zig");
    return instance_map.withInstanceReturn(instance_id, struct {
        ctx_addr: usize,
        callback_bytes: []const u8,
        delay_ms: u64,
        is_interval: bool,
        async_trace: ?async_stack.Trace,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?i32 {
            const tag = inst.backendTag();
            const expected = dispatch.valueByteSize(tag);
            if (expected == 0 or self.callback_bytes.len != expected or self.callback_bytes.len > dispatch.value_storage_size) return null;
            if (inst.teardown_pending or !inst.resources.reserve(.timer, 0)) return null;
            var committed = false;
            defer if (!committed) inst.resources.release(.timer, 0);
            if (inst.timers.clock_now != null) inst.timers.clock_now = @max(inst.timers.clock_now.?, inst.loop.now());
            const id = allocateId(&inst.timers) orelse return null;
            const data = inst.timers.allocator.create(TimerData) catch return null;
            data.* = .{
                .resources = inst.resources,
                .allocator = inst.timers.allocator,
                .backend_tag = tag,
                .ctx_addr = self.ctx_addr,
                .callback_len = 0,
                .timer_id = id,
                .delay_ms = self.delay_ms,
                .is_interval = self.is_interval,
                .instance_id = inst.instance_id,
                .async_trace = self.async_trace,
            };
            data.storeCallback(self.callback_bytes);
            data.timer.init(inst.loop, data, nativeTimerReady);
            const has_pending = inst.timers.pending_head != null;
            if (inst.timers.clock_now != null and !has_pending) data.timer.reserve() catch {
                data.timer.close();
                inst.timers.allocator.destroy(data);
                return null;
            };
            inst.timers.entries.put(id, data) catch {
                data.timer.close();
                inst.timers.allocator.destroy(data);
                return null;
            };
            if (inst.timers.clock_now) |now| {
                const deadline = std.math.add(u64, now, self.delay_ms) catch std.math.maxInt(u64);
                if (has_pending) {
                    data.pending_deadline_ms = deadline;
                    inst.timers.appendPending(data);
                } else data.timer.startAt(deadline) catch {
                    _ = inst.timers.entries.remove(id);
                    data.timer.close();
                    inst.timers.allocator.destroy(data);
                    return null;
                };
            } else inst.timers.appendPending(data);
            inst.timers.next_id = nextId(id);
            committed = true;
            return id;
        }
    }{ .ctx_addr = ctx_addr, .callback_bytes = callback_bytes, .delay_ms = delay_ms, .is_interval = is_interval, .async_trace = async_trace });
}

pub fn schedule(instance_id: i32, ctx: ActiveEngine.Context, callback: ActiveEngine.Value, delay_ms: u64, is_interval: bool, async_trace: ?async_stack.Trace) ?i32 {
    var callback_slot = callback;
    return scheduleOpaque(instance_id, ctxToAddr(ctx), std.mem.asBytes(&callback_slot), delay_ms, is_interval, async_trace);
}
fn nativeTimerReady(ctx: ?*anyopaque, _: *event_loop.Timer) void {
    const data: *TimerData = @ptrCast(@alignCast(ctx.?));
    instance_map.withInstance(data.instance_id, struct {
        data: *TimerData,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) void {
            if (!self.data.closing) inst.timers.appendReady(self.data);
        }
    }{ .data = data });
}
pub const TickStart = struct { now_ms: u64, reentrant: bool };
pub fn beginTick(instance_id: i32, requested_now_ms: u64) ?TickStart {
    return instance_map.withInstanceReturn(instance_id, struct {
        requested_now_ms: u64,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?TickStart {
            if (inst.timers.is_ticking) return .{ .now_ms = inst.timers.clock_now orelse self.requested_now_ms, .reentrant = true };
            inst.timers.is_ticking = true;
            const now = if (inst.timers.clock_now) |old| @max(old, self.requested_now_ms) else self.requested_now_ms;
            inst.timers.clock_now = now;
            inst.timers.armPending();
            return .{ .now_ms = now, .reentrant = false };
        }
    }{ .requested_now_ms = requested_now_ms });
}
pub fn endTick(instance_id: i32) void {
    instance_map.withInstance(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) void {
            inst.timers.is_ticking = false;
        }
    }{});
}
pub fn nextDeadlineForInstance(instance_id: i32) ?u64 {
    return instance_map.withInstanceReturn(instance_id, struct {
        pub fn call(_: @This(), inst: *instance_map.EngineInstance) ?u64 {
            return nextDeadline(inst);
        }
    }{});
}

pub fn cancel(instance_id: i32, timer_id: i32) void {
    const data = instance_map.withInstanceReturn(instance_id, struct {
        timer_id: i32,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) ?*TimerData {
            const data = inst.timers.entries.get(self.timer_id) orelse return null;
            _ = inst.timers.entries.remove(self.timer_id);
            inst.timers.removePending(data);
            inst.timers.removeReady(data);
            inst.timers.removeFiring(data);
            data.timer.close();
            data.closing = true;
            return data;
        }
    }{ .timer_id = timer_id }) orelse return;
    const dispatch = @import("../backend_dispatch.zig");
    dispatch.timerFreeValue(data.backend_tag, data.ctx_addr, data.callbackBytes());
    data.clearCallback();
    if (!data.in_callback) destroyTimerData(data);
}
/// Clear all timers. HashMap unlink runs under the instance-map registry mutex so any-thread
/// snapshot `timers_registered` cannot race destroy. JS value release runs after the unlock
/// (no JS callbacks under the registry lock). Destroy still sequences this after teardown mark
/// + control-plane drain; the mutex is hardening, not a substitute for that order.
pub fn cancelAll(instance: *instance_map.EngineInstance) void {
    const dispatch = @import("../backend_dispatch.zig");
    var free_head: ?*TimerData = null;
    instance_map.withInstance(instance.instance_id, struct {
        free_head: *?*TimerData,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) void {
            var iter = inst.timers.entries.iterator();
            while (iter.next()) |entry| {
                const data = entry.value_ptr.*;
                data.closing = true;
                data.timer.close();
                // Reuse pending_next as an intrusive free list (pending chain is cleared below).
                data.pending_next = self.free_head.*;
                data.pending_prev = null;
                data.pending_deadline_ms = null;
                self.free_head.* = data;
            }
            inst.timers.entries.clearRetainingCapacity();
            inst.timers.pending_head = null;
            inst.timers.pending_tail = null;
            inst.timers.ready_head = null;
            inst.timers.ready_tail = null;
            inst.timers.firing_head = null;
            inst.timers.firing_tail = null;
        }
    }{ .free_head = &free_head });
    var cur = free_head;
    while (cur) |data| {
        const next = data.pending_next;
        data.pending_next = null;
        dispatch.timerFreeValue(data.backend_tag, data.ctx_addr, data.callbackBytes());
        data.clearCallback();
        destroyTimerData(data);
        cur = next;
    }
}
pub fn fireDue(instance_id: i32, now_ms: u64) void {
    const engine_thread = @import("engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer @import("../engine.zig").finishEvalEntry(instance_id, lease);
    if (!lease.allowed or engine_thread.deferredDestroyRequested(lease)) return;
    if (@import("js_scheduler.zig").isTurnActive(instance_id)) return;
    while (fireOneDue(instance_id, now_ms)) {
        if (engine_thread.deferredDestroyRequested(lease)) return;
        @import("js_scheduler.zig").checkpointInstance(instance_id);
        if (instance_map.isTeardownPending(instance_id)) return;
    }
}

/// Run one ready timer callback. The caller owns the microtask checkpoint.
pub fn fireOneDue(instance_id: i32, now_ms: u64) bool {
    const engine_thread = @import("engine_thread.zig");
    const lease = engine_thread.beginEval(instance_id);
    defer @import("../engine.zig").finishEvalEntry(instance_id, lease);
    if (!lease.allowed or engine_thread.deferredDestroyRequested(lease)) return false;
    var queued = @import("js_scheduler.zig").beginQueuedTask(instance_id) orelse return false;
    const inst = instance_map.getInstance(instance_id) orelse {
        _ = queued.end();
        return false;
    };
    if (inst.timers.firing_head == null and inst.timers.ready_head != null) {
        inst.timers.firing_head = inst.timers.ready_head;
        inst.timers.firing_tail = inst.timers.ready_tail;
        inst.timers.ready_head = null;
        inst.timers.ready_tail = null;
        var data = inst.timers.firing_head;
        while (data) |item| : (data = item.ready_next) item.ready_state = .firing;
    }
    const data = inst.timers.firing_head orelse {
        _ = queued.end();
        return false;
    };
    inst.timers.removeFiring(data);
    fireOne(instance_id, data, now_ms, &queued);
    return true;
}
fn fireOne(instance_id: i32, data: *TimerData, now_ms: u64, queued: *(@import("js_event_loop").Scheduler.Task)) void {
    if (!data.is_interval) instance_map.withInstance(instance_id, struct {
        data: *TimerData,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) void {
            _ = inst.timers.entries.remove(self.data.timer_id);
        }
    }{ .data = data });
    data.in_callback = true;
    instance_map.withInstance(instance_id, struct {
        data: *TimerData,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) void {
            inst.timers.current_callback = self.data;
        }
    }{ .data = data });
    defer instance_map.withInstance(instance_id, struct {
        data: *TimerData,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) void {
            if (inst.timers.current_callback == self.data) inst.timers.current_callback = null;
        }
    }{ .data = data });
    const dispatch = @import("../backend_dispatch.zig");
    if (!data.closing and dispatch.timerIsFunction(data.backend_tag, data.ctx_addr, data.callbackBytes())) {
        var dup_buf: [dispatch.value_storage_size]u8 = undefined;
        const dup_len = dispatch.timerDupValue(data.backend_tag, data.ctx_addr, data.callbackBytes(), dup_buf[0..]) orelse 0;
        defer if (dup_len != 0) dispatch.timerFreeValue(data.backend_tag, data.ctx_addr, dup_buf[0..dup_len]);
        if (dup_len != 0) {
            const label: []const u8 = if (data.is_interval) "setInterval" else "setTimeout";
            const entered = if (data.async_trace) |parent| async_stack.enter(instance_id, label, parent) else false;
            defer if (entered) async_stack.leave(instance_id);
            if (dispatch.timerCallNoArgs(data.backend_tag, data.ctx_addr, dup_buf[0..dup_len])) |message| {
                defer std.heap.c_allocator.free(message);
                @import("../inspector/root.zig").exceptions.reportUncaught(instance_id, message, "");
            }
        }
    }
    _ = queued.end();
    data.in_callback = false;
    if (data.closing or !data.is_interval) {
        if (!data.closing) {
            data.closing = true;
            dispatch.timerFreeValue(data.backend_tag, data.ctx_addr, data.callbackBytes());
            data.clearCallback();
        }
        destroyTimerData(data);
        return;
    }
    instance_map.withInstance(instance_id, struct {
        data: *TimerData,
        now_ms: u64,
        pub fn call(self: @This(), inst: *instance_map.EngineInstance) void {
            if (!self.data.closing and !inst.teardown_pending and inst.timers.entries.get(self.data.timer_id) == self.data) {
                const deadline = std.math.add(u64, self.now_ms, self.data.delay_ms) catch std.math.maxInt(u64);
                // A live interval keeps its reservation, so this cannot fail from heap growth after the first successful arm.
                self.data.timer.startAt(deadline) catch unreachable;
            }
        }
    }{ .data = data, .now_ms = now_ms });
}
pub fn nextDeadline(instance: *const instance_map.EngineInstance) ?u64 {
    const timers = &instance.timers;
    if (timers.pending_head != null or timers.ready_head != null) return 0;
    if (timers.current_callback) |data| if (data.is_interval and !data.closing) return data.timer.deadline();
    if (timers.firing_head) |data| return data.timer.deadline();
    return null;
}
fn destroyTimerData(data: *TimerData) void {
    data.timer.close();
    if (data.async_trace) |trace| async_stack.freeTrace(trace);
    data.async_trace = null;
    const resources = data.resources;
    data.allocator.destroy(data);
    resources.release(.timer, 0);
}

test "scheduleOpaque rejects wrong-sized callback" {
    const junk: [3]u8 = .{0, 0, 0};
    try std.testing.expect(scheduleOpaque(1, 0, &junk, 0, false, null) == null);
}
