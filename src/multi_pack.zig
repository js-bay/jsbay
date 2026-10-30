//! Multi-engine pack: create-time backend select helpers.
//!
//! Shared layers stay monomorphic on `build_options.backend` (pack primary / first entry). This module owns packed-engine bare create/destroy. Dual-engine packs are verified on Apple with `-Dbackends=quickjs_ng,jsc`. Linux single-pack builds still cover create-time select through primary `createWithBackend` and forced primary-tag packed_alt tests.

const std = @import("std");
const build_options = @import("build_options");
const backend_mod = @import("backend.zig");

pub const Backend = backend_mod.BackendType;
const Engine = backend_mod.Engine;

const PackedBit = struct {
    const quickjs_ng: u32 = 1 << 0;
    const quickjs: u32 = 1 << 1;
    const jsc: u32 = 1 << 2;
};

pub fn isPacked(tag: Backend) bool {
    const bits = build_options.packed_backend_bits;
    return switch (tag) {
        .quickjs_ng => (bits & PackedBit.quickjs_ng) != 0,
        .quickjs => (bits & PackedBit.quickjs) != 0,
        .jsc => (bits & PackedBit.jsc) != 0,
    };
}

pub fn packedCount() usize {
    var n: usize = 0;
    if (isPacked(.quickjs_ng)) n += 1;
    if (isPacked(.quickjs)) n += 1;
    if (isPacked(.jsc)) n += 1;
    return n;
}

/// Fill `out` with packed backend tags; returns count written.
pub fn availableBackends(out: []Backend) usize {
    var n: usize = 0;
    const order = [_]Backend{ .quickjs_ng, .quickjs, .jsc };
    for (order) |tag| {
        if (!isPacked(tag)) continue;
        if (n >= out.len) break;
        out[n] = tag;
        n += 1;
    }
    return n;
}

/// Bare instance from create-time select (not a full EngineInstance).
pub const BareInstance = struct {
    tag: Backend,
    runtime_addr: usize,
    ctx_addr: usize,
};

fn erasePtr(p: anytype) usize {
    const T = @TypeOf(p);
    switch (@typeInfo(T)) {
        .optional => {
            const v = p orelse unreachable;
            return erasePtr(v);
        },
        .pointer => return @intFromPtr(p),
        else => @compileError("erasePtr expects a pointer or optional pointer"),
    }
}

fn restorePtr(comptime P: type, addr: usize) P {
    switch (@typeInfo(P)) {
        .optional => |o| {
            const child: o.child = restorePtr(o.child, addr);
            return child;
        },
        .pointer => return @ptrFromInt(addr),
        else => @compileError("restorePtr expects a pointer or optional pointer"),
    }
}

fn createReal(comptime tag: Backend) ?BareInstance {
    if (comptime !isPacked(tag)) return null;
    const E = Engine(tag);
    const rt = E.newRuntime() orelse return null;
    const ctx = E.newContext(rt) orelse {
        E.freeRuntime(rt);
        return null;
    };
    return .{
        .tag = tag,
        .runtime_addr = erasePtr(rt),
        .ctx_addr = erasePtr(ctx),
    };
}

fn destroyReal(comptime tag: Backend, inst: BareInstance) void {
    if (comptime !isPacked(tag)) return;
    const E = Engine(tag);
    const ctx = restorePtr(E.Context, inst.ctx_addr);
    const rt = restorePtr(E.Runtime, inst.runtime_addr);
    E.freeContext(ctx);
    E.freeRuntime(rt);
}

/// Create a bare engine instance for a packed backend (create-time select).
pub fn createWithBackend(tag: Backend) ?BareInstance {
    if (!isPacked(tag)) return null;
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == tag) {
            if (comptime isPacked(cand)) return createReal(cand);
            return null;
        }
    }
    return null;
}

pub fn destroyBare(inst: BareInstance) void {
    inline for (.{ .quickjs_ng, .quickjs, .jsc }) |cand| {
        if (cand == inst.tag) {
            if (comptime isPacked(cand)) destroyReal(cand, inst);
            return;
        }
    }
}

test "multi_pack: availableBackends matches packed bits" {
    var buf: [4]Backend = undefined;
    const n = availableBackends(&buf);
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(packedCount(), n);
    for (buf[0..n]) |tag| {
        try std.testing.expect(isPacked(tag));
    }
}

test "multi_pack: createWithBackend primary packed engine" {
    const tag = build_options.backend;
    try std.testing.expect(isPacked(tag));
    const inst = createWithBackend(tag) orelse return error.CreateFailed;
    defer destroyBare(inst);
    try std.testing.expectEqual(tag, inst.tag);
}

fn freeEvalResult(res: @import("types.zig").EvalResult) void {
    if (res.result) |s| std.heap.c_allocator.free(@constCast(s));
    if (res.err_is_heap) {
        if (res.err) |e| std.heap.c_allocator.free(@constCast(e));
    }
}

fn evalOnePlusOne(comptime tag: Backend, inst: BareInstance) !void {
    const E = Engine(tag);
    const ctx = restorePtr(E.Context, inst.ctx_addr);
    const res = E.eval(ctx, "1+1", "<multi_pack>");
    defer freeEvalResult(res);
    if (res.err) |e| {
        std.debug.print("multi_pack eval failed on {s}: {s}\n", .{ @tagName(tag), e });
        return error.EvalFailed;
    }
    try std.testing.expect(res.result != null);
    try std.testing.expectEqualStrings("2", res.result.?);
}

test "multi_pack: dual create real quickjs_ng and jsc when both packed" {
    // Comptime-guard the JSC path so Linux single-pack builds do not link JavaScriptCore.
    if (comptime !(isPacked(.quickjs_ng) and isPacked(.jsc))) return error.SkipZigTest;
    if (comptime isPacked(.quickjs_ng) and isPacked(.jsc)) {
        const a = createWithBackend(.quickjs_ng) orelse return error.CreateNgFailed;
        defer destroyBare(a);
        const b = createWithBackend(.jsc) orelse return error.CreateJscFailed;
        defer destroyBare(b);
        try std.testing.expectEqual(Backend.quickjs_ng, a.tag);
        try std.testing.expectEqual(Backend.jsc, b.tag);
        try std.testing.expect(a.runtime_addr != b.runtime_addr);
        try std.testing.expect(a.ctx_addr != b.ctx_addr);
        // Prove both engines are usable in-process, not merely constructible.
        try evalOnePlusOne(.quickjs_ng, a);
        try evalOnePlusOne(.jsc, b);
    }
}
