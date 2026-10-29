//! Native allocations are separate from the VM heap and require their own budgets.
const std = @import("std");
const sync = @import("zev");

pub const Limits = struct {
    max_timers: usize = 4096,
    max_tsfn_handles: usize = 256,
    max_pending_calls: usize = 4096,
    max_pending_bytes: usize = 8 * 1024 * 1024,
    max_pending_tasks: usize = 4096,
};
pub const max_payload_bytes: usize = 1024 * 1024;
pub const Kind = enum { timer, tsfn_handle, tsfn_call, native_task, script_task };
const kinds = 5;
var mutex: sync.Mutex = .{};
var global_counts: [kinds]usize = @splat(0);
var global_bytes: usize = 0;
const global_caps = [kinds]usize{ 65536, 4096, 65536, 65536, 65536 };
const global_byte_cap: usize = 64 * 1024 * 1024;

/// 25% of each process cap, rounded down, minimum 1 when cap > 0. BACKGROUND may not enter this tail.
fn headroomFor(cap: usize) usize {
    if (cap == 0) return 0;
    return @max(1, cap / 4);
}

fn fgHeadrooms() [kinds]usize {
    var out: [kinds]usize = undefined;
    inline for (0..kinds) |i| out[i] = headroomFor(global_caps[i]);
    return out;
}

fn bgEffectiveCaps() [kinds]usize {
    const rooms = fgHeadrooms();
    var out: [kinds]usize = undefined;
    inline for (0..kinds) |i| out[i] = global_caps[i] -| rooms[i];
    return out;
}

fn fgByteHeadroom() usize {
    return headroomFor(global_byte_cap);
}

fn bgEffectiveByteCap() usize {
    return global_byte_cap -| fgByteHeadroom();
}

pub const InstanceUsage = struct {
    limits: Limits,
    counts: [kinds]usize,
    bytes: usize,
};

pub const GlobalUsage = struct {
    counts: [kinds]usize,
    bytes: usize,
    caps: [kinds]usize,
    byte_cap: usize,
    fg_headrooms: [kinds]usize,
    fg_byte_headroom: usize,
    bg_effective_caps: [kinds]usize,
    bg_effective_byte_cap: usize,
};

pub fn globalUsage() GlobalUsage {
    mutex.lock();
    defer mutex.unlock();
    return .{
        .counts = global_counts,
        .bytes = global_bytes,
        .caps = global_caps,
        .byte_cap = global_byte_cap,
        .fg_headrooms = fgHeadrooms(),
        .fg_byte_headroom = fgByteHeadroom(),
        .bg_effective_caps = bgEffectiveCaps(),
        .bg_effective_byte_cap = bgEffectiveByteCap(),
    };
}

pub const AdmissionClass = enum(u8) {
    foreground = 0,
    background = 1,
};

