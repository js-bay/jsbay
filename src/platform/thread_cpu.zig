const std = @import("std");
const builtin = @import("builtin");

/// Returns CPU time consumed by the calling thread in nanoseconds, including user and kernel time.
/// Returns null where the operating system does not expose a supported current-thread clock.
pub fn currentThreadCpuNanoseconds() ?u64 {
    if (comptime builtin.os.tag == .windows) return windowsThreadCpuNanoseconds();
    if (comptime builtin.os.tag.isDarwin()) return darwinThreadCpuNanoseconds();
    if (comptime builtin.os.tag == .linux) {
        const usage = std.posix.getrusage(1); // RUSAGE_THREAD
        return timevalNanoseconds(usage.utime) + timevalNanoseconds(usage.stime);
    }
    return null;
}

pub fn isSupported() bool {
    return comptime switch (builtin.os.tag) {
        .windows, .linux => true,
        else => builtin.os.tag.isDarwin(),
    };
}

fn timevalNanoseconds(value: anytype) u64 {
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.usec)) * std.time.ns_per_us;
}

fn windowsThreadCpuNanoseconds() ?u64 {
    if (comptime builtin.os.tag != .windows) return null;
    const windows = std.os.windows;
    var creation: windows.FILETIME = undefined;
    var exit: windows.FILETIME = undefined;
    var kernel: windows.FILETIME = undefined;
    var user: windows.FILETIME = undefined;
    if (@backingInt(GetThreadTimes(GetCurrentThread(), &creation, &exit, &kernel, &user)) == 0) return null;
    return (fileTimeTicks(kernel) + fileTimeTicks(user)) * 100;
}

fn darwinThreadCpuNanoseconds() ?u64 {
    if (comptime !builtin.os.tag.isDarwin()) return null;
    const thread = mach_thread_self();
    defer _ = mach_port_deallocate(mach_task_self(), thread);
    var info: std.c.thread_basic_info = undefined;
    var count = std.c.THREAD.BASIC.INFO_COUNT;
    if (std.c.thread_info(thread, std.c.THREAD.BASIC.INFO, @ptrCast(&info), &count) != 0) return null;
    return machTimeNanoseconds(info.user_time) + machTimeNanoseconds(info.system_time);
}

fn machTimeNanoseconds(value: std.c.time_value_t) u64 {
    return @as(u64, @intCast(value.seconds)) * std.time.ns_per_s + @as(u64, @intCast(value.microseconds)) * std.time.ns_per_us;
}

fn fileTimeTicks(value: std.os.windows.FILETIME) u64 {
    return (@as(u64, value.dwHighDateTime) << 32) | value.dwLowDateTime;
}

extern "kernel32" fn GetCurrentThread() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetThreadTimes(
    thread: std.os.windows.HANDLE,
    creation_time: *std.os.windows.FILETIME,
    exit_time: *std.os.windows.FILETIME,
    kernel_time: *std.os.windows.FILETIME,
    user_time: *std.os.windows.FILETIME,
) callconv(.winapi) std.os.windows.BOOL;
extern "c" fn mach_thread_self() std.c.thread_act_t;
extern "c" fn mach_task_self() std.c.mach_port_t;
extern "c" fn mach_port_deallocate(task: std.c.mach_port_t, name: std.c.mach_port_t) c_int;

pub const testing = if (builtin.is_test) struct {
    /// Consume CPU until the platform clock advances; fixed iteration counts cannot guarantee a measurable interval.
    pub fn consumeTick() !void {
        const start = currentThreadCpuNanoseconds() orelse {
            if (isSupported()) return error.CpuClockUnavailable;
            return;
        };
        const io = @import("io.zig");
        const deadline = io.monotonicMilliseconds() + 5_000;
        var work: u64 = 1;
        while (true) {
            for (0..10_000) |index| work = work *% 6364136223846793005 +% index;
            std.mem.doNotOptimizeAway(&work);
            const now = currentThreadCpuNanoseconds() orelse return error.CpuClockUnavailable;
            if (now > start) return;
            if (io.monotonicMilliseconds() >= deadline) return error.CpuClockDidNotAdvance;
        }
    }
} else struct {};

test "thread CPU clock is monotonic when supported" {
    const before = currentThreadCpuNanoseconds();
    var value: u64 = 0;
    for (0..1_000_000) |i| value +%= i;
    std.mem.doNotOptimizeAway(&value);
    const after = currentThreadCpuNanoseconds();
    if (isSupported()) {
        try std.testing.expect(before != null);
        try std.testing.expect(after != null);
        try std.testing.expect(after.? >= before.?);
    } else {
        try std.testing.expect(before == null);
        try std.testing.expect(after == null);
    }
}
