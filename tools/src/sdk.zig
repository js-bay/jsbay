const std = @import("std");

/// The build graph supplies the exact executable under test, independently of the install prefix or an older binary left in the checkout.
pub fn toolPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, @import("tool_options").executable });
}

/// Runs a host command for a black-box SDK or repository-tool contract. The caller owns the captured buffers and must release them with `deinit`.
pub const Output = struct {
    result: std.process.RunResult,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Output) void {
        self.allocator.free(self.result.stdout);
        self.allocator.free(self.result.stderr);
    }

    pub fn succeeded(self: Output) bool {
        return self.result.term.success();
    }
};

pub fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !Output {
    return .{
        .result = try std.process.run(allocator, io, .{
            .argv = argv,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            .stdout_limit = .limited(16 * 1024 * 1024),
            .stderr_limit = .limited(16 * 1024 * 1024),
        }),
        .allocator = allocator,
    };
}
