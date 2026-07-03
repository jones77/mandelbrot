const m = @import("mandelbrot.zig");
const rl = @import("raylib");
const std = @import("std");
const renderer = @import("renderer.zig");
const logEvent = @import("log.zig").logEvent;
const PIXEL_CHANNELS = @import("pixel.zig").PIXEL_CHANNELS;

const DEFAULT_W: i32 = 900;
const DEFAULT_H: i32 = 800;

const LINE1_H: i32 = 32;
const LINE2_H: i32 = 28;
const TOTAL_TOP: i32 = LINE1_H + LINE2_H;
const TOP_PAD: i32 = 4;
const TB_H: i32 = 26;
const BTN_GAP: i32 = 4;
const BTN_ARROW: i32 = 28;
const BTN_ITER: i32 = 35;
const BTN_LG: i32 = 55;
const BTN_RESET: i32 = 55;
const TB_CAP: usize = 127;
const MAX_HISTORY: usize = 64;
const MIN_SELECTION_PX: f64 = 8.0;
const RENDER_TIMEOUT_S: f64 = 60.0;
const CLIPBOARD_BUF: usize = 256;

const COL_BG = rl.Color{ .r = 240, .g = 240, .b = 245, .a = 255 };
const COL_BAR = rl.Color{ .r = 235, .g = 235, .b = 240, .a = 255 };
const COL_SEP = rl.Color{ .r = 190, .g = 190, .b = 200, .a = 255 };
const COL_TEXT = rl.Color{ .r = 30, .g = 30, .b = 40, .a = 255 };
const COL_BTN_TEXT = rl.Color{ .r = 50, .g = 50, .b = 60, .a = 255 };
const COL_HINT = rl.Color{ .r = 60, .g = 60, .b = 70, .a = 255 };
const COL_TB_BG = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
const COL_TB_BORDER_ACTIVE = rl.Color{ .r = 0, .g = 120, .b = 255, .a = 255 };
const COL_TB_BORDER = rl.Color{ .r = 180, .g = 180, .b = 190, .a = 255 };
const COL_BTN_BG = rl.Color{ .r = 230, .g = 230, .b = 238, .a = 255 };
const COL_BTN_BG_HOVER = rl.Color{ .r = 220, .g = 220, .b = 228, .a = 255 };
const COL_BTN_BORDER = rl.Color{ .r = 180, .g = 180, .b = 190, .a = 255 };
const COL_TIMEOUT = rl.Color{ .r = 200, .g = 80, .b = 40, .a = 255 };
const COL_DRAG_HIGHLIGHT = rl.Color{ .r = 255, .g = 30, .b = 30, .a = 200 };

const ANIM_DURATION_MIN: f64 = 0.1;
const ANIM_DURATION_MAX: f64 = 0.5;
const ANIM_AREA_RATIO_HI: f64 = 0.9;
const ANIM_AREA_RATIO_LO: f64 = 0.1;
const HIGHLIGHT_FADE_S: f64 = 2.0;

const TEXT_PAD_X: i32 = 6;
const TEXT_PAD_Y: i32 = 4;
const BTN_TEXT_PAD_X: i32 = 6;
const BTN_TEXT_PAD_Y: i32 = 5;
const ARROW_PAD_X: i32 = 6;
const ARROW_PAD_Y: i32 = 3;
const HINT_PAD_X: i32 = 10;
const HINT_PAD_Y: i32 = 4;
const CURSOR_W: i32 = 2;
const CURSOR_H: i32 = 18;

const FONT_SIZE_LG: f32 = 18.0;
const FONT_SIZE_BTN: i32 = 18;
const FONT_SIZE_ARROW: i32 = 18;
const FONT_SIZE_TIMEOUT: i32 = 18;

const FONT_LOAD_SIZE: i32 = 24;
const ASCII_PRN_MIN: i32 = 32;
const ASCII_PRN_MAX: i32 = 126;
const ASCII_PRN_COUNT = ASCII_PRN_MAX - ASCII_PRN_MIN + 1;
const CP_ARROW_LEFT: i32 = 0x2190;
const CP_ARROW_RIGHT: i32 = 0x2192;

const TOOLTIP_LABEL = "[x] tooltip";
const TOOLTIP_LABEL_OFF = "[ ] tooltip";
const TOOLTIP_DELAY_S: f64 = 2.0;
const TOOLTIP_MOVE_THRESHOLD_PX: i32 = 2;
const TOOLTIP_OFFSET_X: i32 = 12;
const TOOLTIP_OFFSET_Y: i32 = 12;
const TOOLTIP_PAD_X: i32 = 8;
const TOOLTIP_PAD_Y: i32 = 4;

const TextBuf = struct {
    buf: [TB_CAP + 1]u8,
    len: usize,
    cursor: usize,

    fn init() TextBuf {
        var tb = TextBuf{ .buf = undefined, .len = 0, .cursor = 0 };
        tb.buf[0] = 0;
        return tb;
    }

    fn slice(self: TextBuf) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    fn format(self: *TextBuf, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(self.buf[0..TB_CAP], fmt, args) catch {
            self.len = 0;
            self.buf[0] = 0;
            self.cursor = 0;
            return;
        };
        self.len = written.len;
        self.cursor = self.len;
        self.buf[self.len] = 0;
    }

    fn insertChar(self: *TextBuf, ch: u8) void {
        if (self.len >= TB_CAP) return;
        var i = self.len;
        while (i > self.cursor) : (i -= 1) {
            self.buf[i] = self.buf[i - 1];
        }
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
        self.buf[self.len] = 0;
    }

    fn deleteBeforeCursor(self: *TextBuf) void {
        if (self.cursor == 0) return;
        var i = self.cursor;
        while (i < self.len) : (i += 1) {
            self.buf[i - 1] = self.buf[i];
        }
        self.len -= 1;
        self.cursor -= 1;
        self.buf[self.len] = 0;
    }

    fn deleteAfterCursor(self: *TextBuf) void {
        if (self.cursor == self.len) return;
        var i = self.cursor;
        while (i < self.len) : (i += 1) {
            self.buf[i] = self.buf[i + 1];
        }
        self.len -= 1;
        self.buf[self.len] = 0;
    }

    fn moveCursorLeft(self: *TextBuf) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    fn moveCursorRight(self: *TextBuf) void {
        if (self.cursor < self.len) self.cursor += 1;
    }

    fn moveHome(self: *TextBuf) void {
        self.cursor = 0;
    }

    fn moveEnd(self: *TextBuf) void {
        self.cursor = self.len;
    }

    /// Returns the text before the cursor as a null-terminated slice.
    /// Temporarily modifies buf[cursor] to ensure proper termination.
    fn beforeCursor(self: *TextBuf) [:0]const u8 {
        const saved = self.buf[self.cursor];
        self.buf[self.cursor] = 0;
        const result = self.buf[0..self.cursor :0];
        self.buf[self.cursor] = saved;
        return result;
    }
};

const DragState = struct {
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
    active: bool,
};

const ZoomAnimation = struct {
    from_view: m.ViewState,
    to_view: m.ViewState,
    start_time: f64,
    duration: f64,
    active: bool,
};

const HighlightRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    start_time: f64,
    active: bool,
};

