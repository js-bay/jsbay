//! JSC WebKit Inspector surface — enables Safari's Develop menu to attach a real breakpoint-/stepping-capable debugger to a js-bay instance.
//!
//! This is a thin wrapper over private JSC `JSRemoteInspector*` and `JSGlobalContextSetRemoteInspectionEnabled` entry points. The public macOS/iOS SDK headers do not declare them, so this file declares the symbols with `extern "c"` and relies on the framework link to resolve them.
//!
//! The Zig layer here is deliberately boring: resolve the instance's `JSGlobalContextRef`, flip flags, optionally set a human-readable name for the Safari menu. Everything else — transport, protocol, breakpoint machinery — lives inside the framework.
//!
//! Pair with our own CDP inspector (`src/inspector/root.zig`) for Chrome DevTools + QJS. These are two parallel debug surfaces; pick whichever matches your target tooling.

const std = @import("std");
const backend = @import("../../backend.zig");
const instance_map = @import("../../runtime/instance_map.zig");

// ---------------------------------------------------------------------------
// Private JSC externs
// ---------------------------------------------------------------------------
//
// Sourced from WebKit's JSRemoteInspector.h / JSContextRefPrivate.h (both private headers not shipped in the public SDK but documented in the open WebKit tree). Verified-present in the dylib via:
//
//   xcrun dyld_info -exports .../JavaScriptCore.framework/JavaScriptCore
//
// which exposes _JSRemoteInspectorStart, _JSRemoteInspectorSetInspection- EnabledByDefault, _JSGlobalContextSetRemoteInspectionEnabled, and _JSGlobalContextSetName — all 4 we need.
//
// The externs are gated to the JSC backend; under QJS they're never referenced at link time, so the declarations stay inert.
//
// Signatures: void JSRemoteInspectorStart(void); void JSRemoteInspectorSetInspectionEnabledByDefault(bool enabled); void JSGlobalContextSetRemoteInspectionEnabled(JSGlobalContextRef, bool); void JSGlobalContextSetName(JSGlobalContextRef, JSStringRef);
//
// JSStringRef is an opaque pointer from the JSC bindings, referenced only in the JSC branch.

const jsc_mod = if (backend.isJscApiBackend(backend.active_backend))
    @import("../jsc.zig")
else
    struct {};

// These externs are only link-resolved when built against JavaScriptCore. Under QJS they're never called, but declaring them is harmless — Zig emits no references unless a call site is actually reachable.
const externs = if (backend.isJscApiBackend(backend.active_backend)) struct {
    pub extern "c" fn JSRemoteInspectorStart() void;
    pub extern "c" fn JSRemoteInspectorSetInspectionEnabledByDefault(enabled: bool) void;
    pub extern "c" fn JSGlobalContextSetRemoteInspectionEnabled(
        ctx: jsc_mod.jsc.JSGlobalContextRef,
        enabled: bool,
    ) void;
    pub extern "c" fn JSGlobalContextSetName(
        ctx: jsc_mod.jsc.JSGlobalContextRef,
        name: jsc_mod.jsc.JSStringRef,
    ) void;
    // Marks a context as inspectable for remote inspection.
    pub extern "c" fn JSGlobalContextSetInspectable(
        ctx: jsc_mod.jsc.JSGlobalContextRef,
        inspectable: bool,
    ) void;
} else struct {};

// ---------------------------------------------------------------------------
// Internal state
// ---------------------------------------------------------------------------

