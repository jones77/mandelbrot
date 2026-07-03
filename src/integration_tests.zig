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
        .{
            .label = "64x64 perturbation",
            .w = 64,
            .h = 64,
            .view = .{
                .center_x = m.INITIAL_CENTER_X,
                .center_y = m.INITIAL_CENTER_Y,
                .range = m.INITIAL_RANGE,
                .max_iters = m.DEFAULT_MAX_ITERS,
                .render_method = .perturbation,
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

test "all three algorithms agree on interior/exterior classification" {
    m.buildPalette();

    const w: i32 = 64;
    const h: i32 = 64;
    // View centered at (-0.75, 0.1) where the reference is exterior,
    // so .auto activates perturbation — all three paths are exercised.
    const base_view = m.ViewState{
        .center_x = -0.75,
        .center_y = 0.1,
        .range = 0.5,
        .max_iters = 256,
    };
    const methods = [_]m.RenderMethod{ .auto, .f64, .perturbation };

    var images: [3]rl.Image = undefined;
    var pixels: [3][]u8 = undefined;
    for (methods, 0..) |method, i| {
        images[i] = rl.genImageColor(w, h, .black);
        pixels[i] = @as([*]u8, @ptrCast(images[i].data))[0 .. @as(usize, @intCast(w * h * PIXEL_CHANNELS))];
        const view = m.ViewState{
            .center_x = base_view.center_x,
            .center_y = base_view.center_y,
            .range = base_view.range,
            .max_iters = base_view.max_iters,
            .render_method = method,
        };
        const timed_out = try renderer.renderMandelbrot(pixels[i], @intCast(w), @intCast(h), view, true, 0, rl.getTime, null);
        try testing.expect(!timed_out);
    }
    defer {
        for (&images) |*img| rl.unloadImage(img.*);
    }

    const uw: usize = @intCast(w);
    const total = uw * @as(usize, @intCast(h));
    var mismatch: usize = 0;
    var exterior: usize = 0;

    for (0..total) |px| {
        const b0 = isPixelBlack(pixels[0], px * 4);
        const b1 = isPixelBlack(pixels[1], px * 4);
        const b2 = isPixelBlack(pixels[2], px * 4);
        if (b0 != b1 or b0 != b2) mismatch += 1;
        if (!b0) exterior += 1;
    }

    // Allow up to 1 mismatched pixel (out of 4096). At the set boundary,
    // minor threshold differences between the three algorithm paths can
    // cause single-pixel classification disagreements. Zero tolerance would
    // be fragile; more than 1 likely indicates a real regression.
    const max_mismatch: usize = 1;
    try testing.expect(mismatch <= max_mismatch);
    try testing.expect(exterior > 0);
}

fn complexToPixel(cx: f64, cy: f64, view: m.ViewState, w: i32, h: i32) struct { x: f64, y: f64 } {
    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    // Must match renderer.zig's pixel-center mapping (left/top includes offset).
    const left = view.center_x + view.offset_x - range_x / 2.0;
    const top = view.center_y + view.offset_y - range_y / 2.0;
    return .{
        .x = ((cx - left) / range_x) * @as(f64, @floatFromInt(w)) - 0.5,
        .y = ((cy - top) / range_y) * @as(f64, @floatFromInt(h)) - 0.5,
    };
}

test "WellKnown points correctly classified in rendered image" {
    m.buildPalette();

    const w: i32 = 64;
    const h: i32 = 64;
    const view = m.ViewState{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE,
        .max_iters = m.DEFAULT_MAX_ITERS,
    };

    const img = rl.genImageColor(w, h, .black);
    defer rl.unloadImage(img);

    const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(w * h * PIXEL_CHANNELS))];
    const timed_out = try renderer.renderMandelbrot(pixels, @intCast(w), @intCast(h), view, true, 0, rl.getTime, null);
    try testing.expect(!timed_out);

    for (m.WellKnown.points) |p| {
        // Skip points that need more iterations than our render view.
        if (p.max_iters > view.max_iters) continue;

        const px = complexToPixel(p.cx, p.cy, view, w, h);
        // Skip points outside image bounds or within 0.5px of edge
        // to avoid pixel-boundary ambiguity.
        if (px.x < 0.5 or px.x >= @as(f64, @floatFromInt(w)) - 0.5) continue;
        if (px.y < 0.5 or px.y >= @as(f64, @floatFromInt(h)) - 0.5) continue;

        const pix_x: usize = @intFromFloat(@round(px.x));
        const pix_y: usize = @intFromFloat(@round(px.y));
        const idx = (pix_y * @as(usize, @intCast(w)) + pix_x) * 4;

        const black = isPixelBlack(pixels, idx);
        if (p.interior) {
            try testing.expect(black);
        } else {
            try testing.expect(!black);
        }
    }
}

test "deep zoom render produces valid output" {
    m.buildPalette();

    const w: i32 = 32;
    const h: i32 = 32;
    // Seahorse Valley coordinates — exercises the perturbation path
    // with f64 fallback (max_iters > 2048 triggers the threshold).
    const view = m.ViewState{
        .center_x = -1.785897,
        .center_y = 0.000055,
        .range = 2.257306e-3,
        .max_iters = 8192,
    };

    const img = rl.genImageColor(w, h, .black);
    defer rl.unloadImage(img);

    const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(w * h * PIXEL_CHANNELS))];
    const timed_out = try renderer.renderMandelbrot(pixels, @intCast(w), @intCast(h), view, true, 0, rl.getTime, null);
    try testing.expect(!timed_out);

    // Reference point at the center is exterior — must be colored.
    try expectPixelNotBlack(pixels, @intCast(w), @intCast(h), @intCast(w / 2), @intCast(h / 2));

    const total = @as(usize, @intCast(w * h));
    const non_black = countNonBlack(pixels);
    // At least one black (interior) pixel exists.
    try testing.expect(non_black < total);
    // At least one colored (exterior) pixel exists.
    try testing.expect(non_black > 0);
}

