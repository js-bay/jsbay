//! Process-wide JavaScriptCore polling trap configuration for macOS arm64.

const builtin = @import("builtin");
const std = @import("std");

const applies = builtin.os.tag == .macos and builtin.cpu.arch == .aarch64;

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const State = enum { unknown, enabled, disabled, invalid };

var mutex: std.Thread.Mutex = .{};
var state: State = .unknown;

fn parse(value: []const u8) State {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.ascii.eqlIgnoreCase(value, "yes") or std.mem.eql(u8, value, "1")) return .enabled;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.ascii.eqlIgnoreCase(value, "no") or std.mem.eql(u8, value, "0")) return .disabled;
    return .invalid;
}

fn currentEnvironmentState() State {
    const value = getenv("JSC_usePollingTraps") orelse return .enabled;
    return parse(std.mem.span(value));
}

/// Report the capability implied by the current process environment without freezing JSC options.
pub fn supportsInterrupt() bool {
    if (!applies) return true;
    mutex.lock();
    defer mutex.unlock();
    return switch (state) {
        .unknown => currentEnvironmentState() == .enabled,
        .enabled => true,
        .disabled, .invalid => false,
    };
}

/// Resolve the process-wide option before JSContextGroupCreate freezes JSC options.
pub fn prepareBeforeVm() bool {
    if (!applies) return true;
    mutex.lock();
    defer mutex.unlock();
    if (state != .unknown) return state != .invalid;

    const configured = getenv("JSC_usePollingTraps") orelse {
        if (setenv("JSC_usePollingTraps", "true", 0) != 0) {
            state = .invalid;
            return false;
        }
        state = currentEnvironmentState();
        return state == .enabled;
    };
    state = parse(std.mem.span(configured));
    return state != .invalid;
}
