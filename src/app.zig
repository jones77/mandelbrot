const m = @import("mandelbrot.zig");
const rl = @import("raylib");
const std = @import("std");
const renderer = @import("renderer.zig");
const logEvent = @import("log.zig").logEvent;
const PIXEL_CHANNELS = @import("pixel.zig").PIXEL_CHANNELS;
const ui = @import("ui.zig");
const input = @import("input.zig");
const allocator = @import("allocator.zig");

const DEFAULT_W: i32 = 900;
const MAX_HISTORY: usize = 64;
const VIEW_FMT = "x={d:.8} y={d:.8} range={e:.8} iters={d}";

// In app.zig to avoid circular type deps with input.zig
const DragState = struct { start_x: f64, start_y: f64, current_x: f64, current_y: f64, active: bool };

const ZoomAnimation = struct {
    from_view: m.ViewState,
    to_view: m.ViewState,
    start_time: f64,
    duration: f64,
    active: bool,
};

const HistoryEntry = struct {
    view: m.ViewState,
    w: usize,
    h: usize,
    pixels: []u8,
};

fn pushHistory(history: []HistoryEntry, history_len: *usize, history_ptr: *usize, view: m.ViewState, data: []const u8, w: usize, h: usize) !void {
    if (history_len.* >= MAX_HISTORY) return;
    const px_size = w * h * PIXEL_CHANNELS;
    const pixels = try allocator.get().alloc(u8, px_size);
    @memcpy(pixels, data[0..px_size]);
    history[history_len.*] = HistoryEntry{ .view = view, .pixels = pixels, .w = w, .h = h };
    history_len.* += 1;
    history_ptr.* = history_len.* - 1;
}

pub fn truncateFuture(history: []HistoryEntry, history_len: *usize, index: usize) void {
    while (index < history_len.*) {
        history_len.* -= 1;
        allocator.get().free(history[history_len.*].pixels);
    }
}

pub fn computeAnimDuration(from_view: m.ViewState, to_view: m.ViewState) f64 {
    const ANIM_DURATION_MIN: f64 = 0.1;
    const ANIM_DURATION_MAX: f64 = 0.5;
    const ANIM_AREA_RATIO_HI: f64 = 0.9;
    const ANIM_AREA_RATIO_LO: f64 = 0.1;
    const area_from = from_view.range * from_view.range;
    const area_to = to_view.range * to_view.range;
    const area_ratio = @min(area_from, area_to) / @max(area_from, area_to);
    const area_clamped = @max(ANIM_AREA_RATIO_LO, @min(ANIM_AREA_RATIO_HI, area_ratio));
    const area_t = (ANIM_AREA_RATIO_HI - area_clamped) / (ANIM_AREA_RATIO_HI - ANIM_AREA_RATIO_LO);
    const area_duration = ANIM_DURATION_MIN + area_t * (ANIM_DURATION_MAX - ANIM_DURATION_MIN);
    const max_range = @max(from_view.range, to_view.range);
    const dx = (from_view.center_x - to_view.center_x) + (from_view.offset_x - to_view.offset_x);
    const dy = (from_view.center_y - to_view.center_y) + (from_view.offset_y - to_view.offset_y);
    const center_dist = @sqrt(dx * dx + dy * dy);
    const center_t = @min(1.0, center_dist / (max_range * 2.0));
    const center_duration = ANIM_DURATION_MIN + center_t * (ANIM_DURATION_MAX - ANIM_DURATION_MIN);
    return @max(area_duration, center_duration);
}

fn parseField(text: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOfPos(u8, text, 0, key) orelse return null;
    const start = pos + key.len;
    var end = start;
    while (end < text.len and text[end] != ' ') end += 1;
    return if (start < end) text[start..end] else null;
}

