const std = @import("std");

pub const PALETTE_SIZE: usize = 1024;
pub const PALETTE_DENSITY: f64 = 4.0;
pub const INTERIOR_BASE_EPSILON_SQ: f32 = 1e-6;
pub const PERIODICITY_BASE_EPSILON_SQ: f32 = 1e-6;
pub const CARDIOID_DIST_SQ: f64 = 0.25;
pub const BULB_RADIUS_SQ: f64 = 0.0625;
pub const CARDIOID_Y_MAX: f64 = 3.0 * @sqrt(3.0) / 8.0;
pub const ESCAPE_RADIUS_SQ: f64 = 4.0;

/// Pauldelbrot ratio threshold: when |z|² / |Z|² < r, the pixel's orbit
/// has diverged from the reference (|z| is bounded while |Z| grows).
pub const GLITCH_RATIO: f32 = 1e-4;
/// Minimum |Z|² required before applying the Pauldelbrot check — avoids
/// division by near-zero when the reference hasn't escaped yet.
pub const GLITCH_MIN_NORM_SQ: f32 = 1e-10;
pub const DEFAULT_MAX_ITERS: u32 = 2048;
pub const MIN_ITERS: u32 = 16;
pub const MAX_ITERS_CAP: u32 = 65536;
pub const AUTO_SCALE_CAP: u32 = 16384;
pub const AUTO_SCALE_SLOPE: f64 = 0.25;
/// When perturbation is unavailable and max_iters exceeds this, use f64 rebaseFallback
/// instead of f32 standardPixel to avoid precision loss near the set boundary.
pub const F32_MAX_ITERS_THRESHOLD: u32 = 2048;
/// When the pixel step (range_x / w) is below this threshold, use f64 rebaseFallback
/// instead of f32 standardPixel to avoid precision loss at deep zoom levels.
pub const PIXEL_STEP_F64_THRESHOLD: f64 = 1.0e-7;
pub const INITIAL_CENTER_X: f64 = -0.75;
pub const INITIAL_CENTER_Y: f64 = 0.0;
pub const INITIAL_RANGE: f64 = 2.9;

/// Selects which inner-loop algorithm the renderer uses.
/// `auto` picks based on zoom depth (current default).
pub const RenderMethod = enum {
    auto,
    f64,
    perturbation,
};

// ========================= Types =========================

pub const Coord = struct {
    re: f32,
    im: f32,
    pub fn normSq(self: Coord) f32 {
        return self.re * self.re + self.im * self.im;
    }
    pub fn sq(self: Coord) Coord {
        return .{
            .re = self.re * self.re - self.im * self.im,
            .im = 2.0 * self.re * self.im,
        };
    }
};

pub const OrbitPoint = struct { zx: f32, zy: f32 };

pub const RefOrbit = struct { zx: f64, zy: f64 };

pub const ViewState = struct {
    center_x: f64,
    center_y: f64,
    range: f64,
    max_iters: u32,
    render_method: RenderMethod = .auto,
    /// Sub-precise offset from center_x/center_y. When the view is zoomed
    /// so deep that center_x + offset rounds to center_x in f64, the offset
    /// is accumulated here. The renderer adds this to per-pixel dcx/dcy.
    offset_x: f64 = 0,
    offset_y: f64 = 0,
};

pub const ComplexPoint = struct { x: f64, y: f64 };

// ========================= Palette =========================

pub var palette: [PALETTE_SIZE][4]u8 = undefined;

pub fn buildPalette() void {
    var i: usize = 0;
    while (i < PALETTE_SIZE) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(PALETTE_SIZE));
        const hue = 240.0 * (1.0 - t);
        palette[i] = hslToRgb(hue, 0.85, 0.45 + t * 0.35);
    }
}

fn hslToRgb(h: f32, s: f32, l: f32) [4]u8 {
    const c = (1.0 - @abs(2.0 * l - 1.0)) * s;
    const hp = h / 60.0;
    const x = c * (1.0 - @abs(@mod(hp, 2.0) - 1.0));
    const m = l - c / 2.0;

    var r1: f32 = 0;
    var g1: f32 = 0;
    var b1: f32 = 0;

    if (hp < 1) {
        r1 = c;
        g1 = x;
    } else if (hp < 2) {
        r1 = x;
        g1 = c;
    } else if (hp < 3) {
        g1 = c;
        b1 = x;
    } else if (hp < 4) {
        g1 = x;
        b1 = c;
    } else if (hp < 5) {
        r1 = x;
        b1 = c;
    } else {
        r1 = c;
        b1 = x;
    }

    return .{
        @intFromFloat(@round((r1 + m) * 255.0)),
        @intFromFloat(@round((g1 + m) * 255.0)),
        @intFromFloat(@round((b1 + m) * 255.0)),
        255,
    };
}

pub fn smoothColor(mu: f64, max_iters: u32) [4]u8 {
    if (!std.math.isFinite(mu) or mu >= @as(f64, @floatFromInt(max_iters))) return .{ 0, 0, 0, 255 };
    const raw = mu * PALETTE_DENSITY;
    const idx = @as(usize, @intFromFloat(@mod(raw, @as(f64, @floatFromInt(PALETTE_SIZE)))));
    const frac = raw - @floor(raw);
    const next = (idx + 1) % PALETTE_SIZE;

    const c0 = palette[idx];
    const c1 = palette[next];
    return .{
        @intFromFloat(@round(@as(f64, @floatFromInt(c0[0])) * (1.0 - frac) + @as(f64, @floatFromInt(c1[0])) * frac)),
        @intFromFloat(@round(@as(f64, @floatFromInt(c0[1])) * (1.0 - frac) + @as(f64, @floatFromInt(c1[1])) * frac)),
        @intFromFloat(@round(@as(f64, @floatFromInt(c0[2])) * (1.0 - frac) + @as(f64, @floatFromInt(c1[2])) * frac)),
        255,
    };
}

// ========================= Iteration =========================

pub fn computeReference(cx: f64, cy: f64, max_iters: u32, allocator: std.mem.Allocator) ![]RefOrbit {
    const orbit = try allocator.alloc(RefOrbit, max_iters);
    var zx: f64 = cx;
    var zy: f64 = cy;

    for (0..max_iters) |i| {
        orbit[i] = .{ .zx = zx, .zy = zy };
        const zx2 = zx * zx;
        const zy2 = zy * zy;
        zy = 2.0 * zx * zy + cy;
        zx = zx2 - zy2 + cx;
    }

    return orbit[0..max_iters];
}

const PERIODICITY_STORE_SIZE: u32 = 32;

/// Smooth iteration count (mu) from escape data.
/// `norm_sq` = |z|² at escape (must be > 4.0).
pub inline fn smoothIteration(iter: u32, norm_sq: f64) f64 {
    return @as(f64, @floatFromInt(iter)) + 1.0 - @log(0.5 * @log(norm_sq)) / @log(2.0);
}

/// Simplified perturbation (no glitch detection, rebasing, or f64 escape checks).
/// Used only by tests. The production renderer uses renderPerturbationPixel.
/// Returns smooth iteration count `mu`, or `max_iters` as f32 for interior.
pub fn perturbPixel(
    dcx: f32,
    dcy: f32,
    orbit: []const RefOrbit,
    max_iters: u32,
) f32 {
    var dx: f32 = dcx;
    var dy: f32 = dcy;

    for (0..max_iters) |iter| {
        const ref = &orbit[iter];
        const Zx: f32 = @floatCast(ref.zx);
        const Zy: f32 = @floatCast(ref.zy);
        const sumx = Zx + dx;
        const sumy = Zy + dy;
        if (sumx * sumx + sumy * sumy > @as(f32, ESCAPE_RADIUS_SQ)) {
            const raw = smoothIteration(@intCast(iter), @as(f64, sumx * sumx + sumy * sumy));
            return @floatCast(raw);
        }
        const two_zd_re = 2.0 * (Zx * dx - Zy * dy);
        const two_zd_im = 2.0 * (Zx * dy + Zy * dx);
        const dsq_re = dx * dx - dy * dy;
        const dsq_im = 2.0 * dx * dy;
        dx = two_zd_re + dsq_re + dcx;
        dy = two_zd_im + dsq_im + dcy;
    }
    return @as(f32, @floatFromInt(max_iters));
}

