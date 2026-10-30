//! Data-only completion registry for a native operation that returns into JS. Completion threads copy bytes and wake the owner; they never enter a VM.

const std = @import("std");
const zev = @import("zev");
const builtin = @import("builtin");

pub const Outcome = enum { ok, exception, timeout, cancelled };

const Request = struct {
    instance_id: i32,
    mutex: zev.Mutex = .{},
    changed: zev.Condition = .init,
    outcome: ?Outcome = null,
    json: ?[]u8 = null,
    completed_at_ms: u64 = 0,
    deadline_ms: u64 = std.math.maxInt(u64),
    delivered: bool = false,
    refs: std.atomic.Value(usize) = .init(2),

    fn deinit(self: *Request) void {
        if (self.json) |bytes| std.heap.c_allocator.free(bytes);
        self.changed.deinit();
        self.mutex.deinit();
        std.heap.c_allocator.destroy(self);
    }
};

var registry_mutex: zev.Mutex = .{};
var requests = std.AutoHashMap(u64, *Request).init(std.heap.c_allocator);
var next_id: u64 = 1;
var ids_exhausted = false;

pub const Started = struct { id: u64, request: *Request };
pub const Completed = struct { outcome: Outcome, json: ?[]u8 };

pub fn start(instance_id: i32) ?Started {
    const request = std.heap.c_allocator.create(Request) catch return null;
    request.* = .{ .instance_id = instance_id };
    registry_mutex.lock();
    defer registry_mutex.unlock();
    if (ids_exhausted) {
        request.changed.deinit();
        request.mutex.deinit();
        std.heap.c_allocator.destroy(request);
        return null;
    }
    const id = next_id;
    if (next_id == std.math.maxInt(u64)) ids_exhausted = true else next_id += 1;
    requests.put(id, request) catch {
        request.changed.deinit();
        request.mutex.deinit();
        std.heap.c_allocator.destroy(request);
        return null;
    };
    return .{ .id = id, .request = request };
}

fn release(request: *Request) void {
    if (request.refs.fetchSub(1, .acq_rel) == 1) request.deinit();
}

pub fn complete(id: u64, outcome: Outcome, json: []const u8) enum { ok, stale, out_of_memory } {
    if (id == 0) return .stale;
    const copy = std.heap.c_allocator.alloc(u8, json.len) catch return .out_of_memory;
    @memcpy(copy, json);
    registry_mutex.lock();
    const request = requests.get(id) orelse {
        registry_mutex.unlock();
        std.heap.c_allocator.free(copy);
        return .stale;
    };
    _ = request.refs.fetchAdd(1, .acq_rel);
    request.mutex.lock();
    registry_mutex.unlock();
    if (builtin.is_test) test_only.notifyCompleteObserver();
    defer {
        request.mutex.unlock();
        release(request);
    }
    if (request.outcome != null) {
        std.heap.c_allocator.free(copy);
        return .stale;
    }
    const now = zev.monotonicMilliseconds();
    if (now >= request.deadline_ms) {
        request.outcome = .timeout;
        request.changed.broadcast();
        std.heap.c_allocator.free(copy);
        return .stale;
    }
    request.json = copy;
    request.outcome = outcome;
    request.completed_at_ms = now;
    request.changed.broadcast();
    return .ok;
}

fn tightenDeadlineLocked(request: *Request, deadline_ms: u64) void {
    const deadline_was_tightened = deadline_ms < request.deadline_ms;
    request.deadline_ms = @min(request.deadline_ms, deadline_ms);
    if (request.delivered) return;
    if (request.outcome) |outcome| {
        if (outcome == .ok or outcome == .exception) {
            if (request.completed_at_ms >= request.deadline_ms) {
                if (request.json) |bytes| std.heap.c_allocator.free(bytes);
                request.json = null;
                request.outcome = .timeout;
                request.changed.broadcast();
            }
        }
    } else {
        if (zev.monotonicMilliseconds() >= request.deadline_ms) {
            request.outcome = .timeout;
        }
        if (deadline_was_tightened or request.outcome != null) request.changed.broadcast();
    }
}