pub fn parseViewState(text: []const u8) ?m.ViewState {
    const paren = std.mem.indexOfScalar(u8, text, '(');
    if (paren != null) {
        const after_paren = text[paren.? + 1 ..];
        const comma = std.mem.indexOfScalar(u8, after_paren, ',') orelse return null;
        const cx = std.fmt.parseFloat(f64, std.mem.trim(u8, after_paren[0..comma], " ")) catch return null;
        const after_comma = std.mem.trim(u8, after_paren[comma + 1 ..], " ");
        const close = std.mem.indexOfScalar(u8, after_comma, ')') orelse return null;
        const cy = std.fmt.parseFloat(f64, std.mem.trim(u8, after_comma[0..close], " ")) catch return null;
        const range_str = parseField(text, "range=") orelse return null;
        const range = std.fmt.parseFloat(f64, range_str) catch return null;
        const iters_str = parseField(text, "iters=") orelse return null;
        const iters = std.fmt.parseInt(u32, iters_str, 10) catch return null;
        return m.ViewState{ .center_x = cx, .center_y = cy, .range = range, .max_iters = iters };
    }
    const x_str = parseField(text, "x=") orelse return null;
    const y_str = parseField(text, "y=") orelse return null;
    const range_str = parseField(text, "range=") orelse return null;
    const iters_str = parseField(text, "iters=") orelse return null;
    const x = std.fmt.parseFloat(f64, x_str) catch return null;
    const y = std.fmt.parseFloat(f64, y_str) catch return null;
    const range = std.fmt.parseFloat(f64, range_str) catch return null;
    const iters = std.fmt.parseInt(u32, iters_str, 10) catch return null;
    return m.ViewState{ .center_x = x, .center_y = y, .range = range, .max_iters = iters };
}

