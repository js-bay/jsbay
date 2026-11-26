//! Thread-local scope and stack frame tracking for JavaScript values.
const std = @import("std");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");

const ActiveEngine = backend.ActiveEngine;
pub const Local = ActiveEngine.Value;

pub const OwnedValue = struct {
    ctx: ActiveEngine.Context,
    raw: Local,

    pub fn init(ctx: ActiveEngine.Context, v: Local) OwnedValue {
        return .{ .ctx = ctx, .raw = v };
    }

    pub fn borrow(self: *const OwnedValue) Local {
        return self.raw;
    }

    pub fn release(self: *OwnedValue) Local {
        const val = self.raw;
        self.raw = ActiveEngine.undefinedValue();
        return val;
    }

    pub fn deinit(self: *OwnedValue) void {
        ActiveEngine.freeValue(self.ctx, self.raw);
        self.raw = ActiveEngine.undefinedValue();
    }
};

pub const Scope = struct {
    instance_id: i32,
    prev: ?*Scope = null,

    pub fn enter(instance_id: i32) Scope {
        return Scope{
            .instance_id = instance_id,
            .prev = current_scope,
        };
    }

    pub fn exit(self: *Scope) void {
        std.debug.assert(current_scope == self);
        current_scope = self.prev;
        self.prev = null;
    }

    pub fn current() ?*Scope {
        return current_scope;
    }
};

pub fn activate(scope: *Scope) void {
    current_scope = scope;
}

threadlocal var current_scope: ?*Scope = null;

pub fn currentInstanceId() ?i32 {
    const s = current_scope orelse return null;
    return s.instance_id;
}

pub const StackFrameScope = struct {
    instance_id: i32,

    pub fn enter(instance_id: i32) StackFrameScope {
        return StackFrameScope{ .instance_id = instance_id };
    }

    pub fn exit(self: *StackFrameScope) void {
        _ = self;
    }

    pub fn returnValue(self: *StackFrameScope, v: Local) Local {
        const ptrs = instance_map.getPtrs(self.instance_id) orelse return v;
        return ActiveEngine.dupValue(ptrs.ctx, v);
    }
};
