const std = @import("std");
const inspector = @import("inspector");
const InspectorTestApi = struct {
    pub const Transport = inspector.Transport;
    pub const SessionId = inspector.SessionId;
    pub const EventHandler = inspector.EventHandler;

    pub fn state(comptime Host: type) type {
        return inspector.modules.state(Host);
    }
};

comptime {
    _ = @import("protocol_tests.zig");
}

const Probe = struct {
    started: bool = false,
    destroyed: bool = false,
    sent: []const u8 = "",
    const vtable: inspector.Transport.VTable = .{
        .start = start,
        .deinit = deinit,
        .send_text = sendText,
        .broadcast_text = broadcastText,
        .close_session = closeSession,
    };
    fn start(ctx: *anyopaque, _: ?*anyopaque, _: inspector.EventHandler) !void {
        @as(*Probe, @ptrCast(@alignCast(ctx))).started = true;
    }
    fn deinit(ctx: *anyopaque) void {
        @as(*Probe, @ptrCast(@alignCast(ctx))).destroyed = true;
    }
    fn sendText(ctx: *anyopaque, _: inspector.SessionId, text: []const u8) bool {
        @as(*Probe, @ptrCast(@alignCast(ctx))).sent = text;
        return true;
    }
    fn broadcastText(ctx: *anyopaque, text: []const u8) void {
        @as(*Probe, @ptrCast(@alignCast(ctx))).sent = text;
    }
    fn closeSession(_: *anyopaque, _: inspector.SessionId) void {}
};

test "transport forwards host callbacks" {
    var probe = Probe{};
    var transport = inspector.Transport{ .ctx = &probe, .vtable = &Probe.vtable };
    try transport.start(null, struct {
        fn f(_: ?*anyopaque, _: inspector.Event) void {}
    }.f);
    try std.testing.expect(probe.started);
    try std.testing.expect(transport.sendText(7, "reply"));
    try std.testing.expectEqualStrings("reply", probe.sent);
    transport.broadcastText("event");
    try std.testing.expectEqualStrings("event", probe.sent);
    transport.deinit();
    try std.testing.expect(probe.destroyed);
}

test "core factory rejects a disabled inspector before touching a host" {
    const DisabledHost = struct {
        pub const build_options = struct {
            pub const inspector = false;
        };
    };
    const Core = inspector.Inspector(DisabledHost);
    var probe = Probe{};
    var transport = inspector.Transport{ .ctx = &probe, .vtable = &Probe.vtable };
    try std.testing.expectError(error.UnsupportedFeature, Core.start(1, .{ .transport = &transport }));
    try std.testing.expect(probe.destroyed);
}

test "console group sequence stops before reusing its maximum value" {
    try inspector.modules.console(struct {}).TestCases.consoleGroupSequenceStopsBeforeReusingMaximumValue();
}

const ProfilerTestHook = struct {
    const Hook = *const fn (i32) void;
    var hook: std.atomic.Value(?Hook) = .init(null);

    pub fn load() ?Hook {
        return hook.load(.seq_cst);
    }

    pub fn store(value: ?Hook) void {
        hook.store(value, .seq_cst);
    }
};

const TestMutex = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *TestMutex) void {
        std.debug.assert(!self.locked.load(.monotonic));
    }

    pub fn lock(self: *TestMutex) void {
        while (self.locked.swap(true, .acquire)) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *TestMutex) void {
        std.debug.assert(self.locked.swap(false, .release));
    }
};

const TestCondition = struct {
    pub const init: TestCondition = .{};

    pub fn deinit(_: *TestCondition) void {}

    pub fn broadcast(_: *TestCondition) void {}
    pub fn signal(_: *TestCondition) void {}
    pub fn wait(_: *TestCondition, _: *TestMutex) void {
        @panic("StateTestHost does not model condition waits");
    }
};