pub const App = struct {
    view: m.ViewState,
    history: [MAX_HISTORY]HistoryEntry,
    history_len: usize,
    history_ptr: usize,
    render_timed_out: bool,
    screen_w: i32,
    screen_h: i32,
    render_w: i32,
    render_h: i32,
    dpi_scale: i32,
    image: rl.Image,
    texture: rl.Texture2D,
    drag: DragState,
    anim: ZoomAnimation,
    anim_texture: ?rl.Texture2D,
    tb_buf: ui.TextBuf,
    tb_active: bool,
    rows_completed: ?[]bool,
    ui_font: rl.Font,
    btn_w_inc: f32,
    btn_w_dec: f32,
    btn_w_copy: f32,
    btn_w_paste: f32,
    btn_w_reset: f32,
    tooltip_enabled: bool,
    tooltip_label_w: f32,
    tooltip_mouse_still_since: f64,
    tooltip_last_mx: i32,
    tooltip_last_my: i32,
    last_click_time: f64,
    last_click_x: i32,
    last_click_y: i32,

    pub fn init(render_method: m.RenderMethod, tooltip_enabled: bool) !App {
        m.buildPalette();
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        const dpi = @divTrunc(sw, DEFAULT_W);
        const rw = @divExact(sw, dpi);
        const rh = @divExact(sh, dpi);
        const top_phys = ui.TOTAL_TOP * dpi;
        const vh = sh - top_phys;
        const img = rl.genImageColor(sw, vh, .black);
        const tex = try rl.loadTextureFromImage(img);

        var app = App{
            .view = m.ViewState{
                .center_x = m.INITIAL_CENTER_X,
                .center_y = m.INITIAL_CENTER_Y,
                .range = m.INITIAL_RANGE,
                .max_iters = m.DEFAULT_MAX_ITERS,
                .render_method = render_method,
            },
            .history = undefined,
            .history_len = 0,
            .history_ptr = 0,
            .render_timed_out = false,
            .screen_w = sw,
            .screen_h = sh,
            .render_w = rw,
            .render_h = rh,
            .dpi_scale = dpi,
            .image = img,
            .texture = tex,
            .drag = DragState{ .start_x = 0, .start_y = 0, .current_x = 0, .current_y = 0, .active = false },
            .anim = ZoomAnimation{
                .from_view = undefined,
                .to_view = undefined,
                .start_time = 0,
                .duration = 0,
                .active = false,
            },
            .anim_texture = null,
            .tb_buf = ui.TextBuf.init(),
            .tb_active = false,
            .rows_completed = null,
            .ui_font = rl.getFontDefault() catch unreachable,
            .btn_w_inc = undefined,
            .btn_w_dec = undefined,
            .btn_w_copy = undefined,
            .btn_w_paste = undefined,
            .btn_w_reset = undefined,
            .tooltip_enabled = tooltip_enabled,
            .tooltip_label_w = undefined,
            .tooltip_mouse_still_since = 0,
            .tooltip_last_mx = 0,
            .tooltip_last_my = 0,
            .last_click_time = 0,
            .last_click_x = 0,
            .last_click_y = 0,
        };

        @memset(std.mem.asBytes(&app.history), 0);

        {
            const candidates = [_][:0]const u8{
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            };
            for (candidates) |path| {
                const CP_COUNT = ui.ASCII_PRN_COUNT + 2;
                var cps: [CP_COUNT]i32 = undefined;
                for (0..@as(usize, @intCast(ui.ASCII_PRN_COUNT))) |i| cps[i] = @as(i32, @intCast(i + ui.ASCII_PRN_MIN));
                cps[@as(usize, @intCast(ui.ASCII_PRN_COUNT))] = ui.CP_ARROW_LEFT;
                cps[@as(usize, @intCast(ui.ASCII_PRN_COUNT + 1))] = ui.CP_ARROW_RIGHT;
                const f = rl.loadFontEx(path, ui.FONT_LOAD_SIZE, &cps) catch continue;
                if (f.texture.id > 0) { app.ui_font = f; break; }
                rl.unloadFont(f);
            }
        }

        rl.setTextureFilter(app.texture, .point);
        app.btn_w_inc = rl.measureTextEx(app.ui_font, "inc", @floatFromInt(ui.FONT_SIZE_BTN), 0).x;
        app.btn_w_dec = rl.measureTextEx(app.ui_font, "dec", @floatFromInt(ui.FONT_SIZE_BTN), 0).x;
        app.btn_w_copy = rl.measureTextEx(app.ui_font, "copy", @floatFromInt(ui.FONT_SIZE_BTN), 0).x;
        app.btn_w_paste = rl.measureTextEx(app.ui_font, "paste", @floatFromInt(ui.FONT_SIZE_BTN), 0).x;
        app.btn_w_reset = rl.measureTextEx(app.ui_font, "reset", @floatFromInt(ui.FONT_SIZE_BTN), 0).x;
        app.tooltip_label_w = rl.measureTextEx(app.ui_font, ui.TOOLTIP_LABEL, ui.FONT_SIZE_LG, 1).x;
        app.tooltip_mouse_still_since = rl.getTime();
        app.syncTextBox();
        logEvent(.app, "init {d}x{d} dpi={d} method={s}", .{ rw, rh, dpi, @tagName(render_method) });
        return app;
    }

    pub fn cancelAnimation(self: *App) void { self.anim.active = false; }

    fn viewportRect(self: *const App) rl.Rectangle {
        return .{ .x = 0, .y = @floatFromInt(ui.TOTAL_TOP), .width = @floatFromInt(self.render_w), .height = @floatFromInt(self.render_h - ui.TOTAL_TOP) };
    }

    fn viewportAspect(self: *const App) f64 {
        return @as(f64, @floatFromInt(self.image.width)) / @as(f64, @floatFromInt(self.image.height));
    }

    fn viewportDrawHeight(self: *const App) i32 { return self.render_h - ui.TOTAL_TOP; }

    pub fn captureAnimationFrame(self: *App) !void {
        const px_size: usize = @intCast(self.image.width * self.image.height * PIXEL_CHANNELS);
        const pixels = try allocator.get().alloc(u8, px_size);
        defer allocator.get().free(pixels);
        @memcpy(pixels, self.pixelData());
        if (self.anim_texture) |tex| {
            if (tex.width == self.image.width and tex.height == self.image.height) {
                rl.updateTexture(tex, @ptrCast(pixels));
                return;
            }
            rl.unloadTexture(tex);
        }
        const img = rl.Image{ .data = @ptrCast(pixels), .width = self.image.width, .height = self.image.height, .mipmaps = 1, .format = .uncompressed_r8g8b8a8 };
        self.anim_texture = try rl.loadTextureFromImage(img);
        rl.setTextureFilter(self.anim_texture.?, .point);
    }

    pub fn deinit(self: *App) void {
        logEvent(.app, "shutdown", .{});
        self.cancelAnimation();
        if (self.anim_texture) |tex| rl.unloadTexture(tex);
        for (0..self.history_len) |i| {
            if (self.history[i].pixels.len > 0) allocator.get().free(self.history[i].pixels);
        }
        if (self.rows_completed) |rc| allocator.get().free(rc);
        rl.unloadTexture(self.texture);
        rl.unloadImage(self.image);
        rl.unloadFont(self.ui_font);
        allocator.deinit();
    }

    pub fn renderFresh(self: *App, clear: bool) !bool {
        const RENDER_TIMEOUT_S: f64 = 60.0;
        const w: usize = @intCast(self.image.width);
        const h: usize = @intCast(self.image.height);
        const pixels = @as([*]u8, @ptrCast(self.image.data))[0 .. w * h * PIXEL_CHANNELS];
        if (clear) {
            if (self.rows_completed) |rc| allocator.get().free(rc);
            self.rows_completed = try allocator.get().alloc(bool, h);
            @memset(self.rows_completed.?, false);
        } else if (self.rows_completed == null or self.rows_completed.?.len != h) {
            if (self.rows_completed) |rc| allocator.get().free(rc);
            self.rows_completed = try allocator.get().alloc(bool, h);
            @memset(self.rows_completed.?, false);
        }
        self.render_timed_out = try renderer.renderMandelbrot(pixels, w, h, self.view, clear, RENDER_TIMEOUT_S, rl.getTime, self.rows_completed);
        if (self.render_timed_out) logEvent(.render, "timeout", .{});
        if (!self.render_timed_out) {
            if (self.rows_completed) |rc| { allocator.get().free(rc); self.rows_completed = null; }
        }
        rl.updateTexture(self.texture, self.image.data);
        return self.render_timed_out;
    }

    fn pixelData(self: *App) []const u8 {
        const w: usize = @intCast(self.image.width);
        const h: usize = @intCast(self.image.height);
        return @as([*]u8, @ptrCast(self.image.data))[0 .. w * h * PIXEL_CHANNELS];
    }

    pub fn saveSnapshot(self: *App) !void {
        try pushHistory(&self.history, &self.history_len, &self.history_ptr, self.view, self.pixelData(), @intCast(self.image.width), @intCast(self.image.height));
    }

    pub fn handleDoubleClickZoom(self: *App, mx: i32, my: i32) !void {
        self.cancelAnimation();
        const dpi_f = @as(f64, @floatFromInt(self.dpi_scale));
        const phys_x = @as(f64, @floatFromInt(mx)) * dpi_f;
        const phys_y = (@as(f64, @floatFromInt(my)) - @as(f64, @floatFromInt(ui.TOTAL_TOP))) * dpi_f;
        const w_f = @as(f64, @floatFromInt(self.image.width));
        const h_f = @as(f64, @floatFromInt(self.image.height));
        const range_x = self.view.range;
        const delta_x = ((phys_x + 0.5) / w_f - 0.5) * range_x;
        const delta_y = ((phys_y + 0.5) / h_f - 0.5) * (range_x / (w_f / h_f));
        const delta = m.computeDragDelta(self.view, delta_x, delta_y);
        const ZOOM_FACTOR: f64 = 0.25;
        const new_range = self.view.range * ZOOM_FACTOR;
        logEvent(.drag, "double-click zoom from {d:.6} to {d:.6} iters={d}", .{ self.view.range, new_range, self.view.max_iters });
        truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
        const from_view = self.view;
        const to_view = m.ViewState{
            .center_x = delta.center_x,
            .center_y = delta.center_y,
            .offset_x = delta.offset_x,
            .offset_y = delta.offset_y,
            .range = new_range,
            .max_iters = self.view.max_iters,
        };
        try self.captureAnimationFrame();
        self.view = to_view;
        _ = try self.renderFresh(true);
        self.anim.from_view = from_view;
        self.anim.to_view = to_view;
        self.anim.duration = computeAnimDuration(from_view, to_view);
        self.anim.start_time = rl.getTime();
        self.anim.active = true;
        logEvent(.anim, "start in dur={d:.3} from={d:.6} to={d:.6}", .{ self.anim.duration, from_view.range, to_view.range });
        if (self.history_len < 64) try self.saveSnapshot();
    }

    fn startZoomAnimationTo(self: *App, from_view: m.ViewState, to_view: m.ViewState) !void {
        try self.captureAnimationFrame();
        self.anim.from_view = from_view;
        self.anim.to_view = to_view;
        self.anim.duration = computeAnimDuration(from_view, to_view);
        self.anim.start_time = rl.getTime();
        self.anim.active = true;
        logEvent(.anim, "start {s} dur={d:.3} from={d:.6} to={d:.6}", .{
            if (to_view.range > from_view.range) "out" else "in", self.anim.duration, from_view.range, to_view.range,
        });
    }

    fn startZoomAnimation(self: *App, to_entry: *const HistoryEntry) !void {
        self.cancelAnimation();
        const from_view = self.view;
        const to_view = to_entry.view;
        try self.startZoomAnimationTo(from_view, to_view);
        if (to_entry.w == @as(usize, @intCast(self.image.width)) and to_entry.h == @as(usize, @intCast(self.image.height))) {
            const pixels = @as([*]u8, @ptrCast(self.image.data))[0 .. to_entry.w * to_entry.h * PIXEL_CHANNELS];
            @memcpy(pixels, to_entry.pixels);
            rl.updateTexture(self.texture, self.image.data);
        } else {
            _ = try self.renderFresh(true);
        }
        self.view = to_view;
        self.syncTextBox();
    }

    pub fn navigateHistoryBack(self: *App) !void {
        if (self.history_ptr > 0) {
            self.history_ptr -= 1;
            try self.startZoomAnimation(&self.history[self.history_ptr]);
            logEvent(.history, "back entry={d} range={d:.6} anim={s}", .{ self.history_ptr, self.history[self.history_ptr].view.range, if (self.anim.active) "active" else "idle" });
        } else {
            logEvent(.history, "back ignored ptr={d} len={d} anim={s}", .{ self.history_ptr, self.history_len, if (self.anim.active) "active" else "idle" });
        }
    }

    pub fn navigateHistoryForward(self: *App) !void {
        if (self.history_ptr + 1 < self.history_len) {
            self.history_ptr += 1;
            try self.startZoomAnimation(&self.history[self.history_ptr]);
            logEvent(.history, "forward entry={d} range={d:.6} anim={s}", .{ self.history_ptr, self.history[self.history_ptr].view.range, if (self.anim.active) "active" else "idle" });
        } else {
            logEvent(.history, "forward ignored ptr={d} len={d} anim={s}", .{ self.history_ptr, self.history_len, if (self.anim.active) "active" else "idle" });
        }
    }

    fn drawAnimFrame(self: *App) void {
        const anim = &self.anim;
        const elapsed = rl.getTime() - anim.start_time;
        if ((elapsed / anim.duration) >= 1.0) {
            logEvent(.anim, "end", .{});
            self.cancelAnimation();
            return;
        }
        const interp = m.lerpViewState(anim.from_view, anim.to_view, elapsed / anim.duration);
        const tex = self.anim_texture.?;
        const tex_w: f32 = @floatFromInt(tex.width);
        const tex_h: f32 = @floatFromInt(tex.height);
        const vp = self.viewportRect();
        const draw_w = vp.width;
        const draw_h = vp.height;
        const draw_y = vp.y;
        const from_view = &anim.from_view;

        if (interp.range <= from_view.range) {
            const cx_diff = (interp.center_x - from_view.center_x) + (interp.offset_x - from_view.offset_x);
            const cy_diff = (interp.center_y - from_view.center_y) + (interp.offset_y - from_view.offset_y);
            const src_x: f32 = @floatCast(@max(0.0, (cx_diff - (interp.range - from_view.range) / 2.0) / from_view.range * tex_w));
            const src_y: f32 = @floatCast(@max(0.0, (cy_diff - (interp.range - from_view.range) / (2.0 * (tex_w / tex_h))) / (from_view.range / (tex_w / tex_h)) * tex_h));
            const src_w: f32 = @floatCast(@max(0.0, @min(interp.range / from_view.range * tex_w, tex_w - src_x)));
            const src_h: f32 = @floatCast(@max(0.0, @min(interp.range / from_view.range * tex_h, tex_h - src_y)));
            rl.drawTexturePro(tex, .{ .x = src_x, .y = src_y, .width = src_w, .height = src_h }, .{ .x = 0, .y = draw_y, .width = draw_w, .height = draw_h }, .{ .x = 0, .y = 0 }, 0, .white);
        } else {
            const fraction: f32 = @floatCast(from_view.range / interp.range);
            const cx_diff = (from_view.center_x - interp.center_x) + (from_view.offset_x - interp.offset_x);
            const cy_diff = (from_view.center_y - interp.center_y) + (from_view.offset_y - interp.offset_y);
            const dst_x: f32 = @floatCast((cx_diff / interp.range + 0.5) * draw_w - fraction * draw_w / 2.0);
            const dst_y: f32 = @floatCast(draw_y + ((cy_diff / (interp.range / (tex_w / tex_h)) + 0.5) * draw_h - fraction * draw_h / 2.0));
            rl.drawTexturePro(tex, .{ .x = 0, .y = 0, .width = tex_w, .height = tex_h }, .{ .x = dst_x, .y = dst_y, .width = fraction * draw_w, .height = fraction * draw_h }, .{ .x = 0, .y = 0 }, 0, .white);
        }
    }

    pub fn syncTextBox(self: *App) void { self.tb_buf.format(VIEW_FMT, .{ self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters }); }

    pub fn isValidCoord(parsed: m.ViewState) bool {
        return parsed.center_x >= m.INITIAL_CENTER_X - m.INITIAL_RANGE / 2.0 and parsed.center_x <= m.INITIAL_CENTER_X + m.INITIAL_RANGE / 2.0 and
            parsed.center_y >= m.INITIAL_CENTER_Y - m.INITIAL_RANGE / 2.0 and parsed.center_y <= m.INITIAL_CENTER_Y + m.INITIAL_RANGE / 2.0 and
            parsed.range > 0 and parsed.range <= m.INITIAL_RANGE and parsed.max_iters >= m.MIN_ITERS and parsed.max_iters <= m.MAX_ITERS_CAP;
    }

    pub fn textBoxApply(self: *App) !void {
        self.cancelAnimation();
        const parsed = parseViewState(self.tb_buf.buf[0..self.tb_buf.len]) orelse { self.syncTextBox(); return; };
        if (!isValidCoord(parsed)) { self.syncTextBox(); return; }
        if (parsed.center_x == self.view.center_x and parsed.center_y == self.view.center_y and parsed.range == self.view.range and parsed.max_iters == self.view.max_iters) return;
        logEvent(.ui, "textbox apply range={d:.6}", .{parsed.range});
        truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
        self.view = parsed;
        _ = try self.renderFresh(true);
        try self.saveSnapshot();
    }

    pub fn adjustIters(self: *App, increase: bool) !void {
        const old_iters = self.view.max_iters;
        self.cancelAnimation();
        truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
        self.view.max_iters = if (increase) @min(m.MAX_ITERS_CAP, self.view.max_iters +| self.view.max_iters) else @max(m.MIN_ITERS, self.view.max_iters / 2);
        logEvent(.iters, "{s} from {d} to {d}", .{ if (increase) "inc" else "dec", old_iters, self.view.max_iters });
        _ = try self.renderFresh(true);
        try self.saveSnapshot();
    }

    pub fn resetView(self: *App) !void {
        self.cancelAnimation();
        truncateFuture(&self.history, &self.history_len, 0);
        self.history_len = 0;
        self.history_ptr = 0;
        self.view.center_x = m.INITIAL_CENTER_X;
        self.view.center_y = m.INITIAL_CENTER_Y;
        self.view.range = m.INITIAL_RANGE;
        self.view.max_iters = m.DEFAULT_MAX_ITERS;
        _ = try self.renderFresh(true);
        try self.saveSnapshot();
        logEvent(.view, "reset", .{});
    }

    pub fn handleResize(self: *App) !void {
        const new_w = rl.getScreenWidth();
        const new_h = rl.getScreenHeight();
        if (new_w == self.screen_w and new_h == self.screen_h) return;
        self.cancelAnimation();
        if (self.anim_texture) |tex| { rl.unloadTexture(tex); self.anim_texture = null; }
        if (self.rows_completed) |rc| { allocator.get().free(rc); self.rows_completed = null; }
        logEvent(.app, "resize {d}x{d} -> {d}x{d}", .{ self.screen_w, self.screen_h, new_w, new_h });
        self.screen_w = new_w;
        self.screen_h = new_h;
        self.render_w = @divExact(new_w, self.dpi_scale);
        self.render_h = @divExact(new_h, self.dpi_scale);
        const vh = new_h - ui.TOTAL_TOP * self.dpi_scale;
        rl.unloadTexture(self.texture);
        rl.unloadImage(self.image);
        self.image = rl.genImageColor(new_w, vh, .black);
        self.texture = try rl.loadTextureFromImage(self.image);
        rl.setTextureFilter(self.texture, .point);
        _ = try self.renderFresh(true);
    }

    pub fn logInputEvent(self: *App, key_label: []const u8, action: []const u8, reason: []const u8) void {
        logEvent(.history, "{s} {s} ptr={d} len={d} tb={} anim={s} reason={s}", .{ key_label, action, self.history_ptr, self.history_len, self.tb_active, if (self.anim.active) "active" else "idle", reason });
    }

    pub fn handleInput(self: *App) !void { try input.handleInput(self); }

    pub fn drawFrame(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();
        rl.clearBackground(ui.COL_BG);
        rl.drawTexturePro(self.texture, .{ .x = 0, .y = 0, .width = @floatFromInt(self.texture.width), .height = @floatFromInt(self.texture.height) }, self.viewportRect(), .{ .x = 0, .y = 0 }, 0, .white);
        if (self.anim.active) self.drawAnimFrame();
        const mx = rl.getMouseX();
        const my = rl.getMouseY();

        ui.drawToolbar(self.ui_font, self.render_w, self.tb_active, &self.tb_buf, self.view, self.btn_w_inc, self.btn_w_dec, self.btn_w_copy, self.btn_w_paste, self.btn_w_reset, mx, my);
        if (self.drag.active) {
            const x0: f32 = @floatCast(@min(self.drag.start_x, self.drag.current_x));
            const y0: f32 = @floatCast(@min(self.drag.start_y, self.drag.current_y));
            const sz: f32 = @floatCast(@abs(self.drag.current_x - self.drag.start_x));
            if (sz >= 8.0) rl.drawRectangleLines(@intFromFloat(x0), @intFromFloat(y0), @intFromFloat(sz), @intFromFloat(sz), .{ .r = 255, .g = 30, .b = 30, .a = 200 });
        }
        ui.drawTooltipCheckbox(self.ui_font, self.render_w, self.tooltip_enabled, self.tooltip_label_w, mx, my);
        ui.drawCoordinateTooltip(self.ui_font, self.render_w, self.render_h, self.dpi_scale, self.image.width, self.image.height, self.view, self.tooltip_enabled, &self.tooltip_mouse_still_since, &self.tooltip_last_mx, &self.tooltip_last_my, mx, my);
        if (self.render_timed_out) {
            const msg = "[Space]: continue";
            const mw = rl.measureText(msg, 18);
            rl.drawText(msg, self.render_w - ui.TOP_PAD - mw, ui.LINE1_H + ui.HINT_PAD_Y, 18, ui.COL_TIMEOUT);
        }
    }
};

