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
    const test_exe = b.addTest(.{ .root_module = exe_mod });
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
}
