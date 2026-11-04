const std = @import("std");
const thread_cpu = @import("../platform/thread_cpu.zig");

pub const Ledger = struct {
    refs: std.atomic.Value(usize) = .init(1),
    total_ns: std.atomic.Value(u64) = .init(0),
    closing: std.atomic.Value(bool) = .init(false),
    measurable: std.atomic.Value(bool) = .init(true),
    measurement_users: std.atomic.Value(usize) = .init(0),
    sample_attempts: std.atomic.Value(usize) = .init(0),

    pub fn enable(self: *Ledger) void {
        _ = self.measurement_users.fetchAdd(1, .acq_rel);
    }
    pub fn disable(self: *Ledger) void {
        std.debug.assert(self.measurement_users.load(.acquire) != 0);
        _ = self.measurement_users.fetchSub(1, .acq_rel);
    }

    pub fn create() ?*Ledger {
        const ledger = std.heap.c_allocator.create(Ledger) catch return null;
        ledger.* = .{};
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
        if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
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
    yield_suppressions: u32 = 0,

    fn suspended(self: *const Frame) bool {
        return self.disabled_suppressions != 0 or self.yield_suppressions != 0;
    }
};
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
        if (active) |previous| {
            if (!previous.suspended() and now != 0) previous.last_ns = now;
        }
        frame.ledger.release();
        std.heap.c_allocator.destroy(frame);
    }
};

pub fn begin(ledger: *Ledger) Scope {
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

test "execution CPU scopes do not duplicate same ledger nesting" {
    const ledger = Ledger.create() orelse return error.OutOfMemory;
    defer ledger.close();
    ledger.enable();
    defer ledger.disable();
    const before = ledger.total_ns.load(.acquire);
    var outer = begin(ledger);
    var inner = begin(ledger);
    var work: u64 = 0;
    for (0..2_000_000) |i| work +%= i;
    std.mem.doNotOptimizeAway(&work);
    inner.end();
    outer.end();
    if (thread_cpu.isSupported()) try std.testing.expect(ledger.total_ns.load(.acquire) > before);
}

test "execution CPU scopes are inert before measurement is enabled" {
    const ledger = Ledger.create() orelse return error.OutOfMemory;
    defer ledger.close();
    var scope = begin(ledger);
    var work: u64 = 0;
    for (0..2_000_000) |i| work +%= i;
    std.mem.doNotOptimizeAway(&work);
    scope.end();
    try std.testing.expectEqual(@as(usize, 0), ledger.sample_attempts.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), ledger.total_ns.load(.acquire));
}

test "execution CPU scopes separate nested instances" {
    const first = Ledger.create() orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const second = Ledger.create() orelse return error.OutOfMemory;
    defer second.close();
    second.enable();
    defer second.disable();
    var first_scope = begin(first);
    var a: u64 = 0;
    for (0..500_000) |i| a +%= i;
    var second_scope = begin(second);
    var b: u64 = 0;
    for (0..2_000_000) |i| b +%= i;
    second_scope.end();
    first_scope.end();
    std.mem.doNotOptimizeAway(&a);
    std.mem.doNotOptimizeAway(&b);
    if (thread_cpu.isSupported()) {
        try std.testing.expect(first.total_ns.load(.acquire) > 0);
        try std.testing.expect(second.total_ns.load(.acquire) > 0);
    }
}

test "execution CPU scopes count a reentered ledger below a disabled instance" {
    const first = Ledger.create() orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const disabled = Ledger.create() orelse return error.OutOfMemory;
    defer disabled.close();
    var outer = begin(first);
    var disabled_scope = begin(disabled);
    const before = first.total_ns.load(.acquire);
    var disabled_before: u64 = 0;
    for (0..2_000_000) |i| disabled_before +%= i;
    std.mem.doNotOptimizeAway(&disabled_before);
    try std.testing.expectEqual(before, first.total_ns.load(.acquire));
    var reentered = begin(first);
    var work: u64 = 0;
    for (0..4_000_000) |i| work +%= i;
    std.mem.doNotOptimizeAway(&work);
    reentered.end();
    if (thread_cpu.isSupported()) try std.testing.expect(first.total_ns.load(.acquire) > before);
    const after_reentry = first.total_ns.load(.acquire);
    var disabled_after: u64 = 0;
    for (0..2_000_000) |i| disabled_after +%= i;
    std.mem.doNotOptimizeAway(&disabled_after);
    try std.testing.expectEqual(after_reentry, first.total_ns.load(.acquire));
    disabled_scope.end();
    outer.end();
}

