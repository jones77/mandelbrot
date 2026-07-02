const std = @import("std");
const rl = @import("raylib");
const app = @import("app.zig");
const PIXEL_CHANNELS = @import("util.zig").PIXEL_CHANNELS;
const m = @import("mandelbrot.zig");
const renderer = @import("renderer.zig");

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

// ===========================================================================
// Integration tests (need raylib for Image allocation)
// ===========================================================================
const testing = std.testing;

fn expectPixelBlack(pixels: []const u8, w: usize, h: usize, x: usize, y: usize) !void {
    _ = h;
    const idx = (y * w + x) * 4;
    try testing.expectEqual(@as(u8, 0), pixels[idx + 0]);
    try testing.expectEqual(@as(u8, 0), pixels[idx + 1]);
    try testing.expectEqual(@as(u8, 0), pixels[idx + 2]);
}

fn expectPixelNotBlack(pixels: []const u8, w: usize, h: usize, x: usize, y: usize) !void {
    _ = h;
    const idx = (y * w + x) * 4;
    const r = pixels[idx + 0];
    const g = pixels[idx + 1];
    const b = pixels[idx + 2];
    try testing.expect(r > 0 or g > 0 or b > 0);
}

fn countNonBlack(pixels: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        if (pixels[i] > 0 or pixels[i + 1] > 0 or pixels[i + 2] > 0) count += 1;
    }
    return count;
}

const RenderTestCase = struct {
    label: []const u8,
    w: i32,
    h: i32,
    view: m.ViewState,
    min_exterior_pct: u8,
};

test "default view renders with colored exterior pixels" {
    m.buildPalette();

    const cases = [_]RenderTestCase{
        .{
            .label = "32x32 auto",
            .w = 32,
            .h = 32,
            .view = .{
                .center_x = m.INITIAL_CENTER_X,
                .center_y = m.INITIAL_CENTER_Y,
                .range = m.INITIAL_RANGE,
                .max_iters = m.DEFAULT_MAX_ITERS,
            },
            .min_exterior_pct = 30,
        },
        .{
            .label = "32x32 f64",
            .w = 32,
            .h = 32,
            .view = .{
                .center_x = m.INITIAL_CENTER_X,
                .center_y = m.INITIAL_CENTER_Y,
                .range = m.INITIAL_RANGE,
                .max_iters = m.DEFAULT_MAX_ITERS,
                .render_method = .f64,
            },
            .min_exterior_pct = 30,
        },
        .{
            .label = "64x64 auto",
            .w = 64,
            .h = 64,
            .view = .{
                .center_x = m.INITIAL_CENTER_X,
                .center_y = m.INITIAL_CENTER_Y,
                .range = m.INITIAL_RANGE,
                .max_iters = m.DEFAULT_MAX_ITERS,
            },
            .min_exterior_pct = 30,
        },
    };

    for (cases) |c| {
        const img = rl.genImageColor(c.w, c.h, .black);
        defer rl.unloadImage(img);

        const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(c.w * c.h * PIXEL_CHANNELS))];
        const timed_out = try renderer.renderMandelbrot(pixels, @intCast(c.w), @intCast(c.h), c.view, true, 0, rl.getTime, null);
        try testing.expect(!timed_out);

        const uw: usize = @intCast(c.w);
        const uh: usize = @intCast(c.h);
        try expectPixelBlack(pixels, uw, uh, uw / 2, uh / 2);
        try expectPixelNotBlack(pixels, uw, uh, 0, 0);

        const total = @as(usize, @intCast(c.w * c.h));
        const non_black = countNonBlack(pixels);
        try testing.expect(non_black > total * c.min_exterior_pct / 100);
    }
}