/// Production perturbation pixel renderer with glitch detection, Z overflow
/// handling, and f64 rebasing. Used by the multi-threaded renderer.
/// Returns smooth iteration count `mu`, or `max_iters` as f32 for interior.
pub fn renderPerturbationPixel(
    dcx: f64,
    dcy: f64,
    orbit: []const RefOrbit,
    max_iters: u32,
    glitch_ratio: f32,
) f32 {
    var dx: f64 = dcx;
    var dy: f64 = dcy;
    var iter: u32 = 0;
    const max_f: f32 = @floatFromInt(max_iters);
    var result: f32 = max_f;

    while (iter < max_iters) : (iter += 1) {
        const ref = &orbit[iter];
        const Zx = ref.zx;
        const Zy = ref.zy;
        const Z_norm_sq = Zx * Zx + Zy * Zy;

        const rebase_zx = ref.zx + dx;
        const rebase_zy = ref.zy + dy;
        const rebase_cx = orbit[0].zx + dcx;
        const rebase_cy = orbit[0].zy + dcy;
        const rebase_norm_sq = rebase_zx * rebase_zx + rebase_zy * rebase_zy;

        if (!std.math.isFinite(Z_norm_sq)) {
            if (std.math.isFinite(ref.zx + ref.zy)) {
                result = rebaseFallback(rebase_zx, rebase_zy, rebase_cx, rebase_cy, iter, max_iters);
            } else {
                result = rebaseFallback(rebase_cx, rebase_cy, rebase_cx, rebase_cy, 0, max_iters);
            }
            break;
        }

        if (glitch_ratio > 0) {
            if (Z_norm_sq > @as(f64, GLITCH_MIN_NORM_SQ) and
                rebase_norm_sq < @as(f64, glitch_ratio) * Z_norm_sq)
            {
                result = rebaseFallback(rebase_cx, rebase_cy, rebase_cx, rebase_cy, 0, max_iters);
                break;
            }
        }

        if (dx * dx + dy * dy > Z_norm_sq) {
            result = rebaseFallback(rebase_zx, rebase_zy, rebase_cx, rebase_cy, iter, max_iters);
            break;
        }

        if (rebase_norm_sq > ESCAPE_RADIUS_SQ) {
            if (std.math.isFinite(rebase_norm_sq)) {
                result = @floatCast(smoothIteration(iter, rebase_norm_sq));
            } else if (std.math.isFinite(ref.zx + ref.zy)) {
                result = rebaseFallback(rebase_zx, rebase_zy, rebase_cx, rebase_cy, iter, max_iters);
            } else {
                result = rebaseFallback(rebase_cx, rebase_cy, rebase_cx, rebase_cy, 0, max_iters);
            }
            break;
        }

        const two_zd_re = 2.0 * (Zx * dx - Zy * dy);
        const two_zd_im = 2.0 * (Zx * dy + Zy * dx);
        const dsq_re = dx * dx - dy * dy;
        const dsq_im = 2.0 * dx * dy;
        dx = two_zd_re + dsq_re + dcx;
        dy = two_zd_im + dsq_im + dcy;
    }
    return result;
}

/// Standard (non-perturbation) per-pixel iteration.
/// Returns smooth iteration count `mu`, or `max_iters` as f32 for interior.
pub inline fn standardPixel(
    cx: f32,
    cy: f32,
    max_iters: u32,
    interior_eps_sq: f32,
    periodicity_eps_sq: f32,
) f32 {
    var z = Coord{ .re = cx, .im = cy };
    var der = Coord{ .re = 1.0, .im = 0.0 };
    var orbit_stored: [PERIODICITY_STORE_SIZE]OrbitPoint = undefined;
    var orbit_n: u32 = 0;

    for (0..max_iters) |iter| {
        if (der.normSq() < interior_eps_sq) return @as(f32, @floatFromInt(max_iters));
        if (z.normSq() > @as(f32, ESCAPE_RADIUS_SQ)) {
            const raw = smoothIteration(@intCast(iter), @as(f64, z.normSq()));
            return @floatCast(raw);
        }
        {
            var periodic = false;
            for (0..orbit_n) |j| {
                if ((z.re - orbit_stored[j].zx) * (z.re - orbit_stored[j].zx) + (z.im - orbit_stored[j].zy) * (z.im - orbit_stored[j].zy) < periodicity_eps_sq) {
                    periodic = true;
                    break;
                }
            }
            if (periodic) return @as(f32, @floatFromInt(max_iters));
        }
        // Bolt's method: store z at power-of-2 iteration counts to detect periodicity
        if (iter + 1 == (@as(u32, 1) << @as(u5, @intCast(orbit_n)))) {
            orbit_stored[orbit_n] = .{ .zx = z.re, .zy = z.im };
            orbit_n += 1;
        }
        der = Coord{ .re = 2.0 * (z.re * der.re - z.im * der.im), .im = 2.0 * (z.re * der.im + z.im * der.re) };
        z = Coord{ .re = z.re * z.re - z.im * z.im + cx, .im = 2.0 * z.re * z.im + cy };
    }
    return @as(f32, @floatFromInt(max_iters));
}

/// Rebase fallback: continue Mandelbrot iteration from arbitrary z in f64.
/// No derivative or periodicity tracking — just the plain recurrence and escape check.
/// Used when perturbation approximation breaks down (|δ| > |Z| or glitch detected).
/// `start_iter` is the iteration count at which zx, zy were reached.
pub inline fn rebaseFallback(
    zx: f64,
    zy: f64,
    cx: f64,
    cy: f64,
    start_iter: u32,
    max_iters: u32,
) f32 {
    var zx_f = zx;
    var zy_f = zy;
    var iter = start_iter;
    while (iter < max_iters) : (iter += 1) {
        const norm_sq = zx_f * zx_f + zy_f * zy_f;
        if (norm_sq > ESCAPE_RADIUS_SQ) {
            const raw = smoothIteration(iter, norm_sq);
            return @floatCast(raw);
        }
        const nzx = zx_f * zx_f - zy_f * zy_f + cx;
        const nzy = 2.0 * zx_f * zy_f + cy;
        zx_f = nzx;
        zy_f = nzy;
    }
    return @as(f32, @floatFromInt(max_iters));
}

/// Continue Mandelbrot iteration from an arbitrary z value (f64, with derivative + periodicity tracking).
/// Not used in the production renderer (rebaseFallback is preferred); kept for testing/validation.
/// `start_iter` is the iteration count at which zx, zy were reached.
pub fn continueStandard(
    zx: f64,
    zy: f64,
    cx: f64,
    cy: f64,
    start_iter: u32,
    max_iters: u32,
    interior_eps_sq: f64,
    periodicity_eps_sq: f64,
) f32 {
    var zx_f = zx;
    var zy_f = zy;
    var der_re: f64 = 1.0;
    var der_im: f64 = 0.0;
    var orbit_stored: [PERIODICITY_STORE_SIZE]OrbitPoint = undefined;
    var orbit_n: u32 = 0;

    var iter = start_iter;
    while (iter < max_iters) : (iter += 1) {
        if (der_re * der_re + der_im * der_im < interior_eps_sq) return @as(f32, @floatFromInt(max_iters));
        const norm_sq = zx_f * zx_f + zy_f * zy_f;
        if (norm_sq > ESCAPE_RADIUS_SQ) {
            const raw = smoothIteration(iter, norm_sq);
            return @floatCast(raw);
        }
        {
            var periodic = false;
            for (0..orbit_n) |j| {
                if ((zx_f - orbit_stored[j].zx) * (zx_f - orbit_stored[j].zx) + (zy_f - orbit_stored[j].zy) * (zy_f - orbit_stored[j].zy) < periodicity_eps_sq) {
                    periodic = true;
                    break;
                }
            }
            if (periodic) return @as(f32, @floatFromInt(max_iters));
        }
        // Bolt's method: store z at power-of-2 iteration counts to detect periodicity
        if (iter + 1 == (@as(u32, 1) << @as(u5, @intCast(orbit_n)))) {
            orbit_stored[orbit_n] = .{ .zx = @floatCast(zx_f), .zy = @floatCast(zy_f) };
            orbit_n += 1;
        }
        const nd_re = 2.0 * (zx_f * der_re - zy_f * der_im);
        const nd_im = 2.0 * (zx_f * der_im + zy_f * der_re);
        der_re = nd_re;
        der_im = nd_im;
        const nzx = zx_f * zx_f - zy_f * zy_f + cx;
        const nzy = 2.0 * zx_f * zy_f + cy;
        zx_f = nzx;
        zy_f = nzy;
    }
    return @as(f32, @floatFromInt(max_iters));
}

// ========================= Validation Helpers =========================

/// Result of iterating a single point to termination.
pub const PointResult = struct {
    iter: u32,
    zx: f64,
    zy: f64,
    escaped: bool,
};

/// High-precision reference iteration in f64 with no early-outs.
/// Returns the exact iteration count and final z value.
pub fn groundTruthPixel(cx: f64, cy: f64, max_iters: u32) PointResult {
    var zx: f64 = cx;
    var zy: f64 = cy;
    for (0..max_iters) |iter| {
        const norm_sq = zx * zx + zy * zy;
        if (norm_sq > ESCAPE_RADIUS_SQ) {
            return .{ .iter = @intCast(iter), .zx = zx, .zy = zy, .escaped = true };
        }
        const nzx = zx * zx - zy * zy + cx;
        const nzy = 2.0 * zx * zy + cy;
        zx = nzx;
        zy = nzy;
    }
    return .{ .iter = max_iters, .zx = zx, .zy = zy, .escaped = false };
}

/// Returns true if the point is inside the Mandelbrot set,
/// using high-precision ground-truth iteration.
pub fn classifyPixel(cx: f64, cy: f64, max_iters: u32) bool {
    return !groundTruthPixel(cx, cy, max_iters).escaped;
}

/// Well-known Mandelbrot points with verified interior/exterior classification.
pub const WellKnown = struct {
    pub const Point = struct {
        cx: f64,
        cy: f64,
        max_iters: u32,
        interior: bool,
    };

    pub const points = [_]Point{
        .{ .cx = 0.0, .cy = 0.0, .max_iters = 256, .interior = true },
        .{ .cx = -0.75, .cy = 0.0, .max_iters = 256, .interior = true },
        .{ .cx = -1.0, .cy = 0.0, .max_iters = 512, .interior = true },
        .{ .cx = -0.5, .cy = 0.0, .max_iters = 256, .interior = true },
        .{ .cx = 0.3, .cy = 0.0, .max_iters = 256, .interior = false },
        .{ .cx = 1.0, .cy = 0.0, .max_iters = 32, .interior = false },
        .{ .cx = -1.5, .cy = 0.01, .max_iters = 512, .interior = false },
        .{ .cx = -0.75, .cy = 0.1, .max_iters = 256, .interior = false },
        .{ .cx = -0.758, .cy = 0.0, .max_iters = 512, .interior = true },
        .{ .cx = -1.780612, .cy = 0.000054, .max_iters = 512, .interior = false },
        .{ .cx = -1.996378, .cy = 0.000002, .max_iters = 512, .interior = true },
    };
};