test "history_len no-op with garbage entries" {
    var entries: [MAX_HISTORY]HistoryEntry = undefined;
    @memset(std.mem.asBytes(&entries), 0xFF);

    var history_len: usize = 0;

    truncateFuture(&entries, &history_len, 0);
    try std.testing.expectEqual(@as(usize, 0), history_len);

    truncateFuture(&entries, &history_len, MAX_HISTORY);
    try std.testing.expectEqual(@as(usize, 0), history_len);
}

test "computeAnimDuration same view returns min" {
    const v = m.ViewState{ .center_x = -0.75, .center_y = 0.1, .range = 0.5, .max_iters = 256 };
    const d = computeAnimDuration(v, v);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), d, 1e-12);
}

test "computeAnimDuration area ratio extremes" {
    const base = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 2.0, .max_iters = 256 };

    // area_ratio = min(4, 0.01) / max(4, 0.01) = 0.0025 → clamped to 0.1 → area_t = 1 → 0.5
    const tiny = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 0.1, .max_iters = 256 };
    const d_tiny = computeAnimDuration(base, tiny);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), d_tiny, 1e-12);

    // Same range → area_ratio = 1 → clamped to 0.9 → area_t = 0 → 0.1
    const v2 = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 2.0, .max_iters = 256 };
    const d_same = computeAnimDuration(base, v2);
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), d_same, 1e-12);
}

