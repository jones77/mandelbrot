const std = @import("std");
const rl = @import("raylib");
const m = @import("mandelbrot.zig");
const renderer = @import("renderer.zig");

const HUD_HEIGHT: i32 = 26;
const TOP_BAR: i32 = 30;
const TOP_PAD: i32 = 4;
const TB_H: i32 = 22;
const BTN_GAP: i32 = 4;
const BTN_SM: i32 = 28;
const BTN_LG: i32 = 86;
const TB_CAP: usize = 127;
const MAX_HISTORY: usize = 64;
const MIN_SELECTION_PX: f64 = 8.0;
const RENDER_TIMEOUT_S: f64 = 30.0;

const TextBuf = struct {
    buf: [TB_CAP + 1]u8,
    len: usize,

    fn init() TextBuf {
        var tb = TextBuf{ .buf = undefined, .len = 0 };
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
            return;
        };
        self.len = written.len;
        self.buf[self.len] = 0;
    }

    fn append(self: *TextBuf, ch: u8) void {
        if (self.len < TB_CAP) {
            self.buf[self.len] = ch;
            self.len += 1;
            self.buf[self.len] = 0;
        }
    }

    fn backspace(self: *TextBuf) void {
        if (self.len > 0) {
            self.len -= 1;
            self.buf[self.len] = 0;
        }
    }
};

