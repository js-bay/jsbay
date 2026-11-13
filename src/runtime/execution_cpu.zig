const std = @import("std");
const thread_cpu = @import("../platform/thread_cpu.zig");

pub const Ledger = struct {
    allocator: std.mem.Allocator = std.heap.c_allocator,
    refs: std.atomic.Value(usize) = .init(1),
    total_ns: std.atomic.Value(u64) = .init(0),
    closing: std.atomic.Value(bool) = .init(false),
    measurable: std.atomic.Value(bool) = .init(true),
    measurement_users: std.atomic.Value(usize) = .init(0),
    /// Transport-side session teardown cannot sample this thread. It requests a decrement which the owner applies after the active scope has flushed.
    pending_measurement_disables: std.atomic.Value(usize) = .init(0),
    sample_attempts: std.atomic.Value(usize) = .init(0),

    pub fn enable(self: *Ledger) void {
        _ = self.measurement_users.fetchAdd(1, .acq_rel);
    }
    pub fn disable(self: *Ledger) void {
        std.debug.assert(self.measurement_users.load(.acquire) != 0);
        _ = self.measurement_users.fetchSub(1, .acq_rel);
    }

    pub fn requestDisableAtBoundary(self: *Ledger) void {
        _ = self.pending_measurement_disables.fetchAdd(1, .acq_rel);
    }

    pub fn disableOnOwner(self: *Ledger) void {
        disableLedgerOnOwner(self);
    }

    pub fn enableOnOwner(self: *Ledger) void {
        enableLedgerOnOwner(self);
    }

    /// Call only at an owner safe boundary with no active frame for this ledger.
    pub fn applyPendingDisablesOnOwner(self: *Ledger) void {
        applyPendingLedgerDisablesOnOwner(self);
    }

    pub fn create(allocator: std.mem.Allocator) ?*Ledger {
        const ledger = allocator.create(Ledger) catch return null;
        ledger.* = .{ .allocator = allocator };
        return ledger;
    }
    pub fn retain(self: *Ledger) bool {
        if (self.closing.load(.acquire)) return false;
        _ = self.refs.fetchAdd(1, .acq_rel);
        if (!self.closing.load(.acquire)) return true;
        release(self);
        return false;
    }
    pub fn close(self: *Ledger) void {
        self.closing.store(true, .release);
        release(self);
    }
    pub fn release(self: *Ledger) void {
        const alloc = self.allocator;
        if (self.refs.fetchSub(1, .acq_rel) == 1) alloc.destroy(self);
    }
    pub fn seconds(self: *const Ledger) ?f64 {
        if (!thread_cpu.isSupported() or !self.measurable.load(.acquire)) return null;
        const total = self.total_ns.load(.acquire);
        if (total == 0) return null;
        return @as(f64, @floatFromInt(total)) / @as(f64, std.time.ns_per_s);
    }

    fn sample(self: *Ledger) ?u64 {
        _ = self.sample_attempts.fetchAdd(1, .acq_rel);
        return thread_cpu.currentThreadCpuNanoseconds();
    }
};

const Frame = struct {
    ledger: *Ledger,
    previous: ?*Frame,
    last_ns: u64,
    id: u64,
    disabled_suppressions: u32 = 0,
    measurement_suppressions: u32 = 0,
    yield_suppressions: u32 = 0,

    fn suspended(self: *const Frame) bool {
        return self.disabled_suppressions != 0 or self.measurement_suppressions != 0 or self.yield_suppressions != 0;
    }
};

fn applyPendingLedgerDisablesOnOwner(ledger: *Ledger) void {
    const pending = ledger.pending_measurement_disables.swap(0, .acq_rel);
    var remaining = pending;
    while (remaining != 0) : (remaining -= 1) ledger.disable();
}

/// Change measurement at an owner-thread boundary. Any active frame is sampled before disable, and is resumed from this exact owner timestamp after enable.
fn disableLedgerOnOwner(ledger: *Ledger) void {
    if (ledger.measurement_users.load(.acquire) != 1) {
        ledger.disable();
        return;
    }
    const now = ledger.sample() orelse {
        invalidateActiveLedgers();
        ledger.disable();
        return;
    };
    var frame = active;
    while (frame) |current| : (frame = current.previous) {
        if (current.ledger != ledger) continue;
        if (!current.suspended()) Scope.flush(current, now);
        current.measurement_suppressions += 1;
    }
    ledger.disable();
}

