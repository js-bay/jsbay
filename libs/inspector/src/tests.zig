const std = @import("std");
const inspector = @import("inspector");

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
};

test "console buffer releases every partial allocation failure" {
    try inspector.modules.state(StateTestHost).TestCases.consoleBufferReleasesEveryPartialAllocationFailure();
}

test "destroy waits while inspector transport startup owns the registered state" {
    try inspector.modules.state(StateTestHost).TestCases.destroyWaitsWhileTransportStartupOwnsRegisteredState();
}

test "destroy waits for an inspector start reservation before registration" {
    try inspector.modules.state(StateTestHost).TestCases.destroyWaitsForStartReservationBeforeRegistration();
}

test "inspector start admission stays closed during engine runtime teardown" {
    try inspector.modules.state(StateTestHost).TestCases.startAdmissionStaysClosedDuringEngineRuntimeTeardown();
}
