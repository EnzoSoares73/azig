const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{ .name = "azig", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    const libuv_dep = b.dependency("libuv", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.linkLibrary(libuv_dep.artifact("uv"));

    {
        const module = b.addModule("azig", .{
            .root_source_file = b.path("src/azig.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.linkLibrary(libuv_dep.artifact("uv"));
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.linkLibrary(libuv_dep.artifact("uv"));

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
