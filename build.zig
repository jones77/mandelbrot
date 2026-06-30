const std = @import("std");

/// Builds the Mandelbrot visualiser.
///
/// This script expects `raylib-zig` to be available as a Zig package
/// dependency (declared in build.zig.zon).  If you prefer to link
/// against a system-installed raylib, see the commented-out section.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mandelbrot",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- Option A: Use raylib-zig from the package manager ----
    const raylib_dep = b.dependency("raylib-zig", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("raylib", raylib_dep.module("raylib"));
    exe.linkLibrary(raylib_dep.artifact("raylib"));

    // ---- Option B: Link against a system-installed raylib ----
    // (Uncomment this block and comment out Option A if you have
    //  raylib installed via brew / apt / manual build.)
    //
    // exe.linkSystemLibrary("raylib");
    // exe.linkLibC();
    // exe.addIncludePath(.{ .cwd_relative = "/usr/local/include" });

    // ---- Install & run steps ----
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the Mandelbrot visualizer");
    run_step.dependOn(&run_cmd.step);
}
