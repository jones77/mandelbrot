//! Mandelbrot Set Visualizer
//!
//! Interactive zoom and explore the Mandelbrot set.
//! - Click and drag a 1:1 (square) selection box to zoom in.
//!   The box is constrained to square as you drag for accurate preview.
//! - Press Delete / Backspace to return to the previous zoom level.
//! - Use mouse wheel to adjust iteration count (more detail near edges).
//! - Press R to reset the view.
//!
//! Requires raylib (via raylib-zig package or system library).

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
const MAX_HISTORY: usize = 64;
const MIN_SELECTION_PX: f64 = 8.0;
const TARGET_FPS: i32 = 60;
const PALETTE_SIZE: usize = 1024;

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
    /// Constrained to maintain a square selection (same centre, longer side).
    current_x: f64,
    current_y: f64,
    active: bool,
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

    return rl.Color{
        .r = @intFromFloat(@round((r1 + m) * 255.0)),
        .g = @intFromFloat(@round((g1 + m) * 255.0)),
        .b = @intFromFloat(@round((b1 + m) * 255.0)),
        .a = 255,
    };
}

fn iterationColor(iter: u32, max_iters: u32) rl.Color {
    if (iter == max_iters) {
        return rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    }
    const idx = iter % @as(u32, @intCast(PALETTE_SIZE));
    return palette[idx];
}

// ===========================================================================
// Mandelbrot computation
// ===========================================================================

