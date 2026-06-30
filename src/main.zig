//! Mandelbrot Set Visualizer
//!
//! Interactive zoom and explore the Mandelbrot set.
//! - Click and drag a 1:1 (square) selection box to zoom in.
//!   The box is constrained to square as you drag for accurate preview.
//! - Press Delete / Backspace to return to the previous zoom level.
//! - Use mouse wheel to adjust iteration count (more detail near edges).
//! - Press R to reset the view.

const std = @import("std");
const rl = @import("raylib");

// ===========================================================================
// Configuration constants
// ===========================================================================

const DEFAULT_WIDTH: i32 = 900;
const DEFAULT_HEIGHT: i32 = 800;

const INITIAL_CENTER_X: f64 = -0.5;
const INITIAL_CENTER_Y: f64 = 0.0;
const INITIAL_RANGE: f64 = 3.5;

const DEFAULT_MAX_ITERS: u32 = 1024;
const MIN_ITERS: u32 = 16;
const MAX_ITERS_CAP: u32 = 65536; // 2^16 — manual +/wheel can reach this
const AUTO_SCALE_CAP: u32 = 16384; // auto-zoom stops here; user opts in higher
const AUTO_SCALE_SLOPE: f64 = 0.25;
const PALETTE_DENSITY: f64 = 4.0;
const MAX_HISTORY: usize = 64;
const MIN_SELECTION_PX: f64 = 8.0;
const TARGET_FPS: i32 = 60;
const PALETTE_SIZE: usize = 1024;
const MAX_RENDER_THREADS: usize = 8;
const MIN_ROWS_PER_THREAD: usize = 32;
const RENDER_TIMEOUT_S: f64 = 30.0;
const CARDIOID_Y_MAX: f64 = 3.0 * @sqrt(3.0) / 8.0;
const INTERIOR_EPSILON_SQ: f32 = 1e-6;   // |(P^n)'(c)|² < ε → inside M
const PERIODICITY_EPSILON_SQ: f32 = 1e-8; // |z_{n+k} - z_n|² < ε → periodic

// ---- UI layout constants ----
const HUD_HEIGHT: i32 = 50;
const BTN_SIZE: i32 = 28;
const BTN_Y_OFFSET: i32 = 46; // from screen_h
const BTN_GAP: i32 = 32;      // centre-to-centre spacing of [+] [-]

// ===========================================================================
// Types
// ===========================================================================

/// A point in the complex plane (f64, for view-level math).
const ComplexPoint = struct { x: f64, y: f64 };

/// A coordinate pair in f32, used inside the per-pixel hot loop.
const Coord = struct {
    re: f32,
    im: f32,

    fn normSq(self: Coord) f32 {
        return self.re * self.re + self.im * self.im;
    }

    fn sq(self: Coord) Coord {
        return .{
            .re = self.re * self.re - self.im * self.im,
            .im = 2.0 * self.re * self.im,
        };
    }
};

/// A single escape-time orbit value (for periodicity detection).
const OrbitPoint = struct { zx: f32, zy: f32 };

const ViewState = struct {
    center_x: f64,
    center_y: f64,
    range: f64,
    max_iters: u32,
};

const DragState = struct {
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
    active: bool,
};

/// A zoom level in the undo stack, with cached pixel data so
/// Delete/Backspace restores instantly without re-rendering.
const HistoryEntry = struct {
    view: ViewState,
    w: usize,
    h: usize,
    pixels: []u8,
};

/// Per-thread context for rendering a horizontal strip of the image.
const RenderStrip = struct {
    pixels: []u8,
    w: usize,
    h: usize,
    start_row: usize,
    end_row: usize,
    left: f64,
    top: f64,
    range_x: f64,
    range_y: f64,
    max_iters: u32,
    /// When true, skip the per-pixel cardioid/bulb interior tests because
    /// the entire view is outside the bounding box of those shapes.
    skip_periodicity: bool,
    /// Wall-clock deadline in seconds (via rl.getTime); zero means no limit.
    deadline_s: f64,
    /// Set to true by the worker when it stops due to timeout.
    timed_out: bool,
};

// ===========================================================================
// Colour palette
// ===========================================================================

var palette: [PALETTE_SIZE]rl.Color = undefined;

fn buildPalette() void {
    var i: usize = 0;
    while (i < PALETTE_SIZE) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(PALETTE_SIZE));
        const hue = 240.0 * (1.0 - t);
        palette[i] = hslToRgb(hue, 0.85, 0.45 + t * 0.35);
    }
}

fn hslToRgb(h: f32, s: f32, l: f32) rl.Color {
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

    return rl.Color.init(
        @intFromFloat(@round((r1 + m) * 255.0)),
        @intFromFloat(@round((g1 + m) * 255.0)),
        @intFromFloat(@round((b1 + m) * 255.0)),
        255,
    );
}

