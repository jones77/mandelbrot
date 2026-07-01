const std = @import("std");
const m = @import("mandelbrot.zig");

const MAX_RENDER_THREADS: usize = 8;
const MIN_ROWS_PER_THREAD: usize = 32;

const RenderConfig = struct {
    pixels: []u8,
    w: usize,
    h: usize,
    left: f64,
    top: f64,
    range_x: f64,
    range_y: f64,
    max_iters: u32,
    skip_periodicity: bool,
    render_method: m.RenderMethod,
    deadline_s: f64,
    get_time_fn: *const fn () f64,
    interior_eps_sq: f32,
    periodicity_eps_sq: f32,
    glitch_eps_sq: f32,
    ref_orbit: ?[]const m.RefOrbit,
};

const RenderStrip = struct {
    cfg: *const RenderConfig,
    start_row: usize,
    end_row: usize,
    timed_out: bool,
};

fn renderStrip(ctx: *RenderStrip) void {
    const cfg = ctx.cfg;
    const w = cfg.w;
    const h = cfg.h;
    const max_iters = cfg.max_iters;
    if (w < 2 or h < 2) return;

    const pixel_step = cfg.range_x / @as(f64, @floatFromInt(w));
    // When perturbation is unavailable, use f64 rebaseFallback instead of f32 standardPixel.
    const render_fallback_f64 = cfg.render_method == .f64 or (cfg.render_method == .auto and pixel_step < 1.0e-7);

    var py = ctx.start_row;
    while (py < ctx.end_row) : (py += 1) {
        if (cfg.deadline_s > 0 and cfg.get_time_fn() >= cfg.deadline_s) {
            ctx.timed_out = true;
            return;
        }

        const cy_f64 = cfg.top + @as(f64, @floatFromInt(py)) * cfg.range_y / @as(f64, @floatFromInt(h -| 1));
        const cy: f32 = @floatCast(cy_f64);
        const cy2 = cy * cy;

        var px: usize = 0;
        while (px < w) : (px += 1) {
            const cx_f64 = cfg.left + @as(f64, @floatFromInt(px)) * cfg.range_x / @as(f64, @floatFromInt(w -| 1));
            const cx: f32 = @floatCast(cx_f64);

            // Cardioid & period-2 bulb pre-check (always interior, skip iteration).
            // Cardioid: |c - e^(iθ)/2 + e^(2iθ)/4| ≤ 1/4  →  q(q - 1/4) ≤ y²/4.
            // Period-2 bulb: |c + 1| ≤ 1/4.
            if (!cfg.skip_periodicity) {
                const q = (cx - 0.25) * (cx - 0.25) + cy2;
                if (q * (q + (cx - 0.25)) <= 0.25 * cy2) continue;
                if ((cx + 1.0) * (cx + 1.0) + cy2 <= 0.0625) continue;
            }

            const max_f: f32 = @as(f32, @floatFromInt(max_iters));
            const pix_idx = (py * w + px) * 4;

            // Path selection: perturbation (if ref available) > f64 (if deep zoom or high iters) > f32 standard.
            const mu: f32 = if (cfg.ref_orbit) |orbit| blk: {
                const dcx: f32 = @floatCast(cx_f64 - orbit[0].zx);
                const dcy: f32 = @floatCast(cy_f64 - orbit[0].zy);
                var dx: f32 = dcx;
                var dy: f32 = dcy;
                var iter: u32 = 0;

                var result: f32 = max_f;
                while (iter < max_iters) : (iter += 1) {
                    const ref = &orbit[iter];

                    const Zx: f32 = @floatCast(ref.zx);
                    const Zy: f32 = @floatCast(ref.zy);
                    const Z_norm_sq = Zx * Zx + Zy * Zy;

                    // Rebase args (f64) — computed once for all glitch/overflow exits.
                    const rebase_zx = ref.zx + @as(f64, dx);
                    const rebase_zy = ref.zy + @as(f64, dy);
                    const rebase_cx = orbit[0].zx + @as(f64, dcx);
                    const rebase_cy = orbit[0].zy + @as(f64, dcy);
                    const rebase_norm_sq = rebase_zx * rebase_zx + rebase_zy * rebase_zy;

                    // 1. Z overflow check (f32): catch f32 infinity before any f32 ops.
                    if (!std.math.isFinite(Z_norm_sq)) {
                        if (std.math.isFinite(ref.zx + ref.zy)) {
                            result = m.rebaseFallback(rebase_zx, rebase_zy, rebase_cx, rebase_cy, iter, max_iters);
                        } else {
                            result = m.rebaseFallback(rebase_cx, rebase_cy, rebase_cx, rebase_cy, 0, max_iters);
                        }
                        break;
                    }

                    // 2. Pauldelbrot glitch (f64): |z|² / |Z|² < ε.
                    //    Computed in f64 so δ is preserved when |Z| ≫ |δ|.
                    //    Restarts from scratch because δ has f32 rounding error.
                    if (cfg.glitch_eps_sq > 0) {
                        const Z_norm_sq_f64 = ref.zx * ref.zx + ref.zy * ref.zy;
                        if (Z_norm_sq_f64 > @as(f64, m.GLITCH_MIN_NORM_SQ) and
                            rebase_norm_sq < @as(f64, cfg.glitch_eps_sq) * Z_norm_sq_f64)
                        {
                            result = m.rebaseFallback(rebase_cx, rebase_cy, rebase_cx, rebase_cy, 0, max_iters);
                            break;
                        }
                    }

                    // 3. Zhuoran rebasing: |δ|² > |Z|².
                    if (dx * dx + dy * dy > Z_norm_sq) {
                        result = m.rebaseFallback(rebase_zx, rebase_zy, rebase_cx, rebase_cy, iter, max_iters);
                        break;
                    }

                    // 4. Escape check (f64): preserves δ when |Z| ≫ |δ|.
                    if (rebase_norm_sq > m.ESCAPE_RADIUS_SQ) {
                        if (std.math.isFinite(rebase_norm_sq)) {
                            result = @floatCast(m.smoothIteration(iter, rebase_norm_sq));
                        } else if (std.math.isFinite(ref.zx + ref.zy)) {
                            result = m.rebaseFallback(rebase_zx, rebase_zy, rebase_cx, rebase_cy, iter, max_iters);
                        } else {
                            result = m.rebaseFallback(rebase_cx, rebase_cy, rebase_cx, rebase_cy, 0, max_iters);
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
                break :blk result;
            } else if (render_fallback_f64 or max_iters > m.F32_MAX_ITERS_THRESHOLD)
                m.rebaseFallback(cx_f64, cy_f64, cx_f64, cy_f64, 0, max_iters)
            else m.standardPixel(cx, cy, max_iters, cfg.interior_eps_sq, cfg.periodicity_eps_sq);

            if (mu >= max_f) continue;
            const color = m.smoothColor(@as(f64, mu), max_iters);
            cfg.pixels[pix_idx + 0] = color[0];
            cfg.pixels[pix_idx + 1] = color[1];
            cfg.pixels[pix_idx + 2] = color[2];
            cfg.pixels[pix_idx + 3] = color[3];
        }
    }
}

fn logTimeout(view: m.ViewState, timeout_s: f64) void {
    std.debug.print(
        \\TIMEOUT: Mandelbrot render exceeded {d:.0}s
        \\  To recreate: center=({d:.16}, {d:.16})
        \\  range={e:.4}  iters={d}
        \\
    , .{
        timeout_s,
        view.center_x,
        view.center_y,
        view.range,
        view.max_iters,
    });
}

pub fn renderMandelbrot(
    pixels: []u8,
    w: usize,
    h: usize,
    view: m.ViewState,
    clear: bool,
    timeout_s: f64,
    get_time_fn: *const fn () f64,
) !bool {
    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x - range_x / 2.0;
    const right = view.center_x + range_x / 2.0;
    const top = view.center_y - range_y / 2.0;
    const bottom = view.center_y + range_y / 2.0;

    if (clear) {
        m.clearToOpaqueBlack(pixels);
    }

    const skip_periodicity = (right < -1.25 or left > 0.25 or
        bottom < -m.CARDIOID_Y_MAX or top > m.CARDIOID_Y_MAX);

    const interior_eps_sq: f32 = m.INTERIOR_BASE_EPSILON_SQ;
    const periodicity_eps_sq: f32 = m.PERIODICITY_BASE_EPSILON_SQ;

    const ref_orbit = if (view.render_method != .f64)
        try m.computeReference(view.center_x, view.center_y, view.max_iters, std.heap.page_allocator)
    else
        null;
    defer if (ref_orbit) |orbit| std.heap.page_allocator.free(orbit);

    var num_threads: usize = h / MIN_ROWS_PER_THREAD;
    if (num_threads > MAX_RENDER_THREADS) num_threads = MAX_RENDER_THREADS;
    if (num_threads < 1) num_threads = 1;

    const deadline_s: f64 = if (timeout_s > 0) get_time_fn() + timeout_s else 0;

    const config = RenderConfig{
        .pixels = pixels,
        .w = w,
        .h = h,
        .left = left,
        .top = top,
        .range_x = range_x,
        .range_y = range_y,
        .max_iters = view.max_iters,
        .skip_periodicity = skip_periodicity,
        .render_method = view.render_method,
        .deadline_s = deadline_s,
        .get_time_fn = get_time_fn,
        .interior_eps_sq = interior_eps_sq,
        .periodicity_eps_sq = periodicity_eps_sq,
        .glitch_eps_sq = m.GLITCH_EPSILON,
        .ref_orbit = ref_orbit,
    };

    var strips: [MAX_RENDER_THREADS]RenderStrip = undefined;
    var threads: [MAX_RENDER_THREADS]std.Thread = undefined;

    for (0..num_threads) |i| {
        strips[i] = RenderStrip{
            .cfg = &config,
            .start_row = (h * i) / num_threads,
            .end_row = (h * (i + 1)) / num_threads,
            .timed_out = false,
        };
        threads[i] = try std.Thread.spawn(.{}, renderStrip, .{&strips[i]});
    }
    for (0..num_threads) |i| {
        threads[i].join();
    }

    for (0..num_threads) |i| {
        if (strips[i].timed_out) {
            logTimeout(view, timeout_s);
            return true;
        }
    }
    return false;
}