test "computeAnimDuration center distance dominates" {
    const v = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 1.0, .max_iters = 256 };
    // Move center by 2.0 → center_dist = 2.0 = max_range*2 → center_t = 1 → 0.5
    const far = m.ViewState{ .center_x = 1.25, .center_y = 0.0, .range = 1.0, .max_iters = 256 };
    const d = computeAnimDuration(v, far);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), d, 1e-12);
}

test "computeAnimDuration offset contributes to center distance" {
    const v = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 1.0, .max_iters = 256 };
    // Same center, but offset_x moved → dx = -0.75 - (-0.75) + (0 - 0.5) = -0.5, dist = 0.5
    const off = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 1.0, .max_iters = 256, .offset_x = 0.5 };
    const d = computeAnimDuration(v, off);
    // center_dist = 0.5, max_range = 1.0, center_t = min(1, 0.5/2) = 0.25, center_dur = 0.1 + 0.25*0.4 = 0.2
    // area same → area_dur = 0.1
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), d, 1e-12);
}

test "computeAnimDuration result is max of area and center" {
    // Area ratio at 0.25 → area_dur ≈ 0.425
    // Center dist = 0 → center_dur = 0.1
    const from = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 2.0, .max_iters = 256 };
    const to = m.ViewState{ .center_x = -0.75, .center_y = 0.0, .range = 1.0, .max_iters = 256 };
    const d = computeAnimDuration(from, to);
    // area ratio = 1/4 = 0.25, area_t = (0.9-0.25)/0.8 = 0.8125, area_dur = 0.1 + 0.8125*0.4 = 0.425
    try std.testing.expectApproxEqAbs(@as(f64, 0.425), d, 1e-12);
}

