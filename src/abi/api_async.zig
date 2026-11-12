//! Thread-safe completion records for the public Promise C ABI.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("zev");
const backend = @import("../backend.zig");
const api_backend = @import("api_backend.zig");
const api_value = @import("api_value.zig");
const promise = @import("../runtime/promise.zig");
const dispatch = @import("../runtime/dispatch.zig");
const instance_map = @import("../runtime/instance_map.zig");
const resource_limits = @import("../runtime/resource_limits.zig");
const runtime_control = @import("../runtime/runtime_control.zig");

const ActiveEngine = backend.ActiveEngine;

pub const Outcome = enum(c_int) { ok = 0, exception = 1 };
pub const PayloadKind = enum(c_int) { utf8_string = 0, bytes = 1, json = 2, undefined = 3 };
const State = enum { pending, admitting, queued, cancelled };
const types = @import("../types.zig");

const Action = enum { complete, cancel };

const Request = struct {
    id: u64,
    instance_id: types.InstanceId,
    token: dispatch.InstanceToken,
    deferred: promise.Deferred,
    failure: ActiveEngine.Value,
    state: State = .pending,
    refs: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    dropped: bool = false,
    budget: *resource_limits.Budget,
};

const Delivery = struct {
    request: *Request,
    action: Action,
    outcome: Outcome = .ok,
    kind: PayloadKind = .undefined,
    data: []u8 = &.{},
};

var mutex: sync.Mutex = .{};
var requests = std.AutoHashMap(u64, *Request).init(std.heap.c_allocator);
var next_id: u64 = 1;

var after_claim_hook: ?*const fn (u64, ?*anyopaque) void = null;
var after_claim_context: ?*anyopaque = null;

/// Run test interleavings after pinning metadata and before taking an instance lease.
pub fn setAfterClaimHookForTesting(hook: ?*const fn (u64, ?*anyopaque) void, context: ?*anyopaque) void {
    if (builtin.is_test) {
        after_claim_hook = hook;
        after_claim_context = context;
    }
}

fn notifyAfterClaim(request: *Request) void {
    if (builtin.is_test) if (after_claim_hook) |hook| hook(request.id, after_claim_context);
}

pub const CreateResult = union(enum) { ok: struct { request_id: u64, promise: u64 }, status: c_int };

pub fn instanceFor(request_id: u64) ?types.InstanceId {
    mutex.lock();
    defer mutex.unlock();
    return (requests.get(request_id) orelse return null).instance_id;
}

pub fn create(instance_id: types.InstanceId) CreateResult {
    const raw_id = instance_id.toInt();
    if (!api_value.isOwner(raw_id)) return .{ .status = 3 };
    const instance = instance_map.getInstance(raw_id) orelse return .{ .status = 4 };
    if (!instance.isPrimaryBackend()) return .{ .status = 7 };
    const token = dispatch.captureInstanceToken(raw_id) orelse return .{ .status = 4 };
    if (!instance.resources.reserve(.tsfn_call, 0)) return .{ .status = 6 };
    var committed = false;
    defer if (!committed) instance.resources.release(.tsfn_call, 0);
    const ptrs = instance_map.getPtrs(raw_id) orelse return .{ .status = 4 };
    const failure = switch (api_backend.newError(ptrs.ctx, "native promise completion allocation failed")) {
        .ok => |val| val,
        .exception => |exception| {
            ActiveEngine.freeValue(ptrs.ctx, exception);
            return .{ .status = 6 };
        },
        .out_of_memory => return .{ .status = 6 },
    };
    defer if (!committed) ActiveEngine.freeValue(ptrs.ctx, failure);
    var deferred = promise.create(raw_id) orelse return .{ .status = 6 };
    defer if (!committed) deferred.deinit();
    const public_value = ActiveEngine.dupValue(ptrs.ctx, deferred.promise);
    const public_handle = api_value.putOwned(raw_id, public_value) orelse {
        ActiveEngine.freeValue(ptrs.ctx, public_value);
        return .{ .status = 6 };
    };
    defer if (!committed) {
        _ = api_value.release(public_handle);
    };
    const request = std.heap.c_allocator.create(Request) catch return .{ .status = 6 };
    defer if (!committed) std.heap.c_allocator.destroy(request);
    mutex.lock();
    defer mutex.unlock();
    if (next_id == 0 or next_id == std.math.maxInt(u64)) return .{ .status = 6 };
    const id = next_id;
    next_id += 1;
    request.* = .{ .id = id, .instance_id = instance_id, .token = token, .deferred = deferred, .failure = failure, .budget = instance.resources };
    requests.put(id, request) catch return .{ .status = 6 };
    committed = true;
    return .{ .ok = .{ .request_id = id, .promise = public_handle } };
}