const DragState = struct {
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
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
    const px_size = w * h * 4;
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

fn parseViewState(text: []const u8) ?m.ViewState {
    // Accept both old "(cx, cy)" and new "x=... y=..." formats.
    const paren = std.mem.indexOfScalar(u8, text, '(');
    if (paren != null) {
        const after_paren = text[paren.? + 1 ..];
        const comma = std.mem.indexOfScalar(u8, after_paren, ',') orelse return null;
        const cx = std.fmt.parseFloat(f64, std.mem.trim(u8, after_paren[0..comma], " ")) catch return null;
        const after_comma = std.mem.trim(u8, after_paren[comma + 1 ..], " ");
        const close = std.mem.indexOfScalar(u8, after_comma, ')') orelse return null;
        const cy = std.fmt.parseFloat(f64, std.mem.trim(u8, after_comma[0..close], " ")) catch return null;

        const rpos = std.mem.indexOfPos(u8, text, 0, "range=") orelse return null;
        const rstart = rpos + 6;
        var rend = rstart;
        while (rend < text.len and text[rend] != ' ' and text[rend] != ',' and text[rend] != ')') rend += 1;
        if (rstart >= rend) return null;
        const range = std.fmt.parseFloat(f64, text[rstart..rend]) catch return null;

        const ipos = std.mem.indexOfPos(u8, text, 0, "iters=") orelse return null;
        const istart = ipos + 6;
        var iend = istart;
        while (iend < text.len and text[iend] >= '0' and text[iend] <= '9') iend += 1;
        if (istart >= iend) return null;
        const iters = std.fmt.parseInt(u32, text[istart..iend], 10) catch return null;

        return m.ViewState{ .center_x = cx, .center_y = cy, .range = range, .max_iters = iters };
    }
    if (std.mem.indexOfPos(u8, text, 0, "x=") == null or
        std.mem.indexOfPos(u8, text, 0, "y=") == null) return null;
    const x = blk: {
        const pos = (std.mem.indexOfPos(u8, text, 0, "x=") orelse return null) + 2;
        var end = pos;
        while (end < text.len and text[end] != ' ') end += 1;
        break :blk std.fmt.parseFloat(f64, text[pos..end]) catch return null;
    };
    const y = blk: {
        const pos = (std.mem.indexOfPos(u8, text, 0, "y=") orelse return null) + 2;
        var end = pos;
        while (end < text.len and text[end] != ' ') end += 1;
        break :blk std.fmt.parseFloat(f64, text[pos..end]) catch return null;
    };
    const range = blk: {
        const pos = (std.mem.indexOfPos(u8, text, 0, "range=") orelse return null) + 6;
        var end = pos;
        while (end < text.len and text[end] != ' ') end += 1;
        break :blk std.fmt.parseFloat(f64, text[pos..end]) catch return null;
    };
    const iters = blk: {
        const pos = (std.mem.indexOfPos(u8, text, 0, "iters=") orelse return null) + 6;
        var end = pos;
        while (end < text.len and text[end] >= '0' and text[end] <= '9') end += 1;
        break :blk std.fmt.parseInt(u32, text[pos..end], 10) catch return null;
    };
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
    image: rl.Image,
    texture: rl.Texture2D,
    drag: DragState,
    tb_buf: TextBuf,
    tb_active: bool,
    ui_font: rl.Font,

    pub fn init(render_method: m.RenderMethod) !App {
        m.buildPalette();
        const sw = rl.getScreenWidth();
        const sh = rl.getScreenHeight();
        const vh = sh - TOP_BAR - HUD_HEIGHT;
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
            .image = img,
            .texture = tex,
            .drag = DragState{ .start_x = 0, .start_y = 0, .current_x = 0, .current_y = 0, .active = false },
            .tb_buf = TextBuf.init(),
            .tb_active = false,
            .ui_font = rl.getFontDefault() catch unreachable,
        };

        {
            const candidates = [_][:0]const u8{
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            };
            for (candidates) |path| {
                const f = rl.loadFontEx(path, 16, null) catch continue;
                if (f.texture.id > 0) {
                    app.ui_font = f;
                    break;
                }
                rl.unloadFont(f);
            }
        }

        app.syncTextBox();
        return app;
    }

    pub fn deinit(self: *App) void {
        for (0..self.history_len) |i| {
            if (self.history[i].pixels.len > 0)
                std.heap.page_allocator.free(self.history[i].pixels);
        }
        rl.unloadTexture(self.texture);
        rl.unloadImage(self.image);
        rl.unloadFont(self.ui_font);
    }

    pub fn renderFresh(self: *App, clear: bool) !bool {
        const w: usize = @intCast(self.image.width);
        const h: usize = @intCast(self.image.height);
        const pixels = @as([*]u8, @ptrCast(self.image.data))[0 .. w * h * 4];
        self.render_timed_out = try renderer.renderMandelbrot(
            pixels, w, h, self.view, clear,
            RENDER_TIMEOUT_S, rl.getTime,
        );
        rl.updateTexture(self.texture, self.image.data);
        return self.render_timed_out;
    }

    fn pixelData(self: *App) []const u8 {
        const w: usize = @intCast(self.image.width);
        const h: usize = @intCast(self.image.height);
        return @as([*]u8, @ptrCast(self.image.data))[0 .. w * h * 4];
    }

    pub fn saveSnapshot(self: *App) !void {
        try pushHistory(
            &self.history, &self.history_len, &self.history_ptr,
            self.view, self.pixelData(),
            @intCast(self.image.width), @intCast(self.image.height),
        );
    }

    fn restoreCached(self: *App, entry: *const HistoryEntry) !void {
        if (entry.w == @as(usize, @intCast(self.image.width)) and
            entry.h == @as(usize, @intCast(self.image.height)))
        {
            const pixels = @as([*]u8, @ptrCast(self.image.data))[0 .. entry.w * entry.h * 4];
            @memcpy(pixels, entry.pixels);
            rl.updateTexture(self.texture, self.image.data);
        } else {
            _ = try self.renderFresh(true);
        }
    }

    fn syncTextBox(self: *App) void {
        self.tb_buf.format("x={d:.6} y={d:.6} range={e:.6} iters={d}", .{
            self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters,
        });
    }

    fn textBoxApply(self: *App) !void {
        const parsed = parseViewState(self.tb_buf.buf[0..self.tb_buf.len]) orelse return;
        const same = parsed.center_x == self.view.center_x and
            parsed.center_y == self.view.center_y and
            parsed.range == self.view.range and
            parsed.max_iters == self.view.max_iters;
        if (same) return;
        truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
        self.view = parsed;
        _ = try self.renderFresh(true);
        try self.saveSnapshot();
    }

    pub fn handleResize(self: *App) !void {
        const new_w = rl.getScreenWidth();
        const new_h = rl.getScreenHeight();
        if (new_w == self.screen_w and new_h == self.screen_h) return;

        self.screen_w = new_w;
        self.screen_h = new_h;
        const vh = new_h - TOP_BAR - HUD_HEIGHT;
        rl.unloadTexture(self.texture);
        rl.unloadImage(self.image);
        self.image = rl.genImageColor(new_w, vh, .black);
        self.texture = try rl.loadTextureFromImage(self.image);
        _ = try self.renderFresh(true);
    }

    pub fn handleInput(self: *App) !void {
        const mx = rl.getMouseX();
        const my = rl.getMouseY();
        const in_top_bar = my < TOP_BAR;
        const in_hud = my >= self.screen_h - HUD_HEIGHT;
        var tb_click_consumed = false;

        // -- Top bar interactions (text box, buttons) --
        if (in_top_bar and rl.isMouseButtonPressed(.left)) {
            const tb_x: i32 = TOP_PAD;
            const tb_y: i32 = (TOP_BAR - TB_H) / 2;

            const paste_x = self.screen_w - TOP_PAD - BTN_LG;
            const copy_x = paste_x - BTN_GAP - BTN_LG;
            const plus_x = copy_x - BTN_GAP - BTN_SM;
            const minus_x = plus_x - BTN_GAP - BTN_SM;
            const tb_w = minus_x - BTN_GAP - TOP_PAD;

            const in_tb = mx >= tb_x and mx < tb_x + tb_w and my >= tb_y and my < tb_y + TB_H;
            if (in_tb) {
                self.tb_active = true;
                tb_click_consumed = true;
            } else {
                if (self.tb_active) {
                    self.tb_active = false;
                    self.syncTextBox();
                    tb_click_consumed = true;
                }
                if (mx >= minus_x and mx < minus_x + BTN_SM and my >= tb_y and my < tb_y + TB_H) {
                    truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
                    self.view.max_iters = @max(m.MIN_ITERS, self.view.max_iters / 2);
                    _ = try self.renderFresh(true);
                    try self.saveSnapshot();
                    tb_click_consumed = true;
                }
                if (mx >= plus_x and mx < plus_x + BTN_SM and my >= tb_y and my < tb_y + TB_H) {
                    truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
                    self.view.max_iters = @min(m.MAX_ITERS_CAP, self.view.max_iters +| self.view.max_iters);
                    _ = try self.renderFresh(true);
                    try self.saveSnapshot();
                    tb_click_consumed = true;
                }
                if (mx >= copy_x and mx < copy_x + BTN_LG and my >= tb_y and my < tb_y + TB_H) {
                    var buf: [256]u8 = undefined;
                    const text = std.fmt.bufPrintZ(&buf, "x={d:.6} y={d:.6} range={e:.6} iters={d}", .{
                        self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters,
                    }) catch unreachable;
                    rl.setClipboardText(text);
                    tb_click_consumed = true;
                }
                if (mx >= paste_x and mx < paste_x + BTN_LG and my >= tb_y and my < tb_y + TB_H) {
                    const clip = std.mem.sliceTo(rl.getClipboardText(), 0);
                    if (clip.len > 0) {
                        self.tb_buf.format("{s}", .{clip});
                        if (parseViewState(self.tb_buf.buf[0..self.tb_buf.len])) |_| {
                            self.tb_active = false;
                            try self.textBoxApply();
                        } else {
                            self.syncTextBox();
                        }
                    }
                    tb_click_consumed = true;
                }
            }
        }

        if (self.tb_active and rl.isMouseButtonPressed(.left) and !in_top_bar) {
            self.tb_active = false;
            self.syncTextBox();
            tb_click_consumed = true;
        }

        // Always-active keyboard shortcuts (work even when text box is active)
        {
            const key_left = rl.isKeyPressed(.left);
            const key_right = rl.isKeyPressed(.right);
            if (key_left or key_right) {
                if (key_left) {
                    if (self.history_ptr > 0) {
                        self.history_ptr -= 1;
                        self.view = self.history[self.history_ptr].view;
                        try self.restoreCached(&self.history[self.history_ptr]);
                    }
                } else {
                    if (self.history_ptr + 1 < self.history_len) {
                        self.history_ptr += 1;
                        self.view = self.history[self.history_ptr].view;
                        try self.restoreCached(&self.history[self.history_ptr]);
                    }
                }
            }
        }
        {
            const key_inc = rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add);
            const key_dec = rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract);
            if (key_inc or key_dec) {
                truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
                if (key_inc) {
                    self.view.max_iters = @min(m.MAX_ITERS_CAP, self.view.max_iters +| self.view.max_iters);
                } else {
                    self.view.max_iters = @max(m.MIN_ITERS, self.view.max_iters / 2);
                }
                _ = try self.renderFresh(true);
                try self.saveSnapshot();
            }
        }
        if (rl.isKeyPressed(.r)) {
            truncateFuture(&self.history, &self.history_len, 0);
            self.history_len = 0;
            self.history_ptr = 0;
            self.view.center_x = m.INITIAL_CENTER_X;
            self.view.center_y = m.INITIAL_CENTER_Y;
            self.view.range = m.INITIAL_RANGE;
            self.view.max_iters = m.DEFAULT_MAX_ITERS;
            _ = try self.renderFresh(true);
            try self.saveSnapshot();
        }
        if (self.render_timed_out and rl.isKeyPressed(.space)) {
            _ = try self.renderFresh(false);
        }

        if (self.tb_active) {
            if (rl.isKeyPressed(.backspace)) self.tb_buf.backspace();
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
                if (ch >= 32 and ch < 127) self.tb_buf.append(@as(u8, @intCast(ch)));
                ch = rl.getCharPressed();
            }
            return;
        }

        if (!tb_click_consumed and !in_top_bar and !in_hud and rl.isMouseButtonPressed(.left)) {
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
            defer self.drag.active = false;

            const size = @abs(self.drag.current_x - self.drag.start_x);
            if (size < MIN_SELECTION_PX) return;

            const sel_cx = (self.drag.start_x + self.drag.current_x) / 2.0;
            const sel_cy = (self.drag.start_y + self.drag.current_y) / 2.0;

            const c_center = m.screenToComplex(sel_cx, sel_cy - @as(f64, @floatFromInt(TOP_BAR)), self.view, self.image.width, self.image.height);
            const smaller = @min(self.image.width, self.image.height);
            const new_range = self.view.range * (size / @as(f64, @floatFromInt(smaller)));

            truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);

            self.view.center_x = c_center.x;
            self.view.center_y = c_center.y;
            self.view.range = new_range;

            const zoom_factor = m.INITIAL_RANGE / self.view.range;
            const log2_zf = @log(zoom_factor) / @log(2.0);
            const log2_start = @log(@as(f64, @floatFromInt(m.DEFAULT_MAX_ITERS))) / @log(2.0);
            const target_f = @exp2(log2_start + log2_zf * m.AUTO_SCALE_SLOPE);
            const clamped = @min(target_f, @as(f64, @floatFromInt(m.AUTO_SCALE_CAP)));
            const target_iters = m.nextPowerOf2(@as(u32, @intFromFloat(clamped)));
            if (target_iters > self.view.max_iters and target_iters <= m.AUTO_SCALE_CAP) {
                self.view.max_iters = target_iters;
            }

            _ = try self.renderFresh(true);

            if (self.history_len < MAX_HISTORY) {
                try self.saveSnapshot();
            }
        }

        self.syncTextBox();
    }

    pub fn drawFrame(self: *App) void {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.init(240, 240, 245, 255));
        rl.drawTexture(self.texture, 0, TOP_BAR, .white);

        const mx = rl.getMouseX();
        const my = rl.getMouseY();

        // -- Top bar --
        rl.drawRectangle(0, 0, self.screen_w, TOP_BAR, rl.Color.init(235, 235, 240, 255));
        rl.drawRectangle(0, TOP_BAR - 1, self.screen_w, 1, rl.Color.init(190, 190, 200, 255));

        const tb_x: i32 = TOP_PAD;
        const tb_y: i32 = (TOP_BAR - TB_H) / 2;
        const btn_y: i32 = tb_y;
        const btn_h: i32 = TB_H;

        const paste_x = self.screen_w - TOP_PAD - BTN_LG;
        const copy_x = paste_x - BTN_GAP - BTN_LG;
        const plus_x = copy_x - BTN_GAP - BTN_SM;
        const minus_x = plus_x - BTN_GAP - BTN_SM;
        const tb_w = minus_x - BTN_GAP - TOP_PAD;

        rl.drawRectangle(tb_x, tb_y, tb_w, TB_H, rl.Color.init(255, 255, 255, 255));
        rl.drawRectangleLines(tb_x, tb_y, tb_w, TB_H,
            if (self.tb_active) rl.Color.init(0, 120, 255, 255) else rl.Color.init(180, 180, 190, 255));

        var display_buf: [256]u8 = undefined;
        const display_text = std.fmt.bufPrintZ(&display_buf, "x={d:.6} y={d:.6} range={e:.6} iters={d}", .{
            self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters,
        }) catch unreachable;
        rl.drawTextEx(self.ui_font, display_text, .{ .x = @floatFromInt(tb_x + 6), .y = @floatFromInt(tb_y + 4) }, 14.0, 1.0, rl.Color.init(30, 30, 40, 255));

        if (self.tb_active) {
            const blink = @as(u32, @intFromFloat(rl.getTime() * 2.0)) & 1;
            if (blink == 0) {
                const m2 = rl.measureTextEx(self.ui_font, display_text, 14.0, 1.0);
                const cx = tb_x + 6 + @as(i32, @intFromFloat(m2.x));
                rl.drawRectangle(cx, tb_y + 4, 2, 16, rl.Color.init(0, 120, 255, 255));
            }
        }

        const btn_colors = struct {
            fn bg(hover: bool) rl.Color {
                return if (hover) rl.Color.init(220, 220, 228, 255) else rl.Color.init(230, 230, 238, 255);
            }
            fn border() rl.Color {
                return rl.Color.init(180, 180, 190, 255);
            }
        };

        {
            const hover = mx >= plus_x and mx < plus_x + BTN_SM and my >= btn_y and my < btn_y + btn_h;
            rl.drawRectangle(plus_x, btn_y, BTN_SM, btn_h, btn_colors.bg(hover));
            rl.drawRectangleLines(plus_x, btn_y, BTN_SM, btn_h, btn_colors.border());
            rl.drawText("+", plus_x + 7, btn_y + 3, 16, rl.Color.init(50, 50, 60, 255));
        }
        {
            const hover = mx >= minus_x and mx < minus_x + BTN_SM and my >= btn_y and my < btn_y + btn_h;
            rl.drawRectangle(minus_x, btn_y, BTN_SM, btn_h, btn_colors.bg(hover));
            rl.drawRectangleLines(minus_x, btn_y, BTN_SM, btn_h, btn_colors.border());
            rl.drawText("-", minus_x + 8, btn_y + 2, 16, rl.Color.init(50, 50, 60, 255));
        }
        {
            const hover = mx >= copy_x and mx < copy_x + BTN_LG and my >= btn_y and my < btn_y + btn_h;
            rl.drawRectangle(copy_x, btn_y, BTN_LG, btn_h, btn_colors.bg(hover));
            rl.drawRectangleLines(copy_x, btn_y, BTN_LG, btn_h, btn_colors.border());
            rl.drawText("Copy View", copy_x + 9, btn_y + 5, 12, rl.Color.init(50, 50, 60, 255));
        }
        {
            const hover = mx >= paste_x and mx < paste_x + BTN_LG and my >= btn_y and my < btn_y + btn_h;
            rl.drawRectangle(paste_x, btn_y, BTN_LG, btn_h, btn_colors.bg(hover));
            rl.drawRectangleLines(paste_x, btn_y, BTN_LG, btn_h, btn_colors.border());
            rl.drawText("Paste View", paste_x + 9, btn_y + 5, 12, rl.Color.init(50, 50, 60, 255));
        }

        if (self.drag.active) {
            const x0: f32 = @floatCast(@min(self.drag.start_x, self.drag.current_x));
            const y0: f32 = @floatCast(@min(self.drag.start_y, self.drag.current_y));
            const sz: f32 = @floatCast(@abs(self.drag.current_x - self.drag.start_x));
            if (sz >= MIN_SELECTION_PX) {
                rl.drawRectangle(@intFromFloat(x0), @intFromFloat(y0), @intFromFloat(sz), @intFromFloat(sz), rl.Color.init(0, 200, 0, 50));
                rl.drawRectangleLines(@intFromFloat(x0), @intFromFloat(y0), @intFromFloat(sz), @intFromFloat(sz), rl.Color.init(0, 200, 0, 200));
            }
        }

        const hud_top = self.screen_h - HUD_HEIGHT;
        rl.drawRectangle(0, hud_top, self.screen_w, HUD_HEIGHT, rl.Color.init(235, 235, 240, 255));
        rl.drawRectangle(0, hud_top, self.screen_w, 1, rl.Color.init(190, 190, 200, 255));
        rl.drawText("Drag to zoom  |  <- undo  -> redo  |  R reset", 10, hud_top + 6, 14, rl.Color.init(60, 60, 70, 255));

        if (self.render_timed_out) {
            rl.drawText("[Space]: continue", 10, hud_top + 6, 14, rl.Color.init(200, 80, 40, 255));
        }
    }
};

const testing = std.testing;

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
