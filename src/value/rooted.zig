//! Refcounted GC root — `Rooted` handle with single-protect on 0→1 edge and single-unprotect on return to 0.
const std = @import("std");
const backend = @import("../backend.zig");
const instance_map = @import("../runtime/instance_map.zig");
const ref_op = @import("reference_op.zig");

const ActiveEngine = backend.ActiveEngine;
pub const Local = ActiveEngine.Value;

fn rootBackendProtect(ctx: ActiveEngine.Context, cell: *RootCell) ?Local {
    return switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsRootProtect(ctx, cell.val),
        .jsc => @import("../backend/jsc/weak.zig").jsbay_qjsRootProtect(ctx, cell.val),
        .escargot => ActiveEngine.dupValue(ctx, cell.val),
        .hermes => blk: {
            const c = @import("../backend/hermes/c_api.zig");
            const id = cell.identity orelse break :blk null;
            const v = c.hermes_root_protect(ctx, @ptrCast(id));
            break :blk if (v == null) null else v;
        },
    };
}

fn rootBackendUnprotect(ctx: ActiveEngine.Context, v: Local) void {
    switch (backend.active_backend) {
        .quickjs, .quickjs_ng => @import("../backend.zig").ActiveEngineModule.weak.jsbay_qjsRootUnprotect(ctx, v),
        .jsc => @import("../backend/jsc/weak.zig").jsbay_qjsRootUnprotect(ctx, v),
        .escargot, .hermes => ActiveEngine.freeValue(ctx, v),
    }
}

fn rootBackendIdentityCreate(ctx: ActiveEngine.Context, v: Local) ?*anyopaque {
    return switch (backend.active_backend) {
        .hermes => blk: {
            const c = @import("../backend/hermes/c_api.zig");
            break :blk @ptrCast(c.hermes_root_identity_create(ctx, v));
        },
        else => null,
    };
}

fn rootBackendIdentityFree(ctx: ActiveEngine.Context, identity: ?*anyopaque) void {
    const id = identity orelse return;
    if (comptime backend.active_backend == .hermes) {
        const c = @import("../backend/hermes/c_api.zig");
        c.hermes_root_identity_free(ctx, @ptrCast(id));
    }
}

pub const RootCell = struct {
    entry: instance_map.RefEntry,
    instance_id: i32,
    generation: u64,
    ctx: ActiveEngine.Context,
    allocator: std.mem.Allocator,
    val: ActiveEngine.Value,
    identity: ?*anyopaque = null,
    root_count: u32 = 0,
    protected: bool = false,
    released: bool = false,

    fn releaseValue(entry: *instance_map.RefEntry) void {
        const cell: *RootCell = @fieldParentPtr("entry", entry);
        if (cell.released) return;
        if (cell.protected) {
            rootBackendUnprotect(cell.ctx, cell.val);
            cell.protected = false;
        }
        if (cell.identity) |id| {
            rootBackendIdentityFree(cell.ctx, id);
            cell.identity = null;
        }
        cell.root_count = 0;
        cell.released = true;
    }

    fn freeCell(entry: *instance_map.RefEntry) void {
        const cell: *RootCell = @fieldParentPtr("entry", entry);
        cell.allocator.destroy(cell);
    }
};

pub const Rooted = struct {
    instance_id: i32,
    cell: ?*RootCell = null,

    pub fn init(instance_id: i32, v: Local) Rooted {
        var op: ref_op.RefOperation = undefined;
        if (!ref_op.beginRefOperation(&op, instance_id, null)) return Rooted{ .instance_id = instance_id, .cell = null };
        defer op.end();
        const inst = op.lease.inst;
        const ctx = inst.monoCtx() orelse {
            return Rooted{ .instance_id = instance_id, .cell = null };
        };
        const cell = inst.allocator.create(RootCell) catch {
            return Rooted{ .instance_id = instance_id, .cell = null };
        };
        const identity = rootBackendIdentityCreate(ctx, v);
        if (comptime backend.active_backend == .hermes) {
            if (identity == null) {
                inst.allocator.destroy(cell);
                return Rooted{ .instance_id = instance_id, .cell = null };
            }
        }
        cell.* = .{
            .entry = .{ .reset_fn = RootCell.releaseValue, .free_fn = RootCell.freeCell },
            .instance_id = instance_id,
            .generation = op.lease.generation,
            .ctx = ctx,
            .allocator = inst.allocator,
            .val = v,
            .identity = identity,
        };
        ref_op.registerEntryDirect(inst, &cell.entry);
        return Rooted{ .instance_id = instance_id, .cell = cell };
    }

    pub fn isEmpty(self: Rooted) bool {
        const cell = self.cell orelse return true;
        var op: ref_op.RefOperation = undefined;
        if (!ref_op.beginRefOperation(&op, cell.instance_id, cell.generation)) return true;
        defer op.end();
        return cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked) or cell.root_count == 0;
    }

    pub fn root(self: *Rooted) void {
        const cell = self.cell orelse return;
        var op: ref_op.RefOperation = undefined;
        if (!ref_op.beginRefOperation(&op, cell.instance_id, cell.generation)) return;
        defer op.end();
        if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return;
        if (cell.released) return;
        if (cell.root_count == 0) {
            const protected_val = rootBackendProtect(cell.ctx, cell) orelse return;
            cell.val = protected_val;
            cell.protected = true;
        }
        cell.root_count += 1;
    }

    pub fn unroot(self: *Rooted) void {
        const cell = self.cell orelse return;
        var op: ref_op.RefOperation = undefined;
        if (!ref_op.beginRefOperation(&op, cell.instance_id, cell.generation)) return;
        defer op.end();
        if (cell.entry.state.load(.acquire) != @backingInt(instance_map.RefEntryState.linked)) return;
        if (cell.released or cell.root_count == 0) return;
        cell.root_count -= 1;
        if (cell.root_count == 0 and cell.protected) {
            rootBackendUnprotect(cell.ctx, cell.val);
            cell.protected = false;
            if (comptime backend.active_backend == .hermes) {
                cell.val = ActiveEngine.undefinedValue();
            }
        }
    }

    pub fn deinit(self: *Rooted) void {
        const cell = self.cell orelse return;
        var op: ref_op.RefOperation = undefined;
        if (!ref_op.beginRefOperation(&op, cell.instance_id, cell.generation)) {
            ref_op.abandonEntry(&cell.entry);
            self.cell = null;
            return;
        }
        defer op.end();
        if (cell.entry.state.cmpxchgStrong(@backingInt(instance_map.RefEntryState.linked), @backingInt(instance_map.RefEntryState.releasing), .acq_rel, .acquire) == null) {
            ref_op.unregisterEntry(op.lease.inst, &cell.entry);
            RootCell.releaseValue(&cell.entry);
            ref_op.finishRefRelease(&cell.entry);
        } else {
            ref_op.abandonEntry(&cell.entry);
        }
        self.cell = null;
    }
};

test "rootBackendIdentityFree takes the same Context as RootCell, not a nested one" {
    const testing = std.testing;
    const param_types = @typeInfo(@TypeOf(rootBackendIdentityFree)).@"fn".param_types;
    try testing.expectEqual(ActiveEngine.Context, param_types[0].?);
}
