const zev = @import("zev");

pub const FrameDeadline = struct {
    stall_timeout_ms: i64,
    max_deadline: i64,

    pub fn init(stall_ms: i64, max_ms: i64) FrameDeadline {
        const now = @as(i64, @intCast(zev.monotonicMilliseconds()));
        return .{
            .stall_timeout_ms = stall_ms,
            .max_deadline = now + max_ms,
        };
    }

    pub fn checkExpired(self: FrameDeadline) !void {
        const now = @as(i64, @intCast(zev.monotonicMilliseconds()));
        if (now >= self.max_deadline) return error.TimedOut;
    }

    pub fn stallDeadline(self: FrameDeadline, now: i64) i64 {
        return @min(now + self.stall_timeout_ms, self.max_deadline);
    }
};
