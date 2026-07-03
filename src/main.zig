const std = @import("std");
const rl = @import("raylib");
const app = @import("app.zig");
const PIXEL_CHANNELS = @import("util.zig").PIXEL_CHANNELS;
const m = @import("mandelbrot.zig");
const renderer = @import("renderer.zig");
const _ = @import("integration_tests.zig");

const DEFAULT_WIDTH: i32 = 900;
const DEFAULT_HEIGHT: i32 = 800;
const TARGET_FPS: i32 = 60;

pub fn main(init: std.process.Init) !void {
    rl.setConfigFlags(rl.ConfigFlags{ .window_highdpi = true });
    rl.initWindow(DEFAULT_WIDTH, DEFAULT_HEIGHT, "Mandelbrot Set");
    defer rl.closeWindow();
    rl.setTargetFPS(TARGET_FPS);

    const render_method = parseMethodArg(init.minimal.args) orelse .auto;

    var a = try app.App.init(render_method);
    defer a.deinit();

    // Initial render.
    _ = try a.renderFresh(true);
    try a.saveSnapshot();

    // Main loop.
    while (!rl.windowShouldClose()) {
        try a.handleResize();
        try a.handleInput();
        a.drawFrame();
    }
}

fn parseMethodArg(args: std.process.Args) ?m.RenderMethod {
    var it = args.iterate();
    _ = it.next() orelse return null;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--method")) {
            const val = it.next() orelse return null;
            if (std.mem.eql(u8, val, "f64")) return .f64;
            if (std.mem.eql(u8, val, "perturbation")) return .perturbation;
            if (std.mem.eql(u8, val, "auto")) return .auto;
            return null;
        }
    }
    return null;
}


