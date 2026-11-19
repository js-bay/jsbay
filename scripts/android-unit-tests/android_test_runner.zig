//! Official Zig 0.17 test runner for Android device unit_tests.
//!
//! Adds --list, --test-filter=, --isolate (fork), and --timeout=SEC.
//!
//! Does not change Zig's compiler test_runner.zig or production test semantics.
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const posix = std.posix;

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;
var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);
var fba_buffer: [16384]u8 = undefined;
const runner_threaded_io: Io = Io.Threaded.global_single_threaded.io();

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const args = init.args.toSlice(fba.allocator()) catch |err| std.debug.panic("unable to parse command line args: {t}", .{err});

    var list_only = false;
    var isolate = false;
    var timeout_s: u32 = 0;
    var filters_buf: [32][]const u8 = undefined;
    var filter_count: usize = 0;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--isolate")) {
            isolate = true;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_s = std.fmt.parseUnsigned(u32, arg["--timeout=".len..], 10) catch
                @panic("unable to parse --timeout=");
        } else if (std.mem.startsWith(u8, arg, "--test-filter=")) {
            if (filter_count == filters_buf.len) @panic("too many --test-filter=");
            filters_buf[filter_count] = arg["--test-filter=".len..];
            filter_count += 1;
        } else if (std.mem.eql(u8, arg, "--test-filter")) {
            @panic("--test-filter requires --test-filter=text");
        } else if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.eql(u8, arg, "--listen=-") or std.mem.startsWith(u8, arg, "--cache-dir")) {
            // ignored on device (not a zig build server)
        } else {
            std.debug.panic("unrecognized command line argument: {s}", .{arg});
        }
    }
    const filters = filters_buf[0..filter_count];

    const test_fn_list = builtin.test_functions;
    if (list_only) {
        var listed: usize = 0;
        for (test_fn_list) |test_fn| {
            if (!matchFilters(test_fn.name, filters)) continue;
            std.debug.print("{s}\n", .{test_fn.name});
            listed += 1;
        }
        std.debug.print("listed {d} of {d}\n", .{ listed, test_fn_list.len });
        std.process.exit(0);
    }

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var crash_count: usize = 0;
    var timeout_count: usize = 0;
    var selected: usize = 0;

    for (test_fn_list, 0..) |test_fn, i| {
        if (!matchFilters(test_fn.name, filters)) continue;
        selected += 1;
        std.debug.print("{d}/{d} {s}...", .{ i + 1, test_fn_list.len, test_fn.name });

        const outcome: Outcome = if (isolate)
            runIsolated(test_fn, init, timeout_s)
        else
            runInProcess(test_fn, init);

        switch (outcome) {
            .pass => {
                ok_count += 1;
                std.debug.print("PASS\n", .{});
            },
            .skip => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
            },
            .fail => |err_name| {
                fail_count += 1;
                std.debug.print("FAIL ({s})\n", .{err_name});
            },
            .crash => |sig| {
                crash_count += 1;
                std.debug.print("CRASH (signal {d})\n", .{sig});
            },
            .timeout => {
                timeout_count += 1;
                std.debug.print("TIMEOUT ({d}s)\n", .{timeout_s});
            },
            .fail_status => |st| {
                fail_count += 1;
                std.debug.print("FAIL (exit {d})\n", .{st});
            },
        }
    }

    std.debug.print(
        "summary: {d} passed; {d} skipped; {d} failed; {d} crash; {d} timeout; selected {d} of {d}\n",
        .{ ok_count, skip_count, fail_count, crash_count, timeout_count, selected, test_fn_list.len },
    );
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (fail_count != 0 or crash_count != 0 or timeout_count != 0 or log_err_count != 0) {
        std.process.exit(1);
    }
}

fn matchFilters(name: []const u8, filters: []const []const u8) bool {
    if (filters.len == 0) return true;
    for (filters) |f| {
        if (f.len == 0) continue;
        if (std.mem.indexOf(u8, name, f) != null) return true;
    }
    return false;
}