test "execution CPU scopes keep a disabled suppression across an external yield" {
    const first = Ledger.create() orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const disabled = Ledger.create() orelse return error.OutOfMemory;
    defer disabled.close();
    const third = Ledger.create() orelse return error.OutOfMemory;
    defer third.close();
    third.enable();
    defer third.disable();
    var outer = begin(first);
    var disabled_scope = begin(disabled);
    const pause_token = pauseForExternalEval(first);
    try std.testing.expect(pause_token.ledger != null);
    resumeAfterExternalEval(pause_token);
    const before = first.total_ns.load(.acquire);
    var disabled_work: u64 = 0;
    for (0..4_000_000) |i| disabled_work +%= i;
    std.mem.doNotOptimizeAway(&disabled_work);
    var third_scope = begin(third);
    third_scope.end();
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, first.total_ns.load(.acquire));
    disabled_scope.end();
    outer.end();
}

test "execution CPU scopes restore an external yield below an enabled child" {
    const first = Ledger.create() orelse return error.OutOfMemory;
    defer first.close();
    first.enable();
    defer first.disable();
    const child = Ledger.create() orelse return error.OutOfMemory;
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
    var work: u64 = 0;
    for (0..2_000_000) |i| work +%= i;
    std.mem.doNotOptimizeAway(&work);
    outer.end();
    if (thread_cpu.isSupported()) try std.testing.expect(first.total_ns.load(.acquire) > before);
}

test "execution CPU scopes do not flush an enabled child's work to a yielded ancestor" {
    const ancestor = Ledger.create() orelse return error.OutOfMemory;
    defer ancestor.close();
    ancestor.enable();
    defer ancestor.disable();
    const child = Ledger.create() orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var ancestor_scope = begin(ancestor);
    var child_scope = begin(child);
    const before = ancestor.total_ns.load(.acquire);
    var work: u64 = 0;
    for (0..4_000_000) |i| work +%= i;
    std.mem.doNotOptimizeAway(&work);
    const pause_token = pauseForExternalEval(ancestor);
    try std.testing.expect(pause_token.ledger != null);
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, ancestor.total_ns.load(.acquire));
    resumeAfterExternalEval(pause_token);
    child_scope.end();
    ancestor_scope.end();
}

test "execution CPU scopes retain disabled suppression after a yield resumes" {
    const ancestor = Ledger.create() orelse return error.OutOfMemory;
    defer ancestor.close();
    ancestor.enable();
    defer ancestor.disable();
    const disabled = Ledger.create() orelse return error.OutOfMemory;
    defer disabled.close();
    const child = Ledger.create() orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var ancestor_scope = begin(ancestor);
    const pause_token = pauseForExternalEval(ancestor);
    try std.testing.expect(pause_token.ledger != null);
    var disabled_scope = begin(disabled);
    resumeAfterExternalEval(pause_token);
    const before = ancestor.total_ns.load(.acquire);
    var disabled_work: u64 = 0;
    for (0..4_000_000) |i| disabled_work +%= i;
    std.mem.doNotOptimizeAway(&disabled_work);
    var child_scope = begin(child);
    child_scope.end();
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, ancestor.total_ns.load(.acquire));
    disabled_scope.end();
    ancestor_scope.end();
}

test "execution CPU scopes retain a yield after a disabled scope ends" {
    const ancestor = Ledger.create() orelse return error.OutOfMemory;
    defer ancestor.close();
    ancestor.enable();
    defer ancestor.disable();
    const disabled = Ledger.create() orelse return error.OutOfMemory;
    defer disabled.close();
    const child = Ledger.create() orelse return error.OutOfMemory;
    defer child.close();
    child.enable();
    defer child.disable();
    var ancestor_scope = begin(ancestor);
    var disabled_scope = begin(disabled);
    const pause_token = pauseForExternalEval(ancestor);
    try std.testing.expect(pause_token.ledger != null);
    disabled_scope.end();
    const before = ancestor.total_ns.load(.acquire);
    var yielded_work: u64 = 0;
    for (0..4_000_000) |i| yielded_work +%= i;
    std.mem.doNotOptimizeAway(&yielded_work);
    var child_scope = begin(child);
    child_scope.end();
    if (thread_cpu.isSupported()) try std.testing.expectEqual(before, ancestor.total_ns.load(.acquire));
    resumeAfterExternalEval(pause_token);
    ancestor_scope.end();
}