const HistoryEntry = struct {
    view: m.ViewState,
    w: usize,
    h: usize,
    pixels: []u8,
};

fn pushHistory(
    history: []HistoryEntry,
    history_len: *usize,
    history_ptr: *usize,
    view: m.ViewState,
    data: []const u8,
    w: usize,
    h: usize,
) !void {
    if (history_len.* >= MAX_HISTORY) return;
    const px_size = w * h * PIXEL_CHANNELS;
    const pixels = try std.heap.page_allocator.alloc(u8, px_size);
    @memcpy(pixels, data[0..px_size]);
    history[history_len.*] = HistoryEntry{
        .view = view,
        .pixels = pixels,
        .w = w,
        .h = h,
    };
    history_len.* += 1;
    history_ptr.* = history_len.* - 1;
}

fn truncateFuture(history: []HistoryEntry, history_len: *usize, index: usize) void {
    while (index < history_len.*) {
        history_len.* -= 1;
        std.heap.page_allocator.free(history[history_len.*].pixels);
    }
}

fn computeAnimDuration(from_view: m.ViewState, to_view: m.ViewState) f64 {
    const area_from = from_view.range * from_view.range;
    const area_to = to_view.range * to_view.range;
    const area_ratio = @min(area_from, area_to) / @max(area_from, area_to);
    const area_clamped = @max(ANIM_AREA_RATIO_LO, @min(ANIM_AREA_RATIO_HI, area_ratio));
    const area_t = (ANIM_AREA_RATIO_HI - area_clamped) / (ANIM_AREA_RATIO_HI - ANIM_AREA_RATIO_LO);
    const area_duration = ANIM_DURATION_MIN + area_t * (ANIM_DURATION_MAX - ANIM_DURATION_MIN);

    const max_range = @max(from_view.range, to_view.range);
    // Use effective center difference (including sub-precise offset) for deep zoom.
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

fn parseViewState(text: []const u8) ?m.ViewState {
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

const ToolbarLayout = struct {
    arrow_l_x: i32,
    arrow_r_x: i32,
    tb_start_x: i32,
    tb_w: i32,
    inc_x: i32,
    dec_x: i32,
    copy_x: i32,
    paste_x: i32,
    reset_x: i32,

    fn compute(render_w: i32) ToolbarLayout {
        const arrow_l_x: i32 = TOP_PAD;
        const arrow_r_x: i32 = arrow_l_x + BTN_ARROW + BTN_GAP;
        const tb_start_x: i32 = arrow_r_x + BTN_ARROW + BTN_GAP;

        const reset_x = render_w - TOP_PAD - BTN_RESET;
        const paste_x = reset_x - BTN_GAP - BTN_LG;
        const copy_x = paste_x - BTN_GAP - BTN_LG;
        const dec_x = copy_x - BTN_GAP - BTN_ITER;
        const inc_x = dec_x - BTN_GAP - BTN_ITER;
        const tb_w = inc_x - BTN_GAP - tb_start_x;

        return .{
            .arrow_l_x = arrow_l_x,
            .arrow_r_x = arrow_r_x,
            .tb_start_x = tb_start_x,
            .tb_w = tb_w,
            .inc_x = inc_x,
            .dec_x = dec_x,
            .copy_x = copy_x,
            .paste_x = paste_x,
            .reset_x = reset_x,
        };
    }
};

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
    highlight: HighlightRect,
    tb_buf: TextBuf,
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

    pub fn init(render_method: m.RenderMethod, tooltip_enabled: bool) !App {
        m.buildPalette();
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        const dpi = @divTrunc(sw, DEFAULT_W);
        const rw = @divExact(sw, dpi);
        const rh = @divExact(sh, dpi);
        const top_phys = TOTAL_TOP * dpi;
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
            .highlight = HighlightRect{ .x = 0, .y = 0, .w = 0, .h = 0, .start_time = 0, .active = false },
            .tb_buf = TextBuf.init(),
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
        };

        {
            const candidates = [_][:0]const u8{
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            };
            for (candidates) |path| {
                const CP_COUNT = ASCII_PRN_COUNT + 2;
                var cps: [CP_COUNT]i32 = undefined;
                for (0..@as(usize, @intCast(ASCII_PRN_COUNT))) |i| cps[i] = @as(i32, @intCast(i + ASCII_PRN_MIN));
                cps[@as(usize, @intCast(ASCII_PRN_COUNT))] = CP_ARROW_LEFT;
                cps[@as(usize, @intCast(ASCII_PRN_COUNT + 1))] = CP_ARROW_RIGHT;
                const f = rl.loadFontEx(path, FONT_LOAD_SIZE, &cps) catch continue;
                if (f.texture.id > 0) {
                    app.ui_font = f;
                    break;
                }
                rl.unloadFont(f);
            }
        }

        rl.setTextureFilter(app.texture, .point);
        app.btn_w_inc = rl.measureTextEx(app.ui_font, "inc", @floatFromInt(FONT_SIZE_BTN), 0).x;
        app.btn_w_dec = rl.measureTextEx(app.ui_font, "dec", @floatFromInt(FONT_SIZE_BTN), 0).x;
        app.btn_w_copy = rl.measureTextEx(app.ui_font, "copy", @floatFromInt(FONT_SIZE_BTN), 0).x;
        app.btn_w_paste = rl.measureTextEx(app.ui_font, "paste", @floatFromInt(FONT_SIZE_BTN), 0).x;
        app.btn_w_reset = rl.measureTextEx(app.ui_font, "reset", @floatFromInt(FONT_SIZE_BTN), 0).x;
        app.tooltip_label_w = rl.measureTextEx(app.ui_font, TOOLTIP_LABEL, FONT_SIZE_LG, 1).x;
        app.tooltip_mouse_still_since = rl.getTime();
        app.syncTextBox();
        logEvent(.app, "init {d}x{d} dpi={d} method={s}", .{ rw, rh, dpi, @tagName(render_method) });
        return app;
    }

    pub fn cancelAnimation(self: *App) void {
        self.anim.active = false;
    }

    fn viewportRect(self: *const App) rl.Rectangle {
        return .{
            .x = 0,
            .y = @floatFromInt(TOTAL_TOP),
            .width = @floatFromInt(self.render_w),
            .height = @floatFromInt(self.render_h - TOTAL_TOP),
        };
    }

    fn viewportAspect(self: *const App) f64 {
        return @as(f64, @floatFromInt(self.image.width)) / @as(f64, @floatFromInt(self.image.height));
    }

    fn viewportDrawHeight(self: *const App) i32 {
        return self.render_h - TOTAL_TOP;
    }

    fn captureAnimationFrame(self: *App) !void {
        const px_size: usize = @intCast(self.image.width * self.image.height * PIXEL_CHANNELS);
        const pixels = try std.heap.page_allocator.alloc(u8, px_size);
        defer std.heap.page_allocator.free(pixels);
        @memcpy(pixels, self.pixelData());

        if (self.anim_texture) |tex| {
            if (tex.width == self.image.width and tex.height == self.image.height) {
                rl.updateTexture(tex, @ptrCast(pixels));
                return;
            }
            rl.unloadTexture(tex);
        }

        const img = rl.Image{
            .data = @ptrCast(pixels),
            .width = self.image.width,
            .height = self.image.height,
            .mipmaps = 1,
            .format = .uncompressed_r8g8b8a8,
        };
        self.anim_texture = try rl.loadTextureFromImage(img);
        rl.setTextureFilter(self.anim_texture.?, .point);
    }

    pub fn deinit(self: *App) void {
        logEvent(.app, "shutdown", .{});
        self.cancelAnimation();
        if (self.anim_texture) |tex| rl.unloadTexture(tex);
        for (0..self.history_len) |i| {
            if (self.history[i].pixels.len > 0)
                std.heap.page_allocator.free(self.history[i].pixels);
        }
        if (self.rows_completed) |rc| std.heap.page_allocator.free(rc);
        rl.unloadTexture(self.texture);
        rl.unloadImage(self.image);
        rl.unloadFont(self.ui_font);
    }

    pub fn renderFresh(self: *App, clear: bool) !bool {
        const w: usize = @intCast(self.image.width);
        const h: usize = @intCast(self.image.height);
        const pixels = @as([*]u8, @ptrCast(self.image.data))[0 .. w * h * PIXEL_CHANNELS];

        if (clear) {
            if (self.rows_completed) |rc| std.heap.page_allocator.free(rc);
            self.rows_completed = try std.heap.page_allocator.alloc(bool, h);
            @memset(self.rows_completed.?, false);
        } else if (self.rows_completed == null or self.rows_completed.?.len != h) {
            if (self.rows_completed) |rc| std.heap.page_allocator.free(rc);
            self.rows_completed = try std.heap.page_allocator.alloc(bool, h);
            @memset(self.rows_completed.?, false);
        }

        self.render_timed_out = try renderer.renderMandelbrot(
            pixels, w, h, self.view, clear,
            RENDER_TIMEOUT_S, rl.getTime,
            self.rows_completed,
        );
        if (self.render_timed_out) logEvent(.render, "timeout", .{});
        if (!self.render_timed_out) {
            if (self.rows_completed) |rc| {
                std.heap.page_allocator.free(rc);
                self.rows_completed = null;
            }
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
        try pushHistory(
            &self.history, &self.history_len, &self.history_ptr,
            self.view, self.pixelData(),
            @intCast(self.image.width), @intCast(self.image.height),
        );
    }

    fn setupZoomOutHighlight(self: *App, from_view: m.ViewState, to_view: m.ViewState) void {
        const aspect = self.viewportAspect();
        const vph = self.viewportDrawHeight();
        const draw_w: f32 = @floatFromInt(self.render_w);
        const draw_h: f32 = @floatFromInt(vph);
        // Effective center difference (handles deep zoom sub-precise offsets).
        const cx_diff = (from_view.center_x - to_view.center_x) + (from_view.offset_x - to_view.offset_x);
        const cy_diff = (from_view.center_y - to_view.center_y) + (from_view.offset_y - to_view.offset_y);
        const r_diff = to_view.range - from_view.range;
        self.highlight.x = @floatCast((cx_diff - r_diff / 2.0) / to_view.range * draw_w);
        self.highlight.y = @floatCast((cy_diff - r_diff / (2.0 * aspect)) / (to_view.range / aspect) * draw_h + @as(f32, @floatFromInt(TOTAL_TOP)));
        self.highlight.w = @floatCast(from_view.range / to_view.range * draw_w);
        self.highlight.h = @floatCast(from_view.range / to_view.range * draw_h);
        self.highlight.start_time = rl.getTime();
        self.highlight.active = true;
    }

    fn startZoomAnimation(self: *App, to_entry: *const HistoryEntry) !void {
        self.cancelAnimation();

        const from_view = self.view;
        const to_view = to_entry.view;

        if (to_view.range > from_view.range) {
            self.setupZoomOutHighlight(from_view, to_view);
        } else {
            self.highlight.active = false;
        }

        try self.captureAnimationFrame();

        self.anim.from_view = from_view;
        self.anim.to_view = to_view;
        self.anim.duration = computeAnimDuration(from_view, to_view);

        // Immediately restore destination cached image to main texture.
        if (to_entry.w == @as(usize, @intCast(self.image.width)) and
            to_entry.h == @as(usize, @intCast(self.image.height)))
        {
            const pixels = @as([*]u8, @ptrCast(self.image.data))[0 .. to_entry.w * to_entry.h * PIXEL_CHANNELS];
            @memcpy(pixels, to_entry.pixels);
            rl.updateTexture(self.texture, self.image.data);
        } else {
            _ = try self.renderFresh(true);
        }
        self.view = to_view;
        self.syncTextBox();

        self.anim.start_time = rl.getTime();
        self.anim.active = true;
        logEvent(.anim, "start {s} dur={d:.3} from={d:.6} to={d:.6}", .{
            if (to_view.range > from_view.range) "out" else "in",
            self.anim.duration, from_view.range, to_view.range,
        });
    }

    fn drawAnimFrame(self: *App) void {
        const anim = &self.anim;
        const elapsed = rl.getTime() - anim.start_time;
        const t_raw = elapsed / anim.duration;
        if (t_raw >= 1.0) {
            logEvent(.anim, "end", .{});
            self.cancelAnimation();
            return;
        }
        const t = t_raw;

        const interp = m.lerpViewState(anim.from_view, anim.to_view, t);
        const tex = self.anim_texture.?;
        const tex_w: f32 = @floatFromInt(tex.width);
        const tex_h: f32 = @floatFromInt(tex.height);

        const vp = self.viewportRect();
        const aspect = self.viewportAspect();
        const draw_w = vp.width;
        const draw_h = vp.height;
        const draw_y = vp.y;

        const from_view = &anim.from_view;

        if (interp.range <= from_view.range) {
            // Effective center offset (handles deep zoom where f64 loses
            // center_x + offset_x precision).  At normal zoom the center
            // difference dominates; at deep zoom the offset difference
            // captures all movement.
            const cx_diff = (interp.center_x - from_view.center_x) + (interp.offset_x - from_view.offset_x);
            const cy_diff = (interp.center_y - from_view.center_y) + (interp.offset_y - from_view.offset_y);

            const interp_left_offset = cx_diff - (interp.range - from_view.range) / 2.0;
            const interp_top_offset = cy_diff - (interp.range - from_view.range) / (2.0 * aspect);

            const src_x: f32 = @floatCast(@max(0.0, interp_left_offset / from_view.range * tex_w));
            const src_y: f32 = @floatCast(@max(0.0, interp_top_offset / (from_view.range / aspect) * tex_h));
            const src_w: f32 = @floatCast(@max(0.0, @min(interp.range / from_view.range * tex_w, tex_w - src_x)));
            const src_h: f32 = @floatCast(@max(0.0, @min(interp.range / from_view.range * tex_h, tex_h - src_y)));

            const src = rl.Rectangle{ .x = src_x, .y = src_y, .width = src_w, .height = src_h };
            const dst = rl.Rectangle{ .x = 0, .y = draw_y, .width = draw_w, .height = draw_h };
            rl.drawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, 0, .white);
        } else {
            const fraction: f32 = @floatCast(from_view.range / interp.range);
            const cx_diff = (from_view.center_x - interp.center_x) + (from_view.offset_x - interp.offset_x);
            const cy_diff = (from_view.center_y - interp.center_y) + (from_view.offset_y - interp.offset_y);
            const offset_x: f32 = @floatCast(cx_diff / interp.range + 0.5);
            const offset_y: f32 = @floatCast(cy_diff / (interp.range / aspect) + 0.5);

            const dst_x = offset_x * draw_w - fraction * draw_w / 2.0;
            const dst_y = draw_y + (offset_y * draw_h - fraction * draw_h / 2.0);
            const dst_w = fraction * draw_w;
            const dst_h = fraction * draw_h;

            const src = rl.Rectangle{ .x = 0, .y = 0, .width = tex_w, .height = tex_h };
            const dst = rl.Rectangle{ .x = dst_x, .y = dst_y, .width = dst_w, .height = dst_h };
            rl.drawTexturePro(tex, src, dst, .{ .x = 0, .y = 0 }, 0, .white);
        }
    }

    fn drawHighlight(self: *App) void {
        const h = &self.highlight;
        if (!h.active) return;
        const elapsed = rl.getTime() - h.start_time;
        if (elapsed >= HIGHLIGHT_FADE_S) {
            h.active = false;
            return;
        }
        const alpha: u8 = @intFromFloat(255.0 * (1.0 - elapsed / HIGHLIGHT_FADE_S));
        const color = rl.Color{ .r = 255, .g = 30, .b = 30, .a = alpha };
        rl.drawRectangleLines(@intFromFloat(h.x), @intFromFloat(h.y), @intFromFloat(h.w), @intFromFloat(h.h), color);
    }

    fn syncTextBox(self: *App) void {
        self.tb_buf.format(VIEW_FMT, .{
            self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters,
        });
    }

    fn isValidCoord(parsed: m.ViewState) bool {
        const x_min = m.INITIAL_CENTER_X - m.INITIAL_RANGE / 2.0;
        const x_max = m.INITIAL_CENTER_X + m.INITIAL_RANGE / 2.0;
        const y_min = m.INITIAL_CENTER_Y - m.INITIAL_RANGE / 2.0;
        const y_max = m.INITIAL_CENTER_Y + m.INITIAL_RANGE / 2.0;
        if (parsed.center_x < x_min or parsed.center_x > x_max) return false;
        if (parsed.center_y < y_min or parsed.center_y > y_max) return false;
        if (parsed.range <= 0 or parsed.range > m.INITIAL_RANGE) return false;
        if (parsed.max_iters < m.MIN_ITERS or parsed.max_iters > m.MAX_ITERS_CAP) return false;
        return true;
    }

    fn textBoxApply(self: *App) !void {
        self.cancelAnimation();
        const parsed = parseViewState(self.tb_buf.buf[0..self.tb_buf.len]) orelse {
            self.syncTextBox();
            return;
        };
        if (!isValidCoord(parsed)) {
            self.syncTextBox();
            return;
        }
        const same = parsed.center_x == self.view.center_x and
            parsed.center_y == self.view.center_y and
            parsed.range == self.view.range and
            parsed.max_iters == self.view.max_iters;
        if (same) return;
        logEvent(.ui, "textbox apply range={d:.6}", .{parsed.range});
        truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
        self.view = parsed;
        _ = try self.renderFresh(true);
        try self.saveSnapshot();
    }

    const VIEW_FMT = "x={d:.8} y={d:.8} range={e:.8} iters={d}";

    fn adjustIters(self: *App, increase: bool) !void {
        const old_iters = self.view.max_iters;
        self.cancelAnimation();
        truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
        self.view.max_iters = if (increase)
            @min(m.MAX_ITERS_CAP, self.view.max_iters +| self.view.max_iters)
        else
            @max(m.MIN_ITERS, self.view.max_iters / 2);
        logEvent(.iters, "{s} from {d} to {d}", .{ if (increase) "inc" else "dec", old_iters, self.view.max_iters });
        _ = try self.renderFresh(true);
        try self.saveSnapshot();
    }

    fn resetView(self: *App) !void {
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
        if (self.anim_texture) |tex| {
            rl.unloadTexture(tex);
            self.anim_texture = null;
        }
        if (self.rows_completed) |rc| {
            std.heap.page_allocator.free(rc);
            self.rows_completed = null;
        }
        logEvent(.app, "resize {d}x{d} -> {d}x{d}", .{ self.screen_w, self.screen_h, new_w, new_h });

        self.screen_w = new_w;
        self.screen_h = new_h;
        self.render_w = @divExact(new_w, self.dpi_scale);
        self.render_h = @divExact(new_h, self.dpi_scale);
        const vh = new_h - TOTAL_TOP * self.dpi_scale;
        rl.unloadTexture(self.texture);
        rl.unloadImage(self.image);
        self.image = rl.genImageColor(new_w, vh, .black);
        self.texture = try rl.loadTextureFromImage(self.image);
        rl.setTextureFilter(self.texture, .point);
        _ = try self.renderFresh(true);
    }

    pub fn handleInput(self: *App) !void {
        const mx = rl.getMouseX();
        const my = rl.getMouseY();
        const in_top = my < TOTAL_TOP;
        var tb_click_consumed = false;

        // -- Top bar interactions (text box, buttons) --
        if (in_top and rl.isMouseButtonPressed(.left)) {
            const tb_y: i32 = (LINE1_H - TB_H) / 2;
            const tb = ToolbarLayout.compute(self.render_w);

            const in_tb = mx >= tb.tb_start_x and mx < tb.tb_start_x + tb.tb_w and my >= tb_y and my < tb_y + TB_H;
            if (in_tb) {
                self.tb_active = true;
                tb_click_consumed = true;
            } else {
                if (self.tb_active) {
                    self.tb_active = false;
                    self.syncTextBox();
                    tb_click_consumed = true;
                }
                if (mx >= tb.arrow_l_x and mx < tb.arrow_l_x + BTN_ARROW and my >= tb_y and my < tb_y + TB_H) {
                    if (self.history_ptr > 0) {
                        self.history_ptr -= 1;
                        try self.startZoomAnimation(&self.history[self.history_ptr]);
                        logEvent(.history, "back entry={d} range={d:.6} anim={s}", .{ self.history_ptr, self.history[self.history_ptr].view.range, if (self.anim.active) "active" else "idle" });
                    } else {
                        logEvent(.history, "back ignored ptr={d} len={d} anim={s}", .{ self.history_ptr, self.history_len, if (self.anim.active) "active" else "idle" });
                    }
                    tb_click_consumed = true;
                }
                if (mx >= tb.arrow_r_x and mx < tb.arrow_r_x + BTN_ARROW and my >= tb_y and my < tb_y + TB_H) {
                    if (self.history_ptr + 1 < self.history_len) {
                        self.history_ptr += 1;
                        try self.startZoomAnimation(&self.history[self.history_ptr]);
                        logEvent(.history, "forward entry={d} range={d:.6} anim={s}", .{ self.history_ptr, self.history[self.history_ptr].view.range, if (self.anim.active) "active" else "idle" });
                    } else {
                        logEvent(.history, "forward ignored ptr={d} len={d} anim={s}", .{ self.history_ptr, self.history_len, if (self.anim.active) "active" else "idle" });
                    }
                    tb_click_consumed = true;
                }
                if (mx >= tb.inc_x and mx < tb.inc_x + BTN_ITER and my >= tb_y and my < tb_y + TB_H) {
                    try self.adjustIters(true);
                    tb_click_consumed = true;
                }
                if (mx >= tb.dec_x and mx < tb.dec_x + BTN_ITER and my >= tb_y and my < tb_y + TB_H) {
                    try self.adjustIters(false);
                    tb_click_consumed = true;
                }
                if (mx >= tb.copy_x and mx < tb.copy_x + BTN_LG and my >= tb_y and my < tb_y + TB_H) {
                    var buf: [CLIPBOARD_BUF]u8 = undefined;
                    const text = std.fmt.bufPrintZ(&buf, VIEW_FMT, .{
                        self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters,
                    }) catch unreachable;
                    rl.setClipboardText(text);
                    logEvent(.ui, "clipboard copy", .{});
                    tb_click_consumed = true;
                }
                if (mx >= tb.paste_x and mx < tb.paste_x + BTN_LG and my >= tb_y and my < tb_y + TB_H) {
                    const clip = std.mem.sliceTo(rl.getClipboardText(), 0);
                    if (clip.len > 0) {
                        self.tb_buf.format("{s}", .{clip});
                        if (parseViewState(self.tb_buf.buf[0..self.tb_buf.len])) |_| {
                            self.tb_active = false;
                            try self.textBoxApply();
                        } else {
                            self.syncTextBox();
                        }
                        logEvent(.ui, "clipboard paste", .{});
                    }
                    tb_click_consumed = true;
                }
                if (mx >= tb.reset_x and mx < tb.reset_x + BTN_RESET and my >= tb_y and my < tb_y + TB_H) {
                    try self.resetView();
                    tb_click_consumed = true;
                }
                // Second line: tooltip checkbox toggle
                if (my >= LINE1_H and my < TOTAL_TOP) {
                    const chk_x = self.render_w - TOP_PAD - @as(i32, @intFromFloat(self.tooltip_label_w));
                    if (mx >= chk_x and mx < self.render_w - TOP_PAD) {
                        self.tooltip_enabled = !self.tooltip_enabled;
                        tb_click_consumed = true;
                    }
                }
            }
        }

        if (self.tb_active and rl.isMouseButtonPressed(.left) and !in_top) {
            self.tb_active = false;
            self.syncTextBox();
            tb_click_consumed = true;
        }

        if (!self.tb_active) {
            const key_left = rl.isKeyPressed(.left);
            const key_right = rl.isKeyPressed(.right);
            if (key_left or key_right) {
                if (key_left) {
                    if (self.history_ptr > 0) {
                        self.history_ptr -= 1;
                        try self.startZoomAnimation(&self.history[self.history_ptr]);
                        logEvent(.history, "back entry={d} range={d:.6} anim={s}", .{ self.history_ptr, self.history[self.history_ptr].view.range, if (self.anim.active) "active" else "idle" });
                    } else {
                        logEvent(.history, "back ignored ptr={d} len={d} anim={s}", .{ self.history_ptr, self.history_len, if (self.anim.active) "active" else "idle" });
                    }
                } else {
                    if (self.history_ptr + 1 < self.history_len) {
                        self.history_ptr += 1;
                        try self.startZoomAnimation(&self.history[self.history_ptr]);
                        logEvent(.history, "forward entry={d} range={d:.6} anim={s}", .{ self.history_ptr, self.history[self.history_ptr].view.range, if (self.anim.active) "active" else "idle" });
                    } else {
                        logEvent(.history, "forward ignored ptr={d} len={d} anim={s}", .{ self.history_ptr, self.history_len, if (self.anim.active) "active" else "idle" });
                    }
                }
            }
        }
        {
            const key_inc = rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add);
            const key_dec = rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract);
            if (key_inc) {
                try self.adjustIters(true);
            } else if (key_dec) {
                try self.adjustIters(false);
            }
        }
        if (rl.isKeyPressed(.r)) {
            try self.resetView();
        }
        if (self.render_timed_out and rl.isKeyPressed(.space)) {
            logEvent(.render, "continue", .{});
            _ = try self.renderFresh(false);
        }

        if (self.tb_active) {
            if (rl.isKeyPressed(.left)) self.tb_buf.moveCursorLeft();
            if (rl.isKeyPressed(.right)) self.tb_buf.moveCursorRight();
            if (rl.isKeyPressed(.home)) self.tb_buf.moveHome();
            if (rl.isKeyPressed(.end)) self.tb_buf.moveEnd();
            if (rl.isKeyPressed(.backspace)) self.tb_buf.deleteBeforeCursor();
            if (rl.isKeyPressed(.delete)) self.tb_buf.deleteAfterCursor();
            if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) {
                self.tb_active = false;
                try self.textBoxApply();
            }
            if (rl.isKeyPressed(.escape)) {
                self.tb_active = false;
                self.syncTextBox();
            }
            var ch = rl.getCharPressed();
            while (ch != 0) {
                if (ch >= ASCII_PRN_MIN and ch < ASCII_PRN_MAX + 1) self.tb_buf.insertChar(@as(u8, @intCast(ch)));
                ch = rl.getCharPressed();
            }
            return;
        }

        if (!tb_click_consumed and !in_top and rl.isMouseButtonPressed(.left)) {
            self.drag.start_x = @floatFromInt(rl.getMouseX());
            self.drag.start_y = @floatFromInt(rl.getMouseY());
            self.drag.current_x = self.drag.start_x;
            self.drag.current_y = self.drag.start_y;
            self.drag.active = true;
        }

        if (self.drag.active and rl.isMouseButtonDown(.left)) {
            const raw_mx: f64 = @floatFromInt(rl.getMouseX());
            const raw_my: f64 = @floatFromInt(rl.getMouseY());
            const sq = m.constrainDragSquare(self.drag.start_x, self.drag.start_y, raw_mx, raw_my);
            self.drag.current_x = sq.x;
            self.drag.current_y = sq.y;
        }

        if (self.drag.active and rl.isMouseButtonReleased(.left)) {
            self.cancelAnimation();
            defer self.drag.active = false;

            const size = @abs(self.drag.current_x - self.drag.start_x);
            if (size < MIN_SELECTION_PX) return;

            const sel_cx = (self.drag.start_x + self.drag.current_x) / 2.0;
            const sel_cy = (self.drag.start_y + self.drag.current_y) / 2.0;
            const dpi_f = @as(f64, @floatFromInt(self.dpi_scale));
            const phys_cx = sel_cx * dpi_f;
            const phys_cy = (sel_cy - @as(f64, @floatFromInt(TOTAL_TOP))) * dpi_f;
            const phys_size = size * dpi_f;

            const smaller = @min(self.image.width, self.image.height);
            const new_range = self.view.range * (phys_size / @as(f64, @floatFromInt(smaller)));
            logEvent(.drag, "zoom from {d:.6} to {d:.6} iters={d}", .{ self.view.range, new_range, self.view.max_iters });

            // Compute center offset relative to current view instead of using
            // screenToComplex, which loses sub-precise position at deep zoom.
            const aspect = self.viewportAspect();
            const delta_x = (phys_cx / @as(f64, @floatFromInt(self.image.width)) - 0.5) * self.view.range;
            const delta_y = (phys_cy / @as(f64, @floatFromInt(self.image.height)) - 0.5) * (self.view.range / aspect);

            // Compute new center + offset (fold or keep separate based on zoom depth).
            const delta = m.computeDragDelta(self.view, delta_x, delta_y);

            truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);

            {
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

                self.anim.from_view = from_view;
                self.anim.to_view = to_view;
                self.anim.duration = computeAnimDuration(from_view, to_view);
            }

            self.view.center_x = delta.center_x;
            self.view.center_y = delta.center_y;
            self.view.offset_x = delta.offset_x;
            self.view.offset_y = delta.offset_y;
            self.view.range = new_range;

            const target_iters = m.computeAutoZoomIters(self.view.range);
            if (target_iters > self.view.max_iters and target_iters <= m.AUTO_SCALE_CAP) {
                self.view.max_iters = target_iters;
            }

            _ = try self.renderFresh(true);

            if (self.history_len < MAX_HISTORY) {
                try self.saveSnapshot();
            }

            self.anim.start_time = rl.getTime();
            self.anim.active = true;
        }

        self.syncTextBox();
    }

    fn pixelCenterToComplex(self: *const App, px: f64, py: f64) struct { x: f64, y: f64 } {
        const w: f64 = @floatFromInt(self.image.width);
        const h: f64 = @floatFromInt(self.image.height);
        const aspect = self.viewportAspect();
        const range_x = self.view.range;
        const range_y = self.view.range / aspect;
        const cx = (self.view.center_x + self.view.offset_x) + ((px + 0.5) / w - 0.5) * range_x;
        const cy = (self.view.center_y + self.view.offset_y) - ((py + 0.5) / h - 0.5) * range_y;
        return .{ .x = cx, .y = cy };
    }

    fn drawToolbarButton(self: *const App, x: i32, w: i32, label: [:0]const u8, label_w: f32, btn_y: i32, btn_h: i32, mx: i32, my: i32) void {
        const hover = mx >= x and mx < x + w and my >= btn_y and my < btn_y + btn_h;
        rl.drawRectangle(x, btn_y, w, btn_h, if (hover) COL_BTN_BG_HOVER else COL_BTN_BG);
        rl.drawRectangleLines(x, btn_y, w, btn_h, COL_BTN_BORDER);
        const cx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(w)) - label_w) / 2.0;
        rl.drawTextEx(self.ui_font, label, .{ .x = cx, .y = @floatFromInt(btn_y + BTN_TEXT_PAD_Y) }, @floatFromInt(FONT_SIZE_BTN), 0, COL_BTN_TEXT);
    }

    fn drawToolbarArrow(self: *const App, x: i32, cp: i32, btn_y: i32, btn_h: i32, mx: i32, my: i32) void {
        const hover = mx >= x and mx < x + BTN_ARROW and my >= btn_y and my < btn_y + btn_h;
        rl.drawRectangle(x, btn_y, BTN_ARROW, btn_h, if (hover) COL_BTN_BG_HOVER else COL_BTN_BG);
        rl.drawRectangleLines(x, btn_y, BTN_ARROW, btn_h, COL_BTN_BORDER);
        rl.drawTextCodepoint(self.ui_font, cp, .{ .x = @floatFromInt(x + ARROW_PAD_X), .y = @floatFromInt(btn_y + ARROW_PAD_Y) }, FONT_SIZE_ARROW, COL_BTN_TEXT);
    }

    pub fn drawFrame(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(COL_BG);
        {
            const src = rl.Rectangle{ .x = 0, .y = 0, .width = @floatFromInt(self.texture.width), .height = @floatFromInt(self.texture.height) };
            const dst = self.viewportRect();
            rl.drawTexturePro(self.texture, src, dst, .{ .x = 0, .y = 0 }, 0, .white);
        }
        if (self.anim.active) {
            self.drawAnimFrame();
        }

        const mx = rl.getMouseX();
        const my = rl.getMouseY();

        rl.drawRectangle(0, 0, self.render_w, LINE1_H, COL_BAR);
        rl.drawRectangle(0, LINE1_H, self.render_w, 1, COL_SEP);
        rl.drawRectangle(0, LINE1_H + 1, self.render_w, LINE2_H, COL_BAR);
        rl.drawRectangle(0, TOTAL_TOP - 1, self.render_w, 1, COL_SEP);

        rl.drawTextEx(self.ui_font, "drag to zoom    \xe2\x86\x90 left arrow zooms out    \xe2\x86\x92 right arrow zooms back in    press R to reset", .{ .x = @floatFromInt(HINT_PAD_X), .y = @floatFromInt(LINE1_H + HINT_PAD_Y) }, FONT_SIZE_LG, 1, COL_HINT);

        const tb_y: i32 = (LINE1_H - TB_H) / 2;
        const btn_y: i32 = tb_y;
        const btn_h: i32 = TB_H;
        const tb = ToolbarLayout.compute(self.render_w);

        rl.drawRectangle(tb.tb_start_x, tb_y, tb.tb_w, TB_H, COL_TB_BG);
        rl.drawRectangleLines(tb.tb_start_x, tb_y, tb.tb_w, TB_H,
            if (self.tb_active) COL_TB_BORDER_ACTIVE else COL_TB_BORDER);

        var display_buf: [CLIPBOARD_BUF]u8 = undefined;
        const display_text = if (self.tb_active)
            self.tb_buf.slice()
        else
            std.fmt.bufPrintZ(&display_buf, VIEW_FMT, .{
                self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters,
            }) catch unreachable;
        rl.drawTextEx(self.ui_font, display_text, .{ .x = @floatFromInt(tb.tb_start_x + TEXT_PAD_X), .y = @floatFromInt(tb_y + TEXT_PAD_Y) }, FONT_SIZE_LG, 1.0, COL_TEXT);

        if (self.tb_active) {
            const blink = @as(u32, @intFromFloat(rl.getTime() * 2.0)) & 1;
            if (blink == 0) {
                const m2 = rl.measureTextEx(self.ui_font, self.tb_buf.beforeCursor(), FONT_SIZE_LG, 1.0);
                const cx = tb.tb_start_x + TEXT_PAD_X + @as(i32, @intFromFloat(m2.x));
                rl.drawRectangle(cx, tb_y + TEXT_PAD_Y, CURSOR_W, CURSOR_H, COL_TB_BORDER_ACTIVE);
            }
        }

        self.drawToolbarArrow(tb.arrow_l_x, CP_ARROW_LEFT, btn_y, btn_h, mx, my);
        self.drawToolbarArrow(tb.arrow_r_x, CP_ARROW_RIGHT, btn_y, btn_h, mx, my);
        self.drawToolbarButton(tb.inc_x, BTN_ITER, "inc", self.btn_w_inc, btn_y, btn_h, mx, my);
        self.drawToolbarButton(tb.dec_x, BTN_ITER, "dec", self.btn_w_dec, btn_y, btn_h, mx, my);
        self.drawToolbarButton(tb.copy_x, BTN_LG, "copy", self.btn_w_copy, btn_y, btn_h, mx, my);
        self.drawToolbarButton(tb.paste_x, BTN_LG, "paste", self.btn_w_paste, btn_y, btn_h, mx, my);
        self.drawToolbarButton(tb.reset_x, BTN_RESET, "reset", self.btn_w_reset, btn_y, btn_h, mx, my);

        if (self.drag.active) {
            const x0: f32 = @floatCast(@min(self.drag.start_x, self.drag.current_x));
            const y0: f32 = @floatCast(@min(self.drag.start_y, self.drag.current_y));
            const sz: f32 = @floatCast(@abs(self.drag.current_x - self.drag.start_x));
            if (sz >= MIN_SELECTION_PX) {
                rl.drawRectangleLines(@intFromFloat(x0), @intFromFloat(y0), @intFromFloat(sz), @intFromFloat(sz), COL_DRAG_HIGHLIGHT);
            }
        }

        self.drawHighlight();

        // Tooltip checkbox — right-aligned on second line
        {
            const chk_label = if (self.tooltip_enabled) TOOLTIP_LABEL else TOOLTIP_LABEL_OFF;
            const chk_w = self.tooltip_label_w;
            const chk_x = @as(f32, @floatFromInt(self.render_w)) - @as(f32, @floatFromInt(TOP_PAD)) - chk_w;
            const chk_y = @as(f32, @floatFromInt(LINE1_H)) + @as(f32, @floatFromInt(HINT_PAD_Y));
            const hover = @as(f32, @floatFromInt(mx)) >= chk_x and @as(f32, @floatFromInt(mx)) < chk_x + chk_w and
                my >= LINE1_H + HINT_PAD_Y and my < LINE1_H + HINT_PAD_Y + @as(i32, @intFromFloat(FONT_SIZE_LG));
            rl.drawTextEx(self.ui_font, chk_label, .{ .x = chk_x, .y = chk_y }, FONT_SIZE_LG, 1,
                if (hover) COL_TEXT else COL_HINT);
        }

        // Coordinate tooltip: 2s hover delay, pixel-center coords
        if (self.tooltip_enabled) {
            const viewport_y = TOTAL_TOP;
            if (my >= viewport_y and my < self.render_h) {
                const dpi_f: f64 = @floatFromInt(self.dpi_scale);
                const phys_px = @as(f64, @floatFromInt(mx)) * dpi_f;
                const phys_py = (@as(f64, @floatFromInt(my)) - @as(f64, @floatFromInt(viewport_y))) * dpi_f;
                const w_f: f64 = @floatFromInt(self.image.width);
                const h_f: f64 = @floatFromInt(self.image.height);

                if (phys_px >= 0 and phys_px < w_f and phys_py >= 0 and phys_py < h_f) {
                    const moved = @abs(mx - self.tooltip_last_mx) > TOOLTIP_MOVE_THRESHOLD_PX or
                        @abs(my - self.tooltip_last_my) > TOOLTIP_MOVE_THRESHOLD_PX;
                    if (moved) {
                        self.tooltip_mouse_still_since = rl.getTime();
                        self.tooltip_last_mx = mx;
                        self.tooltip_last_my = my;
                    }

                    if (rl.getTime() - self.tooltip_mouse_still_since >= TOOLTIP_DELAY_S) {
                        const px: f64 = @floor(phys_px);
                        const py: f64 = @floor(phys_py);
                        const coord = self.pixelCenterToComplex(px, py);

                        var tooltip_buf: [128]u8 = undefined;
                        const tooltip_text = std.fmt.bufPrintZ(&tooltip_buf, "x={d:.8}  y={d:.8}", .{ coord.x, coord.y }) catch unreachable;

                        const tt_size = rl.measureTextEx(self.ui_font, tooltip_text, FONT_SIZE_LG, 1);
                        const tt_w = tt_size.x + @as(f32, @floatFromInt(TOOLTIP_PAD_X * 2));
                        const tt_h = tt_size.y + @as(f32, @floatFromInt(TOOLTIP_PAD_Y * 2));

                        const c_x: f32 = @floatFromInt(mx + TOOLTIP_OFFSET_X);
                        const c_y: f32 = @floatFromInt(my + TOOLTIP_OFFSET_Y);
                        const max_x = @as(f32, @floatFromInt(self.render_w)) - tt_w - @as(f32, @floatFromInt(TOP_PAD));
                        const max_y = @as(f32, @floatFromInt(self.render_h)) - tt_h - @as(f32, @floatFromInt(TOP_PAD));
                        const tt_x = @min(max_x, @max(@as(f32, @floatFromInt(TOP_PAD)), c_x));
                        const tt_y = @min(max_y, @max(@as(f32, @floatFromInt(viewport_y)), c_y));

                        const bg = rl.Rectangle{ .x = tt_x, .y = tt_y, .width = tt_w, .height = tt_h };
                        rl.drawRectangleRounded(bg, 0.3, 4, .{ .r = 30, .g = 30, .b = 40, .a = 200 });
                        rl.drawTextEx(self.ui_font, tooltip_text, .{ .x = tt_x + @as(f32, @floatFromInt(TOOLTIP_PAD_X)), .y = tt_y + @as(f32, @floatFromInt(TOOLTIP_PAD_Y)) }, FONT_SIZE_LG, 1, .white);
                    }
                }
            } else {
                self.tooltip_mouse_still_since = rl.getTime();
                self.tooltip_last_mx = mx;
                self.tooltip_last_my = my;
            }
        }

        if (self.render_timed_out) {
            const msg = "[Space]: continue";
            const mw = rl.measureText(msg, FONT_SIZE_TIMEOUT);
            rl.drawText(msg, self.render_w - TOP_PAD - mw, LINE1_H + HINT_PAD_Y, FONT_SIZE_TIMEOUT, COL_TIMEOUT);
        }
    }
};

