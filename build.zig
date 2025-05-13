const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "azig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const libuv_dep = b.dependency("libuv", .{
        .target = target,
        .optimize = optimize,
    });
    exe.linkLibrary(libuv_dep.artifact("uv"));

    if (target.result.os.tag == .windows and optimize == .Debug) {
        exe.linkSystemLibrary("ucrtbased");
    }

    {
        const module = b.addModule("azig", .{
            .root_source_file = b.path("src/azig.zig"),
            .target = target,
            .optimize = optimize,
        });
        module.linkLibrary(libuv_dep.artifact("uv"));
        module.linkSystemLibrary("ucrtbased", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/azig.zig"),
        .target = target,
        .optimize = optimize,
    });
    run_step.dependOn(&run_cmd.step);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
