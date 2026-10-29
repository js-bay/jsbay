const std = @import("std");
const jsbay_build = @import("jsbay");

const Backend = enum { quickjs_ng, quickjs, jsc };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "JS Bay backend") orelse .quickjs_ng;
    const inspector_transport = b.option(bool, "inspector-transport", "Include the HTTP/WebSocket inspector transport") orelse true;
    const sysroot = b.option([]const u8, "apple-sysroot", "Apple SDK path for cross compilation");
    const jsbay = if (sysroot) |sdk| b.dependency("jsbay", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .@"inspector-transport" = inspector_transport,
        .@"apple-sysroot" = sdk,
        .@"apple-package" = true,
    }) else b.dependency("jsbay", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .@"inspector-transport" = inspector_transport,
    });

    const exe = b.addExecutable(.{
        .name = "zig-consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    jsbay_build.linkConsumer(exe, jsbay);

    const probe = b.addLibrary(.{
        .name = "zig-consumer-compile-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/compile_probe.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    jsbay_build.linkConsumer(probe, jsbay);
    const check = b.step("check", "Compile the public module consumer without running it");
    check.dependOn(&exe.step);
    check.dependOn(&probe.step);

    const run = b.addRunArtifact(exe);
    const step = b.step("run", "Run the public JS Bay module consumer");
    step.dependOn(&probe.step);
    step.dependOn(&run.step);
}
