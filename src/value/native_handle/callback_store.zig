//! engine/native_handle/callback_store.zig — Fixed-capacity store for JS callback functions used by NativeHandle consumers.
//!
//! Wraps `listeners.NamedListenerRegistry` so the JS-engine handles DupValue / FreeValue / GC-mark automatically.
//!
//! Usage:
//!   1. Embed a CallbackStore in your native state struct.
//!   2. In your onXxx method impl, call store.set(ctx, "play", argv[0]).
//!   3. To fire the callback from native: store.fire(ctx, "play", args).
//!   4. Wire gc_mark_fn → store.markAll(), finalize_fn → store.freeAll().
//!
//! Designed for the pattern: const host = invoke('host'); host.onPlay(() => { ... }); host.onStop(() => { ... })

const types = @import("types.zig");
const listeners = @import("../../runtime/listeners.zig");

const c = types.c;

pub const MAX_CALLBACKS = 16;
pub const MAX_NAME_LEN = 31;

pub const CallbackEntry = struct {
    name: [MAX_NAME_LEN + 1]u8 = @splat(0),
    name_len: u8 = 0,
    value: c.JSValue = types.JS_UNDEFINED,
    active: bool = false,
};

pub const CallbackStore = struct {
    inner: listeners.NamedListenerRegistry = .{},

    /// Set the owner object (the NativeHandle instance). DupValues it so the handle won't be GC'd while callbacks exist.
    ///
    /// Typical call site: right after NativeHandle.create(), before returning the handle to JS.
    pub fn setOwner(self: *CallbackStore, ctx: ?*c.JSContext, obj: c.JSValue) void {
        self.inner.setOwner(ctx, obj);
    }

    /// Store a JS callback under a name. DupValues the function so it won't be GC'd. Replaces any previous callback with the same name.
    pub fn set(self: *CallbackStore, ctx: ?*c.JSContext, name: []const u8, func: c.JSValue) bool {
        return self.inner.set(ctx, name, func);
    }

    /// Remove a callback by name.  FreeValues and marks the slot inactive.
    pub fn remove(self: *CallbackStore, ctx: ?*c.JSContext, name: []const u8) void {
        self.inner.remove(ctx, name);
    }

    /// Fire a stored callback. Returns the JSValue result (caller owns it). If no callback is registered for `name`, returns JS_UNDEFINED.
    ///
    /// `this` inside the callback is the owner object (set via `setOwner`), or `globalThis` if no owner was set.
    pub fn fire(self: *CallbackStore, ctx: ?*c.JSContext, name: []const u8, argc: c_int, argv: ?[*]c.JSValue) c.JSValue {
        const args = if (argv == null or argc <= 0)
            &[_]c.JSValue{}
        else
            argv.?[0..@intCast(argc)];

        return self.inner.callRetained(ctx, name, args) orelse types.JS_UNDEFINED;
    }

    /// Call from gc_mark_fn to mark all stored callbacks and owner as reachable.
    pub fn markAll(self: *CallbackStore, rt: ?*c.JSRuntime, mark_func: ?*const c.JS_MarkFunc) void {
        self.inner.markAll(rt, mark_func);
    }

    /// Call from finalize_fn to free all stored callbacks and owner.
    pub fn freeAll(self: *CallbackStore, ctx: ?*c.JSContext) void {
        self.inner.freeAll(ctx);
    }

    /// Check if a callback is registered for the given name.
    pub fn has(self: *const CallbackStore, name: []const u8) bool {
        return self.inner.has(name);
    }
};
