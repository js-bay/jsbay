//! Bounded real Scheduler.runTurn exploration with controllable source readiness.

const std = @import("std");
const state_tcas = @import("state_tcas");
const js_event_loop = @import("js_event_loop");

const Scheduler = js_event_loop.Scheduler;

test "state_tcas Scheduler.runTurn explores changing source readiness across turns" {
    const Source = Scheduler.TaskSource;
    const source_count = 4;
    const max_turns = 8;
    const TurnAct = union(enum) { refill: u2, run_turn };

    const Coverage = struct {
        ready_masks: u16 = 0,
        selected_sources: u8 = 0,
        source_pairs: u16 = 0,
        successful_turns: usize = 0,
        idle_turns: usize = 0,
    };

    const Snapshot = struct {
        next_source: Source,
        expected_source: Source,
        execution_depth: usize,
        checkpoint_active: bool,
        turn_active: bool,
        task_admission_permit: bool,
        ready: u4,
        refill_used: u4,
        turns: usize,
        last_source: ?usize,
        tasks_this_turn: u8,
        checkpoints_this_turn: u8,
    };

    const World = struct {
        sched: Scheduler = .{},
        expected_source: Source = .host_script,
        ready: u4 = 0b1111,
        refill_used: u4 = 0,
        turns: usize = 0,
        last_source: ?usize = null,
        tasks_this_turn: u8 = 0,
        checkpoints_this_turn: u8 = 0,
        coverage: *Coverage,
        stack: [32]Snapshot = undefined,
        sp: usize = 0,
        acts_buf: [5]TurnAct = undefined,

        fn index(source: Source) usize {
            return @backingInt(source);
        }

        fn capture(self: *const @This()) Snapshot {
            return .{
                .next_source = self.sched.next_task_source,
                .expected_source = self.expected_source,
                .execution_depth = self.sched.execution_depth,
                .checkpoint_active = self.sched.checkpoint_active,
                .turn_active = self.sched.turn_active,
                .task_admission_permit = self.sched.task_admission_permit,
                .ready = self.ready,
                .refill_used = self.refill_used,
                .turns = self.turns,
                .last_source = self.last_source,
                .tasks_this_turn = self.tasks_this_turn,
                .checkpoints_this_turn = self.checkpoints_this_turn,
            };
        }

        fn restore(self: *@This(), snapshot: Snapshot) void {
            self.sched.next_task_source = snapshot.next_source;
            self.expected_source = snapshot.expected_source;
            self.sched.execution_depth = snapshot.execution_depth;
            self.sched.checkpoint_active = snapshot.checkpoint_active;
            self.sched.turn_active = snapshot.turn_active;
            self.sched.task_admission_permit = snapshot.task_admission_permit;
            self.ready = snapshot.ready;
            self.refill_used = snapshot.refill_used;
            self.turns = snapshot.turns;
            self.last_source = snapshot.last_source;
            self.tasks_this_turn = snapshot.tasks_this_turn;
            self.checkpoints_this_turn = snapshot.checkpoints_this_turn;
            self.sp -= 1;
        }

        fn prepare(_: ?*anyopaque) void {}

        fn runOne(context: ?*anyopaque, source: Source) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const i = index(source);
            if ((self.ready & (@as(u4, 1) << @intCast(i))) == 0) return false;
            var task = self.sched.beginQueuedTask() orelse return false;
            self.ready &= ~(@as(u4, 1) << @intCast(i));
            self.tasks_this_turn += 1;
            if (self.last_source) |previous| {
                self.coverage.source_pairs |= @as(u16, 1) << @intCast(previous * source_count + i);
            }
            self.last_source = i;
            _ = task.end();
            return true;
        }

        fn firstReady(self: *const @This()) ?usize {
            const start = @backingInt(self.expected_source);
            for (0..source_count) |offset| {
                const i = (start + offset) % source_count;
                if (self.ready & (@as(u4, 1) << @intCast(i)) != 0) return i;
            }
            return null;
        }

        fn checkpoint(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.checkpoints_this_turn += 1;
        }

        pub fn key(self: *const @This()) u64 {
            const last_source = if (self.last_source) |source| source + 1 else 0;
            return @as(u64, @backingInt(self.sched.next_task_source)) |
                (@as(u64, @backingInt(self.expected_source)) << 2) |
                (@as(u64, self.ready) << 4) |
                (@as(u64, self.refill_used) << 8) |
                (@as(u64, self.turns) << 12) |
                (@as(u64, last_source) << 16);
        }

        pub fn enabled(self: *@This()) []const TurnAct {
            var len: usize = 0;
            for (0..source_count) |i| {
                const bit = @as(u4, 1) << @intCast(i);
                if (self.refill_used & bit == 0 and self.ready & bit == 0) {
                    self.acts_buf[len] = .{ .refill = @intCast(i) };
                    len += 1;
                }
            }
            if (self.turns < max_turns) {
                self.acts_buf[len] = .run_turn;
                len += 1;
            }
            return self.acts_buf[0..len];
        }

        pub fn step(self: *@This(), act: TurnAct) !void {
            self.stack[self.sp] = self.capture();
            self.sp += 1;
            switch (act) {
                .refill => |source| {
                    const bit = @as(u4, 1) << source;
                    self.refill_used |= bit;
                    self.ready |= bit;
                },
                .run_turn => {
                    const before_mask = self.ready;
                    const expected_source = self.firstReady();
                    self.coverage.ready_masks |= @as(u16, 1) << before_mask;
                    self.tasks_this_turn = 0;
                    self.checkpoints_this_turn = 0;
                    const ran = self.sched.runTurn(.{
                        .context = @ptrCast(self),
                        .prepare_native_events = prepare,
                        .run_one_task = runOne,
                        .checkpoint = checkpoint,
                    });
                    try std.testing.expectEqual(expected_source != null, ran);
                    if (ran) {
                        try std.testing.expectEqual(@as(u8, 1), self.tasks_this_turn);
                        try std.testing.expectEqual(@as(u8, 1), self.checkpoints_this_turn);
                        try std.testing.expectEqual(expected_source.?, self.last_source.?);
                        try std.testing.expect(self.sched.allowsQueuedWork());
                        self.expected_source = @fromBackingInt(@intCast((self.last_source.? + 1) % source_count));
                        try std.testing.expectEqual(self.expected_source, self.sched.next_task_source);
                        self.coverage.successful_turns += 1;
                        self.coverage.selected_sources |= @as(u8, 1) << @intCast(self.last_source.?);
                    } else {
                        try std.testing.expectEqual(@as(u8, 0), self.tasks_this_turn);
                        try std.testing.expectEqual(@as(u8, 0), self.checkpoints_this_turn);
                        self.coverage.idle_turns += 1;
                    }
                    self.turns += 1;
                },
            }
        }

        pub fn undo(self: *@This(), _: TurnAct) void {
            self.restore(self.stack[self.sp - 1]);
        }
    };

    var coverage = Coverage{};
    var world = World{ .coverage = &coverage };

    var collided_expected_and_ready = world;
    collided_expected_and_ready.expected_source = .tsfn;
    collided_expected_and_ready.ready = 0;
    var collided_expected_and_ready_other = world;
    collided_expected_and_ready_other.ready = 1;
    try std.testing.expectEqual(collided_expected_and_ready.sched.next_task_source, collided_expected_and_ready_other.sched.next_task_source);
    try std.testing.expectEqual(collided_expected_and_ready.refill_used, collided_expected_and_ready_other.refill_used);
    try std.testing.expectEqual(collided_expected_and_ready.turns, collided_expected_and_ready_other.turns);
    try std.testing.expect(collided_expected_and_ready.key() != collided_expected_and_ready_other.key());

    var different_previous_source = world;
    different_previous_source.last_source = 1;
    try std.testing.expect(different_previous_source.key() != world.key());

    var stats: state_tcas.explore.Stats = .{};
    var visited = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer visited.deinit();
    try state_tcas.explore.dfsKeyed(TurnAct, u64, &world, 100_000, &stats, &visited);

    try std.testing.expect(stats.visits > 100);
    try std.testing.expect(stats.expansions > 100);
    try std.testing.expect(coverage.successful_turns > 0);
    try std.testing.expect(coverage.selected_sources == 0b1111);
    try std.testing.expect(coverage.ready_masks & (@as(u16, 1) << 0) != 0);
    try std.testing.expect(coverage.idle_turns > 0);
    try std.testing.expect(coverage.source_pairs & (@as(u16, 1) << 1) != 0);
    try std.testing.expect(coverage.source_pairs & (@as(u16, 1) << 6) != 0);
    try std.testing.expect(coverage.source_pairs & (@as(u16, 1) << 11) != 0);
    try std.testing.expect(coverage.source_pairs & (@as(u16, 1) << 12) != 0);
    try std.testing.expect(world.sched.next_task_source == .host_script);
    try std.testing.expectEqual(@as(u4, 0b1111), world.ready);
}
