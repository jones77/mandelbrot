const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const raylib_dep = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = optimize,
    });

    exe_mod.addImport("raylib", raylib_dep.module("raylib"));

    // ---- Build options ----
    const default_opts = b.addOptions();
    default_opts.addOption(bool, "use_gpa", false);
    exe_mod.addImport("buildopts", default_opts.createModule());

    // ---- Executable ----
    const exe = b.addExecutable(.{
        .name = "mandelbrot",
        .root_module = exe_mod,
    });
    exe_mod.linkLibrary(raylib_dep.artifact("raylib"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the Mandelbrot visualizer");
    run_step.dependOn(&run_cmd.step);

    // ---- Full test suite ----
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("raylib", raylib_dep.module("raylib"));
    test_mod.addImport("buildopts", default_opts.createModule());

    test_mod.linkLibrary(raylib_dep.artifact("raylib"));
    const test_exe = b.addTest(.{ .root_module = test_mod });

    const run_test = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run all tests (full suite)");
    test_step.dependOn(&run_test.step);

    // ---- Pure-math tests (runs zig test directly, bypasses listen protocol) ----
    const math_test = b.addSystemCommand(&[_][]const u8{
        b.graph.zig_exe,
        "test",
        b.path("src/mandelbrot.zig").getPath(b),
    });
    const math_step = b.step("unit", "Run pure-math tests (prints output)");
    math_step.dependOn(&math_test.step);

    // ---- Sanitised builds (DebugAllocator: catches use-after-free, double-free) ----
    //
    // The Zig-side DebugAllocator (safety + never_unmap) catches most memory bugs
    // in the application code.  C-level ASan (for raylib) is not available on
    // macOS because Zig 0.16 can't link the Clang ASan dylib.
    {
        const san_mod = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug,
        });

        const san_opts = b.addOptions();
        san_opts.addOption(bool, "use_gpa", true);
        san_mod.addImport("buildopts", san_opts.createModule());

        const raylib_dep_san = b.dependency("raylib_zig", .{
            .target = target,
            .optimize = .Debug,
        });
        san_mod.addImport("raylib", raylib_dep_san.module("raylib"));
        san_mod.linkLibrary(raylib_dep_san.artifact("raylib"));

        const san_exe = b.addExecutable(.{
            .name = "mandelbrot",
            .root_module = san_mod,
        });

        const san_install = b.addInstallArtifact(san_exe, .{});
        const san_build_step = b.step("build-san", "Build with DebugAllocator (catches use-after-free, double-free)");
        san_build_step.dependOn(&san_install.step);

        const san_run = b.addRunArtifact(san_exe);
        san_run.step.dependOn(&san_install.step);
        if (b.args) |args| san_run.addArgs(args);
        const san_run_step = b.step("run-san", "Run with DebugAllocator");
        san_run_step.dependOn(&san_run.step);

        const san_test_mod = b.createModule(.{
            .root_source_file = b.path("src/test_runner.zig"),
            .target = target,
            .optimize = .Debug,
        });
        san_test_mod.addImport("raylib", raylib_dep_san.module("raylib"));
        san_test_mod.addImport("buildopts", san_opts.createModule());

        san_test_mod.linkLibrary(raylib_dep_san.artifact("raylib"));
        const san_test = b.addTest(.{ .root_module = san_test_mod });

        const run_san_test = b.addRunArtifact(san_test);
        const san_test_step = b.step("test-san", "Run tests with DebugAllocator");
        san_test_step.dependOn(&run_san_test.step);
    }

    // ---- Release build (always ReleaseSafe, for macOS distribution) ----
    const release_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const release_opts = b.addOptions();
    release_opts.addOption(bool, "use_gpa", false);
    release_mod.addImport("buildopts", release_opts.createModule());
    const raylib_dep_rel = b.dependency("raylib_zig", .{
        .target = target,
        .optimize = .ReleaseSafe,
    });
    release_mod.addImport("raylib", raylib_dep_rel.module("raylib"));
    const release_exe = b.addExecutable(.{
        .name = "mandelbrot",
        .root_module = release_mod,
    });
    release_mod.linkLibrary(raylib_dep_rel.artifact("raylib"));
    const release_install = b.addInstallArtifact(release_exe, .{});
    const release_step = b.step("release", "Build optimized release binary (macOS)");
    release_step.dependOn(&release_install.step);
}