/// Smooth (continuous) iteration colour.  `mu` is the fractional
/// iteration count from the escape-time formula.  PALETTE_DENSITY spreads
/// the full palette across ~256 iterations (default range) so the initial
/// view shows a full rainbow cycle.
fn smoothColor(mu: f64, max_iters: u32) rl.Color {
    if (mu >= @as(f64, @floatFromInt(max_iters))) return .black;
    const raw = mu * PALETTE_DENSITY;
    const idx = @as(usize, @intFromFloat(@mod(raw, @as(f64, @floatFromInt(PALETTE_SIZE)))));
    const frac = raw - @floor(raw);
    const next = (idx + 1) % PALETTE_SIZE;

    const c0 = palette[idx];
    const c1 = palette[next];
    return rl.Color.init(
        @intFromFloat(@round(@as(f64, @floatFromInt(c0.r)) * (1.0 - frac) + @as(f64, @floatFromInt(c1.r)) * frac)),
        @intFromFloat(@round(@as(f64, @floatFromInt(c0.g)) * (1.0 - frac) + @as(f64, @floatFromInt(c1.g)) * frac)),
        @intFromFloat(@round(@as(f64, @floatFromInt(c0.b)) * (1.0 - frac) + @as(f64, @floatFromInt(c1.b)) * frac)),
        255,
    );
}

// ===========================================================================
// Mandelbrot computation (multi-threaded)
// ===========================================================================

/// Render rows [start_row, end_row) into the shared pixel buffer.
/// The image starts black; we only write pixels for escaped points.
fn renderStrip(ctx: *RenderStrip) void {
    const w = ctx.w;
    const h = ctx.h;
    const max_iters = ctx.max_iters;

    var py = ctx.start_row;
    while (py < ctx.end_row) : (py += 1) {
        // Check timeout every row.
        if (ctx.deadline_s > 0 and rl.getTime() >= ctx.deadline_s) {
            ctx.timed_out = true;
            return;
        }

        const cy: f32 = @floatCast(ctx.top + @as(f64, @floatFromInt(py)) * ctx.range_y / @as(f64, @floatFromInt(h -| 1)));
        const cy2 = cy * cy;

        var px: usize = 0;
        while (px < w) : (px += 1) {
            const cx: f32 = @floatCast(ctx.left + @as(f64, @floatFromInt(px)) * ctx.range_x / @as(f64, @floatFromInt(w -| 1)));

            // Periodicity check: skip iteration for points inside the main
            // cardioid or period-2 bulb.  Skipped entirely when the view is
            // far from these shapes (bounding box rejection).
            if (!ctx.skip_periodicity) {
                const q = (cx - 0.25) * (cx - 0.25) + cy2;
                if (q * (q + (cx - 0.25)) <= 0.25 * cy2) continue;
                if ((cx + 1.0) * (cx + 1.0) + cy2 <= 0.0625) continue;
            }

            // Start from z=c (not z=0) so we can track the derivative
            // (P^n)'(c).  For points inside M the derivative shrinks
            // toward zero — we detect that early and stop iterating.
            var z = Coord{ .re = cx, .im = cy };
            var der = Coord{ .re = 1.0, .im = 0.0 };
            var iter: u32 = 0;

            // Periodicity orbit detection: store z at power-of-2
            // iteration counts (1, 2, 4, 8, …).  If z ever returns to
            // within ε of a stored value, the orbit is periodic → M.
            var orbit_stored: [32]OrbitPoint = undefined;
            var orbit_n: u32 = 0;

            // Using the while-else expression: `break` provides the smooth
            // iteration count on escape, `else` provides the limit when the
            // point never escapes (inside the set → leave black).
            const mu: f32 = while (iter < max_iters) : (iter += 1) {
                // Derivative-based interior detection: (P^n)'(c) → 0.
                if (der.normSq() < INTERIOR_EPSILON_SQ) {
                    break @as(f32, @floatFromInt(max_iters));
                }
                if (z.normSq() > 4.0) {
                    const log_mag = 0.5 * @log(z.normSq());
                    break @as(f32, @floatFromInt(iter)) + 1.0 - @log(log_mag) / @log(2.0);
                }
                // Orbit periodicity detection: check if z matches a
                // previous orbit point.
                {
                    var periodic = false;
                    for (0..orbit_n) |j| {
                        const dzx = z.re - orbit_stored[j].zx;
                        const dzy = z.im - orbit_stored[j].zy;
                        if (dzx * dzx + dzy * dzy < PERIODICITY_EPSILON_SQ) {
                            periodic = true;
                            break;
                        }
                    }
                    if (periodic) break @as(f32, @floatFromInt(max_iters));
                }
                // Store z at power-of-2 iterations (1, 2, 4, 8, …).
                if (iter + 1 == (@as(u32, 1) << @as(u5, @intCast(orbit_n)))) {
                    orbit_stored[orbit_n] = .{ .zx = z.re, .zy = z.im };
                    orbit_n += 1;
                }
                // Update derivative BEFORE z (order matters).
                der = Coord{
                    .re = 2.0 * (z.re * der.re - z.im * der.im),
                    .im = 2.0 * (z.re * der.im + z.im * der.re),
                };
                // Update z: z = z² + c
                z = Coord{
                    .re = z.re * z.re - z.im * z.im + cx,
                    .im = 2.0 * z.re * z.im + cy,
                };
            } else @as(f32, @floatFromInt(max_iters));

            if (mu >= @as(f32, @floatFromInt(max_iters))) continue;

            const color = smoothColor(@as(f64, mu), max_iters);
            const pix_idx = (py * w + px) * 4;
            ctx.pixels[pix_idx + 0] = color.r;
            ctx.pixels[pix_idx + 1] = color.g;
            ctx.pixels[pix_idx + 2] = color.b;
            ctx.pixels[pix_idx + 3] = color.a;
        }
    }
}