const Outcome = union(enum) {
    pass,
    skip,
    fail: []const u8,
    fail_status: u32,
    crash: u32,
    timeout,
};

fn runInProcess(test_fn: std.builtin.TestFn, init: std.process.Init.Minimal) Outcome {
    testing.allocator_instance = .init(std.heap.page_allocator, .{
        .canary = 0xc3a701ba,
        .check_write_after_free = true,
    });
    testing.io_instance = .init(testing.allocator, .{
        .argv0 = .init(init.args),
        .environ = init.environ,
    });
    defer {
        testing.io_instance.deinit();
        _ = testing.allocator_instance.deinit();
    }
    testing.log_level = .warn;
    testing.environ = init.environ;

    if (test_fn.func()) |_| {
        return .pass;
    } else |err| switch (err) {
        error.SkipZigTest => return .skip,
        else => {
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpErrorReturnTrace(trace);
            }
            return .{ .fail = @errorName(err) };
        },
    }
}

fn runIsolated(test_fn: std.builtin.TestFn, init: std.process.Init.Minimal, timeout_s: u32) Outcome {
    const linux = std.os.linux;
    const fork_rc = linux.fork();
    if (posix.errno(fork_rc) != .SUCCESS) {
        return .{ .fail = "fork failed; isolation and timeout cannot be guaranteed" };
    }
    if (fork_rc == 0) {
        const child = runInProcess(test_fn, init);
        const code: u8 = switch (child) {
            .pass => 0,
            .skip => 2,
            else => 1,
        };
        std.process.exit(code);
    }

    const child_pid: linux.pid_t = @intCast(fork_rc);
    const started = monotonicMilliseconds() orelse {
        _ = linux.kill(child_pid, .KILL);
        var status: i32 = 0;
        _ = linux.waitpid(child_pid, &status, 0);
        return .{ .fail = "monotonic clock unavailable" };
    };
    const deadline = started +| @as(u64, timeout_s) * std.time.ms_per_s;
    while (true) {
        var status_i: i32 = 0;
        const wait_rc = linux.waitpid(child_pid, &status_i, linux.W.NOHANG);
        if (posix.errno(wait_rc) == .SUCCESS and wait_rc != 0) {
            return classifyWaitStatus(@as(u32, @bitCast(status_i)));
        }
        const now = monotonicMilliseconds() orelse {
            _ = linux.kill(child_pid, .KILL);
            _ = linux.waitpid(child_pid, &status_i, 0);
            return .{ .fail = "monotonic clock failed" };
        };
        if (timeout_s > 0 and now >= deadline) {
            _ = linux.kill(child_pid, .KILL);
            _ = linux.waitpid(child_pid, &status_i, 0);
            return .timeout;
        }
        var req = linux.timespec{ .sec = 0, .nsec = 50_000_000 };
        _ = linux.nanosleep(&req, null);
    }
}

// Counting sleep calls extends a nominal timeout under guest scheduling stalls.
// A monotonic deadline bounds elapsed time instead, including overslept polls.
fn monotonicMilliseconds() ?u64 {
    var stamp: std.os.linux.timespec = undefined;
    if (posix.errno(std.os.linux.clock_gettime(.MONOTONIC, &stamp)) != .SUCCESS) return null;
    if (stamp.sec < 0 or stamp.nsec < 0) return null;
    return @as(u64, @intCast(stamp.sec)) *| std.time.ms_per_s +| @as(u64, @intCast(stamp.nsec)) / std.time.ns_per_ms;
}

fn classifyWaitStatus(status: u32) Outcome {
    const W = std.os.linux.W;
    if (W.IFEXITED(status)) {
        const code = W.EXITSTATUS(status);
        return switch (code) {
            0 => .pass,
            2 => .skip,
            else => .{ .fail_status = code },
        };
    }
    if (W.IFSIGNALED(status)) {
        const sig = W.TERMSIG(status);
        return .{ .crash = @backingInt(sig) };
    }
    return .{ .fail_status = status };
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
