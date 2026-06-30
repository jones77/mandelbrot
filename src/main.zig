const std = @import("std");
const rl = @import("raylib");
const app = @import("app.zig");
const m = @import("mandelbrot.zig");
const renderer = @import("renderer.zig");

const DEFAULT_WIDTH: i32 = 900;
const DEFAULT_HEIGHT: i32 = 800;
const TARGET_FPS: i32 = 60;

pub fn main(init: std.process.Init) !void {
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

// ===========================================================================
// Integration tests (need raylib for Image allocation)
// ===========================================================================
const testing = std.testing;

test "default view renders with colored exterior pixels" {
    m.buildPalette();

    const w: i32 = 32;
    const h: i32 = 32;
    const img = rl.genImageColor(w, h, .black);
    defer rl.unloadImage(img);

    const view = m.ViewState{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE,
        .max_iters = m.DEFAULT_MAX_ITERS,
    };

    const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(w * h * 4))];
    const timed_out = try renderer.renderMandelbrot(pixels, @intCast(w), @intCast(h), view, true, 0, rl.getTime);
    try testing.expect(!timed_out);

    const center_idx: usize = 16 * @as(usize, @intCast(w)) + 16;
    const center_r = pixels[center_idx * 4 + 0];
    const center_g = pixels[center_idx * 4 + 1];
    const center_b = pixels[center_idx * 4 + 2];
    try testing.expectEqual(@as(u8, 0), center_r);
    try testing.expectEqual(@as(u8, 0), center_g);
    try testing.expectEqual(@as(u8, 0), center_b);

    const tl_idx: usize = 0;
    const tl_r = pixels[tl_idx * 4 + 0];
    const tl_g = pixels[tl_idx * 4 + 1];
    const tl_b = pixels[tl_idx * 4 + 2];
    try testing.expect(tl_r > 0 or tl_g > 0 or tl_b > 0);

    var non_black: usize = 0;
    const total = @as(usize, @intCast(w * h));
    for (0..total) |px| {
        const r = pixels[px * 4 + 0];
        const g = pixels[px * 4 + 1];
        const b = pixels[px * 4 + 2];
        if (r > 0 or g > 0 or b > 0) non_black += 1;
    }
    try testing.expect(non_black > total * 30 / 100);
}