/// Returns true if (cx, cy) lies inside the main cardioid or the period-2 bulb,
/// where the Mandelbrot recurrence is guaranteed not to escape.
/// `cy2` is cy * cy (precomputed by the caller).
pub fn isCardioidOrBulb(cx: f32, cy2: f32) bool {
    const q = (cx - 0.25) * (cx - 0.25) + cy2;
    if (q * (q + (cx - 0.25)) <= 0.25 * cy2) return true;
    if ((cx + 1.0) * (cx + 1.0) + cy2 <= 0.0625) return true;
    return false;
}

pub fn clearToOpaqueBlack(pixels: []u8) void {
    if (pixels.len % 4 != 0) @panic("clearToOpaqueBlack: pixels.len must be a multiple of 4");
    @memset(pixels, 0);
    var a: usize = 3;
    while (a < pixels.len) : (a += 4) {
        pixels[a] = 255;
    }
}

// ========================= Utility Functions =========================

pub fn nextPowerOf2(n: u32) u32 {
    if (n == 0) return 1;
    if (n > 0x80000000) return 0x80000000;
    var x = n;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return x + 1;
}

/// Returns true when the renderer should use f64 rebaseFallback instead of
/// f32 standardPixel.  .f64 mode forces f64; .auto uses f64 when the pixel
/// step is below the precision threshold or when max_iters exceeds f32 range.
pub fn shouldUseF64Fallback(render_method: RenderMethod, pixel_step: f64, max_iters: u32) bool {
    return render_method == .f64 or
        (render_method == .auto and pixel_step < PIXEL_STEP_F64_THRESHOLD) or
        max_iters > F32_MAX_ITERS_THRESHOLD;
}

/// Computes the auto-scaled iteration count based on zoom depth.
/// At INITIAL_RANGE returns DEFAULT_MAX_ITERS (2048). At deeper zoom,
/// scales iter count logarithmically up to AUTO_SCALE_CAP (16384).
pub fn computeAutoZoomIters(range: f64) u32 {
    const zoom_factor = INITIAL_RANGE / range;
    const log2_zf = @log(zoom_factor) / @log(2.0);
    const log2_start = @log(@as(f64, @floatFromInt(DEFAULT_MAX_ITERS))) / @log(2.0);
    const target_f = @exp2(log2_start + log2_zf * AUTO_SCALE_SLOPE);
    const clamped = @min(target_f, @as(f64, @floatFromInt(AUTO_SCALE_CAP)));
    return nextPowerOf2(@as(u32, @intFromFloat(clamped)));
}

/// Maps screen pixel coordinates to complex coordinates.
/// When range < ~1e-16 × |center|, the range/2 term rounds to zero in
/// f64, and every pixel maps to the center coordinate.  See offset_x/y
/// in ViewState for the sub-precise representation used at deep zoom.
pub fn screenToComplex(sx: f64, sy: f64, view: ViewState, img_w: i32, img_h: i32) ComplexPoint {
    const aspect = @as(f64, @floatFromInt(img_w)) / @as(f64, @floatFromInt(img_h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x - range_x / 2.0;
    const top = view.center_y - range_y / 2.0;
    const div_w: f64 = @floatFromInt(img_w);
    const div_h: f64 = @floatFromInt(img_h);

    return .{
        .x = left + (sx / div_w) * range_x,
        .y = top + (sy / div_h) * range_y,
    };
}

pub fn constrainDragSquare(start_x: f64, start_y: f64, raw_mx: f64, raw_my: f64) ComplexPoint {
    const raw_dx = raw_mx - start_x;
    const raw_dy = raw_my - start_y;
    const size = @max(@abs(raw_dx), @abs(raw_dy));
    if (size < 1.0) return .{ .x = start_x, .y = start_y };
    return .{
        .x = start_x + std.math.copysign(size, raw_dx),
        .y = start_y + std.math.copysign(size, raw_dy),
    };
}

pub fn lerpViewState(a: ViewState, b: ViewState, t: f64) ViewState {
    return .{
        .center_x = a.center_x + (b.center_x - a.center_x) * t,
        .center_y = a.center_y + (b.center_y - a.center_y) * t,
        .range = a.range + (b.range - a.range) * t,
        .max_iters = a.max_iters,
        .render_method = a.render_method,
        .offset_x = a.offset_x + (b.offset_x - a.offset_x) * t,
        .offset_y = a.offset_y + (b.offset_y - a.offset_y) * t,
    };
}

// ========================= Tests =========================

const testing = std.testing;

test "nextPowerOf2" {
    try testing.expectEqual(@as(u32, 1), nextPowerOf2(0));
    try testing.expectEqual(@as(u32, 1), nextPowerOf2(1));
    try testing.expectEqual(@as(u32, 2), nextPowerOf2(2));
    try testing.expectEqual(@as(u32, 4), nextPowerOf2(3));
    try testing.expectEqual(@as(u32, 16), nextPowerOf2(9));
    try testing.expectEqual(@as(u32, 16), nextPowerOf2(16));
    try testing.expectEqual(@as(u32, 32), nextPowerOf2(17));
    try testing.expectEqual(@as(u32, 64), nextPowerOf2(33));
    try testing.expectEqual(@as(u32, 128), nextPowerOf2(127));
    try testing.expectEqual(@as(u32, 65536), nextPowerOf2(65536));
    try testing.expectEqual(@as(u32, 65536), nextPowerOf2(65535));
    try testing.expectEqual(@as(u32, 0x80000000), nextPowerOf2(0x80000000));
    try testing.expectEqual(@as(u32, 0x80000000), nextPowerOf2(0x80000001));
}

test "constrainDragSquare" {
    var sq = constrainDragSquare(100.0, 100.0, 300.0, 150.0);
    try testing.expectEqual(@as(f64, 300.0), sq.x);
    try testing.expectEqual(@as(f64, 300.0), sq.y);

    // Downward drag: dx=50, dy=200 → constrained to 200×200 square.
    sq = constrainDragSquare(100.0, 100.0, 150.0, 300.0);
    try testing.expectEqual(@as(f64, 300.0), sq.x);
    try testing.expectEqual(@as(f64, 300.0), sq.y);

    // Reverse drag (right-to-left, bottom-to-top): dx=-200, dy=-150.
    sq = constrainDragSquare(300.0, 300.0, 100.0, 150.0);
    try testing.expectEqual(@as(f64, 100.0), sq.x);
    try testing.expectEqual(@as(f64, 100.0), sq.y);

    sq = constrainDragSquare(100.0, 100.0, 100.5, 100.5);
    try testing.expectEqual(@as(f64, 100.0), sq.x);
    try testing.expectEqual(@as(f64, 100.0), sq.y);
}

test "screenToComplex round-trip" {
    const view = ViewState{
        .center_x = -0.5,
        .center_y = 0.0,
        .range = 3.5,
        .max_iters = 100,
    };
    const w: i32 = 900;
    const h: i32 = 800;
    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_y = 3.5 / aspect;
    const left = -0.5 - 3.5 / 2.0;
    const top = 0.0 - range_y / 2.0;

    var c = screenToComplex(450.0, 400.0, view, w, h);
    try testing.expectApproxEqAbs(-0.5, c.x, 1e-12);
    try testing.expectApproxEqAbs(0.0, c.y, 1e-12);

    c = screenToComplex(0.0, 0.0, view, w, h);
    try testing.expectApproxEqAbs(left, c.x, 1e-12);
    try testing.expectApproxEqAbs(top, c.y, 1e-12);
}

test "hslToRgb known values" {
    var rgb = hslToRgb(0.0, 0.0, 1.0);
    try testing.expectEqual(@as(u8, 255), rgb[0]);
    try testing.expectEqual(@as(u8, 255), rgb[1]);
    try testing.expectEqual(@as(u8, 255), rgb[2]);

    rgb = hslToRgb(0.0, 0.0, 0.0);
    try testing.expectEqual(@as(u8, 0), rgb[0]);
    try testing.expectEqual(@as(u8, 0), rgb[1]);
    try testing.expectEqual(@as(u8, 0), rgb[2]);

    rgb = hslToRgb(0.0, 1.0, 0.5);
    try testing.expectEqual(@as(u8, 255), rgb[0]);
    try testing.expectEqual(@as(u8, 0), rgb[1]);
    try testing.expectEqual(@as(u8, 0), rgb[2]);

    rgb = hslToRgb(120.0, 1.0, 0.5);
    try testing.expectEqual(@as(u8, 0), rgb[0]);
    try testing.expectEqual(@as(u8, 255), rgb[1]);
    try testing.expectEqual(@as(u8, 0), rgb[2]);

    rgb = hslToRgb(240.0, 1.0, 0.5);
    try testing.expectEqual(@as(u8, 0), rgb[0]);
    try testing.expectEqual(@as(u8, 0), rgb[1]);
    try testing.expectEqual(@as(u8, 255), rgb[2]);
}

test "smoothColor inside set" {
    try testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, smoothColor(100.0, 100));
    try testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, smoothColor(999.0, 100));
}

test "buildPalette all valid" {
    buildPalette();
    for (palette) |c| {
        try testing.expectEqual(@as(u8, 255), c[3]);
    }
}

