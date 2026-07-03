const std = @import("std");
const rl = @import("raylib");
const app = @import("app.zig");
const PIXEL_CHANNELS = @import("pixel.zig").PIXEL_CHANNELS;
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
    const tooltip_enabled = parseTooltipArg(init.minimal.args);

    var a = try app.App.init(render_method, tooltip_enabled);
    defer a.deinit();

    // Initial render.
    _ = try a.renderFresh(true);
    try a.saveSnapshot();

    // Drain stale input events accumulated during init/rendering so the
    // main loop starts with a clean input state.  We poll twice: the first
    // call loads stale events into currentKeyState; the second copies those
    // into previousKeyState so isKeyPressed() never sees a 0→1 transition
    // for stale events.
    rl.pollInputEvents();
    rl.pollInputEvents();
    while (rl.getKeyPressed() != .null) {}
    while (rl.getCharPressed() != 0) {}

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

fn parseTooltipArg(args: std.process.Args) bool {
    var it = args.iterate();
    _ = it.next() orelse return true;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-tooltip")) return false;
        if (std.mem.eql(u8, arg, "--tooltip")) return true;
    }
    return true;
}