const testing = std.testing;

test "TextBuf init is empty, cursor at 0" {
    const tb = TextBuf.init();
    try testing.expectEqual(@as(usize, 0), tb.len);
    try testing.expectEqual(@as(usize, 0), tb.cursor);
    try testing.expectEqual(@as(u8, 0), tb.buf[0]);
}

test "TextBuf format sets cursor to len" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 3), tb.cursor);
}

test "TextBuf insertChar at cursor shifts right" {
    var tb = TextBuf.init();
    tb.format("ac", .{});
    tb.cursor = 1;
    tb.insertChar('b');
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 2), tb.cursor);
    try testing.expectEqualSlices(u8, "abc", tb.slice());
}

test "TextBuf insertChar at end appends" {
    var tb = TextBuf.init();
    tb.format("ab", .{});
    tb.insertChar('c');
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 3), tb.cursor);
    try testing.expectEqualSlices(u8, "abc", tb.slice());
}

test "TextBuf insertChar at start prepends" {
    var tb = TextBuf.init();
    tb.format("bc", .{});
    tb.cursor = 0;
    tb.insertChar('a');
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 1), tb.cursor);
    try testing.expectEqualSlices(u8, "abc", tb.slice());
}

test "TextBuf deleteBeforeCursor removes char before cursor" {
    var tb = TextBuf.init();
    tb.format("abcd", .{});
    tb.cursor = 3;
    tb.deleteBeforeCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 2), tb.cursor);
    try testing.expectEqualSlices(u8, "abd", tb.slice());
}

