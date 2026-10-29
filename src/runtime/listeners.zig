//! Backend-neutral listener registry for host-owned JS callbacks.
//!
//! This keeps callback lifetime management in js-bay instead of scattering engine-specific retain/release logic in consumers.

const std = @import("std");
const backend = @import("../backend.zig");

const ActiveEngine = backend.ActiveEngine;

pub const MAX_LISTENERS = 16;
pub const MAX_NAME_LEN = 31;

pub const ListenerEntry = struct {
    name: [MAX_NAME_LEN + 1]u8 = @splat(0),
    name_len: u8 = 0,
    value: ActiveEngine.Value = ActiveEngine.undefinedValue(),
    active: bool = false,
};

pub const NamedListenerRegistry = struct {
    entries: [MAX_LISTENERS]ListenerEntry = @splat(.{}),
    owner: ActiveEngine.Value = ActiveEngine.undefinedValue(),
    owner_set: bool = false,

    pub fn setOwner(self: *NamedListenerRegistry, ctx: ActiveEngine.Context, obj: ActiveEngine.Value) void {
        if (self.owner_set) {
            ActiveEngine.freeValue(ctx, self.owner);
        }
        self.owner = ActiveEngine.dupValue(ctx, obj);
        self.owner_set = true;
    }

    pub fn set(self: *NamedListenerRegistry, ctx: ActiveEngine.Context, name: []const u8, func: ActiveEngine.Value) bool {
        if (name.len == 0 or name.len > MAX_NAME_LEN) return false;

        for (&self.entries) |*e| {
            if (e.active and e.name_len == name.len and std.mem.eql(u8, e.name[0..e.name_len], name)) {
                ActiveEngine.freeValue(ctx, e.value);
                e.value = ActiveEngine.dupValue(ctx, func);
                return true;
            }
        }

        for (&self.entries) |*e| {
            if (!e.active) {
                @memset(&e.name, 0);
                @memcpy(e.name[0..name.len], name);
                e.name_len = @intCast(name.len);
                e.value = ActiveEngine.dupValue(ctx, func);
                e.active = true;
                return true;
            }
        }

        return false;
    }

    pub fn remove(self: *NamedListenerRegistry, ctx: ActiveEngine.Context, name: []const u8) void {
        for (&self.entries) |*e| {
            if (e.active and e.name_len == name.len and std.mem.eql(u8, e.name[0..e.name_len], name)) {
                ActiveEngine.freeValue(ctx, e.value);
                e.value = ActiveEngine.undefinedValue();
                e.active = false;
                return;
            }
        }
    }

    pub fn has(self: *const NamedListenerRegistry, name: []const u8) bool {
        for (&self.entries) |*e| {
            if (e.active and e.name_len == name.len and std.mem.eql(u8, e.name[0..e.name_len], name)) {
                return true;
            }
        }
        return false;
    }

    /// Advanced API: invokes a stored callback and returns a retained result. Returns null when the listener does not exist or throws.
    pub fn callRetained(
        self: *const NamedListenerRegistry,
        ctx: ActiveEngine.Context,
        name: []const u8,
        args: []const ActiveEngine.Value,
    ) ?ActiveEngine.Value {
        var execution = @import("js_scheduler.zig").beginContextExecution(ctx);
        if (!execution.admitted) return null;
        defer execution.end();
        for (&self.entries) |*e| {
            if (e.active and e.name_len == name.len and std.mem.eql(u8, e.name[0..e.name_len], name)) {
                var this_val: ActiveEngine.Value = undefined;
                var free_this = false;
                if (self.owner_set) {
                    this_val = self.owner;
                } else {
                    this_val = ActiveEngine.getGlobalObject(ctx);
                    free_this = true;
                }
                defer if (free_this) ActiveEngine.freeValue(ctx, this_val);

                const result = ActiveEngine.callFunction(ctx, e.value, this_val, args);
                if (execution.isClosing()) {
                    if (result) |value| ActiveEngine.freeValue(ctx, value);
                    return null;
                }
                return result;
            }
        }
        return null;
    }

    /// Common event path: invoke and discard the return value.
    pub fn emit(self: *const NamedListenerRegistry, ctx: ActiveEngine.Context, name: []const u8, args: []const ActiveEngine.Value) bool {
        var execution = @import("js_scheduler.zig").beginContextExecution(ctx);
        if (!execution.admitted) return false;
        defer execution.end();
        const result = self.callRetained(ctx, name, args) orelse return false;
        ActiveEngine.freeValue(ctx, result);
        execution.checkpoint();
        return !execution.isClosing();
    }

    pub fn freeAll(self: *NamedListenerRegistry, ctx: ActiveEngine.Context) void {
        if (self.owner_set) {
            ActiveEngine.freeValue(ctx, self.owner);
            self.owner = ActiveEngine.undefinedValue();
            self.owner_set = false;
        }
        for (&self.entries) |*e| {
            if (e.active) {
                ActiveEngine.freeValue(ctx, e.value);
                e.value = ActiveEngine.undefinedValue();
                e.active = false;
            }
        }
    }

    /// QuickJS-only GC mark hook for registries embedded in native opaque data.
    pub fn markAll(self: *const NamedListenerRegistry, rt: anytype, mark_func: anytype) void {
        switch (backend.active_backend) {
            .quickjs, .quickjs_ng => {
                const qjs = backend.ActiveEngineModule.qjs;
                if (self.owner_set) {
                    qjs.JS_MarkValue(rt, self.owner, @constCast(mark_func));
                }
                for (&self.entries) |*e| {
                    if (e.active) {
                        qjs.JS_MarkValue(rt, e.value, @constCast(mark_func));
                    }
                }
            },
            .jsc => {},
        }
    }
};
