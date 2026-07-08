const std = @import("std");
const m = @import("mandelbrot.zig");
const PIXEL_CHANNELS = @import("pixel.zig").PIXEL_CHANNELS;
const isoNow = @import("log.zig").isoNow;
const refbank = @import("refbank.zig");
const allocator = @import("allocator.zig");

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
    left_f128: f128,
    top_f128: f128,
    range_x_f128: f128,
    range_y_f128: f128,
    max_iters: u32,
    skip_periodicity: bool,
    render_method: m.RenderMethod,
    deadline_s: f64,
    get_time_fn: *const fn () f64,
    interior_eps_sq: f32,
    periodicity_eps_sq: f32,
    glitch_ratio: f32,
    ref_bank: ?m.RefBank,
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
    const render_fallback_f64 = m.shouldUseF64Fallback(cfg.render_method, pixel_step, max_iters);

    var py = ctx.start_row;
    while (py < ctx.end_row) : (py += 1) {
        if (cfg.rows_completed) |rc| {
            if (rc[py]) continue;
        }
        if (cfg.deadline_s > 0 and cfg.get_time_fn() >= cfg.deadline_s) {
            ctx.timed_out = true;
            return;
        }

        // Pixel-center convention: each pixel samples the centre of its cell.
        //   cx = left + (px + 0.5) * range_x / w
        //   cy = top  + (py + 0.5) * range_y / h
        // This is the standard in Mandelbrot explorers — the image evenly
        // covers [left, right] × [top, bottom] with w×h cells.
        const cy_f64 = cfg.top + (@as(f64, @floatFromInt(py)) + 0.5) * cfg.range_y / @as(f64, @floatFromInt(h));
        const cy: f32 = @floatCast(cy_f64);
        const cy2 = cy * cy;

        // Per-strip y-offset (constant for all x pixels in this strip).
        const half_range_x = 0.5 * cfg.range_x;
        const half_step_x = 0.5 * pixel_step;
        const strip_pixel_oy = ((@as(f64, @floatFromInt(py)) + 0.5) / @as(f64, @floatFromInt(h)) - 0.5) * cfg.range_y;
        const strip_pixel_rel_cy = cfg.offset_y + strip_pixel_oy;

        const pixel_step_f128 = cfg.range_x_f128 / @as(f128, @floatFromInt(w));
        const cy_f128 = cfg.top_f128 + (@as(f128, @floatFromInt(py)) + 0.5) * @as(f128, cfg.range_y_f128) / @as(f128, @floatFromInt(h));

        var px: usize = 0;
        var pixel_rel_cx = cfg.offset_x + half_step_x - half_range_x; // (px+0.5)*step_x - half_range for px=0
        while (px < w) : (px += 1) {
            const cx_f64 = cfg.left + (@as(f64, @floatFromInt(px)) + 0.5) * pixel_step;
            const cx: f32 = @floatCast(cx_f64);

            // Cardioid & period-2 bulb pre-check (always interior, skip iteration).
            if (!cfg.skip_periodicity and m.isCardioidOrBulb(cx, cy2)) continue;

            const max_f: f32 = @as(f32, @floatFromInt(max_iters));
            const pix_idx = (py * w + px) * PIXEL_CHANNELS;

            // Path selection: RefBank perturbation (nearest escaping ref) > f128 fallback (deep zoom / no bank) > f32 standard.
            // Pixel-centre convention used in all paths — see comment above.
            //
            // Nearest-reference lookup and dcx/dcy both use relative coordinates
            // (small ~range terms, not ~|center|) to preserve precision at deep zoom:
            //   pixel_rel_cx = offset_x + (px+0.5)*step_x - half_range
            //   ref.rel_cx   = (grid_col_frac - 0.5) * range_x
            //   dcx          = pixel_rel_cx - ref.rel_cx
            const deep_zoom = pixel_step < m.DEEP_ZOOM_PIXEL_STEP;
            const fpx = m.F128Px{ .left = cfg.left_f128, .step = pixel_step_f128, .px = px, .cy = cy_f128 };
            const mu: f32 = if (cfg.ref_bank) |bank| blk: {
                const ref = bank.nearestByOffset(pixel_rel_cx, strip_pixel_rel_cy) orelse &bank.entries[0];
                const dcx = pixel_rel_cx - ref.rel_cx;
                const dcy = strip_pixel_rel_cy - ref.rel_cy;
                break :blk m.renderPerturbationPixel(dcx, dcy, ref.orbit, max_iters, cfg.glitch_ratio, cx_f64, cy_f64, deep_zoom, fpx);
            } else if (render_fallback_f64)
                m.rebaseFallback(cx_f64, cy_f64, cx_f64, cy_f64, 0, max_iters)
            else
                m.standardPixel(cx, cy, max_iters, cfg.interior_eps_sq, cfg.periodicity_eps_sq);

            pixel_rel_cx += pixel_step;

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
    width: usize,
    height: usize,
    view: m.ViewState,
    clear: bool,
    timeout_s: f64,
    get_time_fn: *const fn () f64,
    rows_completed: ?[]bool,
) !bool {
    const aspect = @as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(height));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x + view.offset_x - range_x / 2.0;
    const left_f128 = @as(f128, view.center_x) + @as(f128, view.offset_x) - @as(f128, range_x) / 2.0;
    const right = view.center_x + view.offset_x + range_x / 2.0;
    const top = view.center_y + view.offset_y - range_y / 2.0;
    const top_f128 = @as(f128, view.center_y) + @as(f128, view.offset_y) - @as(f128, range_y) / 2.0;
    const bottom = view.center_y + view.offset_y + range_y / 2.0;

    if (clear) {
        m.clearToOpaqueBlack(pixels);
    }

    const skip_periodicity = (right < -1.25 or left > 0.25 or
        bottom < -m.CARDIOID_Y_MAX or top > m.CARDIOID_Y_MAX);

    const interior_eps_sq: f32 = m.INTERIOR_BASE_EPSILON_SQ;
    const periodicity_eps_sq: f32 = m.PERIODICITY_BASE_EPSILON_SQ;

    // --- Reference orbit bank ---
    // Build a grid of reference orbits across the viewport.  Each pixel
    // selects the nearest escaping reference, reducing perturbation δ and
    // glitch triggers.  At deep zoom the off-axis candidates often escape
    // even when the viewport center is interior (real-axis case).
    var ref_bank: ?m.RefBank = if (view.render_method != .f64) blk: {
        const grid_cols: usize = 1;
        const grid_rows: usize = 1;
        var bank = refbank.buildRefBank(
            allocator.get(),
            view.center_x, view.center_y,
            range_x, range_y,
            view.max_iters,
            grid_cols, grid_rows,
        ) catch |err| {
            std.debug.print("refbank build error: {}\n", .{err});
            break :blk null;
        };
        if (bank.escapedCount() == 0 and view.render_method != .perturbation) {
            bank.deinit();
            break :blk null;
        }
        {
            var ts_buf: [24]u8 = undefined;
            std.debug.print("{s} [refbank] grid={d}x{d} total={d} escaped={d} range={e:.4}\n", .{
                isoNow(&ts_buf), grid_cols, grid_rows,
                bank.entries.len, bank.escapedCount(), view.range,
            });
        }
        break :blk bank;
    } else null;
    defer if (ref_bank) |*b| b.deinit();

    var num_threads: usize = height / MIN_ROWS_PER_THREAD;
    if (num_threads > MAX_RENDER_THREADS) num_threads = MAX_RENDER_THREADS;
    if (num_threads < 1) num_threads = 1;

    const deadline_s: f64 = if (timeout_s > 0) get_time_fn() + timeout_s else 0;

    const config = RenderConfig{
        .pixels = pixels,
        .w = width,
        .h = height,
        .left = left,
        .top = top,
        .range_x = range_x,
        .range_y = range_y,
        .left_f128 = left_f128,
        .top_f128 = top_f128,
        .range_x_f128 = @as(f128, range_x),
        .range_y_f128 = @as(f128, range_y),
        .max_iters = view.max_iters,
        .skip_periodicity = skip_periodicity,
        .render_method = view.render_method,
        .deadline_s = deadline_s,
        .get_time_fn = get_time_fn,
        .interior_eps_sq = interior_eps_sq,
        .periodicity_eps_sq = periodicity_eps_sq,
        .glitch_ratio = m.GLITCH_RATIO,
        .ref_bank = ref_bank,
        .rows_completed = rows_completed,
        .offset_x = view.offset_x,
        .offset_y = view.offset_y,
    };

    var strips: [MAX_RENDER_THREADS]RenderStrip = undefined;
    var threads: [MAX_RENDER_THREADS]std.Thread = undefined;

    for (0..num_threads) |i| {
        strips[i] = RenderStrip{
            .cfg = &config,
            .start_row = (height * i) / num_threads,
            .end_row = (height * (i + 1)) / num_threads,
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
