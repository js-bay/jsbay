const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const is_darwin = builtin.os.tag.isDarwin();
const uses_futex = builtin.os.tag == .linux;
const is_ohos = builtin.abi == .ohos or builtin.abi == .ohoseabi;

/// A blocking native mutex for shared package state. The mutex must stay at a stable address after its first use and be deinitialized only after all threads have stopped using it.
pub const Mutex = if (is_windows) WindowsMutex else PthreadMutex;
const pthread_api = if (is_ohos) @import("ohos_pthread") else std.c;

const WindowsMutex = struct {
    inner: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,

    pub fn lock(self: *WindowsMutex) void {
        acquireWindows(&self.inner);
    }
    pub fn unlock(self: *WindowsMutex) void {
        releaseWindows(&self.inner);
    }
    pub fn tryLock(self: *WindowsMutex) bool {
        return @backingInt(TryAcquireSRWLockExclusive(&self.inner)) != 0;
    }
    pub fn deinit(_: *WindowsMutex) void {}
};

const PthreadMutex = struct {
    inner: pthread_api.pthread_mutex_t = if (is_ohos) pthread_api.zev_mutex_initializer else std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *PthreadMutex) void {
        checkPthreadResult(pthread_api.pthread_mutex_lock(&self.inner), "mutex lock failed");
    }
    pub fn unlock(self: *PthreadMutex) void {
        checkPthreadResult(pthread_api.pthread_mutex_unlock(&self.inner), "mutex unlock failed");
    }
    pub fn tryLock(self: *PthreadMutex) bool {
        const result = pthreadResultCode(pthread_api.pthread_mutex_trylock(&self.inner));
        if (result == 0) return true;
        if (result == pthread_busy) return false;
        @panic("mutex tryLock failed");
    }
    pub fn deinit(self: *PthreadMutex) void {
        checkPthreadResult(pthread_api.pthread_mutex_destroy(&self.inner), "mutex destroyed while in use");
    }
};

fn pthreadResultCode(result: anytype) c_int {
    return if (@TypeOf(result) == c_int) result else @intCast(@backingInt(result));
}
const pthread_busy: c_int = if (is_ohos) pthread_api.EBUSY else @intCast(@backingInt(std.posix.E.BUSY));
fn checkPthreadResult(result: anytype, message: []const u8) void {
    if (pthreadResultCode(result) != 0) @panic(message);
}