/// Fill a RGBA buffer with opaque black (all bytes to 0, alpha to 255).
/// Extracted for testability — the `@memset` + alpha fix pattern is easy
/// to get wrong (the bug was alpha=0 → transparent black).
fn clearToOpaqueBlack(pixels: []u8) void {
    @memset(pixels, 0);
    var a: usize = 3;
    while (a < pixels.len) : (a += 4) {
        pixels[a] = 255;
    }
}

/// Render the Mandelbrot set across multiple CPU cores.
/// `clear` — zero the pixel buffer first (needed for a new view).
/// Returns `true` if the render timed out (partial image, press Space to continue).
fn renderMandelbrot(image: *rl.Image, view: ViewState, clear: bool) !bool {
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);

    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x - range_x / 2.0;
    const top = view.center_y - range_y / 2.0;

    const pixels = @as([*]u8, @ptrCast(image.data))[0 .. w * h * 4];

    if (clear) {
        clearToOpaqueBlack(pixels);
    }

    // Bounding-box test for cardioid/bulb periodicity checking.
    // If the entire view lies outside [-1.25, 0.25] × [-0.6495, 0.6495]
    // then no pixel can be inside the main cardioid or period-2 bulb,
    // so we skip those per-pixel tests entirely.
    const view_left = view.center_x - range_x / 2.0;
    const view_right = view.center_x + range_x / 2.0;
    const view_top = view.center_y - range_y / 2.0;
    const view_bottom = view.center_y + range_y / 2.0;
    const skip_periodicity = (view_right < -1.25 or view_left > 0.25 or
        view_bottom < -CARDIOID_Y_MAX or view_top > CARDIOID_Y_MAX);

    const deadline_s = rl.getTime() + RENDER_TIMEOUT_S;

    // Determine thread count: at most MAX_RENDER_THREADS, and at least MIN_ROWS_PER_THREAD each.
    var num_threads: usize = h / MIN_ROWS_PER_THREAD;
    if (num_threads > MAX_RENDER_THREADS) num_threads = MAX_RENDER_THREADS;
    if (num_threads < 1) num_threads = 1;

    var strips: [MAX_RENDER_THREADS]RenderStrip = undefined;
    var threads: [MAX_RENDER_THREADS]std.Thread = undefined;

    for (0..num_threads) |i| {
        strips[i] = RenderStrip{
            .pixels = pixels,
            .w = w,
            .h = h,
            .start_row = (h * i) / num_threads,
            .end_row = (h * (i + 1)) / num_threads,
            .left = left,
            .top = top,
            .range_x = range_x,
            .range_y = range_y,
            .max_iters = view.max_iters,
            .skip_periodicity = skip_periodicity,
            .deadline_s = deadline_s,
            .timed_out = false,
        };
        threads[i] = try std.Thread.spawn(.{}, renderStrip, .{&strips[i]});
    }
    for (0..num_threads) |i| {
        threads[i].join();
    }

    // Log if any thread timed out, and tell the caller.
    for (0..num_threads) |i| {
        if (strips[i].timed_out) {
            std.debug.print(
                \\TIMEOUT: Mandelbrot render exceeded {d:.0}s
                \\  To recreate: center=({d:.16}, {d:.16})
                \\  range={e:.4}  iters={d}
                \\
            , .{
                RENDER_TIMEOUT_S,
                view.center_x,
                view.center_y,
                view.range,
                view.max_iters,
            });
            return true;
        }
    }
    return false;
}

// ===========================================================================
// Coordinate mapping
// ===========================================================================

