const std = @import("std");
const io = @import("../platform/io.zig");
const inspector = @import("../inspector/root.zig");
const inspector_state = @import("../inspector/root.zig").state;

pub fn run(destroy_fn: *const fn (i32) void, instance_id: i32, expected_console_entries: usize) !void {
    const Destroy = struct {
        instance_id: i32,
        destroy_fn: *const fn (i32) void,
        done: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.destroy_fn(self.instance_id);
            self.done.store(true, .seq_cst);
        }
    };
    var destroy = Destroy{ .instance_id = instance_id, .destroy_fn = destroy_fn };
    const destroy_thread = try std.Thread.spawn(.{}, Destroy.run, .{&destroy});
    const deadline = io.monotonicMilliseconds() + 5_000;
    while (io.monotonicMilliseconds() < deadline and !destroy.done.load(.seq_cst)) {
        io.sleepMs(1);
    }
    if (!destroy.done.load(.seq_cst)) {
        std.debug.print("engine destroy did not finish Inspector teardown\n", .{});
        std.process.exit(1);
    }
    destroy_thread.join();
    try std.testing.expectEqual(expected_console_entries, inspector.liveConsoleEntries());
    try std.testing.expectEqual(@as(usize, 0), inspector_state.retiredStateCount(instance_id));
}