pub fn tightenDeadline(request: *Request, deadline_ms: u64) void {
    request.mutex.lock();
    defer request.mutex.unlock();
    tightenDeadlineLocked(request, deadline_ms);
}

pub fn tightenDeadlinesForInstance(instance_id: i32, deadline_ms: u64) void {
    registry_mutex.lock();
    defer registry_mutex.unlock();
    var it = requests.valueIterator();
    while (it.next()) |entry| {
        const request = entry.*;
        if (request.instance_id != instance_id) continue;
        request.mutex.lock();
        tightenDeadlineLocked(request, deadline_ms);
        request.mutex.unlock();
    }
}

/// This deliberately waits only on native synchronization. It never pumps a JavaScript event loop, so a completion cannot depend on queued JS work.
pub fn wait(request: *Request) Completed {
    request.mutex.lock();
    defer request.mutex.unlock();
    while (request.outcome == null) {
        const now = zev.monotonicMilliseconds();
        if (now >= request.deadline_ms) {
            request.outcome = .timeout;
            break;
        }
        if (builtin.is_test) test_only.notifyWaitObserver();
        _ = request.changed.waitTimeout(&request.mutex, request.deadline_ms - now);
    }
    const completed = Completed{ .outcome = request.outcome.?, .json = request.json };
    request.delivered = true;
    return completed;
}

pub fn finish(id: u64, request: *Request) void {
    registry_mutex.lock();
    const removed = requests.fetchRemove(id);
    registry_mutex.unlock();
    std.debug.assert(removed != null and removed.?.value == request);
    release(request);
    release(request);
}

pub fn cancelForInstance(instance_id: i32) void {
    registry_mutex.lock();
    var it = requests.valueIterator();
    while (it.next()) |entry| {
        const request = entry.*;
        if (request.instance_id != instance_id) continue;
        request.mutex.lock();
        if (request.outcome == null) {
            request.outcome = .cancelled;
            request.changed.broadcast();
        }
        request.mutex.unlock();
    }
    registry_mutex.unlock();
}

pub fn cancel(id: u64) void {
    registry_mutex.lock();
    const request = requests.get(id) orelse {
        registry_mutex.unlock();
        return;
    };
    _ = request.refs.fetchAdd(1, .acq_rel);
    request.mutex.lock();
    registry_mutex.unlock();
    if (request.outcome == null) {
        request.outcome = .cancelled;
        request.changed.broadcast();
    }
    request.mutex.unlock();
    release(request);
}

pub const test_only = if (builtin.is_test) struct {
    pub const CompleteObserver = *const fn (?*anyopaque) void;
    pub const WaitObserver = *const fn (?*anyopaque) void;

    var complete_observer: ?CompleteObserver = null;
    var complete_observer_context: ?*anyopaque = null;
    var wait_observer: ?WaitObserver = null;
    var wait_observer_context: ?*anyopaque = null;

    /// The observer runs with the request mutex locked and no registry mutex.
    pub fn setCompleteObserver(observer: ?CompleteObserver, context: ?*anyopaque) void {
        complete_observer = observer;
        complete_observer_context = context;
    }

    fn notifyCompleteObserver() void {
        if (complete_observer) |observer| observer(complete_observer_context);
    }

    /// The observer runs with the request mutex locked and no registry mutex.
    pub fn setWaitObserver(observer: ?WaitObserver, context: ?*anyopaque) void {
        wait_observer = observer;
        wait_observer_context = context;
    }

    fn notifyWaitObserver() void {
        if (wait_observer) |observer| observer(wait_observer_context);
    }

    pub fn setNextId(id: u64) void {
        registry_mutex.lock();
        defer registry_mutex.unlock();
        next_id = id;
        ids_exhausted = false;
    }
} else struct {
    fn notifyCompleteObserver() void {}
    fn notifyWaitObserver() void {}
};