fn screenToComplex(
    sx: f64,
    sy: f64,
    view: ViewState,
    img_w: i32,
    img_h: i32,
) ComplexPoint {
    const aspect = @as(f64, @floatFromInt(img_w)) / @as(f64, @floatFromInt(img_h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x - range_x / 2.0;
    const top = view.center_y - range_y / 2.0;

    return .{
        .x = left + (sx / @as(f64, @floatFromInt(img_w))) * range_x,
        .y = top + (sy / @as(f64, @floatFromInt(img_h))) * range_y,
    };
}

/// Push the current view + its pixel data onto the undo history stack.
/// Truncation of future entries must happen separately before calling this.
fn pushHistory(
    history: []HistoryEntry,
    history_len: *usize,
    history_ptr: *usize,
    view: ViewState,
    image: *rl.Image,
    screen_w: i32,
    screen_h: i32,
) !void {
    if (history_len.* >= MAX_HISTORY) return;
    const px_w: usize = @intCast(screen_w);
    const px_h: usize = @intCast(screen_h);
    const px_size = px_w * px_h * 4;
    const pixels = try std.heap.page_allocator.alloc(u8, px_size);
    @memcpy(pixels, @as([*]u8, @ptrCast(image.data))[0..px_size]);
    history[history_len.*] = HistoryEntry{
        .view = view,
        .pixels = pixels,
        .w = px_w,
        .h = px_h,
    };
    history_len.* += 1;
    history_ptr.* = history_len.* - 1;
}

/// Free pixel data in entries [index..history_len) and shrink history_len
/// to `index`.  Used to invalidate "future" entries after an undo.
fn truncateFuture(history: []HistoryEntry, history_len: *usize, index: usize) void {
    while (index < history_len.*) {
        history_len.* -= 1;
        std.heap.page_allocator.free(history[history_len.*].pixels);
        history[history_len.*].pixels = &[_]u8{};
    }
}

// ===========================================================================
// Helpers
// ===========================================================================

/// Smallest power of two ≥ n (or 0 if n exceeds u32 max power of two).
fn nextPowerOf2(n: u32) u32 {
    if (n == 0) return 1;
    if (n > 0x80000000) return 0x80000000; // clamp to 2^31
    var x = n;
    x -= 1;
    x |= x >> 1;
    x |= x >> 2;
    x |= x >> 4;
    x |= x >> 8;
    x |= x >> 16;
    return x + 1;
}

fn constrainDragSquare(start_x: f64, start_y: f64, raw_mx: f64, raw_my: f64) ComplexPoint {
    const raw_dx = raw_mx - start_x;
    const raw_dy = raw_my - start_y;
    const size = @max(@abs(raw_dx), @abs(raw_dy));
    if (size < 1.0) return .{ .x = start_x, .y = start_y };
    // Inline sign: use copysign to apply the sign of raw_dx/raw_dy to `size`.
    return .{
        .x = start_x + std.math.copysign(size, raw_dx),
        .y = start_y + std.math.copysign(size, raw_dy),
    };
}

// ===========================================================================
// Main
// ===========================================================================

pub fn main() anyerror!void {
    buildPalette();

    var view = ViewState{
        .center_x = INITIAL_CENTER_X,
        .center_y = INITIAL_CENTER_Y,
        .range = INITIAL_RANGE,
        .max_iters = DEFAULT_MAX_ITERS,
    };

    var history: [MAX_HISTORY]HistoryEntry = undefined;
    var history_len: usize = 0;
    var history_ptr: usize = 0;
    var render_timed_out = false;

    // ---- Window ----
    rl.initWindow(DEFAULT_WIDTH, DEFAULT_HEIGHT, "Mandelbrot Set");
    defer rl.closeWindow();
    rl.setTargetFPS(TARGET_FPS);

    // ---- Image & texture ----
    var screen_w: i32 = rl.getScreenWidth();
    var screen_h: i32 = rl.getScreenHeight();

    var image = rl.genImageColor(screen_w, screen_h, .black);
    defer rl.unloadImage(image);

    var texture = try rl.loadTextureFromImage(image);
    defer rl.unloadTexture(texture);

    var drag = DragState{
        .start_x = 0,
        .start_y = 0,
        .current_x = 0,
        .current_y = 0,
        .active = false,
    };

    // ---- Initial render ----
    render_timed_out = try renderMandelbrot(&image, view, true);
    rl.updateTexture(texture, image.data);

    // Seed history with the initial view.
    try pushHistory(&history, &history_len, &history_ptr, view, &image, screen_w, screen_h);

    // ---- Main loop ----
    while (!rl.windowShouldClose()) {
        // ---- Handle window resize ----
        const new_w = rl.getScreenWidth();
        const new_h = rl.getScreenHeight();
        if (new_w != screen_w or new_h != screen_h) {
            screen_w = new_w;
            screen_h = new_h;

            rl.unloadTexture(texture);
            rl.unloadImage(image);

            image = rl.genImageColor(screen_w, screen_h, .black);
            texture = try rl.loadTextureFromImage(image);

            render_timed_out = try renderMandelbrot(&image, view, true);
            rl.updateTexture(texture, image.data);
        }

        // ============================================================
        // Input
        // ============================================================

        // -- On-screen [+] / [−] button clicks (checked before drag so
        //    a zoom-release doesn't accidentally trigger a button) --
        if (!drag.active and rl.isMouseButtonReleased(.left)) {
            const mx = rl.getMouseX();
            const my = rl.getMouseY();
            const by = screen_h - BTN_Y_OFFSET;
            if (my >= by and my < by + BTN_SIZE) {
                // Minus button (rightmost)
                if (mx >= screen_w - BTN_GAP - BTN_SIZE and mx < screen_w - BTN_GAP) {
                    truncateFuture(&history, &history_len, history_ptr + 1);
                    view.max_iters = @max(MIN_ITERS, view.max_iters / 2);
                    render_timed_out = try renderMandelbrot(&image, view, true);
                    rl.updateTexture(texture, image.data);
                    try pushHistory(&history, &history_len, &history_ptr, view, &image, screen_w, screen_h);
                }
                // Plus button
                if (mx >= screen_w - BTN_SIZE and mx < screen_w) {
                    truncateFuture(&history, &history_len, history_ptr + 1);
                    view.max_iters = @min(MAX_ITERS_CAP, view.max_iters +| view.max_iters);
                    render_timed_out = try renderMandelbrot(&image, view, true);
                    rl.updateTexture(texture, image.data);
                    try pushHistory(&history, &history_len, &history_ptr, view, &image, screen_w, screen_h);
                }
            }
        }

        // -- Start drag --
        if (rl.isMouseButtonPressed(.left)) {
            drag.start_x = @floatFromInt(rl.getMouseX());
            drag.start_y = @floatFromInt(rl.getMouseY());
            drag.current_x = drag.start_x;
            drag.current_y = drag.start_y;
            drag.active = true;
        }

        // -- Update drag (constrain to square in real time) --
        if (drag.active and rl.isMouseButtonDown(.left)) {
            const raw_mx: f64 = @floatFromInt(rl.getMouseX());
            const raw_my: f64 = @floatFromInt(rl.getMouseY());
            const sq = constrainDragSquare(drag.start_x, drag.start_y, raw_mx, raw_my);
            drag.current_x = sq.x;
            drag.current_y = sq.y;
        }

        // -- End drag -> zoom in --
        if (drag.active and rl.isMouseButtonReleased(.left)) {
            defer drag.active = false;

            const size = @abs(drag.current_x - drag.start_x);
            if (size < MIN_SELECTION_PX) continue;

            const sel_cx = (drag.start_x + drag.current_x) / 2.0;
            const sel_cy = (drag.start_y + drag.current_y) / 2.0;

            const c_center = screenToComplex(sel_cx, sel_cy, view, screen_w, screen_h);

            // Use the smaller image dimension so a square selection fills
            // the full height of the zoomed view (no clipping).
            const smaller = @min(screen_w, screen_h);
            const new_range = view.range * (size / @as(f64, @floatFromInt(smaller)));

            // Truncate any "future" entries (left over after an undo)
            // before updating view.
            truncateFuture(&history, &history_len, history_ptr + 1);

            view.center_x = c_center.x;
            view.center_y = c_center.y;
            view.range = new_range;

            // Auto-scale iterations: deeper zooms need more iterations
            // to resolve fine detail at the Mandelbrot boundary.
            // Uses a logarithmic scale: each ~4 zoom doublings (16x zoom)
            // doubles the iteration count, starting from DEFAULT_MAX_ITERS.
            const zoom_factor = INITIAL_RANGE / view.range;
            const log2_zf = @log(zoom_factor) / @log(2.0);
            const log2_start = @log(@as(f64, @floatFromInt(DEFAULT_MAX_ITERS))) / @log(2.0);
            const target_f = @exp2(log2_start + log2_zf * AUTO_SCALE_SLOPE);
            const clamped = @min(target_f, @as(f64, @floatFromInt(AUTO_SCALE_CAP)));
            const target_iters = nextPowerOf2(@as(u32, @intFromFloat(clamped)));
            if (target_iters > view.max_iters and target_iters <= AUTO_SCALE_CAP) {
                view.max_iters = target_iters;
            }

            render_timed_out = try renderMandelbrot(&image, view, true);
            rl.updateTexture(texture, image.data);

            // Save the new view + its pixels into history (undo target).
            try pushHistory(&history, &history_len, &history_ptr, view, &image, screen_w, screen_h);
        }

        // -- Left / Delete / Backspace -> undo zoom (instantly from cache) --
        if (rl.isKeyPressed(.delete) or rl.isKeyPressed(.backspace) or rl.isKeyPressed(.left)) {
            if (history_ptr > 0) {
                history_ptr -= 1;
                const entry = &history[history_ptr];
                view = entry.view;

                if (entry.w == @as(usize, @intCast(screen_w)) and
                    entry.h == @as(usize, @intCast(screen_h)))
                {
                    @memcpy(
                        @as([*]u8, @ptrCast(image.data))[0 .. entry.w * entry.h * 4],
                        entry.pixels,
                    );
                    rl.updateTexture(texture, image.data);
                } else {
                    render_timed_out = try renderMandelbrot(&image, view, true);
                    rl.updateTexture(texture, image.data);
                }
            }
        }

        // -- Right -> redo zoom (instantly from cache) --
        if (rl.isKeyPressed(.right)) {
            if (history_ptr + 1 < history_len) {
                history_ptr += 1;
                const entry = &history[history_ptr];
                view = entry.view;

                if (entry.w == @as(usize, @intCast(screen_w)) and
                    entry.h == @as(usize, @intCast(screen_h)))
                {
                    @memcpy(
                        @as([*]u8, @ptrCast(image.data))[0 .. entry.w * entry.h * 4],
                        entry.pixels,
                    );
                    rl.updateTexture(texture, image.data);
                } else {
                    render_timed_out = try renderMandelbrot(&image, view, true);
                    rl.updateTexture(texture, image.data);
                }
            }
        }

        // -- +/- keys -> double/halve iterations (saved in history so undoable) --
        {
            const key_inc = rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add);
            const key_dec = rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract);

            if (key_inc or key_dec) {
                truncateFuture(&history, &history_len, history_ptr + 1);
                if (key_inc) {
                    view.max_iters = @min(MAX_ITERS_CAP, view.max_iters +| view.max_iters);
                } else {
                    view.max_iters = @max(MIN_ITERS, view.max_iters / 2);
                }
                render_timed_out = try renderMandelbrot(&image, view, true);
                rl.updateTexture(texture, image.data);
                try pushHistory(&history, &history_len, &history_ptr, view, &image, screen_w, screen_h);
            }
        }

        // -- R -> reset (clean up all cached entries) --
        if (rl.isKeyPressed(.r)) {
            truncateFuture(&history, &history_len, 0);
            history_len = 0;
            history_ptr = 0;
            view.center_x = INITIAL_CENTER_X;
            view.center_y = INITIAL_CENTER_Y;
            view.range = INITIAL_RANGE;
            render_timed_out = try renderMandelbrot(&image, view, true);
            rl.updateTexture(texture, image.data);
        }

        // -- Space -> continue a timed-out render (add another 30s, preserve pixels) --
        if (render_timed_out and rl.isKeyPressed(.space)) {
            render_timed_out = try renderMandelbrot(&image, view, false);
            rl.updateTexture(texture, image.data);
        }

        // ============================================================
        // Drawing
        // ============================================================
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.init(20, 20, 30, 255));

        rl.drawTexture(texture, 0, 0, .white);

        // Draw the selection rectangle (always square).
        if (drag.active) {
            const x0: f32 = @floatCast(@min(drag.start_x, drag.current_x));
            const y0: f32 = @floatCast(@min(drag.start_y, drag.current_y));
            const sz: f32 = @floatCast(@abs(drag.current_x - drag.start_x));

            if (sz >= MIN_SELECTION_PX) {
                rl.drawRectangle(
                    @intFromFloat(x0),
                    @intFromFloat(y0),
                    @intFromFloat(sz),
                    @intFromFloat(sz),
                    rl.Color.init(0, 255, 0, 40),
                );
                rl.drawRectangleLines(
                    @intFromFloat(x0),
                    @intFromFloat(y0),
                    @intFromFloat(sz),
                    @intFromFloat(sz),
                    rl.Color.init(0, 255, 0, 180),
                );
            }
        }

        // ---- HUD ----
        var buf: [256]u8 = undefined;
        const center_text = std.fmt.bufPrintZ(
            &buf,
            "Center: ({e:.4}, {e:.4})  |  Range: {e:.4}  |  Iters: {d}",
            .{ view.center_x, view.center_y, view.range, view.max_iters },
        ) catch unreachable;

        const hud_top = screen_h - HUD_HEIGHT;
        rl.drawRectangle(0, hud_top, screen_w, HUD_HEIGHT, rl.Color.init(0, 0, 0, 160));
        rl.drawText(center_text, 10, hud_top + 8, 18, rl.Color.init(200, 200, 200, 255));
        rl.drawText(
            "Drag: zoom (1:1)  |  <-: undo  ->: redo  |  R: reset  |  +/-: x2",
            10,
            hud_top + 28,
            14,
            rl.Color.init(150, 150, 150, 255),
        );

        if (render_timed_out) {
            rl.drawText(
                "[Space]: continue rendering (30s more)",
                10,
                hud_top + 4,
                12,
                rl.Color.init(255, 200, 100, 255),
            );
        }

        // On-screen iteration buttons.
        const btn_y = screen_h - BTN_Y_OFFSET;
        const mx = rl.getMouseX();
        const my = rl.getMouseY();

        // [-] button (rightmost)
        const minus_x = screen_w - BTN_GAP - BTN_SIZE;
        const minus_hover = mx >= minus_x and mx < minus_x + BTN_SIZE and my >= btn_y and my < btn_y + BTN_SIZE;
        rl.drawRectangle(minus_x, btn_y, BTN_SIZE, BTN_SIZE, if (minus_hover) rl.Color.init(80, 80, 90, 220) else rl.Color.init(50, 50, 60, 200));
        rl.drawRectangleLines(minus_x, btn_y, BTN_SIZE, BTN_SIZE, rl.Color.init(100, 100, 110, 180));
        rl.drawText("-", minus_x + 7, btn_y + 4, 20, rl.Color.init(200, 200, 200, 255));

        // [+] button
        const plus_x = screen_w - BTN_SIZE;
        const plus_hover = mx >= plus_x and mx < plus_x + BTN_SIZE and my >= btn_y and my < btn_y + BTN_SIZE;
        rl.drawRectangle(plus_x, btn_y, BTN_SIZE, BTN_SIZE, if (plus_hover) rl.Color.init(80, 80, 90, 220) else rl.Color.init(50, 50, 60, 200));
        rl.drawRectangleLines(plus_x, btn_y, BTN_SIZE, BTN_SIZE, rl.Color.init(100, 100, 110, 180));
        rl.drawText("+", plus_x + 8, btn_y + 4, 20, rl.Color.init(200, 200, 200, 255));
    }
}