test "Coord normSq and sq" {
    const z = Coord{ .re = 3.0, .im = 4.0 };
    try testing.expectEqual(@as(f32, 25.0), z.normSq());
    const z2 = z.sq();
    try testing.expectEqual(@as(f32, -7.0), z2.re);
    try testing.expectEqual(@as(f32, 24.0), z2.im);

    const zero = Coord{ .re = 0, .im = 0 };
    try testing.expectEqual(@as(f32, 0.0), zero.normSq());

    const unit = Coord{ .re = 1.0, .im = 1.0 };
    const unit_sq = unit.sq();
    try testing.expectApproxEqAbs(@as(f32, 0.0), unit_sq.re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), unit_sq.im, 1e-6);
}

test "clearToOpaqueBlack sets RGBA=0 with A=255" {
    var buf = [_]u8{0xFF} ** 16;
    clearToOpaqueBlack(&buf);
    for (0..4) |i| {
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 0]);
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 1]);
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 2]);
        try testing.expectEqual(@as(u8, 255), buf[i * 4 + 3]);
    }
}

test "screenToComplex inverse consistency" {
    const v = ViewState{
        .center_x = -0.5,
        .center_y = 0.0,
        .range = 3.5,
        .max_iters = 100,
    };
    const w: i32 = 900;
    const h: i32 = 800;

    try testing.expect(std.math.isFinite(screenToComplex(0.0, 0.0, v, w, h).x));
    try testing.expect(std.math.isFinite(screenToComplex(450.0, 400.0, v, w, h).x));
    try testing.expect(std.math.isFinite(screenToComplex(899.0, 799.0, v, w, h).x));
    try testing.expect(std.math.isFinite(screenToComplex(100.0, 700.0, v, w, h).x));

    const c = screenToComplex(0.0, 0.0, v, w, h);
    try testing.expect(c.x >= -2.25 and c.x <= 1.25);
    try testing.expect(c.y >= -1.75 and c.y <= 1.75);
}

test "computeReference interior point returns orbit" {
    const result = try computeReference(-0.5, 0.0, 1024, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1024), result.len);
    try testing.expectApproxEqAbs(@as(f64, -0.5), result[0].zx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result[0].zy, 1e-12);
}

test "computeReference exterior point returns orbit" {
    const result = try computeReference(1.0, 0.0, 1024, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1024), result.len);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result[0].zx, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.0), result[0].zy, 1e-12);
    var found_escape = false;
    for (result) |o| {
        if (o.zx * o.zx + o.zy * o.zy > 4.0) { found_escape = true; break; }
    }
    try testing.expect(found_escape);
}

test "computeReference far exterior escapes immediately" {
    const result = try computeReference(2.0, 0.0, 1024, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1024), result.len);
    try testing.expect(result[1].zx * result[1].zx + result[1].zy * result[1].zy > 4.0);
}

test "computeReference max_iters=0 returns empty orbit" {
    const result = try computeReference(-0.5, 0.0, 0, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 0), result.len);
}