const WindowsState = struct {
    mutex: std.os.windows.SRWLOCK = std.os.windows.SRWLOCK_INIT,
    condition: std.os.windows.CONDITION_VARIABLE = std.os.windows.CONDITION_VARIABLE_INIT,
    generation_value: u64 = 0,
};
const PthreadState = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    generation_value: u64 = 0,
};
// Linux, Android, and OpenHarmony use the kernel futex ABI. This keeps monotonic relative timeouts for waiting; OpenHarmony mutex definitions come separately from its SDK pthread header.
//
// The generation is the futex word itself. It is 32 bits wide because 32-bit targets have no 64-bit atomics; it wraps, and callers only compare it for equality.
const FutexState = struct {
    generation_value: std.atomic.Value(u32) = .init(0),
};
pub const State = if (is_windows) WindowsState else if (uses_futex) FutexState else PthreadState;
pub const init: State = .{};
pub fn destroy(state: *State) void {
    if (comptime !is_windows and !uses_futex) {
        const cond_result = std.c.pthread_cond_destroy(&state.condition);
        const mutex_result = std.c.pthread_mutex_destroy(&state.mutex);
        if (@backingInt(cond_result) != 0 or @backingInt(mutex_result) != 0) @panic("event waiter destroyed while in use");
    }
}
pub fn generation(state: *State) u64 {
    if (comptime is_windows) {
        acquireWindows(&state.mutex);
        defer releaseWindows(&state.mutex);
        return state.generation_value;
    }
    if (comptime uses_futex) return @as(u64, state.generation_value.load(.acquire));
    lockPthread(&state.mutex);
    defer unlockPthread(&state.mutex);
    return state.generation_value;
}
pub fn signal(state: *State) void {
    wake(state, false);
}
pub fn broadcast(state: *State) void {
    wake(state, true);
}
fn wake(state: *State, all: bool) void {
    if (comptime is_windows) {
        acquireWindows(&state.mutex);
        state.generation_value +%= 1;
        if (all) wakeAllWindows(&state.condition) else wakeOneWindows(&state.condition);
        releaseWindows(&state.mutex);
    } else if (comptime uses_futex) {
        // The atomic add wraps. The kernel sleeps a waiter only while the word still equals the value it read, so a wake after that read makes the wait return immediately. A miss needs exactly 2^32 wakes to land between the waiter's read and its futex call.
        _ = state.generation_value.fetchAdd(1, .release);
        futexWake(&state.generation_value, if (all) @intCast(std.math.maxInt(i32)) else 1);
    } else {
        lockPthread(&state.mutex);
        state.generation_value +%= 1;
        const result = if (all) std.c.pthread_cond_broadcast(&state.condition) else std.c.pthread_cond_signal(&state.condition);
        unlockPthread(&state.mutex);
        if (@backingInt(result) != 0) @panic("event waiter wake failed");
    }
}
pub fn waitUntilChange(state: *State, expected_generation: u64, timeout_ms: ?u64) bool {
    if (comptime is_windows) return waitWindows(state, expected_generation, timeout_ms);
    if (comptime uses_futex) return waitFutex(state, expected_generation, timeout_ms);
    return waitPthread(state, expected_generation, timeout_ms);
}
fn waitPthread(state: *PthreadState, expected_generation: u64, timeout_ms: ?u64) bool {
    const deadline = if (timeout_ms) |milliseconds| addMilliseconds(monotonicMilliseconds(), milliseconds) else null;
    lockPthread(&state.mutex);
    defer unlockPthread(&state.mutex);
    while (state.generation_value == expected_generation) {
        if (deadline) |end| {
            const now = monotonicMilliseconds();
            if (now >= end) return false;
            if (comptime is_darwin) {
                var relative = millisecondsTimespec(end - now);
                const result = pthread_cond_timedwait_relative_np(&state.condition, &state.mutex, &relative);
                if (result != 0 and result != timed_out_error) @panic("event waiter wait failed");
            } else {
                const realtime_end = addMilliseconds(realtimeMilliseconds(), end - now);
                var absolute = millisecondsTimespec(realtime_end);
                const result = std.c.pthread_cond_timedwait(&state.condition, &state.mutex, &absolute);
                if (@backingInt(result) != 0 and @backingInt(result) != timed_out_error) @panic("event waiter wait failed");
            }
        } else {
            const result = std.c.pthread_cond_wait(&state.condition, &state.mutex);
            if (@backingInt(result) != 0) @panic("event waiter wait failed");
        }
    }
    return true;
}
fn waitFutex(state: *FutexState, expected_generation: u64, timeout_ms: ?u64) bool {
    const deadline = if (timeout_ms) |milliseconds| addMilliseconds(monotonicMilliseconds(), milliseconds) else null;
    const expected: u32 = @truncate(expected_generation);
    while (state.generation_value.load(.acquire) == expected) {
        var timeout: ?std.os.linux.timespec = null;
        if (deadline) |end| {
            const now = monotonicMilliseconds();
            if (now >= end) return false;
            timeout = millisecondsTimespecLinux(end - now);
        }
        futexWait(&state.generation_value, expected, if (timeout) |*value| value else null);
    }
    return true;
}
fn waitWindows(state: *WindowsState, expected_generation: u64, timeout_ms: ?u64) bool {
    const deadline = if (timeout_ms) |milliseconds| addMilliseconds(monotonicMilliseconds(), milliseconds) else null;
    acquireWindows(&state.mutex);
    defer releaseWindows(&state.mutex);
    while (state.generation_value == expected_generation) {
        const duration: u32 = if (deadline) |end| blk: {
            const now = monotonicMilliseconds();
            if (now >= end) return false;
            break :blk @intCast(@min(end - now, @as(u64, std.math.maxInt(u32) - 1)));
        } else std.math.maxInt(u32);
        if (!sleepConditionWindows(&state.condition, &state.mutex, duration)) {
            if (windowsLastError() == 1_460) continue;
            @panic("event waiter wait failed");
        }
    }
    return true;
}
pub fn monotonicMilliseconds() u64 {
    if (comptime is_windows) return tickCountWindows();
    if (comptime uses_futex) {
        var now: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(.MONOTONIC, &now) != 0) @panic("monotonic clock unavailable");
        return timespecMillisecondsLinux(now);
    }
    var now: std.c.timespec = undefined;
    if (clock_gettime(clock_monotonic, &now) != 0) @panic("monotonic clock unavailable");
    return timespecMilliseconds(now);
}
pub fn realtimeMilliseconds() u64 {
    if (comptime is_windows) {
        var filetime: FileTime = undefined;
        getSystemTimeAsFileTime(&filetime);
        return (((@as(u64, filetime.high) << 32) | filetime.low) / 10_000) - 11_644_473_600_000;
    }
    if (comptime uses_futex) {
        var now: std.os.linux.timespec = undefined;
        if (std.os.linux.clock_gettime(.REALTIME, &now) != 0) @panic("realtime clock unavailable");
        return timespecMillisecondsLinux(now);
    }
    var now: std.c.timespec = undefined;
    if (clock_gettime(0, &now) != 0) @panic("realtime clock unavailable");
    return timespecMilliseconds(now);
}
pub fn sleepMilliseconds(milliseconds: u64) void {
    if (comptime is_windows) {
        var remaining = milliseconds;
        while (remaining != 0) {
            const chunk: u32 = @intCast(@min(remaining, @as(u64, std.math.maxInt(u32) - 1)));
            sleepWindows(chunk);
            remaining -= chunk;
        }
        return;
    }
    if (comptime uses_futex) {
        var remaining = milliseconds;
        while (remaining != 0) {
            const chunk = @min(remaining, @as(u64, 86_400_000));
            var duration = millisecondsTimespecLinux(chunk);
            var interrupted: std.os.linux.timespec = undefined;
            while (true) {
                const result = std.os.linux.nanosleep(&duration, &interrupted);
                if (result == 0) break;
                if (result != linuxError(.INTR)) @panic("thread sleep failed");
                duration = interrupted;
            }
            remaining -= chunk;
        }
        return;
    }
    var remaining = milliseconds;
    while (remaining != 0) {
        const chunk = @min(remaining, @as(u64, 86_400_000));
        var duration = millisecondsTimespec(chunk);
        var interrupted: std.c.timespec = undefined;
        while (nanosleep(&duration, &interrupted) != 0) {
            if (std.c.errno(-1) != .INTR) @panic("thread sleep failed");
            duration = interrupted;
        }
        remaining -= chunk;
    }
}
fn addMilliseconds(start: u64, duration: u64) u64 {
    return std.math.add(u64, start, duration) catch std.math.maxInt(u64);
}
// `sec` is 32 bits wide on 32-bit targets, so clamp to the field's own range.
fn millisecondsTimespec(milliseconds: u64) std.c.timespec {
    const max_sec: u64 = std.math.maxInt(@FieldType(std.c.timespec, "sec"));
    return .{ .sec = @intCast(@min(milliseconds / 1_000, max_sec)), .nsec = @intCast((milliseconds % 1_000) * 1_000_000) };
}
fn millisecondsTimespecLinux(milliseconds: u64) std.os.linux.timespec {
    const max_sec: u64 = std.math.maxInt(@FieldType(std.os.linux.timespec, "sec"));
    return .{ .sec = @intCast(@min(milliseconds / 1_000, max_sec)), .nsec = @intCast((milliseconds % 1_000) * 1_000_000) };
}
fn timespecMilliseconds(value: std.c.timespec) u64 {
    if (value.sec < 0) @panic("clock returned a negative timestamp");
    return @as(u64, @intCast(value.sec)) * 1_000 + @as(u64, @intCast(value.nsec)) / 1_000_000;
}
fn timespecMillisecondsLinux(value: std.os.linux.timespec) u64 {
    if (value.sec < 0) @panic("clock returned a negative timestamp");
    return @as(u64, @intCast(value.sec)) * 1_000 + @as(u64, @intCast(value.nsec)) / 1_000_000;
}
fn linuxError(err: std.os.linux.E) usize {
    return @bitCast(-@as(isize, @backingInt(err)));
}
fn linuxErrno(result: usize) ?std.os.linux.E {
    const signed: isize = @bitCast(result);
    if (signed >= 0) return null;
    return @fromBackingInt(@intCast(-signed));
}
const clock_monotonic: c_int = if (is_darwin) 6 else 1;
const timed_out_error: c_int = if (is_darwin) 60 else 110;
extern "c" fn clock_gettime(clock: c_int, now: *std.c.timespec) c_int;
extern "c" fn nanosleep(duration: *const std.c.timespec, remaining: *std.c.timespec) c_int;
extern "c" fn pthread_cond_timedwait_relative_np(condition: *std.c.pthread_cond_t, mutex: *std.c.pthread_mutex_t, duration: *const std.c.timespec) c_int;
fn lockPthread(mutex: *std.c.pthread_mutex_t) void {
    if (@backingInt(std.c.pthread_mutex_lock(mutex)) != 0) @panic("event waiter lock failed");
}
fn unlockPthread(mutex: *std.c.pthread_mutex_t) void {
    if (@backingInt(std.c.pthread_mutex_unlock(mutex)) != 0) @panic("event waiter unlock failed");
}
fn futexWait(sequence: *std.atomic.Value(u32), expected: u32, timeout: ?*const std.os.linux.timespec) void {
    const result = std.os.linux.futex_4arg(sequence, .{ .cmd = .WAIT, .private = true }, expected, timeout);
    if (linuxErrno(result)) |err| switch (err) {
        .AGAIN, .INTR, .TIMEDOUT => {},
        else => @panic("event waiter futex wait failed"),
    };
}
fn futexWake(sequence: *std.atomic.Value(u32), count: u32) void {
    const result = std.os.linux.futex_3arg(sequence, .{ .cmd = .WAKE, .private = true }, count);
    if (linuxErrno(result) != null) @panic("event waiter futex wake failed");
}
const windows = std.os.windows;
const FileTime = extern struct { low: u32, high: u32 };
extern "kernel32" fn AcquireSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn ReleaseSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) void;
extern "kernel32" fn TryAcquireSRWLockExclusive(lock: *windows.SRWLOCK) callconv(.winapi) windows.BOOLEAN;
extern "kernel32" fn WakeConditionVariable(condition: *windows.CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn WakeAllConditionVariable(condition: *windows.CONDITION_VARIABLE) callconv(.winapi) void;
extern "kernel32" fn SleepConditionVariableSRW(condition: *windows.CONDITION_VARIABLE, lock: *windows.SRWLOCK, milliseconds: u32, flags: u32) callconv(.winapi) windows.BOOL;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetSystemTimeAsFileTime(result: *FileTime) callconv(.winapi) void;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
fn acquireWindows(lock: *windows.SRWLOCK) void {
    AcquireSRWLockExclusive(lock);
}
fn releaseWindows(lock: *windows.SRWLOCK) void {
    ReleaseSRWLockExclusive(lock);
}
fn wakeOneWindows(condition: *windows.CONDITION_VARIABLE) void {
    WakeConditionVariable(condition);
}
fn wakeAllWindows(condition: *windows.CONDITION_VARIABLE) void {
    WakeAllConditionVariable(condition);
}
fn sleepConditionWindows(condition: *windows.CONDITION_VARIABLE, lock: *windows.SRWLOCK, milliseconds: u32) bool {
    return @backingInt(SleepConditionVariableSRW(condition, lock, milliseconds, 0)) != 0;
}
fn windowsLastError() u32 {
    return GetLastError();
}
fn tickCountWindows() u64 {
    return GetTickCount64();
}
fn getSystemTimeAsFileTime(result: *FileTime) void {
    GetSystemTimeAsFileTime(result);
}
fn sleepWindows(milliseconds: u32) void {
    Sleep(milliseconds);
}