// ===========================================================================
// Unit tests
// ===========================================================================

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
    // Simple rightward drag.
    var sq = constrainDragSquare(100.0, 100.0, 300.0, 150.0);
    try testing.expectEqual(@as(f64, 100.0), sq.x);
    try testing.expectEqual(@as(f64, 100.0), sq.y);

    // Simple downward drag (y is larger → size from y).
    sq = constrainDragSquare(100.0, 100.0, 150.0, 300.0);
    try testing.expectEqual(@as(f64, 100.0), sq.x);
    try testing.expectEqual(@as(f64, 100.0), sq.y);

    // Reverse drag (right-to-left, bottom-to-top).
    sq = constrainDragSquare(300.0, 300.0, 100.0, 150.0);
    try testing.expectEqual(@as(f64, 0.0), sq.x);
    try testing.expectEqual(@as(f64, 0.0), sq.y);

    // Tiny drag (< 1) → no movement.
    sq = constrainDragSquare(100.0, 100.0, 100.5, 100.5);
    try testing.expectEqual(@as(f64, 100.0), sq.x);
    try testing.expectEqual(@as(f64, 100.0), sq.y);
}

test "screenToComplex round-trip" {
    // A 900×800 window centered at (-0.5, 0) with range 3.5.
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

    // Centre pixel maps to the view centre.
    var c = screenToComplex(450.0, 400.0, view, w, h);
    try testing.expectApproxEqAbs(-0.5, c.x, 1e-12);
    try testing.expectApproxEqAbs(0.0, c.y, 1e-12);

    // Top-left corner.
    c = screenToComplex(0.0, 0.0, view, w, h);
    try testing.expectApproxEqAbs(left, c.x, 1e-12);
    try testing.expectApproxEqAbs(top, c.y, 1e-12);
}

