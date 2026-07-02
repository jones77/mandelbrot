const std = @import("std");
const m = @import("mandelbrot.zig");
const PIXEL_CHANNELS = @import("util.zig").PIXEL_CHANNELS;
const isoNow = @import("util.zig").isoNow;

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
    glitch_ratio: f32,
    ref_orbit: ?[]const m.RefOrbit,
    rows_completed: ?[]bool,
    offset_x: f64,
    offset_y: f64,
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
    const render_fallback_f64 = cfg.render_method == .f64 or (cfg.render_method == .auto and pixel_step < m.PIXEL_STEP_F64_THRESHOLD);

    var py = ctx.start_row;
    while (py < ctx.end_row) : (py += 1) {
        if (cfg.rows_completed) |rc| {
            if (rc[py]) continue;
        }
        if (cfg.deadline_s > 0 and cfg.get_time_fn() >= cfg.deadline_s) {
            ctx.timed_out = true;
            return;
        }

        const cy_f64 = cfg.top + @as(f64, @floatFromInt(py)) * cfg.range_y / @as(f64, @floatFromInt(h));
        const cy: f32 = @floatCast(cy_f64);
        const cy2 = cy * cy;

        var px: usize = 0;
        while (px < w) : (px += 1) {
            const cx_f64 = cfg.left + @as(f64, @floatFromInt(px)) * cfg.range_x / @as(f64, @floatFromInt(w));
            const cx: f32 = @floatCast(cx_f64);

            // Cardioid & period-2 bulb pre-check (always interior, skip iteration).
            if (!cfg.skip_periodicity and m.isCardioidOrBulb(cx, cy2)) continue;

            const max_f: f32 = @as(f32, @floatFromInt(max_iters));
            const pix_idx = (py * w + px) * PIXEL_CHANNELS;

            // Path selection: perturbation (if ref available) > f64 (if deep zoom or high iters) > f32 standard.
            const mu: f32 = if (cfg.ref_orbit) |orbit| blk: {
                const dcx = @as(f64, @floatFromInt(px)) * cfg.range_x / @as(f64, @floatFromInt(w)) - 0.5 * cfg.range_x + cfg.offset_x;
                const dcy = @as(f64, @floatFromInt(py)) * cfg.range_y / @as(f64, @floatFromInt(h)) - 0.5 * cfg.range_y + cfg.offset_y;
                break :blk m.renderPerturbationPixel(dcx, dcy, orbit, max_iters, cfg.glitch_ratio);
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
        if (cfg.rows_completed) |rc| rc[py] = true;
    }
}

fn logTimeout(view: m.ViewState, timeout_s: f64) void {
    var ts_buf: [24]u8 = undefined;
    const ts = isoNow(&ts_buf);
    std.debug.print(
        \\{s} [render] timeout
        \\   exceeded {d:.0}s
        \\   center=({d:.16}, {d:.16})
        \\   range={e:.4}  iters={d}
        \\
    , .{
        ts,
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
    rows_completed: ?[]bool,
) !bool {
    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x + view.offset_x - range_x / 2.0;
    const right = view.center_x + view.offset_x + range_x / 2.0;
    const top = view.center_y + view.offset_y - range_y / 2.0;
    const bottom = view.center_y + view.offset_y + range_y / 2.0;

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
        .glitch_ratio = m.GLITCH_RATIO,
        .ref_orbit = ref_orbit,
        .rows_completed = rows_completed,
        .offset_x = view.offset_x,
        .offset_y = view.offset_y,
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