/// Settle with an existing owner-thread public value. `value` remains owned by its caller.
pub fn settle(request_id: u64, outcome: Outcome, value_handle: u64) c_int {
    const entry = api_value.get(value_handle) orelse return 5;
    const instance_id = instanceFor(request_id) orelse return 5;
    if (entry.instance_id != instance_id.toInt()) return 2;
    if (!api_value.isOwner(instance_id.toInt())) return 3;
    const request = switch (claim(request_id)) {
        .ok => |request| request,
        .status => |status| return status,
    };
    markAdmitted(request);
    const ctx = instance_map.getPtrs(request.instance_id.toInt()) orelse {
        unclaim(request);
        return 4;
    };
    const value = ActiveEngine.dupValue(ctx.ctx, entry.value);
    defer ActiveEngine.freeValue(ctx.ctx, value);
    const settled = switch (outcome) {
        .ok => request.deferred.resolve(value),
        .exception => request.deferred.reject(value),
    };
    if (take(request) != .missing) {
        dropForOwner(request);
        release(request); // map reference
    }
    release(request); // claim reference
    return if (settled) 0 else 4;
}

pub fn complete(request_id: u64, outcome: Outcome, kind: PayloadKind, bytes: []const u8) c_int {
    if ((kind == .utf8_string or kind == .json or outcome == .exception) and !std.unicode.utf8ValidateSlice(bytes)) return 2;
    if (kind == .undefined and (bytes.len != 0 or outcome == .exception)) return 2;
    const request = switch (claim(request_id)) {
        .ok => |request| request,
        .status => |status| return status,
    };
    notifyAfterClaim(request);
    var reservation = dispatch.reserveTaskWithToken(request.token, .native_task, bytes.len) orelse {
        const stale = expiredGeneration(request.token);
        unclaim(request);
        return if (stale) 5 else 6;
    };
    const data = std.heap.c_allocator.dupe(u8, bytes) catch {
        reservation.deinit();
        unclaim(request);
        return 6;
    };
    const delivery = std.heap.c_allocator.create(Delivery) catch {
        std.heap.c_allocator.free(data);
        reservation.deinit();
        unclaim(request);
        return 6;
    };
    delivery.* = .{ .request = request, .action = .complete, .outcome = outcome, .kind = kind, .data = data };
    if (!dispatch.postReservedTaskWithToken(request.token, &reservation, .{ .ctx = delivery, .owner = request, .run = runDelivery, .cancel = cancelDelivery, .on_admitted = deliveryAdmitted, .resource_bytes = data.len })) {
        std.heap.c_allocator.free(delivery.data);
        std.heap.c_allocator.destroy(delivery);
        const stale = expiredGeneration(request.token);
        reservation.deinit();
        unclaim(request);
        return if (stale) 5 else 6;
    }
    return 0;
}

pub fn cancel(request_id: u64) c_int {
    const request = switch (claim(request_id)) {
        .ok => |request| request,
        .status => |status| return status,
    };
    notifyAfterClaim(request);
    const delivery = std.heap.c_allocator.create(Delivery) catch {
        unclaim(request);
        return 6;
    };
    delivery.* = .{ .request = request, .action = .cancel };
    if (!dispatch.postTaskWithToken(request.token, .{ .ctx = delivery, .owner = request, .run = runDelivery, .cancel = cancelDelivery, .on_admitted = deliveryAdmitted })) {
        std.heap.c_allocator.destroy(delivery);
        const stale = expiredGeneration(request.token);
        unclaim(request);
        return if (stale) 5 else 6;
    }
    return 0;
}

const ClaimResult = union(enum) { ok: *Request, status: c_int };

fn claim(request_id: u64) ClaimResult {
    mutex.lock();
    defer mutex.unlock();
    const request = requests.get(request_id) orelse return .{ .status = 5 };
    const shutdown = runtime_control.shutdownStatus(request.instance_id.toInt()) orelse return .{ .status = 5 };
    if (shutdown.phase == .cancelled) {
        request.state = .cancelled;
        return .{ .status = 5 };
    }
    switch (request.state) {
        .admitting => return .{ .status = 6 },
        .queued, .cancelled => return .{ .status = 5 },
        .pending => {},
    }
    request.state = .admitting;
    _ = request.refs.fetchAdd(1, .seq_cst);
    return .{ .ok = request };
}

fn markAdmitted(context: ?*anyopaque) void {
    const request: *Request = @ptrCast(@alignCast(context orelse return));
    mutex.lock();
    defer mutex.unlock();
    if (requests.get(request.id) == request and request.state == .admitting) request.state = .queued;
}

fn deliveryAdmitted(context: ?*anyopaque) void {
    const delivery: *Delivery = @ptrCast(@alignCast(context orelse return));
    markAdmitted(delivery.request);
}

fn expiredGeneration(token: dispatch.InstanceToken) bool {
    return (instance_map.captureGeneration(token.instance_id) orelse return true) != token.generation;
}

fn unclaim(request: *Request) void {
    mutex.lock();
    defer mutex.unlock();
    if (requests.get(request.id) == request and request.state == .admitting) request.state = .pending;
    release(request);
}