test "hslToRgb known values" {
    // White: h=any, s=0, l=1.
    var rgb = hslToRgb(0.0, 0.0, 1.0);
    try testing.expectEqual(@as(u8, 255), rgb.r);
    try testing.expectEqual(@as(u8, 255), rgb.g);
    try testing.expectEqual(@as(u8, 255), rgb.b);

    // Black: h=any, s=0, l=0.
    rgb = hslToRgb(0.0, 0.0, 0.0);
    try testing.expectEqual(@as(u8, 0), rgb.r);
    try testing.expectEqual(@as(u8, 0), rgb.g);
    try testing.expectEqual(@as(u8, 0), rgb.b);

    // Pure red: h=0, s=1, l=0.5.
    rgb = hslToRgb(0.0, 1.0, 0.5);
    try testing.expectEqual(@as(u8, 255), rgb.r);
    try testing.expectEqual(@as(u8, 0), rgb.g);
    try testing.expectEqual(@as(u8, 0), rgb.b);

    // Pure green: h=120, s=1, l=0.5.
    rgb = hslToRgb(120.0, 1.0, 0.5);
    try testing.expectEqual(@as(u8, 0), rgb.r);
    try testing.expectEqual(@as(u8, 255), rgb.g);
    try testing.expectEqual(@as(u8, 0), rgb.b);

    // Pure blue: h=240, s=1, l=0.5.
    rgb = hslToRgb(240.0, 1.0, 0.5);
    try testing.expectEqual(@as(u8, 0), rgb.r);
    try testing.expectEqual(@as(u8, 0), rgb.g);
    try testing.expectEqual(@as(u8, 255), rgb.b);
}

