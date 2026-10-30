//! Memory-limit headroom sweep.
//!
//! Reference cases: quickjs-ng api-test.c `backtrace_oom_callsite_array`, `backtrace_oom_current_exception`, and `large_allocation_accounting`.
//!
//! The runtime cap is tightened to `usage + k` for growing k. At every step each host API under test must return a status allowed by the C ABI matrix (OK, EXCEPTION or OUT_OF_MEMORY), leave failed outputs zeroed, leak no objects, and the same engine must still evaluate correctly once the cap is lifted. Whether a given step succeeds is deliberately not asserted: the cut-over point differs per backend.

const std = @import("std");
const testing = std.testing;

const backend = @import("../backend.zig");
const c_api = @import("../c_api.zig");
const helpers = @import("test_helpers.zig");
const rc = @import("../runtime/runtime_control.zig");

const api_ok: c_int = 0;
const api_exception: c_int = 1;
const api_out_of_memory: c_int = 6;

const Op = enum { to_json, to_utf8, error_stack, array_build };
const op_count = std.enums.values(Op).len;

const Tally = struct {
    ok: usize = 0,
    exception: usize = 0,
    out_of_memory: usize = 0,
};

const Fixture = struct {
    id: i32,
    big_object: u64 = 0,
    big_string: u64 = 0,
    expected_json: []u8 = &.{},
    expected_utf8: []u8 = &.{},
    tally: [op_count]Tally = @splat(.{}),

    fn deinit(self: *Fixture) void {
        _ = c_api.jsbay_value_release(self.big_object);
        _ = c_api.jsbay_value_release(self.big_string);
        testing.allocator.free(self.expected_json);
        testing.allocator.free(self.expected_utf8);
    }

    fn evaluate(self: *Fixture, source: []const u8, out_value: *u64, out_exception: *u64) c_int {
        // Poison the outputs: the API must clear them before doing any work.
        out_value.* = 0xdead;
        out_exception.* = 0xbeef;
        return c_api.jsbay_engine_evaluate(
            self.id,
            .{ .data = source.ptr, .len = source.len },
            .{ .data = "oom-sweep.js", .len = 12 },
            null,
            out_value,
            out_exception,
        );
    }

    /// Unlimited evaluation that must succeed; returns the owned result handle.
    fn evaluateOk(self: *Fixture, source: []const u8) !u64 {
        var value: u64 = 0;
        var exception: u64 = 0;
        try testing.expectEqual(api_ok, self.evaluate(source, &value, &exception));
        try testing.expect(value != 0);
        try testing.expectEqual(@as(u64, 0), exception);
        return value;
    }

    fn expectAnswer(self: *Fixture) !void {
        const value = try self.evaluateOk("6 * 7");
        defer _ = c_api.jsbay_value_release(value);
        var number: f64 = 0;
        try testing.expectEqual(api_ok, c_api.jsbay_value_to_number(value, &number));
        try testing.expectEqual(@as(f64, 42), number);
    }

    fn textOf(self: *Fixture, comptime to_text: anytype, value: u64) ![]u8 {
        _ = self;
        var bytes: c_api.Bytes = .{ .data = null, .len = 0 };
        var exception: u64 = 0;
        try testing.expectEqual(api_ok, to_text(value, &bytes, &exception));
        defer c_api.jsbay_free_bytes(bytes);
        try testing.expectEqual(@as(u64, 0), exception);
        const data = bytes.data orelse return error.NoBytes;
        return testing.allocator.dupe(u8, data[0..bytes.len]);
    }

    fn prepare(self: *Fixture) !void {
        // A wide object graph and a string with multi-byte code points, so serialization and UTF-8 conversion both need real scratch memory.
        self.big_object = try self.evaluateOk(
            \\({ name: 'sweep', blob: 'x'.repeat(40000),
            \\   rows: Array.from({ length: 1500 }, (_, i) => ({ i, label: 'row-' + i, nested: { even: i % 2 === 0 } })) })
        );
        self.big_string = try self.evaluateOk("'h\\u00e9llo-\\u4e16\\u754c-'.repeat(8000)");
        self.expected_json = try self.textOf(c_api.jsbay_value_to_json, self.big_object);
        self.expected_utf8 = try self.textOf(c_api.jsbay_value_to_utf8, self.big_string);
        try testing.expect(self.expected_json.len > 40000);
        try testing.expect(self.expected_utf8.len > 100000);
    }

    fn record(self: *Fixture, op: Op, status: c_int) void {
        const tally = &self.tally[@backingInt(op)];
        switch (status) {
            api_ok => tally.ok += 1,
            api_exception => tally.exception += 1,
            else => tally.out_of_memory += 1,
        }
    }

    /// Shared post-conditions for a call that returned a value/exception pair.
    fn expectPair(status: c_int, value: u64, exception: u64) !void {
        switch (status) {
            api_ok => {
                try testing.expect(value != 0);
                try testing.expectEqual(@as(u64, 0), exception);
            },
            api_exception => {
                try testing.expectEqual(@as(u64, 0), value);
                try testing.expect(exception != 0);
            },
            api_out_of_memory => {
                try testing.expectEqual(@as(u64, 0), value);
                try testing.expectEqual(@as(u64, 0), exception);
            },
            else => {
                std.debug.print("unexpected status {d} under memory limit\n", .{status});
                return error.UnexpectedStatus;
            },
        }
    }

    /// Text conversion under the cap. A success must be byte-identical to the unlimited result.
    fn convertText(self: *Fixture, op: Op, comptime to_text: anytype, value: u64, expected: []const u8) !void {
        // Poison the outputs: the API must clear them before doing any work.
        var bytes: c_api.Bytes = .{ .data = @ptrFromInt(0x10), .len = 77 };
        var exception: u64 = 0xbeef;
        const status = to_text(value, &bytes, &exception);
        defer if (exception != 0) {
            _ = c_api.jsbay_value_release(exception);
        };
        self.record(op, status);
        switch (status) {
            api_ok => {
                defer c_api.jsbay_free_bytes(bytes);
                try testing.expectEqual(@as(u64, 0), exception);
                const data = bytes.data orelse return error.NoBytes;
                try testing.expectEqualSlices(u8, expected, data[0..bytes.len]);
            },
            api_exception, api_out_of_memory => {
                try testing.expectEqual(@as(?[*]u8, null), bytes.data);
                try testing.expectEqual(@as(usize, 0), bytes.len);
                if (status == api_exception) try testing.expect(exception != 0) else try testing.expectEqual(@as(u64, 0), exception);
            },
            else => {
                std.debug.print("unexpected status {d} under memory limit\n", .{status});
                return error.UnexpectedStatus;
            },
        }
    }

    fn evalUnderLimit(self: *Fixture, op: Op, source: []const u8, expect_number: ?f64) !void {
        var value: u64 = 0;
        var exception: u64 = 0;
        const status = self.evaluate(source, &value, &exception);
        defer if (value != 0 and value != 0xdead) {
            _ = c_api.jsbay_value_release(value);
        };
        defer if (exception != 0 and exception != 0xbeef) {
            _ = c_api.jsbay_value_release(exception);
        };
        self.record(op, status);
        try expectPair(status, value, exception);
        if (status == api_ok) {
            if (expect_number) |want| {
                var number: f64 = 0;
                try testing.expectEqual(api_ok, c_api.jsbay_value_to_number(value, &number));
                try testing.expectEqual(want, number);
            }
        }
    }

    fn errorWithStack(self: *Fixture) !void {
        // Native constructor first: it only allocates an Error object.
        var made: u64 = 0xdead;
        const message = "constructed-under-limit";
        const made_status = c_api.jsbay_value_new_error(self.id, .{ .data = message, .len = message.len }, &made);
        self.record(.error_stack, made_status);
        switch (made_status) {
            api_ok => {
                defer _ = c_api.jsbay_value_release(made);
                try testing.expect(made != 0);
            },
            else => try testing.expectEqual(@as(u64, 0), made),
        }

        // Script-created Error captures a stack through several frames. Only the frame name is checked: whether the stack text also carries the message header differs per backend. The depth stays small because unoptimized QuickJS builds have a tight native stack budget.
        const source =
            \\(function build(n) {
            \\  function frame(depth) { return depth === 0 ? new Error('deep-error') : frame(depth - 1); }
            \\  const e = frame(n);
            \\  return e instanceof Error && typeof e.stack === 'string' && e.stack.length > 0 && e.stack.indexOf('frame') >= 0;
            \\})(6)
        ;
        var value: u64 = 0;
        var exception: u64 = 0;
        const status = self.evaluate(source, &value, &exception);
        defer if (value != 0 and value != 0xdead) {
            _ = c_api.jsbay_value_release(value);
        };
        defer if (exception != 0 and exception != 0xbeef) {
            _ = c_api.jsbay_value_release(exception);
        };
        self.record(.error_stack, status);
        try expectPair(status, value, exception);
        if (status == api_ok) {
            var flag = false;
            try testing.expectEqual(api_ok, c_api.jsbay_value_to_bool(value, &flag));
            try testing.expect(flag);
        }
    }

    /// Runs every operation once under the current cap.
    fn runAll(self: *Fixture) !void {
        try self.convertText(.to_json, c_api.jsbay_value_to_json, self.big_object, self.expected_json);
        try self.convertText(.to_utf8, c_api.jsbay_value_to_utf8, self.big_string, self.expected_utf8);
        try self.errorWithStack();
        try self.evalUnderLimit(
            .array_build,
            "(function () { const a = []; for (let i = 0; i < 20000; i++) a.push({ i, s: 'v' + i }); return a.length; })()",
            20000,
        );
    }
};