/// Have we called `JSRemoteInspectorStart` in this process? Guard the documented one-time call.
var g_listener_started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Have we flipped `SetInspectionEnabledByDefault(true)` this process? Same guard as above; once set there's no reason to set it again.
var g_default_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Start the process-wide JSC remote-inspection listener. Idempotent. On macOS this kicks off the XPC/Bonjour service Safari discovers. Must be called at least once before `enable` for the enable to be effective.
///
/// Under QJS backend: no-op, returns false.
pub fn startListener() bool {
    if (!backend.isJscApiBackend(backend.active_backend)) return false;
    if (g_listener_started.swap(true, .seq_cst)) {
        // Already started — idempotent success.
        return true;
    }
    externs.JSRemoteInspectorStart();
    return true;
}
/// Enable JSC's built-in WebKit Inspector agent on this engine instance so Safari's Develop menu can attach with full breakpoint/stepping support.
///
/// Call AFTER engine.create and BEFORE any JS that you care about being debuggable has run. Pair with `disable(id)` before `engine.destroy` to be clean (the value is attached to the underlying JSGlobalContext and goes away on context teardown anyway, so leaks are bounded).
///
/// `name` is shown in Safari's menu (e.g. "my-app"). Pass null to leave it as JSC's default.
///
/// Returns false if called on the QJS backend, if the instance is gone, or if `JSRemoteInspectorStart` hasn't been called yet (call `startListener` first or the convenience `startAndEnable`).
pub fn enable(instance_id: i32, name: ?[]const u8) bool {
    if (!backend.isJscApiBackend(backend.active_backend)) return false;

    if (!g_listener_started.load(.seq_cst)) {
        std.log.warn(
            "jsc_remote_inspector.enable({d}): listener not started; call startListener() or startAndEnable()",
            .{instance_id},
        );
        return false;
    }

    const ptrs = instance_map.getPtrs(instance_id) orelse {
        std.log.warn("jsc_remote_inspector.enable({d}): no such instance", .{instance_id});
        return false;
    };
    const ctx: jsc_mod.jsc.JSGlobalContextRef = ptrs.ctx;
    if (ctx == null) {
        std.log.warn("jsc_remote_inspector.enable({d}): null context", .{instance_id});
        return false;
    }

    // Global default — safe to call multiple times but we gate it anyway.
    if (!g_default_enabled.swap(true, .seq_cst)) {
        externs.JSRemoteInspectorSetInspectionEnabledByDefault(true);
    }

    // Enable remote inspection and mark this context as inspectable.
    externs.JSGlobalContextSetRemoteInspectionEnabled(ctx, true);
    externs.JSGlobalContextSetInspectable(ctx, true);

    // Human-readable name for Safari's Develop menu.
    if (name) |n| setName(ctx, n);

    return true;
}

/// Disable remote inspection on this engine instance. Safe to call even if `enable` was never called. Does NOT stop the process-wide listener (it has no off switch in the public-but-private JSC API anyway).
pub fn disable(instance_id: i32) bool {
    if (!backend.isJscApiBackend(backend.active_backend)) return false;

    const ptrs = instance_map.getPtrs(instance_id) orelse return false;
    const ctx: jsc_mod.jsc.JSGlobalContextRef = ptrs.ctx;
    if (ctx == null) return false;

    externs.JSGlobalContextSetRemoteInspectionEnabled(ctx, false);
    externs.JSGlobalContextSetInspectable(ctx, false);
    return true;
}

/// Convenience: `startListener()` + `enable(instance_id, name)` in one call. Returns true only if both steps succeed.
pub fn startAndEnable(instance_id: i32, name: ?[]const u8) bool {
    if (!backend.isJscApiBackend(backend.active_backend)) return false;
    if (!startListener()) return false;
    return enable(instance_id, name);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn setName(ctx: anytype, name: []const u8) void {
    if (!backend.isJscApiBackend(backend.active_backend)) return;

    // JSStringCreateWithUTF8CString requires a NUL-terminated input. The `name` we get from callers is a Zig slice that may not be sentinel-terminated, so duplicate into a c_allocator-owned buffer first.
    const z = std.heap.c_allocator.dupeSentinel(u8, name, 0) catch {
        std.log.warn("jsc_remote_inspector.setName: OOM duping name; skipping", .{});
        return;
    };
    defer std.heap.c_allocator.free(z);

    const name_ref = jsc_mod.jsc.JSStringCreateWithUTF8CString(z.ptr);
    if (name_ref == null) {
        std.log.warn("jsc_remote_inspector.setName: JSStringCreateWithUTF8CString returned null", .{});
        return;
    }
    defer jsc_mod.jsc.JSStringRelease(name_ref);

    externs.JSGlobalContextSetName(ctx, name_ref);
}