const ProfilerTestHost = struct {
    pub const debugger = struct {
        pub const StackFrameBuf = struct {
            name: []u8,
            url: []u8,
            name_len: usize = 0,
            url_len: usize = 0,
            line: i32 = 0,
            column: i32 = 0,
            script_tag: u64 = 0,
        };

        pub fn writeDebugStack(_: i32, _: []StackFrameBuf) usize {
            return 0;
        }
    };
    pub const io = struct {
        pub fn monotonicMilliseconds() i64 {
            return 0;
        }
    };
    pub const sample_hook = ProfilerTestHook;
    pub const sync = struct {
        pub const Mutex = TestMutex;
    };
    pub const test_faults = struct {
        pub fn take(_: i32, _: anytype) bool {
            return false;
        }
    };
};

test "profiler stopInstance releases the instance slot and buffers" {
    try inspector.modules.profiler(ProfilerTestHost).TestCases.profilerStopInstanceReleasesSlotAndBuffers();
}

test "profiler clears its sample hook after the last active instance stops" {
    try inspector.modules.profiler(ProfilerTestHost).TestCases.profilerClearsSampleHookAfterLastActiveInstanceStops();
}

test "profiler start uses the configured sampling interval" {
    try inspector.modules.profiler(ProfilerTestHost).TestCases.profilerStartUsesConfiguredInterval();
}

const StateTestHost = struct {
    pub const instance_map = struct {
        pub fn generationOf(instance_id: i32) ?u64 {
            return if (instance_id == 61_771) 4 else null;
        }

        pub fn isTeardownPending(_: i32) bool {
            return false;
        }
    };
    pub const backend = struct {
        pub const ActiveEngine = struct {
            pub const Context = *anyopaque;
            pub const Value = usize;

            pub fn dupValue(_: Context, _: Value) Value {
                @panic("StateTestHost must not retain JS values");
            }

            pub fn freeValue(_: Context, _: Value) void {
                @panic("StateTestHost must not free JS values");
            }
        };
    };
    pub const sync = struct {
        pub const Mutex = TestMutex;
        pub const Condition = TestCondition;
    };
    pub const execution_cpu = struct {
        pub const Ledger = struct {
            refs: std.atomic.Value(usize) = .init(1),
            measurement_users: std.atomic.Value(usize) = .init(0),

            pub fn create() ?*Ledger {
                const ledger = std.heap.c_allocator.create(Ledger) catch return null;
                ledger.* = .{};
                return ledger;
            }

            pub fn retain(self: *Ledger) bool {
                _ = self.refs.fetchAdd(1, .acq_rel);
                return true;
            }

            pub fn release(self: *Ledger) void {
                if (self.refs.fetchSub(1, .acq_rel) == 1) std.heap.c_allocator.destroy(self);
            }

            pub fn enable(self: *Ledger) void {
                _ = self.measurement_users.fetchAdd(1, .acq_rel);
            }

            pub fn disable(self: *Ledger) void {
                _ = self.measurement_users.fetchSub(1, .acq_rel);
            }

            pub fn requestDisableAtBoundary(self: *Ledger) void {
                self.disable();
            }

            pub fn disableOnOwner(self: *Ledger) void {
                self.disable();
            }

            pub fn enableOnOwner(self: *Ledger) void {
                self.enable();
            }

            pub fn applyPendingDisablesOnOwner(_: *Ledger) void {}

            pub fn seconds(_: *const Ledger) ?f64 {
                return null;
            }
        };
    };
    pub const test_faults = struct {
        pub fn take(_: i32, _: anytype) bool {
            return false;
        }
    };
};

test "console buffer releases every partial allocation failure" {
    try inspector.modules.state(StateTestHost).TestCases.consoleBufferReleasesEveryPartialAllocationFailure();
}

test "Runtime enable replay queues concurrent events in order and stays bounded" {
    try @import("console_replay_tests.zig").run(StateTestHost, InspectorTestApi);
}

test "command queue bounds concurrent admission and session discard" {
    try @import("command_queue_tests.zig").run(StateTestHost, InspectorTestApi);
}