const Steps = struct {
    const values = blk: {
        // 0, then powers of two from 16 B up to 128 MiB.
        var list: [26]u64 = undefined;
        list[0] = 0;
        var i: usize = 1;
        var v: u64 = 16;
        while (i < list.len) : (i += 1) {
            list[i] = v;
            v *= 2;
        }
        break :blk list;
    };
    const len = values.len;
};

test "oom sweep: host APIs stay valid and the engine recovers at every memory headroom" {
    const id = helpers.nextInstanceId();
    try testing.expect(c_api.jsbay_engine_create(id, null, null));
    defer c_api.jsbay_engine_destroy(id);

    if (comptime backend.isJscApiBackend(backend.active_backend)) {
        // JSC has no heap cap; the rejection itself is the contract (see runtime_control_tests).
        try testing.expect(!rc.setMemoryLimit(id, 1));
        try testing.expect(!c_api.jsbay_engine_set_memory_limit(id, 1));
        return;
    }

    var fixture: Fixture = .{ .id = id };
    defer fixture.deinit();
    try fixture.prepare();

    // One unlimited pass first: lazily created intrinsics must not be mistaken for leaks, and the heap settles so each step's baseline is comparable.
    try fixture.runAll();
    fixture.tally = @splat(.{});
    _ = rc.runGc(id);
    const settled = rc.getMemoryUsage(id) orelse return error.NoUsage;

    for (Steps.values) |headroom| {
        _ = rc.runGc(id);
        const usage = rc.getMemoryUsage(id) orelse return error.NoUsage;
        try testing.expect(c_api.jsbay_engine_set_memory_limit(id, usage.malloc_size + headroom));
        const limited = rc.getMemoryUsage(id) orelse return error.NoUsage;
        try testing.expectEqual(usage.malloc_size + headroom, limited.malloc_limit);

        try fixture.runAll();

        try testing.expect(c_api.jsbay_engine_set_memory_limit(id, 0));
        const lifted = rc.getMemoryUsage(id) orelse return error.NoUsage;
        try testing.expectEqual(@as(u64, 0), lifted.malloc_limit);
        try fixture.expectAnswer();
    }

    // The widest step must complete every operation, and the tightest must hit the failure paths this sweep exists to cover.
    for (fixture.tally, 0..) |tally, index| {
        if (tally.ok == 0 or tally.exception + tally.out_of_memory == 0) {
            std.debug.print("op {d}: ok={d} exception={d} oom={d}\n", .{ index, tally.ok, tally.exception, tally.out_of_memory });
        }
        try testing.expect(tally.ok > 0);
        try testing.expect(tally.exception + tally.out_of_memory > 0);
    }

    // Failed attempts must not retain objects: after a full collection the live object count is back to the pre-sweep value. Allocator count may rise only with permanently interned atoms (upstream ng OOM quirk).
    _ = rc.runGc(id);
    const after = rc.getMemoryUsage(id) orelse return error.NoUsage;
    // Failed attempts must not retain JS objects.
    try testing.expectEqual(settled.obj_count, after.obj_count);
    // Allocator count: classic QuickJS returns to the pre-sweep baseline (atoms may still rise without a malloc_count change). quickjs-ng has been observed to keep one extra interned atom after OOM paths (malloc_count +1 with matching atom_count +1, obj_count unchanged). Allow only that explained upstream drift — see docs/upstream-known-issues.md; do not patch vendor/.
    if (after.malloc_count != settled.malloc_count) {
        const atom_delta = after.atom_count -| settled.atom_count;
        if (atom_delta == 0 or after.malloc_count != settled.malloc_count + atom_delta) {
            std.debug.print(
                "oom sweep malloc drift: settled malloc_count={d} atom={d}; after malloc_count={d} atom={d}\n",
                .{ settled.malloc_count, settled.atom_count, after.malloc_count, after.atom_count },
            );
            return error.MallocCountDrift;
        }
    }

    // Same engine, same inputs: the unlimited results match the pre-sweep ones.
    try fixture.convertText(.to_json, c_api.jsbay_value_to_json, fixture.big_object, fixture.expected_json);
    try fixture.convertText(.to_utf8, c_api.jsbay_value_to_utf8, fixture.big_string, fixture.expected_utf8);
}