test "parseViewState field-based format" {
    const text = "x=-0.75000000 y=0.00000000 range=2.90000000 iters=8192";
    const parsed = parseViewState(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, -0.75), parsed.center_x, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), parsed.center_y, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 2.9), parsed.range, 1e-8);
    try std.testing.expectEqual(@as(u32, 8192), parsed.max_iters);
}

test "parseViewState paren-based format" {
    const text = "(-0.75, 0.0) range=2.9 iters=256";
    const parsed = parseViewState(text) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, -0.75), parsed.center_x, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), parsed.center_y, 1e-8);
    try std.testing.expectApproxEqAbs(@as(f64, 2.9), parsed.range, 1e-8);
    try std.testing.expectEqual(@as(u32, 256), parsed.max_iters);
}

test "parseViewState empty or malformed returns null" {
    try std.testing.expect(parseViewState("") == null);
    try std.testing.expect(parseViewState("junk") == null);
    try std.testing.expect(parseViewState("x=abc") == null);
    try std.testing.expect(parseViewState("x=1.0 y=2.0 range=abc iters=10") == null);
    try std.testing.expect(parseViewState("() range=1 iters=1") == null);
    try std.testing.expect(parseViewState("(1.0) range=1 iters=1") == null);
}

test "isValidCoord rejects out-of-bounds values" {
    const center: f64 = m.INITIAL_CENTER_X;
    const range: f64 = m.INITIAL_RANGE;
    const iters: u32 = m.DEFAULT_MAX_ITERS;

    // Within bounds
    try std.testing.expect(App.isValidCoord(m.ViewState{ .center_x = center, .center_y = 0, .range = range / 2, .max_iters = iters }));

    // center_x too far left
    try std.testing.expect(!App.isValidCoord(m.ViewState{ .center_x = center - range, .center_y = 0, .range = range / 2, .max_iters = iters }));

    // center_x too far right
    try std.testing.expect(!App.isValidCoord(m.ViewState{ .center_x = center + range, .center_y = 0, .range = range / 2, .max_iters = iters }));

    // Range zero
    try std.testing.expect(!App.isValidCoord(m.ViewState{ .center_x = center, .center_y = 0, .range = 0, .max_iters = iters }));

    // Range exceeds max
    try std.testing.expect(!App.isValidCoord(m.ViewState{ .center_x = center, .center_y = 0, .range = range + 1, .max_iters = iters }));

    // Iters below min
    try std.testing.expect(!App.isValidCoord(m.ViewState{ .center_x = center, .center_y = 0, .range = range / 2, .max_iters = m.MIN_ITERS - 1 }));

    // Iters above cap
    try std.testing.expect(!App.isValidCoord(m.ViewState{ .center_x = center, .center_y = 0, .range = range / 2, .max_iters = m.MAX_ITERS_CAP + 1 }));
}