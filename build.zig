const std = @import("std");
const builtin = @import("builtin");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const vcpkg_root = try setupVcpkg(b);
    installLibuv(b, vcpkg_root);

    const exe = b.addExecutable(.{
        .name = "azig",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.linkSystemLibrary("uv");
    exe.linkLibC();

    exe.addLibraryPath(b.path("vcpkg/installed/x64-windows/lib"));
    exe.addIncludePath(b.path("vcpkg/installed/x64-windows/include"));

    if (target.result.os.tag == .windows) {
        exe.linkSystemLibrary("ws2_32");
        exe.linkSystemLibrary("userenv");
    }

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.addPathDir("vcpkg/installed/x64-windows/bin");

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
}

fn setupVcpkg(b: *std.Build) ![]const u8 {
    const vcpkg_dir = "vcpkg";
    var clone_step: *std.Build.Step = undefined;

    if (!try fileExists(vcpkg_dir)) {
        const clone_cmd = b.addSystemCommand(&.{ "git", "clone", "https://github.com/microsoft/vcpkg.git" });
        clone_step = b.step("Clone vcpkg", "Clone vcpkg");
        clone_step.dependOn(&clone_cmd.step);
    } else if (try fileExists(b.pathJoin(&.{ vcpkg_dir, ".git" }))) {
        const clone_cmd = b.addSystemCommand(&.{ "git", "pull" });
        clone_step = b.step("Pull vcpkg", "Pull vcpkg");
        clone_step.dependOn(&clone_cmd.step);
    } else {
        try std.fs.cwd().deleteDirZ(vcpkg_dir);
        const clone_cmd = b.addSystemCommand(&.{ "git", "clone", "https://github.com/microsoft/vcpkg.git" });
        clone_step = b.step("Clone vcpkg", "Clone vcpkg");
        clone_step.dependOn(&clone_cmd.step);
    }

    if (!try fileExists(b.pathJoin(&.{ vcpkg_dir, "vcpkg.exe" }))) {
        const bootstrap_cmd = b.addSystemCommand(&.{if (builtin.os.tag == .windows) "bootstrap-vcpkg.bat" else "./bootstrap-vcpkg.sh"});
        bootstrap_cmd.setCwd(b.path(vcpkg_dir));
        bootstrap_cmd.step.dependOn(clone_step);
        var bootstrap_step = b.step("Bootstrap vcpkg", "Bootstrap vcpkg");
        bootstrap_step.dependOn(&bootstrap_cmd.step);

        b.getInstallStep().dependOn(bootstrap_step);
    }

    return vcpkg_dir;
}

fn installLibuv(b: *std.Build, vcpkg_root: []const u8) void {
    const triplet = switch (builtin.os.tag) {
        .windows => "x64-windows",
        .linux => "x64-linux",
        .macos => "x64-osx",
        else => @panic("Unsupported OS"),
    };

    const install_libuv_cmd = b.addSystemCommand(&.{
        "vcpkg",
        "install",
        "libuv",
        "--triplet",
        triplet,
    });
    install_libuv_cmd.setCwd(b.path(vcpkg_root));
    var install_libuv_step = b.step("Install libuv", "Install libuv");
    install_libuv_step.dependOn(&install_libuv_cmd.step);

    b.getInstallStep().dependOn(install_libuv_step);
}

fn fileExists(path: []const u8) !bool {
    var found = true;
    std.fs.cwd().access(path, .{}) catch |e| switch (e) {
        error.FileNotFound => found = false,
        else => return e,
    };
    return found;
}