test "TextBuf deleteBeforeCursor at position 0 does nothing" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    tb.cursor = 0;
    tb.deleteBeforeCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 0), tb.cursor);
}

test "TextBuf deleteAfterCursor removes char at cursor" {
    var tb = TextBuf.init();
    tb.format("abcd", .{});
    tb.cursor = 1;
    tb.deleteAfterCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 1), tb.cursor);
    try testing.expectEqualSlices(u8, "acd", tb.slice());
}

test "TextBuf deleteAfterCursor at end does nothing" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    tb.cursor = 3;
    tb.deleteAfterCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
}

test "TextBuf deleteAfterCursor on empty buffer does nothing" {
    var tb = TextBuf.init();
    tb.deleteAfterCursor();
    try testing.expectEqual(@as(usize, 0), tb.len);
    try testing.expectEqual(@as(usize, 0), tb.cursor);
}

test "TextBuf beforeCursor returns null-terminated text before cursor" {
    var tb = TextBuf.init();
    tb.format("hello world", .{});
    tb.cursor = 5;
    try testing.expectEqualSlices(u8, "hello", tb.beforeCursor());
    // Verify buffer is unmodified after call
    try testing.expectEqual(@as(usize, 5), tb.cursor);
    try testing.expectEqual(@as(usize, 11), tb.len);
    try testing.expectEqualSlices(u8, "hello world", tb.slice());
}