fn renderMandelbrot(image: *rl.Image, view: ViewState) void {
    const w: usize = @intCast(image.width);
    const h: usize = @intCast(image.height);

    const aspect = @as(f64, @floatFromInt(w)) / @as(f64, @floatFromInt(h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    const left = view.center_x - range_x / 2.0;
    const top = view.center_y - range_y / 2.0;

    const pixels = @as([*]u8, @ptrCast(image.data.?))[0 .. w * h * 4];

    var py: usize = 0;
    while (py < h) : (py += 1) {
        const cy = top + @as(f64, @floatFromInt(py)) * range_y / @as(f64, @floatFromInt(h -| 1));

        var px: usize = 0;
        while (px < w) : (px += 1) {
            const cx = left + @as(f64, @floatFromInt(px)) * range_x / @as(f64, @floatFromInt(w -| 1));

            var zx: f64 = 0.0;
            var zy: f64 = 0.0;
            var iter: u32 = 0;

            while (iter < view.max_iters) : (iter += 1) {
                const zx2 = zx * zx;
                const zy2 = zy * zy;
                if (zx2 + zy2 > 4.0) break;
                zy = 2.0 * zx * zy + cy;
                zx = zx2 - zy2 + cx;
            }

            const color = iterationColor(iter, view.max_iters);
            const idx = (py * w + px) * 4;
            pixels[idx + 0] = color.r;
            pixels[idx + 1] = color.g;
            pixels[idx + 2] = color.b;
            pixels[idx + 3] = color.a;
        }
    }
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

/// Returns -1.0, 0.0, or 1.0 for the given float.
fn signf(x: f64) f64 {
    if (x > 0) return 1.0;
    if (x < 0) return -1.0;
    return 0.0;
}

/// Constrain a drag so it always forms a square.  The square has the
/// same starting corner as the original drag but uses the longer axis
/// for both width and height.
fn constrainDragSquare(start_x: f64, start_y: f64, raw_mx: f64, raw_my: f64) struct { x: f64, y: f64 } {
    const raw_dx = raw_mx - start_x;
    const raw_dy = raw_my - start_y;
    const size = @max(@abs(raw_dx), @abs(raw_dy));
    if (size < 1.0) {
        return .{ .x = start_x, .y = start_y };
    }
    return .{
        .x = start_x + signf(raw_dx) * size,
        .y = start_y + signf(raw_dy) * size,
    };
}

// ===========================================================================
// Main
// ===========================================================================

pub fn main() !void {
    buildPalette();

    var view = ViewState{
        .center_x = INITIAL_CENTER_X,
        .center_y = INITIAL_CENTER_Y,
        .range = INITIAL_RANGE,
        .max_iters = DEFAULT_MAX_ITERS,
    };

    var history: [MAX_HISTORY]ViewState = undefined;
    var history_len: usize = 0;

    // ---- Window ----
    rl.InitWindow(DEFAULT_WIDTH, DEFAULT_HEIGHT, "Mandelbrot Set");
    defer rl.CloseWindow();
    rl.SetTargetFPS(TARGET_FPS);

    // ---- Image & texture ----
    var screen_w: i32 = rl.GetScreenWidth();
    var screen_h: i32 = rl.GetScreenHeight();

    var image = rl.GenImageColor(screen_w, screen_h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
    defer rl.UnloadImage(image);

    var texture = rl.LoadTextureFromImage(image);
    defer rl.UnloadTexture(texture);

    var drag = DragState{
        .start_x = 0,
        .start_y = 0,
        .current_x = 0,
        .current_y = 0,
        .active = false,
    };

    // ---- Initial render ----
    renderMandelbrot(&image, view);
    rl.UpdateTexture(texture, image.data);

    // ---- Main loop ----
    while (!rl.WindowShouldClose()) {
        // ---- Handle window resize ----
        const new_w = rl.GetScreenWidth();
        const new_h = rl.GetScreenHeight();
        if (new_w != screen_w or new_h != screen_h) {
            screen_w = new_w;
            screen_h = new_h;

            rl.UnloadTexture(texture);
            rl.UnloadImage(image);

            image = rl.GenImageColor(screen_w, screen_h, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 });
            texture = rl.LoadTextureFromImage(image);

            renderMandelbrot(&image, view);
            rl.UpdateTexture(texture, image.data);
        }

        // ============================================================
        // Input
        // ============================================================

        // -- Start drag --
        if (rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT)) {
            drag.start_x = @floatFromInt(rl.GetMouseX());
            drag.start_y = @floatFromInt(rl.GetMouseY());
            drag.current_x = drag.start_x;
            drag.current_y = drag.start_y;
            drag.active = true;
        }

        // -- Update drag (constrain to square in real time) --
        if (drag.active and rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const raw_mx: f64 = @floatFromInt(rl.GetMouseX());
            const raw_my: f64 = @floatFromInt(rl.GetMouseY());
            const sq = constrainDragSquare(drag.start_x, drag.start_y, raw_mx, raw_my);
            drag.current_x = sq.x;
            drag.current_y = sq.y;
        }

        // -- End drag -> zoom in --
        if (drag.active and rl.IsMouseButtonReleased(rl.MOUSE_BUTTON_LEFT)) {
            defer drag.active = false;

            const size = @abs(drag.current_x - drag.start_x);
            if (size < MIN_SELECTION_PX) continue;

            // Centre of the selection square in screen space.
            const sel_cx = (drag.start_x + drag.current_x) / 2.0;
            const sel_cy = (drag.start_y + drag.current_y) / 2.0;

            const c_center = screenToComplex(sel_cx, sel_cy, view, screen_w, screen_h);
            const new_range = view.range * (size / @as(f64, @floatFromInt(screen_w)));

            // Save current view to history.
            if (history_len < MAX_HISTORY) {
                history[history_len] = view;
                history_len += 1;
            }

            view.center_x = c_center.x;
            view.center_y = c_center.y;
            view.range = new_range;

            renderMandelbrot(&image, view);
            rl.UpdateTexture(texture, image.data);
        }

        // -- Delete / Backspace -> undo zoom --
        if (rl.IsKeyPressed(rl.KEY_DELETE) or rl.IsKeyPressed(rl.KEY_BACKSPACE)) {
            if (history_len > 0) {
                history_len -= 1;
                view = history[history_len];
                renderMandelbrot(&image, view);
                rl.UpdateTexture(texture, image.data);
            }
        }

        // -- Scroll wheel -> adjust max iterations --
        const wheel = rl.GetMouseWheelMove();
        if (wheel != 0) {
            const delta: i32 = if (wheel > 0) @as(i32, 32) else -32;
            const new_iters: i32 = @as(i32, @intCast(view.max_iters)) + delta;
            view.max_iters = @intCast(@max(32, @min(4096, new_iters)));
            renderMandelbrot(&image, view);
            rl.UpdateTexture(texture, image.data);
        }

        // -- R -> reset --
        if (rl.IsKeyPressed(rl.KEY_R)) {
            view = ViewState{
                .center_x = INITIAL_CENTER_X,
                .center_y = INITIAL_CENTER_Y,
                .range = INITIAL_RANGE,
                .max_iters = view.max_iters,
            };
            history_len = 0;
            renderMandelbrot(&image, view);
            rl.UpdateTexture(texture, image.data);
        }

        // ============================================================
        // Drawing
        // ============================================================
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.Color{ .r = 20, .g = 20, .b = 30, .a = 255 });

        // Draw the Mandelbrot texture.
        rl.DrawTexture(texture, 0, 0, rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 });

        // Draw the selection rectangle (always square because we constrain it).
        if (drag.active) {
            const x0: f32 = @floatCast(@min(drag.start_x, drag.current_x));
            const y0: f32 = @floatCast(@min(drag.start_y, drag.current_y));
            const sz: f32 = @floatCast(@abs(drag.current_x - drag.start_x));

            if (sz >= MIN_SELECTION_PX) {
                rl.DrawRectangle(
                    @intFromFloat(x0),
                    @intFromFloat(y0),
                    @intFromFloat(sz),
                    @intFromFloat(sz),
                    rl.Color{ .r = 0, .g = 255, .b = 0, .a = 40 },
                );
                rl.DrawRectangleLines(
                    @intFromFloat(x0),
                    @intFromFloat(y0),
                    @intFromFloat(sz),
                    @intFromFloat(sz),
                    rl.Color{ .r = 0, .g = 255, .b = 0, .a = 180 },
                );
            }
        }

        // ---- HUD ----
        var buf: [256]u8 = undefined;
        const center_text = std.fmt.bufPrintZ(
            &buf,
            "Center: ({d:.8}, {d:.8})  |  Range: {d:.4e}  |  Iters: {d}",
            .{ view.center_x, view.center_y, view.range, view.max_iters },
        ) catch unreachable;

        const help_text = "Left-drag: zoom (1:1)  |  Del/Backspace: undo  |  R: reset  |  Wheel: +-iters";

        rl.DrawRectangle(0, screen_h - 50, screen_w, 50, rl.Color{ .r = 0, .g = 0, .b = 0, .a = 160 });
        rl.DrawText(center_text.ptr, 10, screen_h - 42, 18, rl.Color{ .r = 200, .g = 200, .b = 200, .a = 255 });
        rl.DrawText(help_text, 10, screen_h - 22, 14, rl.Color{ .r = 150, .g = 150, .b = 150, .a = 255 });
    }
}