/// Enable measurement from an owner-thread boundary, first consuming teardown decrements that were deferred from transport threads.
fn enableLedgerOnOwner(ledger: *Ledger) void {
    applyPendingLedgerDisablesOnOwner(ledger);
    const users = ledger.measurement_users.load(.acquire);
    ledger.enable();
    if (users != 0) return;
    const now = ledger.sample() orelse {
        invalidateActiveLedgers();
        return;
    };
    var frame = active;
    while (frame) |current| : (frame = current.previous) {
        if (current.ledger != ledger or current.measurement_suppressions == 0) continue;
        current.measurement_suppressions -= 1;
        current.last_ns = now;
    }
}
threadlocal var active: ?*Frame = null;
threadlocal var next_frame_id: u64 = 1;

pub const PauseToken = struct {
    ledger: ?*Ledger = null,
    frame_id: u64 = 0,
};

fn invalidateActiveLedgers() void {
    var frame = active;
    while (frame) |current| {
        current.ledger.measurable.store(false, .release);
        frame = current.previous;
    }
}

pub const Scope = struct {
    frame: ?*Frame = null,
    nested: bool = false,
    suppressed_parent: ?*Frame = null,
    resumes_suppressed_parent: bool = false,
    fn flush(frame: *Frame, now: u64) void {
        if (!frame.suspended() and now >= frame.last_ns) _ = frame.ledger.total_ns.fetchAdd(now - frame.last_ns, .acq_rel);
        frame.last_ns = now;
    }
    pub fn end(self: *Scope) void {
        if (self.suppressed_parent) |parent| {
            self.suppressed_parent = null;
            if (!self.resumes_suppressed_parent) return;
            self.resumes_suppressed_parent = false;
            const now = parent.ledger.sample() orelse blk: {
                invalidateActiveLedgers();
                break :blk null;
            };
            std.debug.assert(active == parent);
            std.debug.assert(parent.disabled_suppressions != 0);
            parent.disabled_suppressions -= 1;
            if (now) |value| parent.last_ns = value;
            return;
        }
        const frame = self.frame orelse return;
        self.frame = null;
        if (self.nested) return;
        const now = frame.ledger.sample() orelse blk: {
            invalidateActiveLedgers();
            break :blk 0;
        };
        if (now != 0) flush(frame, now);
        std.debug.assert(active == frame);
        active = frame.previous;
        var has_ancestor_with_ledger = false;
        var ancestor = active;
        while (ancestor) |current| : (ancestor = current.previous) {
            if (current.ledger == frame.ledger) {
                has_ancestor_with_ledger = true;
                break;
            }
        }
        if (!has_ancestor_with_ledger) applyPendingLedgerDisablesOnOwner(frame.ledger);
        if (active) |previous| {
            if (!previous.suspended() and now != 0) previous.last_ns = now;
        }
        frame.ledger.release();
        std.heap.c_allocator.destroy(frame);
    }
};

pub fn begin(ledger: *Ledger) Scope {
    var has_active_ledger = false;
    var scan = active;
    while (scan) |current| : (scan = current.previous) {
        if (current.ledger == ledger) {
            has_active_ledger = true;
            break;
        }
    }
    if (!has_active_ledger) applyPendingLedgerDisablesOnOwner(ledger);
    if (ledger.measurement_users.load(.acquire) == 0) {
        const current = active orelse return .{};
        if (!current.suspended()) {
            const now = current.ledger.sample() orelse {
                invalidateActiveLedgers();
                current.disabled_suppressions += 1;
                return .{ .suppressed_parent = current, .resumes_suppressed_parent = true };
            };
            Scope.flush(current, now);
        }
        current.disabled_suppressions += 1;
        return .{ .suppressed_parent = current, .resumes_suppressed_parent = true };
    }
    const now = ledger.sample() orelse {
        invalidateActiveLedgers();
        ledger.measurable.store(false, .release);
        return .{};
    };
    if (!ledger.retain()) return .{};
    if (active) |current| {
        if (current.ledger == ledger and !current.suspended()) {
            ledger.release();
            return .{ .frame = current, .nested = true };
        }
        Scope.flush(current, now);
    }
    const frame = std.heap.c_allocator.create(Frame) catch {
        invalidateActiveLedgers();
        ledger.measurable.store(false, .release);
        ledger.release();
        return .{};
    };
    const id = next_frame_id;
    next_frame_id +%= 1;
    if (next_frame_id == 0) next_frame_id = 1;
    frame.* = .{ .ledger = ledger, .previous = active, .last_ns = now, .id = id };
    active = frame;
    return .{ .frame = frame };
}