test "destroy waits while inspector transport startup owns the registered state" {
    try inspector.modules.state(StateTestHost).TestCases.destroyWaitsWhileTransportStartupOwnsRegisteredState();
}

test "destroy waits for an inspector start reservation before registration" {
    try inspector.modules.state(StateTestHost).TestCases.destroyWaitsForStartReservationBeforeRegistration();
}

test "inspector start admission stays closed during engine runtime teardown" {
    const State = inspector.modules.state(StateTestHost);
    const instance_id: i32 = 61_770;
    var destroy_lease: State.EngineDestroyLease = .{};
    try std.testing.expect(State.beginEngineDestroy(instance_id, 0, &destroy_lease));
    defer State.endEngineDestroy(&destroy_lease);
    try std.testing.expect(!State.reserveStart(instance_id));
    State.endEngineDestroy(&destroy_lease);
    try std.testing.expect(State.reserveStart(instance_id));
    State.cancelStartReservation(instance_id);
}

test "inspector start admission requires a live matching generation" {
    const State = inspector.modules.state(StateTestHost);
    try std.testing.expect(!State.reserveStartForGeneration(61_771, 3));
    try std.testing.expect(State.reserveStartForGeneration(61_771, 4));
    State.cancelStartReservation(61_771);
}

test "engine runtime destroy gate is generation scoped" {
    const State = inspector.modules.state(StateTestHost);
    const instance_id: i32 = 61_769;
    var generation_7: State.EngineDestroyLease = .{};
    var generation_8: State.EngineDestroyLease = .{};
    var duplicate_7: State.EngineDestroyLease = .{};
    try std.testing.expect(State.beginEngineDestroy(instance_id, 7, &generation_7));
    try std.testing.expect(State.beginEngineDestroy(instance_id, 8, &generation_8));
    try std.testing.expect(!State.beginEngineDestroy(instance_id, 7, &duplicate_7));
    State.endEngineDestroy(&generation_7);
    try std.testing.expect(!State.beginEngineDestroy(instance_id, 8, &duplicate_7));
    State.endEngineDestroy(&generation_8);
    try std.testing.expect(State.beginEngineDestroy(instance_id, 8, &duplicate_7));
    State.endEngineDestroy(&duplicate_7);
}

test "engine runtime destroy gate admits one concurrent owner without allocation" {
    const Race = struct {
        const GateState = inspector.modules.state(StateTestHost);
        ready: std.atomic.Value(u32) = .init(0),
        arrived: std.atomic.Value(u32) = .init(0),
        winners: std.atomic.Value(u32) = .init(0),
        duplicates: std.atomic.Value(u32) = .init(0),
        release: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var lease: GateState.EngineDestroyLease = .{};
            _ = self.ready.fetchAdd(1, .seq_cst);
            while (self.ready.load(.seq_cst) < 2) std.Thread.yield() catch {};
            const acquired = GateState.beginEngineDestroy(61_768, 9, &lease);
            if (acquired) {
                _ = self.winners.fetchAdd(1, .seq_cst);
            } else {
                _ = self.duplicates.fetchAdd(1, .seq_cst);
            }
            _ = self.arrived.fetchAdd(1, .seq_cst);
            while (!self.release.load(.seq_cst)) std.Thread.yield() catch {};
            if (acquired) GateState.endEngineDestroy(&lease);
        }
    };

    var race = Race{};
    const first = try std.Thread.spawn(.{}, Race.run, .{&race});
    const second = try std.Thread.spawn(.{}, Race.run, .{&race});
    while (race.arrived.load(.seq_cst) < 2) std.Thread.yield() catch {};
    race.release.store(true, .seq_cst);
    first.join();
    second.join();
    try std.testing.expectEqual(@as(u32, 1), race.winners.load(.seq_cst));
    try std.testing.expectEqual(@as(u32, 1), race.duplicates.load(.seq_cst));
}