pub const Budget = struct {
    limits: Limits,
    /// Affects future `reserve` only (see FG headroom). Default foreground preserves single-instance hosts.
    admission_class: AdmissionClass = .foreground,
    refs: usize = 1,
    counts: [kinds]usize = @splat(0),
    bytes: usize = 0,

    pub fn create(limits: Limits) ?*Budget {
        const b = std.heap.c_allocator.create(Budget) catch return null;
        b.* = .{ .limits = limits };
        return b;
    }
    /// Every reservation owns a reference, including work detached during teardown.
    pub fn reserve(self: *Budget, kind: Kind, bytes: usize) bool {
        mutex.lock();
        defer mutex.unlock();
        const i = @backingInt(kind);
        const cap = switch (kind) {
            .timer => self.limits.max_timers,
            .tsfn_handle => self.limits.max_tsfn_handles,
            .tsfn_call => self.limits.max_pending_calls,
            .native_task, .script_task => self.limits.max_pending_tasks,
        };
        const process_cap = switch (self.admission_class) {
            .foreground => global_caps[i],
            .background => global_caps[i] -| headroomFor(global_caps[i]),
        };
        if (self.counts[i] >= cap or global_counts[i] >= process_cap) return false;
        const process_byte_cap = switch (self.admission_class) {
            .foreground => global_byte_cap,
            .background => bgEffectiveByteCap(),
        };
        if (bytes > max_payload_bytes or bytes > self.limits.max_pending_bytes -| self.bytes or bytes > process_byte_cap -| global_bytes) return false;
        self.counts[i] += 1;
        global_counts[i] += 1;
        self.bytes += bytes;
        global_bytes += bytes;
        self.refs += 1;
        return true;
    }
    pub fn release(self: *Budget, kind: Kind, bytes: usize) void {
        mutex.lock();
        const i = @backingInt(kind);
        std.debug.assert(self.counts[i] > 0 and global_counts[i] > 0);
        self.counts[i] -= 1;
        global_counts[i] -= 1;
        self.bytes -= bytes;
        global_bytes -= bytes;
        self.refs -= 1;
        const last = self.refs == 0;
        mutex.unlock();
        if (last) std.heap.c_allocator.destroy(self);
    }
    pub fn deinit(self: *Budget) void {
        mutex.lock();
        self.refs -= 1;
        const last = self.refs == 0;
        mutex.unlock();
        if (last) std.heap.c_allocator.destroy(self);
    }

    pub fn admissionClass(self: *const Budget) AdmissionClass {
        mutex.lock();
        defer mutex.unlock();
        return self.admission_class;
    }

    /// Future admissions only; live reservations stay until release.
    pub fn setAdmissionClass(self: *Budget, class: AdmissionClass) void {
        mutex.lock();
        defer mutex.unlock();
        self.admission_class = class;
    }

    /// Snapshot reservations and the active Limits under the process budget lock.
    pub fn usage(self: *const Budget) InstanceUsage {
        mutex.lock();
        defer mutex.unlock();
        return .{
            .limits = self.limits,
            .counts = self.counts,
            .bytes = self.bytes,
        };
    }

    /// Replace Limits for future admissions. Existing reservations stay until release; a tighter cap rejects new work of that kind until usage falls below it.
    pub fn setLimits(self: *Budget, limits: Limits) void {
        mutex.lock();
        defer mutex.unlock();
        self.limits = limits;
    }
};

test "native budgets preserve reservations across owner destruction and return global capacity" {
    const b = Budget.create(.{ .max_timers = 1, .max_pending_bytes = 3 }) orelse return error.OutOfMemory;
    try std.testing.expect(b.reserve(.timer, 0));
    try std.testing.expect(!b.reserve(.timer, 0));
    try std.testing.expect(b.reserve(.tsfn_call, 3));
    try std.testing.expect(!b.reserve(.tsfn_call, 1));
    b.deinit();
    b.release(.timer, 0);
    b.release(.tsfn_call, 3);
    const next = Budget.create(.{}) orelse return error.OutOfMemory;
    defer next.deinit();
    try std.testing.expect(next.reserve(.timer, 0));
    next.release(.timer, 0);
}

test "native budgets enforce a shared process cap across instances" {
    const a = Budget.create(.{ .max_timers = 65536 }) orelse return error.OutOfMemory;
    defer a.deinit();
    const b = Budget.create(.{}) orelse return error.OutOfMemory;
    defer b.deinit();
    var reserved: usize = 0;
    defer for (0..reserved) |_| a.release(.timer, 0);
    for (0..65536) |_| {
        try std.testing.expect(a.reserve(.timer, 0));
        reserved += 1;
    }
    try std.testing.expect(!b.reserve(.timer, 0));
    a.release(.timer, 0);
    reserved -= 1;
    try std.testing.expect(b.reserve(.timer, 0));
    b.release(.timer, 0);
}