pub fn pauseForExternalEval(ledger: *Ledger) PauseToken {
    var frame = active;
    while (frame) |current| : (frame = current.previous) {
        if (current.ledger != ledger) continue;
        if (current.yield_suppressions != 0) return .{};
        if (active == current and !current.suspended()) {
            const now = ledger.sample() orelse {
                ledger.measurable.store(false, .release);
                return .{};
            };
            Scope.flush(current, now);
        }
        current.yield_suppressions += 1;
        return .{ .ledger = ledger, .frame_id = current.id };
    }
    return .{};
}

pub fn resumeAfterExternalEval(token: PauseToken) void {
    const ledger = token.ledger orelse return;
    var frame = active;
    while (frame) |current| : (frame = current.previous) {
        if (current.ledger != ledger or current.id != token.frame_id) continue;
        if (current.yield_suppressions == 0) return;
        current.yield_suppressions -= 1;
        if (active == current) {
            current.last_ns = ledger.sample() orelse {
                ledger.measurable.store(false, .release);
                return;
            };
        }
        return;
    }
}

test "execution CPU defers a transport disable until its active scope ends" {
    const ledger = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ledger.close();
    ledger.enable();
    var scope = begin(ledger);
    ledger.requestDisableAtBoundary();
    try std.testing.expectEqual(@as(usize, 1), ledger.measurement_users.load(.acquire));
    scope.end();
    try std.testing.expectEqual(@as(usize, 0), ledger.measurement_users.load(.acquire));
}

test "execution CPU keeps a pending transport disable below a reentered ledger frame" {
    const ledger = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ledger.close();
    ledger.enable();
    var outer = begin(ledger);
    const disabled = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer disabled.close();
    var suppressed = begin(disabled);
    var inner = begin(ledger);
    ledger.requestDisableAtBoundary();
    inner.end();
    try std.testing.expectEqual(@as(usize, 1), ledger.measurement_users.load(.acquire));
    suppressed.end();
    outer.end();
    try std.testing.expectEqual(@as(usize, 0), ledger.measurement_users.load(.acquire));
}

test "execution CPU keeps an active frame measuring until the last user disables" {
    const ledger = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ledger.close();
    ledger.enable();
    ledger.enable();
    var scope = begin(ledger);
    try thread_cpu.testing.consumeTick();
    const before = ledger.total_ns.load(.acquire);
    ledger.disableOnOwner();
    try std.testing.expectEqual(@as(usize, 1), ledger.measurement_users.load(.acquire));
    try thread_cpu.testing.consumeTick();
    scope.end();
    if (thread_cpu.isSupported()) try std.testing.expect(ledger.total_ns.load(.acquire) > before);
    ledger.disable();
}

test "execution CPU scopes do not duplicate same ledger nesting" {
    const ledger = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ledger.close();
    ledger.enable();
    defer ledger.disable();
    const before = ledger.total_ns.load(.acquire);
    var outer = begin(ledger);
    var inner = begin(ledger);
    try thread_cpu.testing.consumeTick();
    inner.end();
    outer.end();
    if (thread_cpu.isSupported()) try std.testing.expect(ledger.total_ns.load(.acquire) > before);
}

test "execution CPU scopes are inert before measurement is enabled" {
    const ledger = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ledger.close();
    var scope = begin(ledger);
    try thread_cpu.testing.consumeTick();
    scope.end();
    try std.testing.expectEqual(@as(usize, 0), ledger.sample_attempts.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), ledger.total_ns.load(.acquire));
}

