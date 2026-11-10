const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const transport_dep = b.dependency("inspector_transport", .{
        .target = target,
        .optimize = optimize,
    });
    const zev_dep = b.dependency("zev", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "jsbay-inspector-bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("inspector_transport", transport_dep.module("inspector_transport"));
    exe.root_module.addImport("zev", zev_dep.module("zev"));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the JSC inspector bridge").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run JSC inspector bridge tests").dependOn(&run_tests.step);
}