const TakeResult = enum { missing, active, cancelled };

/// Remove one queued request while atomically observing terminal cancellation. JS must only run after this returns and the mutex has been released.
fn take(request: *Request) TakeResult {
    mutex.lock();
    defer mutex.unlock();
    if (requests.get(request.id) != request) return .missing;
    const shutdown = runtime_control.shutdownStatus(request.instance_id.toInt()) orelse {
        _ = requests.remove(request.id);
        return .cancelled;
    };
    const cancelled = request.state == .cancelled or shutdown.phase == .cancelled;
    _ = requests.remove(request.id);
    return if (cancelled) .cancelled else .active;
}

fn dropForOwner(request: *Request) void {
    if (request.dropped) return;
    request.dropped = true;
    if (instance_map.getPtrs(request.instance_id.toInt())) |ptrs| ActiveEngine.freeValue(ptrs.ctx, request.failure);
    request.deferred.deinit();
    request.budget.release(.tsfn_call, 0);
}

fn release(request: *Request) void {
    if (request.refs.fetchSub(1, .seq_cst) == 1) std.heap.c_allocator.destroy(request);
}

fn cancelDelivery(context: ?*anyopaque) void {
    const delivery: *Delivery = @ptrCast(@alignCast(context orelse return));
    if (delivery.data.len != 0) std.heap.c_allocator.free(delivery.data);
    if (take(delivery.request) != .missing) {
        dropForOwner(delivery.request);
        release(delivery.request); // map reference
    }
    release(delivery.request); // delivery reference
    std.heap.c_allocator.destroy(delivery);
}

fn runDelivery(context: ?*anyopaque) void {
    const delivery: *Delivery = @ptrCast(@alignCast(context orelse return));
    defer std.heap.c_allocator.destroy(delivery);
    defer if (delivery.data.len != 0) std.heap.c_allocator.free(delivery.data);
    const taken = take(delivery.request);
    if (taken == .missing) {
        release(delivery.request); // delivery reference
        return;
    }
    defer release(delivery.request); // delivery reference
    defer release(delivery.request); // map reference
    defer dropForOwner(delivery.request);
    if (taken == .cancelled) return;
    const inst = instance_map.getInstance(delivery.request.instance_id.toInt()) orelse return;
    const ctx = inst.monoCtx() orelse return;
    var value: ActiveEngine.Value = undefined;
    const making_error = delivery.action == .cancel or (delivery.outcome == .exception and delivery.kind != .json);
    const made: api_backend.Result = if (delivery.action == .cancel)
        api_backend.newError(ctx, "native promise was cancelled")
    else if (delivery.outcome == .exception and delivery.kind != .json)
        api_backend.newError(ctx, delivery.data)
    else switch (delivery.kind) {
        .undefined => .{ .ok = ActiveEngine.newUndefinedVal(ctx) },
        .utf8_string => api_backend.newString(ctx, delivery.data),
        .bytes => api_backend.newArrayBuffer(ctx, delivery.data),
        .json => api_backend.parseJson(inst.allocator, ctx, delivery.data),
    };
    switch (made) {
        .ok => |made_value| {
            value = made_value;
            defer ActiveEngine.freeValue(ctx, value);
            _ = if (delivery.action == .complete and delivery.outcome == .ok) delivery.request.deferred.resolve(value) else delivery.request.deferred.reject(value);
        },
        .exception => |exception| {
            defer ActiveEngine.freeValue(ctx, exception);
            // Error construction can itself fail without an allocated Error value. Keep cancellation and message rejections observable under that pressure.
            const reason = if (making_error or ActiveEngine.isNull(ctx, exception) or ActiveEngine.isUndefined(ctx, exception)) delivery.request.failure else exception;
            _ = delivery.request.deferred.reject(reason);
        },
        .out_of_memory => {
            _ = delivery.request.deferred.reject(delivery.request.failure);
        },
    }
}

/// Called during engine destruction after queued NativeTasks have been cancelled and before reference bookkeeping is released.
pub fn cancelForInstance(instance_id: types.InstanceId) void {
    while (true) {
        mutex.lock();
        var found: ?*Request = null;
        var it = requests.valueIterator();
        while (it.next()) |request| if (request.*.instance_id == instance_id) {
            found = request.*;
            break;
        };
        const request = found orelse {
            mutex.unlock();
            return;
        };
        _ = requests.remove(request.id);
        mutex.unlock();
        dropForOwner(request);
        release(request); // map reference
    }
}

/// Terminal generation cancellation prevents any pending completion from entering the VM. The owner later drops the records when queued work reaches its turn or during destroy.
pub fn cancelGeneration(instance_id: types.InstanceId, generation: u64) void {
    mutex.lock();
    defer mutex.unlock();
    var it = requests.valueIterator();
    while (it.next()) |request| {
        if (request.*.instance_id == instance_id and request.*.token.generation == generation) request.*.state = .cancelled;
    }
}