test "TextBuf moveCursorLeft and moveCursorRight" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    tb.moveCursorLeft();
    try testing.expectEqual(@as(usize, 2), tb.cursor);
    tb.moveCursorLeft();
    try testing.expectEqual(@as(usize, 1), tb.cursor);
    tb.moveCursorLeft();
    try testing.expectEqual(@as(usize, 0), tb.cursor);
    tb.moveCursorLeft();
    try testing.expectEqual(@as(usize, 0), tb.cursor);
    tb.moveCursorRight();
    try testing.expectEqual(@as(usize, 1), tb.cursor);
    tb.moveCursorRight();
    try testing.expectEqual(@as(usize, 2), tb.cursor);
    tb.moveCursorRight();
    try testing.expectEqual(@as(usize, 3), tb.cursor);
    tb.moveCursorRight();
    try testing.expectEqual(@as(usize, 3), tb.cursor);
}

test "TextBuf moveHome and moveEnd" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    tb.cursor = 2;
    tb.moveHome();
    try testing.expectEqual(@as(usize, 0), tb.cursor);
    tb.moveEnd();
    try testing.expectEqual(@as(usize, 3), tb.cursor);
}

test "isValidCoord validates bounds" {
    // Valid: default view center
    try testing.expect(App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE,
        .max_iters = m.DEFAULT_MAX_ITERS,
    }));

    // Valid: zoomed in
    try testing.expect(App.isValidCoord(.{
        .center_x = -0.75,
        .center_y = 0.0,
        .range = 0.1,
        .max_iters = 4096,
    }));

    // Invalid: center_x too far left
    try testing.expect(!App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X - m.INITIAL_RANGE,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE / 2,
        .max_iters = m.DEFAULT_MAX_ITERS,
    }));

    // Invalid: center_y too far down
    try testing.expect(!App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y - m.INITIAL_RANGE,
        .range = m.INITIAL_RANGE / 2,
        .max_iters = m.DEFAULT_MAX_ITERS,
    }));

    // Invalid: range > INITIAL_RANGE
    try testing.expect(!App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE + 0.01,
        .max_iters = m.DEFAULT_MAX_ITERS,
    }));

    // Invalid: range <= 0
    try testing.expect(!App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = -0.1,
        .max_iters = m.DEFAULT_MAX_ITERS,
    }));

    // Invalid: iters < MIN_ITERS
    try testing.expect(!App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE / 2,
        .max_iters = m.MIN_ITERS - 1,
    }));

    // Invalid: iters > MAX_ITERS_CAP
    try testing.expect(!App.isValidCoord(.{
        .center_x = m.INITIAL_CENTER_X,
        .center_y = m.INITIAL_CENTER_Y,
        .range = m.INITIAL_RANGE / 2,
        .max_iters = m.MAX_ITERS_CAP + 1,
    }));
}

