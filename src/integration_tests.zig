const std = @import("std");
const rl = @import("raylib");
const m = @import("mandelbrot.zig");
const renderer = @import("renderer.zig");
const PIXEL_CHANNELS = @import("util.zig").PIXEL_CHANNELS;

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

fn isPixelBlack(pixels: []const u8, idx: usize) bool {
    return pixels[idx + 0] == 0 and pixels[idx + 1] == 0 and pixels[idx + 2] == 0;
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
