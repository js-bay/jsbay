//! Native-stack measurements used to keep a VM's stack budget inside the currently executing thread.  The result is deliberately optional: hosts outside the supported platform APIs use a conservative fallback cap.

const std = @import("std");
const builtin = @import("builtin");

/// Keep VM recursion away from the native stack guard page and the native frames which run after the VM reports an overflow.
pub const reserve_bytes: usize = 128 * 1024;

/// Floor for the VM budget when the platform reports the current stack. Debug builds of QuickJS can burn ~50KiB+ of native stack inside `JS_Eval` before the first overflow check; a tiny remainder after `reserve_bytes` then makes even `6 * 7` fail on a 512KiB worker thread. Shrink the reserve rather than returning that unusable remainder.
pub const min_js_budget_bytes: usize = 96 * 1024;

/// Fallback when a caller supplies no cap or the platform cannot report a current thread boundary. Unknown smaller stacks still require host validation.
pub const conservative_limit: usize = 1024 * 1024;

/// Bytes between `sp` and the low end of the current downward-growing native stack. Returns null when the platform does not expose this information.
pub fn availableBelow(sp: usize) ?usize {
    switch (builtin.os.tag) {
        .macos, .ios, .watchos, .tvos, .visionos => {
            const c = struct {
                extern "c" fn pthread_self() std.c.pthread_t;
                extern "c" fn pthread_get_stackaddr_np(std.c.pthread_t) ?*anyopaque;
                extern "c" fn pthread_get_stacksize_np(std.c.pthread_t) usize;
            };
            const thread = c.pthread_self();
            const top = @intFromPtr(c.pthread_get_stackaddr_np(thread) orelse return null);
            const size = c.pthread_get_stacksize_np(thread);
            const low = top -| size;
            return if (sp >= low and sp <= top) sp - low else null;
        },
        .linux => {
            const c = struct {
                extern "c" fn pthread_self() std.c.pthread_t;
                extern "c" fn pthread_getattr_np(std.c.pthread_t, *std.c.pthread_attr_t) c_int;
                extern "c" fn pthread_attr_getstack(*const std.c.pthread_attr_t, *?*anyopaque, *usize) c_int;
                extern "c" fn pthread_attr_destroy(*std.c.pthread_attr_t) c_int;
            };
            var attr: std.c.pthread_attr_t = undefined;
            if (c.pthread_getattr_np(c.pthread_self(), &attr) != 0) return null;
            defer _ = c.pthread_attr_destroy(&attr);
            var low_ptr: ?*anyopaque = null;
            var size: usize = 0;
            if (c.pthread_attr_getstack(&attr, &low_ptr, &size) != 0) return null;
            const low = @intFromPtr(low_ptr orelse return null);
            const top = low +| size;
            return if (sp >= low and sp <= top) sp - low else null;
        },
        .windows => {
            const kernel32 = struct {
                extern "kernel32" fn GetCurrentThreadStackLimits(low_limit: *usize, high_limit: *usize) callconv(.winapi) void;
            };
            var low: usize = 0;
            var high: usize = 0;
            kernel32.GetCurrentThreadStackLimits(&low, &high);
            return if (sp >= low and sp <= high) sp - low else null;
        },
        else => return null,
    }
}

/// Cap `configured` to what the current thread can actually spare below `sp`.
///
/// Prefer keeping [reserve_bytes] between the VM limit and the native stack low. When that would leave less than [min_js_budget_bytes] for the VM, shrink the reserve so Debug `JS_Eval` prologue + a trivial script still fit. Pathologically small stacks split the remainder in half rather than returning a one-byte budget that rejects every evaluation.
pub fn capToCurrentThread(configured: usize, sp: usize) usize {
    const requested = if (configured == 0) conservative_limit else configured;
    const available = availableBelow(sp) orelse return @min(requested, conservative_limit);
    return capAvailable(requested, available);
}

/// Pure helper for [capToCurrentThread] so unit tests can lock the policy without mocking pthread.
pub fn capAvailable(requested: usize, available: usize) usize {
    var reserve = reserve_bytes;
    if (available > min_js_budget_bytes) {
        const max_reserve = available - min_js_budget_bytes;
        if (reserve > max_reserve) reserve = max_reserve;
    } else {
        reserve = available / 2;
    }
    const safe = available -| reserve;
    return @min(requested, @max(@as(usize, 1), safe));
}