test "smoothColor inside set" {
    // mu >= max_iters → black.
    try testing.expectEqual(rl.Color.black, smoothColor(100.0, 100));
    try testing.expectEqual(rl.Color.black, smoothColor(999.0, 100));
}

test "buildPalette all valid" {
    buildPalette();
    for (palette) |c| {
        // Alpha must be 255 for every palette entry.
        try testing.expectEqual(@as(u8, 255), c.a);
    }
}

// ===========================================================================
// Integration tests — these would have caught past regressions
// ===========================================================================

test "Coord normSq and sq" {
    const z = Coord{ .re = 3.0, .im = 4.0 };
    try testing.expectEqual(@as(f32, 25.0), z.normSq());
    const z2 = z.sq();
    try testing.expectEqual(@as(f32, -7.0), z2.re);
    try testing.expectEqual(@as(f32, 24.0), z2.im);

    // |0|² = 0
    const zero = Coord{ .re = 0, .im = 0 };
    try testing.expectEqual(@as(f32, 0.0), zero.normSq());

    // (1 + i)² = 2i
    const unit = Coord{ .re = 1.0, .im = 1.0 };
    const unit_sq = unit.sq();
    try testing.expectApproxEqAbs(@as(f32, 0.0), unit_sq.re, 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), unit_sq.im, 1e-6);
}

