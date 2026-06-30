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

const DEFAULT_MAX_ITERS: u32 = 256;
const MIN_ITERS: u32 = 16;
const MAX_ITERS_CAP: u32 = 65536; // 2^16
const AUTO_SCALE_BASE: f64 = 80.0;
const PALETTE_DENSITY: f64 = 4.0;
const MAX_HISTORY: usize = 64;
const MIN_SELECTION_PX: f64 = 8.0;
const TARGET_FPS: i32 = 60;
const PALETTE_SIZE: usize = 1024;
const MAX_RENDER_THREADS: usize = 8;
const RENDER_TIMEOUT_S: f64 = 30.0;

// ===========================================================================
// Types
// ===========================================================================

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

        const cy = ctx.top + @as(f64, @floatFromInt(py)) * ctx.range_y / @as(f64, @floatFromInt(h -| 1));
        const cy2 = cy * cy;

        var px: usize = 0;
        while (px < w) : (px += 1) {
            const cx = ctx.left + @as(f64, @floatFromInt(px)) * ctx.range_x / @as(f64, @floatFromInt(w -| 1));

            // Periodicity check: skip iteration for points inside the main
            // cardioid or period-2 bulb.  Skipped entirely when the view is
            // far from these shapes (bounding box rejection).
            if (!ctx.skip_periodicity) {
                const q = (cx - 0.25) * (cx - 0.25) + cy2;
                if (q * (q + (cx - 0.25)) <= 0.25 * cy2) continue;
                if ((cx + 1.0) * (cx + 1.0) + cy2 <= 0.0625) continue;
            }

            var zx: f64 = 0.0;
            var zy: f64 = 0.0;
            var iter: u32 = 0;

            // Using the while-else expression: `break` provides the smooth
            // iteration count on escape, `else` provides the limit when the
            // point never escapes (inside the set → leave black).
            const mu = while (iter < max_iters) : (iter += 1) {
                const zx2 = zx * zx;
                const zy2 = zy * zy;
                if (zx2 + zy2 > 4.0) {
                    const log_mag = 0.5 * @log(zx2 + zy2);
                    break @as(f64, @floatFromInt(iter)) + 1.0 - @log(log_mag) / @log(2.0);
                }
                zy = 2.0 * zx * zy + cy;
                zx = zx2 - zy2 + cx;
            } else @as(f64, @floatFromInt(max_iters));

            if (mu >= @as(f64, @floatFromInt(max_iters))) continue;

            const color = smoothColor(mu, max_iters);
            const pix_idx = (py * w + px) * 4;
            ctx.pixels[pix_idx + 0] = color.r;
            ctx.pixels[pix_idx + 1] = color.g;
            ctx.pixels[pix_idx + 2] = color.b;
            ctx.pixels[pix_idx + 3] = color.a;
        }
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
        // Clear to black so old pixels from a previous zoom don't persist
        // in areas that are now "inside set" (black → left unwritten).
        @memset(pixels, 0);
    }

    // Bounding-box test for cardioid/bulb periodicity checking.
    // If the entire view lies outside [-1.25, 0.25] × [-0.6495, 0.6495]
    // then no pixel can be inside the main cardioid or period-2 bulb,
    // so we skip those per-pixel tests entirely.
    const box_ymax = 3.0 * @sqrt(3.0) / 8.0;
    const view_left = view.center_x - range_x / 2.0;
    const view_right = view.center_x + range_x / 2.0;
    const view_top = view.center_y - range_y / 2.0;
    const view_bottom = view.center_y + range_y / 2.0;
    const skip_periodicity = (view_right < -1.25 or view_left > 0.25 or
        view_bottom < -box_ymax or view_top > box_ymax);

    const deadline_s = rl.getTime() + RENDER_TIMEOUT_S;

    // Determine thread count: at most MAX_RENDER_THREADS, and at least 32 rows each.
    var num_threads: usize = h / 32;
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
) struct { x: f64, y: f64 } {
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

// ===========================================================================
// Helpers
// ===========================================================================

fn signf(x: f64) f64 {
    if (x > 0) return 1.0;
    if (x < 0) return -1.0;
    return 0.0;
}

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

fn constrainDragSquare(start_x: f64, start_y: f64, raw_mx: f64, raw_my: f64) struct { x: f64, y: f64 } {
    const raw_dx = raw_mx - start_x;
    const raw_dy = raw_my - start_y;
    const size = @max(@abs(raw_dx), @abs(raw_dy));
    if (size < 1.0) return .{ .x = start_x, .y = start_y };
    return .{
        .x = start_x + signf(raw_dx) * size,
        .y = start_y + signf(raw_dy) * size,
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
    {
        const px_w: usize = @intCast(screen_w);
        const px_h: usize = @intCast(screen_h);
        const px_size = px_w * px_h * 4;
        history[0] = HistoryEntry{
            .view = view,
            .pixels = try std.heap.page_allocator.alloc(u8, px_size),
            .w = px_w,
            .h = px_h,
        };
        @memcpy(history[0].pixels, @as([*]u8, @ptrCast(image.data))[0..px_size]);
        history_len = 1;
        history_ptr = 0;
    }

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
            const by = screen_h - 46;
            if (my >= by and my < by + 28) {
                if (mx >= screen_w - 68 and mx < screen_w - 40) {
                    view.max_iters = @max(MIN_ITERS, view.max_iters / 2);
                    render_timed_out = try renderMandelbrot(&image, view, true);
                    rl.updateTexture(texture, image.data);
                }
                if (mx >= screen_w - 36 and mx < screen_w - 8) {
                    view.max_iters = @min(MAX_ITERS_CAP, view.max_iters +| view.max_iters);
                    render_timed_out = try renderMandelbrot(&image, view, true);
                    rl.updateTexture(texture, image.data);
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
            if (history_len < MAX_HISTORY) {
                while (history_ptr + 1 < history_len) {
                    history_len -= 1;
                    std.heap.page_allocator.free(history[history_len].pixels);
                    history[history_len].pixels = &[_]u8{};
                }
            }

            view.center_x = c_center.x;
            view.center_y = c_center.y;
            view.range = new_range;

            // Auto-scale iterations: deeper zooms need more iterations
            // to resolve fine detail at the Mandelbrot boundary.
            // Snaps to the next power of two (2^4 … 2^31).
            const zoom_factor = INITIAL_RANGE / view.range;
            const raw_iters = zoom_factor * AUTO_SCALE_BASE;
            const clamped = @min(raw_iters, @as(f64, @floatFromInt(MAX_ITERS_CAP)));
            const target_iters = nextPowerOf2(@as(u32, @intFromFloat(clamped)));
            if (target_iters > view.max_iters and target_iters <= MAX_ITERS_CAP) {
                view.max_iters = target_iters;
            }

            render_timed_out = try renderMandelbrot(&image, view, true);
            rl.updateTexture(texture, image.data);

            // Save the new view + its pixels into history (undo target).
            if (history_len < MAX_HISTORY) {
                const px_w: usize = @intCast(screen_w);
                const px_h: usize = @intCast(screen_h);
                const px_size = px_w * px_h * 4;
                const pixels = try std.heap.page_allocator.alloc(u8, px_size);
                @memcpy(pixels, @as([*]u8, @ptrCast(image.data))[0..px_size]);
                history[history_len] = HistoryEntry{
                    .view = view,
                    .pixels = pixels,
                    .w = px_w,
                    .h = px_h,
                };
                history_len += 1;
                history_ptr = history_len - 1;
            }
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

        // -- Scroll wheel / +/- keys -> double/halve iterations --
        {
            const wheel = rl.getMouseWheelMove();
            const key_inc = rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add);
            const key_dec = rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract);

            var changed = false;
            if (wheel > 0 or key_inc) {
                view.max_iters = @min(MAX_ITERS_CAP, view.max_iters +| view.max_iters);
                changed = true;
            } else if (wheel < 0 or key_dec) {
                view.max_iters = @max(MIN_ITERS, view.max_iters / 2);
                changed = true;
            }
            if (changed) {
                render_timed_out = try renderMandelbrot(&image, view, true);
                rl.updateTexture(texture, image.data);
            }
        }

        // -- R -> reset (clean up all cached entries) --
        if (rl.isKeyPressed(.r)) {
            for (0..history_len) |i| {
                if (history[i].pixels.len > 0)
                    std.heap.page_allocator.free(history[i].pixels);
            }
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
            "Center: ({d:.8}, {d:.8})  |  Range: {e:.4}  |  Iters: {d}",
            .{ view.center_x, view.center_y, view.range, view.max_iters },
        ) catch unreachable;

        rl.drawRectangle(0, screen_h - 50, screen_w, 50, rl.Color.init(0, 0, 0, 160));
        rl.drawText(center_text, 10, screen_h - 42, 18, rl.Color.init(200, 200, 200, 255));
        rl.drawText(
            "Drag: zoom (1:1)  |  <-: undo  ->: redo  |  R: reset  |  Wheel/+/-: x2",
            10,
            screen_h - 22,
            14,
            rl.Color.init(150, 150, 150, 255),
        );

        if (render_timed_out) {
            rl.drawText(
                "[Space]: continue rendering (30s more)",
                10,
                screen_h - 46,
                12,
                rl.Color.init(255, 200, 100, 255),
            );
        }

        // On-screen iteration buttons.
        const btn_y = screen_h - 46;
        const btn_h: i32 = 28;
        const btn_w: i32 = 28;

        // [−]
        const mx = rl.getMouseX();
        const my = rl.getMouseY();
        const minus_x = screen_w - 68;
        const minus_hover = mx >= minus_x and mx < minus_x + btn_w and my >= btn_y and my < btn_y + btn_h;
        rl.drawRectangle(minus_x, btn_y, btn_w, btn_h, if (minus_hover) rl.Color.init(80, 80, 90, 220) else rl.Color.init(50, 50, 60, 200));
        rl.drawRectangleLines(minus_x, btn_y, btn_w, btn_h, rl.Color.init(100, 100, 110, 180));
        rl.drawText("-", minus_x + 7, btn_y + 4, 20, rl.Color.init(200, 200, 200, 255));

        // [+]
        const plus_x = screen_w - 36;
        const plus_hover = mx >= plus_x and mx < plus_x + btn_w and my >= btn_y and my < btn_y + btn_h;
        rl.drawRectangle(plus_x, btn_y, btn_w, btn_h, if (plus_hover) rl.Color.init(80, 80, 90, 220) else rl.Color.init(50, 50, 60, 200));
        rl.drawRectangleLines(plus_x, btn_y, btn_w, btn_h, rl.Color.init(100, 100, 110, 180));
        rl.drawText("+", plus_x + 8, btn_y + 4, 20, rl.Color.init(200, 200, 200, 255));
    }
}