var timeout_clock_calls: u32 = 0;

fn timeoutTestClock() f64 {
    const calls = @atomicRmw(u32, &timeout_clock_calls, .Add, 1, .Monotonic);
    // Stay at 0 for first 10 calls so those row-checks pass,
    // then jump far past deadline to trigger timeout.
    if (calls < 10) return 0.0;
    return 100.0;
}

test "renderer reports timeout with short deadline" {
    m.buildPalette();

    const w: i32 = 64;
    const h: i32 = 64;
    const view = m.ViewState{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE,
        .max_iters = 65536,
    };

    timeout_clock_calls = 0;

    const img = rl.genImageColor(w, h, .black);
    defer rl.unloadImage(img);

    const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(w * h * PIXEL_CHANNELS))];
    const timed_out = try renderer.renderMandelbrot(pixels, @intCast(w), @intCast(h), view, true, 0.001, timeoutTestClock, null);
    try testing.expect(timed_out);

    const total = @as(usize, @intCast(w * h));
    const non_black = countNonBlack(pixels);
    // At least one row was rendered before timeout.
    try testing.expect(non_black > 0);
    // Not all rows were rendered.
    try testing.expect(non_black < total);
}

/// Independent ground-truth Mandelbrot iteration in pure f64.
/// Returns `true` if the point is interior (never escaped within max_iters).
/// Purpose-built for integration testing — shares no code with
/// mandelbrot.zig's iteration functions.
fn groundTruthInterior(cx: f64, cy: f64, max_iters: u32) bool {
    var zx: f64 = cx;
    var zy: f64 = cy;
    var i: u32 = 0;
    while (i < max_iters) : (i += 1) {
        const zx2 = zx * zx;
        const zy2 = zy * zy;
        if (zx2 + zy2 > 4.0) return false;
        zy = 2.0 * zx * zy + cy;
        zx = zx2 - zy2 + cx;
    }
    return true;
}

test "every pixel classification matches ground truth at 128 iters" {
    const max_iters: u32 = 128;
    const w: i32 = 64;
    const h: i32 = 64;

    const view = m.ViewState{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE,
        .max_iters = max_iters,
    };

    // 1. Render with the full pipeline.
    m.buildPalette();
    const img = rl.genImageColor(w, h, .black);
    defer rl.unloadImage(img);
    const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(w * h * PIXEL_CHANNELS))];
    const timed_out = try renderer.renderMandelbrot(pixels, @intCast(w), @intCast(h), view, true, 0, rl.getTime, null);
    try testing.expect(!timed_out);

    // 2. Pixel-to-complex mapping (must match renderer.zig: pixel centers).
    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x + view.offset_x - range_x / 2.0;
    const top = view.center_y + view.offset_y - range_y / 2.0;

    var mismatch: usize = 0;
    var interior: usize = 0;
    var exterior: usize = 0;

    for (0..@as(usize, @intCast(h))) |py| {
        const cy = top + (@as(f64, @floatFromInt(py)) + 0.5) * range_y / @as(f64, @floatFromInt(h));
        for (0..@as(usize, @intCast(w))) |px| {
            const cx = left + (@as(f64, @floatFromInt(px)) + 0.5) * range_x / @as(f64, @floatFromInt(w));

            const gt_interior = groundTruthInterior(cx, cy, max_iters);
            const idx = (py * @as(usize, @intCast(w)) + px) * 4;
            const renderer_black = isPixelBlack(pixels, idx);

            if (gt_interior != renderer_black) mismatch += 1;
            if (gt_interior) interior += 1 else exterior += 1;
        }
    }

    try testing.expectEqual(@as(usize, 0), mismatch);
    try testing.expect(interior > 0);
    try testing.expect(exterior > 0);
}

test "every pixel matches ground truth at startup resolution and iters" {
    const max_iters: u32 = m.DEFAULT_MAX_ITERS;
    const w: i32 = 128;
    const h: i32 = 128;

    const view = m.ViewState{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE,
        .max_iters = max_iters,
    };

    m.buildPalette();
    const img = rl.genImageColor(w, h, .black);
    defer rl.unloadImage(img);
    const pixels = @as([*]u8, @ptrCast(img.data))[0 .. @as(usize, @intCast(w * h * PIXEL_CHANNELS))];
    const timed_out = try renderer.renderMandelbrot(pixels, @intCast(w), @intCast(h), view, true, 0, rl.getTime, null);
    try testing.expect(!timed_out);

    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x + view.offset_x - range_x / 2.0;
    const top = view.center_y + view.offset_y - range_y / 2.0;

    var mismatch: usize = 0;
    var interior: usize = 0;
    var exterior: usize = 0;

    for (0..@as(usize, @intCast(h))) |py| {
        const cy = top + (@as(f64, @floatFromInt(py)) + 0.5) * range_y / @as(f64, @floatFromInt(h));
        for (0..@as(usize, @intCast(w))) |px| {
            const cx = left + (@as(f64, @floatFromInt(px)) + 0.5) * range_x / @as(f64, @floatFromInt(w));

            const gt_interior = groundTruthInterior(cx, cy, max_iters);
            const idx = (py * @as(usize, @intCast(w)) + px) * 4;
            const renderer_black = isPixelBlack(pixels, idx);

            if (gt_interior != renderer_black) mismatch += 1;
            if (gt_interior) interior += 1 else exterior += 1;
        }
    }

    try testing.expectEqual(@as(usize, 0), mismatch);
    try testing.expect(interior > 0);
    try testing.expect(exterior > 0);
}