test "parseViewState round-trip default view" {
    const v = m.ViewState{
        .center_x = -0.5,
        .center_y = 0.0,
        .range = 3.5,
        .max_iters = 1024,
    };
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "x={d:.6} y={d:.6} range={e:.6} iters={d}", .{
        v.center_x, v.center_y, v.range, v.max_iters,
    });
    const parsed = parseViewState(text) orelse {
        @panic("parseViewState returned null");
    };
    try testing.expectApproxEqAbs(v.center_x, parsed.center_x, 1e-4);
    try testing.expectApproxEqAbs(v.center_y, parsed.center_y, 1e-4);
    try testing.expectApproxEqAbs(v.range, parsed.range, 1e-4);
    try testing.expectEqual(v.max_iters, parsed.max_iters);
}

test "parseViewState deep zoom" {
    const v = m.ViewState{
        .center_x = -0.743566,
        .center_y = 0.131402,
        .range = 4.5e-10,
        .max_iters = 65536,
    };
    var buf: [128]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "x={d:.6} y={d:.6} range={e:.6} iters={d}", .{
        v.center_x, v.center_y, v.range, v.max_iters,
    });
    const parsed = parseViewState(text) orelse {
        @panic("parseViewState returned null");
    };
    try testing.expectApproxEqAbs(v.center_x, parsed.center_x, 1e-4);
    try testing.expectApproxEqAbs(v.center_y, parsed.center_y, 1e-4);
    try testing.expectApproxEqAbs(v.range, parsed.range, 1e-10);
    try testing.expectEqual(v.max_iters, parsed.max_iters);
}

test "parseViewState invalid input returns null" {
    try testing.expect(parseViewState("garbage") == null);
    try testing.expect(parseViewState("(abc, def)") == null);
    try testing.expect(parseViewState("(1, 2) range=abc iters=1024") == null);
    try testing.expect(parseViewState("(1, 2) range=3.5 iters=xyz") == null);
    try testing.expect(parseViewState("no parens here") == null);
}

test "parseViewState parenthesized format" {
    const expected = m.ViewState{
        .center_x = -0.743566,
        .center_y = 0.131402,
        .range = 4.5e-10,
        .max_iters = 65536,
    };
    const text = "(-0.743566, 0.131402) range=4.5e-10 iters=65536";
    const parsed = parseViewState(text) orelse {
        @panic("parseViewState returned null");
    };
    try testing.expectApproxEqAbs(expected.center_x, parsed.center_x, 1e-6);
    try testing.expectApproxEqAbs(expected.center_y, parsed.center_y, 1e-6);
    try testing.expectApproxEqAbs(expected.range, parsed.range, 1e-14);
    try testing.expectEqual(expected.max_iters, parsed.max_iters);
}