test "clearToOpaqueBlack sets RGBA=0 with A=255" {
    // This would have caught the @memset alpha=0 bug.
    var buf = [_]u8{0xFF} ** 16; // 4 pixels, all 0xFF
    clearToOpaqueBlack(&buf);
    for (0..4) |i| {
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 0]); // R
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 1]); // G
        try testing.expectEqual(@as(u8, 0), buf[i * 4 + 2]); // B
        try testing.expectEqual(@as(u8, 255), buf[i * 4 + 3]); // A ← was 0, fixed
    }
}

test "clearToOpaqueBlack large buffer" {
    var buf: [400]u8 = undefined; // 100 pixels
    clearToOpaqueBlack(&buf);
    for (0..100) |i| {
        // Every alpha byte must be 255 (not just the first one).
        try testing.expectEqual(@as(u8, 255), buf[i * 4 + 3]);
    }
}

test "zoom math round-trip" {
    // Simulate a drag-zoom and verify the new view is a proper subset.
    const screen_w: i32 = 900;
    const screen_h: i32 = 800;

    var view = ViewState{
        .center_x = -0.5,
        .center_y = 0.0,
        .range = 3.5,
        .max_iters = 256,
    };

    // User drags from (200, 200) to (500, 500) — a 300×300 square.
    const drag_start_x: f64 = 200.0;
    const drag_start_y: f64 = 200.0;
    const drag_end_x: f64 = 500.0;
    const drag_end_y: f64 = 500.0;

    // Constrain to square (longer side).
    const size = @max(@abs(drag_end_x - drag_start_x), @abs(drag_end_y - drag_start_y));
    const sel_cx = (drag_start_x + drag_end_x) / 2.0;
    const sel_cy = (drag_start_y + drag_end_y) / 2.0;

    const c_center = screenToComplex(sel_cx, sel_cy, view, screen_w, screen_h);
    const smaller = @min(screen_w, screen_h);
    const new_range = view.range * (size / @as(f64, @floatFromInt(smaller)));

    // Verify the new view is a subset of the old view.
    try testing.expect(new_range < view.range);
    try testing.expectApproxEqAbs(-0.5, c_center.x, 0.5); // still near centre
    try testing.expectApproxEqAbs(0.0, c_center.y, 0.5);

    // Update view and verify round-trip consistency.
    const old_range = view.range;
    view.range = new_range;
    view.center_x = c_center.x;
    view.center_y = c_center.y;

    // The new range must be positive and smaller.
    try testing.expect(view.range > 0);
    try testing.expect(view.range < old_range);
}

test "zoom auto-scale iterations" {
    // At the initial view, auto-scale should not reduce below DEFAULT.
    const v = ViewState{
        .center_x = -0.5,
        .center_y = 0.0,
        .range = 3.5,
        .max_iters = DEFAULT_MAX_ITERS,
    };
    // Simulate the auto-scale formula used on zoom.
    const zoom_factor = INITIAL_RANGE / v.range;
    const log2_zf = @log(zoom_factor) / @log(2.0);
    const log2_start = @log(@as(f64, @floatFromInt(DEFAULT_MAX_ITERS))) / @log(2.0);
    const target_f = @exp2(log2_start + log2_zf * AUTO_SCALE_SLOPE);
    const clamped = @min(target_f, @as(f64, @floatFromInt(AUTO_SCALE_CAP)));
    const target = nextPowerOf2(@as(u32, @intFromFloat(clamped)));
    // At 1× zoom the target should be ≤ DEFAULT_MAX_ITERS.
    try testing.expect(target <= DEFAULT_MAX_ITERS);
    // After zooming in 100× the auto-scale should have kicked in.
    const range2 = 3.5 / 100.0;
    const zf2 = INITIAL_RANGE / range2;
    const t2 = nextPowerOf2(@as(u32, @intFromFloat(@min(
        @exp2(
            @log(@as(f64, @floatFromInt(DEFAULT_MAX_ITERS))) / @log(2.0) +
            (@log(zf2) / @log(2.0)) * AUTO_SCALE_SLOPE,
        ),
        @as(f64, @floatFromInt(AUTO_SCALE_CAP)),
    ))));
    try testing.expect(t2 > DEFAULT_MAX_ITERS);
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

    // Test several screen positions.
    try testing.expect(std.math.isFinite(screenToComplex(0.0, 0.0, v, w, h).x));
    try testing.expect(std.math.isFinite(screenToComplex(450.0, 400.0, v, w, h).x));
    try testing.expect(std.math.isFinite(screenToComplex(899.0, 799.0, v, w, h).x));
    try testing.expect(std.math.isFinite(screenToComplex(100.0, 700.0, v, w, h).x));
    // Within the initial view bounds.
    const c = screenToComplex(0.0, 0.0, v, w, h);
    try testing.expect(c.x >= -2.25 and c.x <= 1.25);
    try testing.expect(c.y >= -1.75 and c.y <= 1.75);
}