test "native budgets expose usage and honor tighter Limits after setLimits" {
    const a = Budget.create(.{ .max_timers = 2 }) orelse return error.OutOfMemory;
    defer a.deinit();
    const b = Budget.create(.{ .max_timers = 3 }) orelse return error.OutOfMemory;
    defer b.deinit();
    try std.testing.expect(a.reserve(.timer, 0));
    try std.testing.expect(a.reserve(.timer, 0));
    try std.testing.expect(!a.reserve(.timer, 0));
    const snap = a.usage();
    try std.testing.expectEqual(@as(usize, 2), snap.counts[@backingInt(Kind.timer)]);
    try std.testing.expectEqual(@as(usize, 2), snap.limits.max_timers);
    try std.testing.expect(b.reserve(.timer, 0));
    const global = globalUsage();
    try std.testing.expectEqual(@as(usize, 3), global.counts[@backingInt(Kind.timer)]);
    try std.testing.expectEqual(@as(usize, 65536), global.caps[@backingInt(Kind.timer)]);
    a.setLimits(.{ .max_timers = 1 });
    try std.testing.expect(!a.reserve(.timer, 0));
    a.release(.timer, 0);
    try std.testing.expect(!a.reserve(.timer, 0));
    a.release(.timer, 0);
    try std.testing.expect(a.reserve(.timer, 0));
    a.release(.timer, 0);
    b.release(.timer, 0);
}

test "native budgets: BACKGROUND cannot enter FG headroom; FOREGROUND still admits" {
    const bg = Budget.create(.{ .max_tsfn_handles = 4096 }) orelse return error.OutOfMemory;
    defer bg.deinit();
    bg.setAdmissionClass(.background);
    const fg = Budget.create(.{ .max_tsfn_handles = 4096 }) orelse return error.OutOfMemory;
    defer fg.deinit();
    try std.testing.expectEqual(AdmissionClass.foreground, fg.admissionClass());

    const global = globalUsage();
    const kind_i = @backingInt(Kind.tsfn_handle);
    const bg_cap = global.bg_effective_caps[kind_i];
    const hard = global.caps[kind_i];
    try std.testing.expectEqual(@as(usize, 3072), bg_cap);
    try std.testing.expectEqual(@as(usize, 4096), hard);
    try std.testing.expectEqual(@as(usize, 1024), global.fg_headrooms[kind_i]);

    var reserved_bg: usize = 0;
    defer for (0..reserved_bg) |_| bg.release(.tsfn_handle, 0);
    for (0..bg_cap) |_| {
        try std.testing.expect(bg.reserve(.tsfn_handle, 0));
        reserved_bg += 1;
    }
    try std.testing.expect(!bg.reserve(.tsfn_handle, 0));

    var reserved_fg: usize = 0;
    defer for (0..reserved_fg) |_| fg.release(.tsfn_handle, 0);
    for (0..(hard - bg_cap)) |_| {
        try std.testing.expect(fg.reserve(.tsfn_handle, 0));
        reserved_fg += 1;
    }
    try std.testing.expect(!fg.reserve(.tsfn_handle, 0));
    try std.testing.expect(!bg.reserve(.tsfn_handle, 0));
}

test "native budgets: FG filling past headroom denies BACKGROUND" {
    const fg = Budget.create(.{ .max_tsfn_handles = 4096 }) orelse return error.OutOfMemory;
    defer fg.deinit();
    const bg = Budget.create(.{ .max_tsfn_handles = 4096 }) orelse return error.OutOfMemory;
    defer bg.deinit();
    bg.setAdmissionClass(.background);

    const bg_cap = globalUsage().bg_effective_caps[@backingInt(Kind.tsfn_handle)];
    var reserved: usize = 0;
    defer for (0..reserved) |_| fg.release(.tsfn_handle, 0);
    for (0..(bg_cap + 1)) |_| {
        try std.testing.expect(fg.reserve(.tsfn_handle, 0));
        reserved += 1;
    }
    try std.testing.expect(!bg.reserve(.tsfn_handle, 0));
}

test "native budgets: setAdmissionClass mid-flight keeps live reservations" {
    const b = Budget.create(.{ .max_timers = 8 }) orelse return error.OutOfMemory;
    defer b.deinit();
    try std.testing.expect(b.reserve(.timer, 0));
    try std.testing.expect(b.reserve(.timer, 0));
    b.setAdmissionClass(.background);
    try std.testing.expectEqual(AdmissionClass.background, b.admissionClass());
    const snap = b.usage();
    try std.testing.expectEqual(@as(usize, 2), snap.counts[@backingInt(Kind.timer)]);
    b.release(.timer, 0);
    b.release(.timer, 0);
}