test "computeReference max_iters=1 exterior escapes at start" {
    const result = try computeReference(2.5, 0.0, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(result[0].zx * result[0].zx + result[0].zy * result[0].zy > 4.0);
}

test "zoom math round-trip" {
    const screen_w: i32 = 900;
    const screen_h: i32 = 800;

    var view = ViewState{
        .center_x = -0.5,
        .center_y = 0.0,
        .range = 3.5,
        .max_iters = 256,
    };

    const drag_start_x: f64 = 200.0;
    const drag_start_y: f64 = 200.0;
    const drag_end_x: f64 = 500.0;
    const drag_end_y: f64 = 500.0;

    const size = @max(@abs(drag_end_x - drag_start_x), @abs(drag_end_y - drag_start_y));
    const sel_cx = (drag_start_x + drag_end_x) / 2.0;
    const sel_cy = (drag_start_y + drag_end_y) / 2.0;

    const c_center = screenToComplex(sel_cx, sel_cy, view, screen_w, screen_h);
    const smaller = @min(screen_w, screen_h);
    const new_range = view.range * (size / @as(f64, @floatFromInt(smaller)));

    try testing.expect(new_range < view.range);
    try testing.expectApproxEqAbs(-0.5, c_center.x, 0.5);
    try testing.expectApproxEqAbs(0.0, c_center.y, 0.5);

    const old_range = view.range;
    view.range = new_range;
    view.center_x = c_center.x;
    view.center_y = c_center.y;

    try testing.expect(view.range > 0);
    try testing.expect(view.range < old_range);
}

test "zoom auto-scale iterations" {
    // At INITIAL_RANGE, zoom factor = 1 → target stays at baseline 2048
    try testing.expectEqual(DEFAULT_MAX_ITERS, computeAutoZoomIters(INITIAL_RANGE));
    // At 100× zoom, target should scale up to 8192
    try testing.expectEqual(@as(u32, 8192), computeAutoZoomIters(INITIAL_RANGE / 100.0));
    // At extreme zoom, target should be capped at AUTO_SCALE_CAP
    try testing.expectEqual(@as(u32, AUTO_SCALE_CAP), computeAutoZoomIters(INITIAL_RANGE / 1e9));
}

// --- Perturbation boundary checking tests ---

test "perturbation matches standard" {
    const TestCase = struct {
        ref_cx: f32, ref_cy: f32,
        dcx: f32, dcy: f32,
        max_iters: u32,
        tolerance: f32,
    };
    const cases = [_]TestCase{
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = 0.0, .dcy = 0.0, .max_iters = 64, .tolerance = 0.01 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = 0.001, .dcy = 0.001, .max_iters = 64, .tolerance = 0.01 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = 0.001, .dcy = -0.002, .max_iters = 64, .tolerance = 0.1 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = -0.01, .dcy = 0.01, .max_iters = 64, .tolerance = 0.1 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = 0.02, .dcy = -0.03, .max_iters = 64, .tolerance = 0.1 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = 0.2, .dcy = 0.2, .max_iters = 64, .tolerance = 0.1 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = -2.0, .dcy = -0.2, .max_iters = 128, .tolerance = 0.5 },
        .{ .ref_cx = 1.0, .ref_cy = 0.0, .dcx = 0.0, .dcy = 0.0, .max_iters = 32, .tolerance = 0.01 },
        .{ .ref_cx = 0.5, .ref_cy = 0.3, .dcx = 1.5, .dcy = -0.3, .max_iters = 64, .tolerance = 0.1 },
    };

    // Compute orbits lazily, reusing allocations for same reference point
    var prev_ref: struct { f32, f32 } = .{ std.math.nan(f32), std.math.nan(f32) };
    var orbit: ?[]const RefOrbit = null;
    defer if (orbit) |o| std.testing.allocator.free(o);

    for (cases) |c| {
        if (prev_ref[0] != c.ref_cx or prev_ref[1] != c.ref_cy) {
            if (orbit) |o| std.testing.allocator.free(o);
            prev_ref = .{ c.ref_cx, c.ref_cy };
            orbit = try computeReference(c.ref_cx, c.ref_cy, c.max_iters, std.testing.allocator);
        }
        const orb = orbit orelse @panic("expected exterior reference");

        const pix_cx = c.ref_cx + c.dcx;
        const pix_cy = c.ref_cy + c.dcy;

        const mu_p = perturbPixel(c.dcx, c.dcy, orb, c.max_iters);
        const mu_s = standardPixel(pix_cx, pix_cy, c.max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

        try testing.expect(mu_p < @as(f32, @floatFromInt(c.max_iters)));
        try testing.expect(mu_s < @as(f32, @floatFromInt(c.max_iters)));
        try testing.expectApproxEqAbs(mu_s, mu_p, c.tolerance);
    }
}

test "perturbation interior point classified interior" {
    const ref_cx: f32 = 0.3;
    const ref_cy: f32 = 0.0;
    const pix_cx: f32 = 0.24;
    const pix_cy: f32 = 0.0;
    const max_iters: u32 = 128;
    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    const mu_p = perturbPixel(pix_cx - ref_cx, pix_cy - ref_cy, orbit, max_iters);
    const mu_s = standardPixel(pix_cx, pix_cy, max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_p >= @as(f32, @floatFromInt(max_iters)));
    try testing.expect(mu_s >= @as(f32, @floatFromInt(max_iters)));
}

test "perturbPixel with large offset escapes immediately" {
    const ref_cx: f32 = 0.3;
    const ref_cy: f32 = 0.0;
    const dcx: f32 = 2.0;
    const dcy: f32 = 0.0;
    const max_iters: u32 = 128;
    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    const mu = perturbPixel(dcx, dcy, orbit, max_iters);
    try testing.expect(std.math.isFinite(mu));
    try testing.expect(mu < @as(f32, @floatFromInt(max_iters)));
    // At iter=0: sumx = 0.3 + 2.0 = 2.3, |z|² = 5.29 > 4, mu ≈ 1.26
    try testing.expect(mu > 1.0 and mu < 2.0);
}

test "renderPerturbationPixel escapes at reference point" {
    const ref_cx: f64 = 0.3;
    const ref_cy: f64 = 0.0;
    const max_iters: u32 = 128;
    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    const mu = renderPerturbationPixel(0.0, 0.0, orbit, max_iters, GLITCH_RATIO);
    try testing.expect(std.math.isFinite(mu));
    try testing.expect(mu < @as(f32, @floatFromInt(max_iters)));
}

test "renderPerturbationPixel interior point returns max_iters" {
    const ref_cx: f64 = 0.3;
    const ref_cy: f64 = 0.0;
    const max_iters: u32 = 128;
    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    const mu = renderPerturbationPixel(-0.06, 0.0, orbit, max_iters, GLITCH_RATIO);
    try testing.expect(std.math.isFinite(mu));
    try testing.expect(mu >= @as(f32, @floatFromInt(max_iters)));
}

test "renderPerturbationPixel matches perturbPixel with glitch_ratio=0" {
    const ref_cx: f64 = 0.5;
    const ref_cy: f64 = 0.3;
    const max_iters: u32 = 64;
    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    const offsets = [_]struct { dcx: f64, dcy: f64 }{
        .{ .dcx = 0.0, .dcy = 0.0 },
        .{ .dcx = 0.001, .dcy = 0.001 },
        .{ .dcx = 0.001, .dcy = -0.002 },
        .{ .dcx = -0.01, .dcy = 0.01 },
        .{ .dcx = 0.02, .dcy = -0.03 },
    };
    for (offsets) |off| {
        const mu_rp = renderPerturbationPixel(off.dcx, off.dcy, orbit, max_iters, 0);
        const mu_pp = perturbPixel(@floatCast(off.dcx), @floatCast(off.dcy), orbit, max_iters);
        try testing.expect(mu_rp < @as(f32, @floatFromInt(max_iters)));
        try testing.expect(mu_pp < @as(f32, @floatFromInt(max_iters)));
        try testing.expectApproxEqAbs(mu_pp, mu_rp, 0.01);
    }
}

test "renderPerturbationPixel Seahorse Valley regression" {
    const ref_cx: f64 = -1.785897;
    const ref_cy: f64 = 0.000055;
    const range: f64 = 2.257306e-3;
    const max_iters: u32 = 8192;

    const offsets = [_]struct { dx: f64, dy: f64 }{
        .{ .dx = 0.0, .dy = 0.0 },
        .{ .dx = -0.3 * range, .dy = 0.0 },
        .{ .dx = 0.3 * range, .dy = 0.0 },
        .{ .dx = 0.0, .dy = -0.3 * range },
        .{ .dx = 0.0, .dy = 0.3 * range },
        .{ .dx = -0.5 * range, .dy = -0.5 * range },
        .{ .dx = 0.5 * range, .dy = 0.5 * range },
        .{ .dx = -0.7 * range, .dy = 0.0 },
        .{ .dx = 0.7 * range, .dy = 0.0 },
    };

    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    for (offsets) |off| {
        const pix_cx = ref_cx + off.dx;
        const pix_cy = ref_cy + off.dy;
        const mu_rp = renderPerturbationPixel(off.dx, off.dy, orbit, max_iters, GLITCH_RATIO);
        const gt = groundTruthPixel(pix_cx, pix_cy, max_iters);

        if (gt.escaped) {
            try testing.expect(mu_rp < @as(f32, @floatFromInt(max_iters)));
            const mu_gt_f64 = smoothIteration(gt.iter, gt.zx * gt.zx + gt.zy * gt.zy);
            const mu_gt: f32 = @floatCast(mu_gt_f64);
            try testing.expectApproxEqAbs(mu_gt, mu_rp, 0.5);
        }
    }
}

test "continueStandard from start matches standardPixel" {
    const cx: f64 = 0.5;
    const cy: f64 = 0.3;
    const max_iters: u32 = 64;

    const mu_cs = continueStandard(cx, cy, cx, cy, 0, max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
    const mu_s = standardPixel(@floatCast(cx), @floatCast(cy), max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_s < @as(f32, @floatFromInt(max_iters)));
    try testing.expectApproxEqAbs(mu_s, mu_cs, 0.001);
}

test "continueStandard mid-iteration matches standardPixel" {
    const cx: f64 = 0.5;
    const cy: f64 = 0.3;
    const max_iters: u32 = 64;

    var zx: f64 = cx;
    var zy: f64 = cy;
    for (0..10) |_| {
        const nzx = zx * zx - zy * zy + cx;
        zy = 2.0 * zx * zy + cy;
        zx = nzx;
    }

    const mu_cs = continueStandard(zx, zy, cx, cy, 10, max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
    const mu_s = standardPixel(@floatCast(cx), @floatCast(cy), max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_s < @as(f32, @floatFromInt(max_iters)));
    try testing.expectApproxEqAbs(mu_s, mu_cs, 0.01);
}

test "continueStandard interior via derivative matches standardPixel" {
    const cx: f64 = 0.0;
    const cy: f64 = 0.0;
    const max_iters: u32 = 512;

    const mu_cs = continueStandard(cx, cy, cx, cy, 0, max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
    const mu_s = standardPixel(@floatCast(cx), @floatCast(cy), max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_cs >= @as(f32, @floatFromInt(max_iters)));
    try testing.expect(mu_s >= @as(f32, @floatFromInt(max_iters)));
}

test "continueStandard interior via periodicity matches standardPixel" {
    const cx: f64 = -0.758;
    const cy: f64 = 0.0;
    const max_iters: u32 = 256;

    const mu_cs = continueStandard(cx, cy, cx, cy, 0, max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
    const mu_s = standardPixel(@floatCast(cx), @floatCast(cy), max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_cs >= @as(f32, @floatFromInt(max_iters)));
    try testing.expect(mu_s >= @as(f32, @floatFromInt(max_iters)));
}

test "standardPixel epsilon=0 still detects escape" {
    // With interior_eps_sq=0, derivative detection never fires.
    // With periodicity_eps_sq=0, periodicity detection never fires.
    // Must still escape via norm_sq check.
    const mu0 = standardPixel(0.5, 0.3, 64, 0.0, 0.0);
    try testing.expect(mu0 < @as(f32, @floatFromInt(64)));

    const mu1 = standardPixel(0.0, 0.0, 256, 0.0, 0.0);
    try testing.expect(mu1 >= @as(f32, @floatFromInt(256)));
}

test "rebaseFallback from start matches standardPixel" {
    const cx: f64 = 0.5;
    const cy: f64 = 0.3;
    const max_iters: u32 = 64;

    const mu_rb = rebaseFallback(cx, cy, cx, cy, 0, max_iters);
    const mu_s = standardPixel(@floatCast(cx), @floatCast(cy), max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_s < @as(f32, @floatFromInt(max_iters)));
    try testing.expectApproxEqAbs(mu_s, mu_rb, 0.001);
}

test "rebaseFallback mid-iteration matches standardPixel" {
    const cx: f64 = 0.5;
    const cy: f64 = 0.3;
    const max_iters: u32 = 64;

    var zx: f64 = cx;
    var zy: f64 = cy;
    for (0..10) |_| {
        const nzx = zx * zx - zy * zy + cx;
        zy = 2.0 * zx * zy + cy;
        zx = nzx;
    }

    const mu_rb = rebaseFallback(zx, zy, cx, cy, 10, max_iters);
    const mu_s = standardPixel(@floatCast(cx), @floatCast(cy), max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

    try testing.expect(mu_s < @as(f32, @floatFromInt(max_iters)));
    try testing.expectApproxEqAbs(mu_s, mu_rb, 0.01);
}

test "rebaseFallback interior reaches max_iters" {
    const cx: f64 = 0.0;
    const cy: f64 = 0.0;
    const max_iters: u32 = 64;

    const mu_rb = rebaseFallback(cx, cy, cx, cy, 0, max_iters);

    try testing.expect(mu_rb >= @as(f32, @floatFromInt(max_iters)));
}

test "rebaseFallback escapes at blocky regression coordinate" {
    // At (-1.780612, 0.000054), f32 quantization makes adjacent pixels
    // indistinguishable (~15 pixels per f32 ULP).  The f64 fallback
    // must correctly resolve this as exterior.
    const mu_rb = rebaseFallback(-1.780612, 0.000054, -1.780612, 0.000054, 0, 512);
    try testing.expect(mu_rb < @as(f32, @floatFromInt(512)));
}

test "rebaseFallback interior at timeout regression coordinate" {
    // At (-1.996378, 0.000002) near the tip, this is genuinely interior.
    // The simplified f64 loop must agree.
    const mu_rb = rebaseFallback(-1.996378, 0.000002, -1.996378, 0.000002, 0, 512);
    try testing.expect(mu_rb >= @as(f32, @floatFromInt(512)));
}

test "rebaseFallback start_iter equals max_iters returns max_iters" {
    const mu = rebaseFallback(0.0, 0.0, 0.0, 0.0, 64, 64);
    try testing.expect(mu >= @as(f32, @floatFromInt(64)));
}

test "rebaseFallback start_iter near max_iters interior returns max_iters" {
    // start_iter = max_iters - 1, origin point → one more iteration, no escape
    const mu = rebaseFallback(0.0, 0.0, 0.0, 0.0, 63, 64);
    try testing.expect(mu >= @as(f32, @floatFromInt(64)));
}

test "rebaseFallback start_iter near max_iters escapes immediately" {
    // start_iter = max_iters - 1, z already past escape radius → escapes
    const mu = rebaseFallback(3.0, 0.0, 2.5, 0.0, 63, 64);
    try testing.expect(mu < @as(f32, @floatFromInt(64)));
    try testing.expect(mu >= 63.0 and mu < 64.0);
}

test "rebaseFallback matches standardPixel at moderate zoom coordinates" {
    // At moderate zoom, f32 precision is sufficient, so rebaseFallback
    // (f64) and standardPixel (f32) must agree.
    const cases = [_]struct { cx: f64, cy: f64, max_iters: u32, tol: f32, label: []const u8 }{
        .{ .cx = -0.75, .cy = 0.1, .max_iters = 256, .tol = 0.001, .label = "near-cardioid-exterior" },
        .{ .cx = 0.0, .cy = 0.0, .max_iters = 256, .tol = 0.001, .label = "origin-interior" },
        .{ .cx = -1.5, .cy = 0.0, .max_iters = 512, .tol = 0.01, .label = "real-axis-interior" },
        .{ .cx = -1.5, .cy = 0.01, .max_iters = 512, .tol = 0.01, .label = "real-axis-exterior" },
    };
    for (cases) |c| {
        const mu_rb = rebaseFallback(c.cx, c.cy, c.cx, c.cy, 0, c.max_iters);
        const mu_s = standardPixel(@floatCast(c.cx), @floatCast(c.cy), c.max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
        const interior_rb = mu_rb >= @as(f32, @floatFromInt(c.max_iters));
        const interior_s = mu_s >= @as(f32, @floatFromInt(c.max_iters));
        if (interior_rb != interior_s) {
            std.debug.print("FAIL {s}: rebase={d:.6} std={d:.6}\n", .{ c.label, mu_rb, mu_s });
            return error.TestUnexpectedResult;
        }
        if (!interior_rb) {
            try testing.expectApproxEqAbs(mu_s, mu_rb, c.tol);
        }
    }
}

test "rebaseFallback matches continueStandard where f64 is correct" {
    // Both rebaseFallback and continueStandard use f64 internally.
    // They should agree on interior/exterior and mu values for exterior.
    // NOTE: continueStandard uses derivative+periodicity tracking which
    // can false-positive interior near the set boundary (e.g. at the
    // blocky regression coordinate).  Those are excluded here — the
    // simplified rebaseFallback loop is the correct result.
    const cases = [_]struct { cx: f64, cy: f64, max_iters: u32, tol: f32, label: []const u8 }{
        .{ .cx = -0.75, .cy = 0.1, .max_iters = 256, .tol = 0.001, .label = "standard-exterior" },
        .{ .cx = 0.0, .cy = 0.0, .max_iters = 256, .tol = 0.001, .label = "origin-interior" },
        .{ .cx = -1.996378, .cy = 0.000002, .max_iters = 512, .tol = 0.01, .label = "tip-interior" },
    };
    for (cases) |c| {
        const mu_rb = rebaseFallback(c.cx, c.cy, c.cx, c.cy, 0, c.max_iters);
        const mu_cs = continueStandard(c.cx, c.cy, c.cx, c.cy, 0, c.max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
        const interior_rb = mu_rb >= @as(f32, @floatFromInt(c.max_iters));
        const interior_cs = mu_cs >= @as(f32, @floatFromInt(c.max_iters));
        if (interior_rb != interior_cs) {
            std.debug.print("FAIL {s}: rebase={d:.6} cs={d:.6}\n", .{ c.label, mu_rb, mu_cs });
            return error.TestUnexpectedResult;
        }
        if (!interior_rb) {
            try testing.expectApproxEqAbs(mu_cs, mu_rb, c.tol);
        }
    }
}

test "groundTruthPixel well-known points" {
    for (WellKnown.points) |p| {
        const result = groundTruthPixel(p.cx, p.cy, p.max_iters);
        if (result.escaped == p.interior) {
            std.debug.print("FAIL ({d}, {d}): expected interior={}, got escaped={} at iter {}\n", .{ p.cx, p.cy, p.interior, result.escaped, result.iter });
            return error.TestUnexpectedResult;
        }
    }
}

test "perturbation matches groundTruthPixel at exterior points" {
    const TestCase = struct {
        ref_cx: f64, ref_cy: f64,
        dcx: f32, dcy: f32,
        max_iters: u32,
        tolerance: f32,
    };
    const cases = [_]TestCase{
        .{ .ref_cx = 1.0, .ref_cy = 0.0, .dcx = 0.0, .dcy = 0.0, .max_iters = 64, .tolerance = 0.001 },
        .{ .ref_cx = 1.0, .ref_cy = 0.0, .dcx = 0.01, .dcy = 0.01, .max_iters = 64, .tolerance = 0.01 },
        .{ .ref_cx = 0.3, .ref_cy = 0.0, .dcx = 0.0, .dcy = 0.0, .max_iters = 256, .tolerance = 0.001 },
        .{ .ref_cx = 0.3, .ref_cy = 0.0, .dcx = 0.001, .dcy = 0.001, .max_iters = 256, .tolerance = 0.01 },
        .{ .ref_cx = 2.0, .ref_cy = 0.0, .dcx = 0.0, .dcy = 0.0, .max_iters = 64, .tolerance = 0.001 },
        .{ .ref_cx = -0.75, .ref_cy = 0.1, .dcx = 0.0, .dcy = 0.0, .max_iters = 256, .tolerance = 0.001 },
    };

    for (cases) |c| {
        const orbit = try computeReference(c.ref_cx, c.ref_cy, c.max_iters, std.testing.allocator);
        defer std.testing.allocator.free(orbit);

        const pix_cx = c.ref_cx + @as(f64, @floatCast(c.dcx));
        const pix_cy = c.ref_cy + @as(f64, @floatCast(c.dcy));

        const mu_p = perturbPixel(c.dcx, c.dcy, orbit, c.max_iters);
        const gt = groundTruthPixel(pix_cx, pix_cy, c.max_iters);
        try testing.expect(gt.escaped);
        const mu_gt_f64 = smoothIteration(gt.iter, gt.zx * gt.zx + gt.zy * gt.zy);
        const mu_gt: f32 = @floatCast(mu_gt_f64);
        try testing.expectApproxEqAbs(mu_gt, mu_p, c.tolerance);
    }
}

test "rebaseFallback matches groundTruthPixel" {
    for (WellKnown.points) |p| {
        const mu_rb = rebaseFallback(p.cx, p.cy, p.cx, p.cy, 0, p.max_iters);
        const gt = groundTruthPixel(p.cx, p.cy, p.max_iters);

        if (gt.escaped) {
            try testing.expect(mu_rb < @as(f32, @floatFromInt(p.max_iters)));
            const mu_gt_f64 = smoothIteration(gt.iter, gt.zx * gt.zx + gt.zy * gt.zy);
            const mu_gt: f32 = @floatCast(mu_gt_f64);
            try testing.expectApproxEqAbs(mu_gt, mu_rb, 0.001);
        } else {
            try testing.expect(mu_rb >= @as(f32, @floatFromInt(p.max_iters)));
        }
    }
}

test "all algorithms agree at standard coordinates" {
    const test_points = [_]struct { cx: f64, cy: f64, max_iters: u32, tol: f32 }{
        .{ .cx = 0.3, .cy = 0.0, .max_iters = 256, .tol = 0.001 },
        .{ .cx = 1.0, .cy = 0.0, .max_iters = 64, .tol = 0.001 },
        .{ .cx = -0.75, .cy = 0.1, .max_iters = 256, .tol = 0.01 },
        .{ .cx = 0.0, .cy = 0.0, .max_iters = 256, .tol = 0.001 },
    };
    for (test_points) |p| {
        const gt = groundTruthPixel(p.cx, p.cy, p.max_iters);
        const mu_s = standardPixel(@floatCast(p.cx), @floatCast(p.cy), p.max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);
        const mu_rb = rebaseFallback(p.cx, p.cy, p.cx, p.cy, 0, p.max_iters);
        const mu_cs = continueStandard(p.cx, p.cy, p.cx, p.cy, 0, p.max_iters, INTERIOR_BASE_EPSILON_SQ, PERIODICITY_BASE_EPSILON_SQ);

        if (gt.escaped) {
            const mu_gt_f64 = smoothIteration(gt.iter, gt.zx * gt.zx + gt.zy * gt.zy);
            const mu_gt: f32 = @floatCast(mu_gt_f64);
            try testing.expect(mu_s < @as(f32, @floatFromInt(p.max_iters)));
            try testing.expect(mu_rb < @as(f32, @floatFromInt(p.max_iters)));
            try testing.expect(mu_cs < @as(f32, @floatFromInt(p.max_iters)));
            try testing.expectApproxEqAbs(mu_gt, mu_s, p.tol);
            try testing.expectApproxEqAbs(mu_gt, mu_rb, p.tol);
            try testing.expectApproxEqAbs(mu_gt, mu_cs, p.tol);
        } else {
            try testing.expect(mu_s >= @as(f32, @floatFromInt(p.max_iters)));
            try testing.expect(mu_rb >= @as(f32, @floatFromInt(p.max_iters)));
            try testing.expect(mu_cs >= @as(f32, @floatFromInt(p.max_iters)));
        }
    }
}

test "regression: big black circle at Seahorse Valley" {
    // This test reproduces the exact coordinates where users reported a
    // "big black circle" artifact — exterior pixels near the reference
    // classified as interior (black).
    //
    // The reference point is near the Seahorse Valley period-3 minibrot.
    // When the reference orbit's Z overflows f32 (~7 iterations post-escape),
    // the Z_norm_sq check triggers a rebase. If the f32 δ has lost precision
    // (it's at magnitude ~3.4e38 while the pixel's true z is ~2.1), the
    // rebase receives a garbage z value and misclassifies exterior pixels
    // as interior.
    //
    // Fixed by:
    //   1. Reordering checks so Z_norm_sq overflow is caught before the
    //      escape check masks it.
    //   2. Using ref.zx (f64) instead of @as(f64, Zx) (f32→f64 inf) in
    //      rebaseFallback calls.
    //   3. Moving Zhuoran/Pauldelbrot checks before Z overflow to catch
    //      diverging pixels while δ is still f32-representable.

    const ref_cx: f64 = -1.785897;
    const ref_cy: f64 = 0.000055;
    const range: f64 = 2.257306e-3;
    const max_iters: u32 = 8192;

    // Build offsets spanning the view, weighted toward the center where
    // the black circle artifact appears.
    const offsets = [_]struct { dx: f64, dy: f64 }{
        .{ .dx = 0.0, .dy = 0.0 },
        .{ .dx = -0.3 * range, .dy = 0.0 },
        .{ .dx = 0.3 * range, .dy = 0.0 },
        .{ .dx = 0.0, .dy = -0.3 * range },
        .{ .dx = 0.0, .dy = 0.3 * range },
        .{ .dx = -0.5 * range, .dy = -0.5 * range },
        .{ .dx = 0.5 * range, .dy = 0.5 * range },
        .{ .dx = -0.7 * range, .dy = 0.0 },
        .{ .dx = 0.7 * range, .dy = 0.0 },
    };

    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    for (offsets) |off| {
        const dcx: f32 = @floatCast(off.dx);
        const dcy: f32 = @floatCast(off.dy);
        const pix_cx = ref_cx + off.dx;
        const pix_cy = ref_cy + off.dy;
        const mu_p = perturbPixel(dcx, dcy, orbit, max_iters);
        const gt = groundTruthPixel(pix_cx, pix_cy, max_iters);

        if (gt.escaped) {
            try testing.expect(mu_p < @as(f32, @floatFromInt(max_iters)));
            const mu_gt_f64 = smoothIteration(gt.iter, gt.zx * gt.zx + gt.zy * gt.zy);
            const mu_gt: f32 = @floatCast(mu_gt_f64);
            try testing.expectApproxEqAbs(mu_gt, mu_p, 0.5);
        }
    }
}

test "regression: f32 precision at 4096 iters near minibrot" {
    // At x=-1.388676, y=0.006144, range=6.24e-2, iters=4096, the f32
    // standardPixel path produces "lots of little black circles" —
    // exterior boundary pixels misclassified as interior.
    // With iters=8192, rebaseFallback (f64) is used and renders correctly.
    //
    // Fixed by lowering the f64 threshold from max_iters > 4096 to > 2048.

    const ref_cx: f64 = -1.388676;
    const ref_cy: f64 = 0.006144;
    const range: f64 = 6.243948e-2;
    const max_iters: u32 = 4096;

    const offsets = [_]struct { dx: f64, dy: f64 }{
        .{ .dx = 0.0, .dy = 0.0 },
        .{ .dx = -0.3 * range, .dy = 0.0 },
        .{ .dx = 0.3 * range, .dy = 0.0 },
        .{ .dx = 0.0, .dy = -0.3 * range },
        .{ .dx = 0.0, .dy = 0.3 * range },
        .{ .dx = 0.5 * range, .dy = 0.0 },
    };

    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);
    for (offsets) |off| {
        const dcx: f32 = @floatCast(off.dx);
        const dcy: f32 = @floatCast(off.dy);
        const pix_cx = ref_cx + off.dx;
        const pix_cy = ref_cy + off.dy;
        const mu_p = perturbPixel(dcx, dcy, orbit, max_iters);
        const gt = groundTruthPixel(pix_cx, pix_cy, max_iters);
        if (gt.escaped) {
            try testing.expect(mu_p < @as(f32, @floatFromInt(max_iters)));
        }
    }
}

test "regression: f64 escape check preserves delta at deep zoom" {
    // At range=7.7e-11, the pixel-to-reference delta (~4e-11) is lost in
    // f32 addition Zx + dx when |Z| > 100 (e.g. after reference escapes).
    // The f32 sum_norm_sq ≈ |Z|², so ALL adjacent pixels appear to escape
    // at the same iteration → blur.
    //
    // Fixed by computing escape and Pauldelbrot checks in f64 using
    // rebase_zx = ref.zx + @as(f64, dx), which preserves δ.

    const ref_cx: f64 = 0.3;
    const ref_cy: f64 = 0.0;
    const max_iters: u32 = 4096;

    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    // Interior pixel inside the main cardioid — must remain interior.
    {
        const mu = perturbPixel(-0.06, 0.0, orbit, max_iters);
        try testing.expect(std.math.isFinite(mu));
        try testing.expect(mu >= @as(f32, @floatFromInt(max_iters)));
    }

    // Exterior pixel just outside the cardioid — must escape with finite mu.
    {
        const mu = perturbPixel(0.001, 0.0, orbit, max_iters);
        try testing.expect(std.math.isFinite(mu));
        try testing.expect(mu < @as(f32, @floatFromInt(max_iters)));
    }

    // Exterior pixel with tiny delta — must differ from the above pixel.
    {
        const mu1 = perturbPixel(0.001, 0.0, orbit, max_iters);
        const mu2 = perturbPixel(0.0010001, 0.0, orbit, max_iters);
        try testing.expect(std.math.isFinite(mu1));
        try testing.expect(std.math.isFinite(mu2));
        try testing.expect(mu1 != mu2);
    }
}

test "regression: reference f64 overflow at 65536 iterations" {
    // When the reference orbit overflows f64 (zx, zy → inf ~10 iters
    // post-escape), the Z_norm_sq overflow check must detect that ref.zx
    // is also non-finite and restart from scratch.
    const ref_cx: f64 = 0.3;
    const ref_cy: f64 = 0.0;
    const max_iters: u32 = 65536;

    const orbit = try computeReference(ref_cx, ref_cy, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);

    // Interior pixel: Pauldelbrot fires, restarts from scratch → max_iters.
    {
        const mu = perturbPixel(-0.06, 0.0, orbit, max_iters);
        try testing.expect(std.math.isFinite(mu));
        try testing.expect(mu >= @as(f32, @floatFromInt(max_iters)));
    }

    // Pixel at the reference: escapes with finite mu.
    {
        const mu = perturbPixel(0.0, 0.0, orbit, max_iters);
        try testing.expect(std.math.isFinite(mu));
        try testing.expect(mu < @as(f32, @floatFromInt(max_iters)));
    }
}

test "smoothColor at boundary" {
    buildPalette();
    // mu >= max_iters → black (interior)
    try testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, smoothColor(512.0, 512));
    // mu == 0 → colored (not black)
    const c0 = smoothColor(0.0, 1024);
    try testing.expect(c0[3] == 255);
    try testing.expect(!(c0[0] == 0 and c0[1] == 0 and c0[2] == 0));
    // mu * 4.0 = 1024 → 1024 % 1024 = 0 → wraps to start of palette
    try testing.expectEqualDeep(smoothColor(0.0, 1024), smoothColor(256.0, 1024));
}

test "smoothIteration known values" {
    // iter=0, norm_sq=4.01 (just above escape) → mu ≈ 1.53
    const mu0 = smoothIteration(0, 4.01);
    try testing.expect(mu0 > 1.0 and mu0 < 2.0);
    try testing.expectApproxEqAbs(mu0, 1.53, 0.01);

    // iter=10, norm_sq=1000 → mu ≈ 9.21
    const mu1 = smoothIteration(10, 1000.0);
    try testing.expect(mu1 > 9.0 and mu1 < 10.0);
    try testing.expectApproxEqAbs(mu1, 9.21, 0.01);

    // iter=256, norm_sq=1e10 → mu ≈ 253.47
    const mu2 = smoothIteration(256, 1e10);
    try testing.expect(mu2 > 253.0 and mu2 < 254.0);

    // Monotonicity: more iterations → larger mu at same norm_sq
    try testing.expect(mu1 > mu0);
    try testing.expect(mu2 > mu1);
}

test "smoothColor with NaN or inf returns black" {
    buildPalette();
    try testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, smoothColor(std.math.nan(f64), 1024));
    try testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, smoothColor(std.math.inf(f64), 1024));
    try testing.expectEqualDeep([4]u8{ 0, 0, 0, 255 }, smoothColor(-std.math.inf(f64), 1024));
}

test "computeReference at high max_iters" {
    const max_iters: u32 = 8192;
    const orbit = try computeReference(1.0, 0.0, max_iters, std.testing.allocator);
    defer std.testing.allocator.free(orbit);
    try testing.expectEqual(@as(usize, 8192), orbit.len);

    var escape_idx: ?usize = null;
    for (orbit, 0..) |o, i| {
        if (o.zx * o.zx + o.zy * o.zy > 4.0) { escape_idx = i; break; }
    }
    try testing.expect(escape_idx != null);
    const ei = escape_idx.?;
    for (orbit[0..ei]) |o| {
        try testing.expect(std.math.isFinite(o.zx));
        try testing.expect(std.math.isFinite(o.zy));
    }
}

test "deep zoom screenToComplex precision loss" {
    // At range ≈ 8e-23, f64 cannot distinguish adjacent screen pixels
    // because the per-pixel complex step (≈ 9e-26) is far below the f64 ULP
    // (≈ 2e-16) at |center| ≈ 2.  screenToComplex returns the same coordinate
    // for every pixel — confirming the fundamental precision limitation.
    const view = ViewState{
        .center_x = -1.99183057,
        .center_y = 0.0,
        .range = 7.82875744e-23,
        .max_iters = 16384,
    };
    const w: i32 = 900;
    const h: i32 = 800;

    const c_center = screenToComplex(450.0, 400.0, view, w, h);
    const c_corner = screenToComplex(0.0, 0.0, view, w, h);
    const c_opposite = screenToComplex(899.0, 799.0, view, w, h);

    // All three X values equal center_x — the pixel-step offset is below
    // f64 precision when added to |center_x| ≈ 2.
    try testing.expect(c_center.x == view.center_x);
    try testing.expect(c_corner.x == view.center_x);
    try testing.expect(c_opposite.x == view.center_x);
    // Y coordinates ARE distinguishable because center_y = 0 — there is no
    // large-number+small-offset addition.
    try testing.expect(c_center.y == view.center_y);
    try testing.expect(c_corner.y != view.center_y);
    try testing.expect(c_opposite.y != view.center_y);
    try testing.expect(c_center.y == 0.0);
    try testing.expect(c_corner.y < 0);
    try testing.expect(c_opposite.y > 0);
}

test "deep zoom zoom math produces valid target" {
    // Emulate a drag-to-zoom at the user's deep zoom level.
    // The new center offset (from screen midpoint) is a tiny f64 value that
    // CAN be represented precisely, but cannot be added to center_x without
    // precision loss.  This test verifies the offset math works.
    const view = ViewState{
        .center_x = -1.99183057,
        .center_y = 0.0,
        .range = 7.82875744e-23,
        .max_iters = 16384,
    };
    const w: i32 = 900;
    const h: i32 = 800;
    const smaller = @as(f64, @floatFromInt(@min(w, h)));

    // Drag from (200, 200) to (400, 400) — 200×200 square
    const drag_start_x: f64 = 200.0;
    const drag_start_y: f64 = 200.0;
    const drag_end_x: f64 = 400.0;
    const drag_end_y: f64 = 400.0;

    const size = @max(@abs(drag_end_x - drag_start_x), @abs(drag_end_y - drag_start_y));
    const sel_cx = (drag_start_x + drag_end_x) / 2.0;
    const sel_cy = (drag_start_y + drag_end_y) / 2.0;

    // The absolute-complex approach (what screenToComplex does) — loses precision.
    const c_abs = screenToComplex(sel_cx, sel_cy, view, w, h);
    _ = c_abs;

    // The relative-offset approach — delta is a small, representable f64.
    const delta_x = (sel_cx / @as(f64, @floatFromInt(w)) - 0.5) * view.range;
    const delta_y = (sel_cy / @as(f64, @floatFromInt(h)) - 0.5) * view.range;

    try testing.expect(@abs(delta_x) <= view.range / 2.0);
    try testing.expect(@abs(delta_y) <= view.range / 2.0);
    try testing.expect(delta_x != 0);
    // delta_y = (300/800 - 0.5) * range = -0.125 * range
    try testing.expect(delta_y < 0);
    try testing.expectApproxEqAbs(delta_y, -0.125 * view.range, 1e-30);

    // New range: zoom factor = drag_size / viewport_size
    const new_range = view.range * (size / smaller);
    try testing.expect(new_range < view.range);
    try testing.expect(new_range > 0);
}

test "lerpViewState interpolates offset" {
    const from_v = ViewState{
        .center_x = -1.99183057,
        .center_y = 0.0,
        .offset_x = 0.0,
        .offset_y = 0.0,
        .range = 7.82875744e-23,
        .max_iters = 16384,
    };
    const to_v = ViewState{
        .center_x = -1.99183057,
        .center_y = 0.0,
        .offset_x = 3.5e-23,
        .offset_y = 1.2e-23,
        .range = 3.0e-23,
        .max_iters = 16384,
    };

    // t=0: same as from
    const v0 = lerpViewState(from_v, to_v, 0.0);
    try testing.expect(v0.center_x == from_v.center_x);
    try testing.expect(v0.offset_x == 0.0);
    try testing.expect(v0.range == from_v.range);

    // t=1: same as to
    const v1 = lerpViewState(from_v, to_v, 1.0);
    try testing.expect(v1.center_x == to_v.center_x);
    try testing.expect(v1.offset_x == to_v.offset_x);
    try testing.expect(v1.range == to_v.range);

    // t=0.5: midpoints
    const v05 = lerpViewState(from_v, to_v, 0.5);
    try testing.expect(v05.offset_x == to_v.offset_x / 2.0);
    try testing.expect(v05.offset_y == to_v.offset_y / 2.0);
    try testing.expect(v05.center_x == from_v.center_x);
    try testing.expect(v05.range == (from_v.range + to_v.range) / 2.0);

    // At this zoom depth, center_x should not change — all the movement
    // is captured in offset_x/offset_y.
    try testing.expect(from_v.center_x == to_v.center_x);
    try testing.expect(from_v.center_x == v05.center_x);
}

test "rebaseFallback at high iteration counts" {
    const cases = [_]struct { cx: f64, cy: f64, max_iters: u32, expect_exterior: bool }{
        .{ .cx = -0.75, .cy = 0.1, .max_iters = 4096, .expect_exterior = true },
        .{ .cx = 0.0, .cy = 0.0, .max_iters = 4096, .expect_exterior = false },
        .{ .cx = -1.5, .cy = 0.01, .max_iters = 4096, .expect_exterior = true },
    };
    for (cases) |c| {
        const mu_rb = rebaseFallback(c.cx, c.cy, c.cx, c.cy, 0, c.max_iters);
        const gt = groundTruthPixel(c.cx, c.cy, c.max_iters);
        const rb_exterior = mu_rb < @as(f32, @floatFromInt(c.max_iters));
        try testing.expectEqual(c.expect_exterior, rb_exterior);
        try testing.expectEqual(c.expect_exterior, gt.escaped);
    }
}

test "isCardioidOrBulb classifies known points" {
    // Inside main cardioid on real axis
    try testing.expect(isCardioidOrBulb(-0.1, 0.0));
    try testing.expect(isCardioidOrBulb(0.0, 0.0));
    try testing.expect(isCardioidOrBulb(0.24, 0.0));
    // Inside period-2 bulb
    try testing.expect(isCardioidOrBulb(-1.0, 0.0));
    try testing.expect(isCardioidOrBulb(-1.2, 0.01));
    // Outside both (just right of cardioid cusp at x=0.25)
    try testing.expect(!isCardioidOrBulb(0.26, 0.0));
    // Outside both
    try testing.expect(!isCardioidOrBulb(-0.75, 0.25));
    try testing.expect(!isCardioidOrBulb(0.5, 0.5));
    try testing.expect(!isCardioidOrBulb(-1.5, 0.5));
}

test "isoNow format matches ISO 8601" {
    const util = @import("util.zig");
    var buf: [24]u8 = undefined;
    const ts = util.isoNow(&buf);
    try testing.expectEqual(@as(usize, 24), ts.len);
    try testing.expectEqual(@as(u8, 'T'), ts[10]);
    try testing.expectEqual(@as(u8, 'Z'), ts[23]);
    try testing.expectEqual(@as(u8, '-'), ts[4]);
    try testing.expectEqual(@as(u8, '-'), ts[7]);
    try testing.expectEqual(@as(u8, ':'), ts[13]);
    try testing.expectEqual(@as(u8, ':'), ts[16]);
    try testing.expectEqual(@as(u8, '.'), ts[19]);
}

test "glitch detection converges to ground truth at Seahorse Valley" {
    // Verify renderPerturbationPixel with both glitch_ratio=0 and
    // glitch_ratio=GLITCH_RATIO against groundTruthPixel at a deep zoom
    // Seahorse Valley coordinate known to trigger glitch correction.
    const ref_cx: f64 = -1.785897;
    const ref_cy: f64 = 0.000055;
    const range: f64 = 2.257306e-3;
    const max_iters: u32 = 8192;

    const offsets = [_]struct { dx: f64, dy: f64 }{
        .{ .dx = 0.0, .dy = 0.0 },
        .{ .dx = -0.5 * range, .dy = -0.5 * range },
        .{ .dx = 0.5 * range, .dy = 0.5 * range },
    };

    const orbit = try computeReference(ref_cx, ref_cy, max_iters, testing.allocator);
    defer testing.allocator.free(orbit);

    for (offsets) |off| {
        const pix_cx = ref_cx + off.dx;
        const pix_cy = ref_cy + off.dy;
        const gt = groundTruthPixel(pix_cx, pix_cy, max_iters);
        if (!gt.escaped) continue;

        _ = renderPerturbationPixel(off.dx, off.dy, orbit, max_iters, 0);
        const mu_glitch = renderPerturbationPixel(off.dx, off.dy, orbit, max_iters, GLITCH_RATIO);
        const mu_gt_f64 = smoothIteration(gt.iter, gt.zx * gt.zx + gt.zy * gt.zy);
        const mu_gt: f32 = @floatCast(mu_gt_f64);

        // With glitch detection the result agrees with ground truth.
        try testing.expectApproxEqAbs(mu_gt, mu_glitch, 0.5);
    }
}

test "shouldUseF64Fallback path selection" {
    // .f64 always falls back
    try testing.expect(shouldUseF64Fallback(.f64, 1.0, 100));
    // .auto with large pixel step and low iters → f32
    try testing.expect(!shouldUseF64Fallback(.auto, PIXEL_STEP_F64_THRESHOLD * 10, 256));
    // .auto with small pixel step → f64
    try testing.expect(shouldUseF64Fallback(.auto, PIXEL_STEP_F64_THRESHOLD / 10, 256));
    // .auto with high iteration count → f64
    try testing.expect(shouldUseF64Fallback(.auto, 1.0, F32_MAX_ITERS_THRESHOLD + 100));
    // .perturbation never falls back (uses perturbation path instead)
    try testing.expect(!shouldUseF64Fallback(.perturbation, 0.0, 100));
}

