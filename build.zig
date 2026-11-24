const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    const libuv_dep = b.dependency("libuv", .{
        .target = target,
        .optimize = optimize,
    });
    const libuv = libuv_dep.artifact("uv");

    // Generate the libuv bindings for the target being built: libuv's structs differ
    // between Windows and Unix, so a single pre-translated file can't serve every platform.
    const uv_translate = b.addTranslateC(.{
        .root_source_file = libuv.getEmittedIncludeTree().path(b, "uv.h"),
        .target = target,
        .optimize = optimize,
    });
    uv_translate.addIncludePath(libuv.getEmittedIncludeTree());
    const uv_module = uv_translate.createModule();

    const exe = b.addExecutable(.{ .name = "azig", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "uv", .module = uv_module }},
    }) });
    exe.root_module.linkLibrary(libuv);

    {
        const module = b.addModule("azig", .{
            .root_source_file = b.path("src/azig.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "uv", .module = uv_module }},
        });
        module.linkLibrary(libuv);
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
            .imports = &.{.{ .name = "uv", .module = uv_module }},
        }),
    });
    unit_tests.root_module.linkLibrary(libuv);

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