test "execution CPU scopes separate nested instances" {
    const first = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const second = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer second.close();
    second.enable();
    defer second.disable();
    var first_scope = begin(first);
    try thread_cpu.testing.consumeTick();
    var second_scope = begin(second);
    try thread_cpu.testing.consumeTick();
    second_scope.end();
    first_scope.end();
    if (thread_cpu.isSupported()) {
        try std.testing.expect(first.total_ns.load(.acquire) > 0);
        try std.testing.expect(second.total_ns.load(.acquire) > 0);
    }
}

test "execution CPU scopes count a reentered ledger below a disabled instance" {
    const first = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const disabled = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer disabled.close();
    var outer = begin(first);
    var disabled_scope = begin(disabled);
    const before = first.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    try std.testing.expectEqual(before, first.total_ns.load(.acquire));
    var reentered = begin(first);
    try thread_cpu.testing.consumeTick();
    reentered.end();
    if (thread_cpu.isSupported()) try std.testing.expect(first.total_ns.load(.acquire) > before);
    const after_reentry = first.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    try std.testing.expectEqual(after_reentry, first.total_ns.load(.acquire));
    disabled_scope.end();
    outer.end();
}

test "execution CPU scopes keep a disabled suppression across an external yield" {
    const first = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const disabled = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer disabled.close();
    const third = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer third.close();
    third.enable();
    defer third.disable();
    var outer = begin(first);
    var disabled_scope = begin(disabled);
    const pause_token = pauseForExternalEval(first);
    try std.testing.expect(pause_token.ledger != null);
    resumeAfterExternalEval(pause_token);
    const before = first.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    var third_scope = begin(third);
    third_scope.end();
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, first.total_ns.load(.acquire));
    disabled_scope.end();
    outer.end();
}

test "execution CPU scopes restore an external yield below an enabled child" {
    const first = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const child = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var outer = begin(first);
    const pause_token = pauseForExternalEval(first);
    try std.testing.expect(pause_token.ledger != null);
    var child_scope = begin(child);
    resumeAfterExternalEval(pause_token);
    child_scope.end();
    const before = first.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    outer.end();
    if (thread_cpu.isSupported()) try std.testing.expect(first.total_ns.load(.acquire) > before);
}

test "execution CPU scopes do not flush an enabled child's work to a yielded ancestor" {
    const ancestor = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ancestor.close();
    ancestor.enable();
    defer ancestor.disable();
    const child = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var ancestor_scope = begin(ancestor);
    var child_scope = begin(child);
    const before = ancestor.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    const pause_token = pauseForExternalEval(ancestor);
    try std.testing.expect(pause_token.ledger != null);
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, ancestor.total_ns.load(.acquire));
    resumeAfterExternalEval(pause_token);
    child_scope.end();
    ancestor_scope.end();
}

test "execution CPU scopes retain disabled suppression after a yield resumes" {
    const ancestor = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ancestor.close();
    ancestor.enable();
    defer ancestor.disable();
    const disabled = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer disabled.close();
    const child = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var ancestor_scope = begin(ancestor);
    const pause_token = pauseForExternalEval(ancestor);
    try std.testing.expect(pause_token.ledger != null);
    var disabled_scope = begin(disabled);
    resumeAfterExternalEval(pause_token);
    const before = ancestor.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    var child_scope = begin(child);
    child_scope.end();
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, ancestor.total_ns.load(.acquire));
    disabled_scope.end();
    ancestor_scope.end();
}

test "execution CPU scopes retain a yield after a disabled scope ends" {
    const ancestor = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer ancestor.close();
    ancestor.enable();
    defer ancestor.disable();
    const disabled = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer disabled.close();
    const child = Ledger.create(std.testing.allocator) orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var ancestor_scope = begin(ancestor);
    var disabled_scope = begin(disabled);
    const pause_token = pauseForExternalEval(ancestor);
    try std.testing.expect(pause_token.ledger != null);
    disabled_scope.end();
    const before = ancestor.total_ns.load(.acquire);
    try thread_cpu.testing.consumeTick();
    var child_scope = begin(child);
    child_scope.end();
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, ancestor.total_ns.load(.acquire));
    resumeAfterExternalEval(pause_token);
    ancestor_scope.end();
}
