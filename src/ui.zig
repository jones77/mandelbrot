const m = @import("mandelbrot.zig");
const rl = @import("raylib");
const std = @import("std");

pub const LINE1_H: i32 = 32;
pub const LINE2_H: i32 = 28;
pub const LINE3_H: i32 = 28;
pub const TOTAL_TOP: i32 = LINE1_H + LINE2_H + LINE3_H;
pub const TOP_PAD: i32 = 4;
pub const TB_H: i32 = 26;
pub const BTN_GAP: i32 = 4;
pub const BTN_ARROW: i32 = 28;
pub const BTN_ITER: i32 = 35;
pub const BTN_LG: i32 = 55;
pub const BTN_RESET: i32 = 55;
pub const TB_CAP: usize = 127;
pub const PAD_X: i32 = 6;
pub const HINT_PAD_Y: i32 = 4;

pub const FONT_SIZE_LG: f32 = 18.0;
pub const FONT_SIZE_BTN: i32 = 18;

pub const COL_BG = rl.Color{ .r = 240, .g = 240, .b = 245, .a = 255 };
pub const COL_BAR = rl.Color{ .r = 235, .g = 235, .b = 240, .a = 255 };
pub const COL_SEP = rl.Color{ .r = 190, .g = 190, .b = 200, .a = 255 };
pub const COL_TEXT = rl.Color{ .r = 30, .g = 30, .b = 40, .a = 255 };
pub const COL_BTN_TEXT = rl.Color{ .r = 50, .g = 50, .b = 60, .a = 255 };
pub const COL_HINT = rl.Color{ .r = 60, .g = 60, .b = 70, .a = 255 };
pub const COL_TB_BG = rl.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
pub const COL_TB_BORDER_ACTIVE = rl.Color{ .r = 0, .g = 120, .b = 255, .a = 255 };
pub const COL_TB_BORDER = rl.Color{ .r = 180, .g = 180, .b = 190, .a = 255 };
pub const COL_BTN_BG = rl.Color{ .r = 230, .g = 230, .b = 238, .a = 255 };
pub const COL_BTN_BG_HOVER = rl.Color{ .r = 220, .g = 220, .b = 228, .a = 255 };
pub const COL_BTN_BORDER = rl.Color{ .r = 180, .g = 180, .b = 190, .a = 255 };
pub const COL_TIMEOUT = rl.Color{ .r = 200, .g = 80, .b = 40, .a = 255 };

pub const CP_ARROW_LEFT: i32 = 0x2190;
pub const CP_ARROW_RIGHT: i32 = 0x2192;

pub const TOOLTIP_LABEL = "[x] tooltip";

pub const FONT_LOAD_SIZE: i32 = 24;
pub const ASCII_PRN_MIN: i32 = 32;
pub const ASCII_PRN_MAX: i32 = 126;
pub const ASCII_PRN_COUNT = ASCII_PRN_MAX - ASCII_PRN_MIN + 1;

// ─── TextBuf ───────────────────────────────────────────────────

pub const TextBuf = struct {
    buf: [TB_CAP + 1]u8,
    len: usize,
    cursor: usize,

    pub fn init() TextBuf {
        var tb = TextBuf{ .buf = undefined, .len = 0, .cursor = 0 };
        tb.buf[0] = 0;
        return tb;
    }

    pub fn slice(self: *const TextBuf) [:0]const u8 {
        return self.buf[0..self.len :0];
    }

    pub fn format(self: *TextBuf, comptime fmt: []const u8, args: anytype) void {
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

    pub fn insertChar(self: *TextBuf, ch: u8) void {
        if (self.len >= TB_CAP) return;
        var i = self.len;
        while (i > self.cursor) : (i -= 1)
            self.buf[i] = self.buf[i - 1];
        self.buf[self.cursor] = ch;
        self.len += 1;
        self.cursor += 1;
        self.buf[self.len] = 0;
    }

    pub fn deleteBeforeCursor(self: *TextBuf) void {
        if (self.cursor == 0) return;
        var i = self.cursor;
        while (i < self.len) : (i += 1)
            self.buf[i - 1] = self.buf[i];
        self.len -= 1;
        self.cursor -= 1;
        self.buf[self.len] = 0;
    }

    pub fn deleteAfterCursor(self: *TextBuf) void {
        if (self.cursor == self.len) return;
        var i = self.cursor;
        while (i < self.len) : (i += 1)
            self.buf[i] = self.buf[i + 1];
        self.len -= 1;
        self.buf[self.len] = 0;
    }

    pub fn moveCursorLeft(self: *TextBuf) void {
        if (self.cursor > 0) self.cursor -= 1;
    }
    pub fn moveCursorRight(self: *TextBuf) void {
        if (self.cursor < self.len) self.cursor += 1;
    }
    pub fn moveHome(self: *TextBuf) void { self.cursor = 0; }
    pub fn moveEnd(self: *TextBuf) void { self.cursor = self.len; }
    pub fn beforeCursor(self: *const TextBuf) []const u8 {
        return self.buf[0..self.cursor];
    }
};

// ─── Toolbar layout ────────────────────────────────────────────

pub const ToolbarLayout = struct {
    arrow_l_x: i32,
    arrow_r_x: i32,
    tb_start_x: i32,
    tb_w: i32,
    inc_x: i32,
    dec_x: i32,
    copy_x: i32,
    paste_x: i32,
    reset_x: i32,

    pub fn compute(render_w: i32) ToolbarLayout {
        const arrow_l_x: i32 = TOP_PAD;
        const arrow_r_x: i32 = arrow_l_x + BTN_ARROW + BTN_GAP;
        const tb_start_x: i32 = arrow_r_x + BTN_ARROW + BTN_GAP;
        const reset_x = render_w - TOP_PAD - BTN_RESET;
        const paste_x = reset_x - BTN_GAP - BTN_LG;
        const copy_x = paste_x - BTN_GAP - BTN_LG;
        const dec_x = copy_x - BTN_GAP - BTN_ITER;
        const inc_x = dec_x - BTN_GAP - BTN_ITER;
        const tb_w = render_w - TOP_PAD - tb_start_x;
        return .{ .arrow_l_x = arrow_l_x, .arrow_r_x = arrow_r_x, .tb_start_x = tb_start_x, .tb_w = tb_w, .inc_x = inc_x, .dec_x = dec_x, .copy_x = copy_x, .paste_x = paste_x, .reset_x = reset_x };
    }
};

// ─── Coordinate helper ─────────────────────────────────────────

fn pixelCenterToComplex(view: m.ViewState, img_w: i32, img_h: i32, px: f64, py: f64) struct { x: f64, y: f64 } {
    const w: f64 = @floatFromInt(img_w);
    const h: f64 = @floatFromInt(img_h);
    const aspect = @as(f64, @floatFromInt(img_w)) / @as(f64, @floatFromInt(img_h));
    const range_x = view.range;
    const range_y = view.range / aspect;
    return .{
        .x = (view.center_x + view.offset_x) + ((px + 0.5) / w - 0.5) * range_x,
        .y = (view.center_y + view.offset_y) - ((py + 0.5) / h - 0.5) * range_y,
    };
}

// ─── Drawing ───────────────────────────────────────────────────

fn drawToolbarButton(font: rl.Font, x: i32, w: i32, label: [:0]const u8, label_w: f32, btn_y: i32, btn_h: i32, mx: i32, my: i32) void {
    const hover = mx >= x and mx < x + w and my >= btn_y and my < btn_y + btn_h;
    rl.drawRectangle(x, btn_y, w, btn_h, if (hover) COL_BTN_BG_HOVER else COL_BTN_BG);
    rl.drawRectangleLines(x, btn_y, w, btn_h, COL_BTN_BORDER);
    const cx = @as(f32, @floatFromInt(x)) + (@as(f32, @floatFromInt(w)) - label_w) / 2.0;
    rl.drawTextEx(font, label, .{ .x = cx, .y = @floatFromInt(btn_y + 5) }, @floatFromInt(FONT_SIZE_BTN), 0, COL_BTN_TEXT);
}

fn drawToolbarArrow(font: rl.Font, x: i32, cp: i32, btn_y: i32, btn_h: i32, mx: i32, my: i32) void {
    const hover = mx >= x and mx < x + BTN_ARROW and my >= btn_y and my < btn_y + btn_h;
    rl.drawRectangle(x, btn_y, BTN_ARROW, btn_h, if (hover) COL_BTN_BG_HOVER else COL_BTN_BG);
    rl.drawRectangleLines(x, btn_y, BTN_ARROW, btn_h, COL_BTN_BORDER);
    rl.drawTextCodepoint(font, cp, .{ .x = @floatFromInt(x + PAD_X), .y = @floatFromInt(btn_y + 3) }, 18, COL_BTN_TEXT);
}

pub fn drawToolbar(
    font: rl.Font, render_w: i32, tb_active: bool, tb_buf: *const TextBuf, view: m.ViewState,
    btn_w_inc: f32, btn_w_dec: f32, btn_w_copy: f32, btn_w_paste: f32, btn_w_reset: f32, mx: i32, my: i32,
) void {
    const CURSOR_W: i32 = 2;
    const CURSOR_H: i32 = 18;
    const VIEW_FMT = "x={e:.16} y={e:.16} range={e:.8} iters={d}";

    rl.drawRectangle(0, 0, render_w, LINE1_H, COL_BAR);
    rl.drawRectangle(0, LINE1_H, render_w, 1, COL_SEP);
    rl.drawRectangle(0, LINE1_H + 1, render_w, LINE2_H, COL_BAR);
    rl.drawRectangle(0, LINE1_H + LINE2_H, render_w, 1, COL_SEP);
    rl.drawRectangle(0, LINE1_H + LINE2_H + 1, render_w, LINE3_H, COL_BAR);
    rl.drawRectangle(0, TOTAL_TOP - 1, render_w, 1, COL_SEP);

    rl.drawTextEx(font, "double-click/drag to zoom    \xe2\x86\x90 left arrow zooms out    \xe2\x86\x92 right arrow zooms back in    press R to reset", .{ .x = 10, .y = @floatFromInt(LINE1_H + LINE2_H + HINT_PAD_Y) }, FONT_SIZE_LG, 1, COL_HINT);

    const tb_y: i32 = (LINE1_H - TB_H) / 2;
    const tb = ToolbarLayout.compute(render_w);

    rl.drawRectangle(tb.tb_start_x, tb_y, tb.tb_w, TB_H, COL_TB_BG);
    rl.drawRectangleLines(tb.tb_start_x, tb_y, tb.tb_w, TB_H, if (tb_active) COL_TB_BORDER_ACTIVE else COL_TB_BORDER);

    var display_buf: [256]u8 = undefined;
    const display_text = if (tb_active) tb_buf.slice() else std.fmt.bufPrintZ(&display_buf, VIEW_FMT, .{ view.center_x + view.offset_x, view.center_y + view.offset_y, view.range, view.max_iters }) catch unreachable;
    rl.drawTextEx(font, display_text, .{ .x = @floatFromInt(tb.tb_start_x + PAD_X), .y = @floatFromInt(tb_y + 4) }, FONT_SIZE_LG, 1.0, COL_TEXT);

    drawToolbarArrow(font, tb.arrow_l_x, CP_ARROW_LEFT, tb_y, TB_H, mx, my);
    drawToolbarArrow(font, tb.arrow_r_x, CP_ARROW_RIGHT, tb_y, TB_H, mx, my);

    if (tb_active) {
        const blink = @as(u32, @intFromFloat(rl.getTime() * 2.0)) & 1;
        if (blink == 0) {
            var buf: [TB_CAP + 1]u8 = undefined;
            @memcpy(buf[0..tb_buf.cursor], tb_buf.buf[0..tb_buf.cursor]);
            buf[tb_buf.cursor] = 0;
            const m2 = rl.measureTextEx(font, buf[0..tb_buf.cursor :0], FONT_SIZE_LG, 1.0);
            const cx = tb.tb_start_x + PAD_X + @as(i32, @intFromFloat(m2.x));
            rl.drawRectangle(cx, tb_y + 4, CURSOR_W, CURSOR_H, COL_TB_BORDER_ACTIVE);
        }
    }
    const btn_y: i32 = LINE1_H + (LINE2_H - TB_H) / 2;
    drawToolbarButton(font, tb.inc_x, BTN_ITER, "inc", btn_w_inc, btn_y, TB_H, mx, my);
    drawToolbarButton(font, tb.dec_x, BTN_ITER, "dec", btn_w_dec, btn_y, TB_H, mx, my);
    drawToolbarButton(font, tb.copy_x, BTN_LG, "copy", btn_w_copy, btn_y, TB_H, mx, my);
    drawToolbarButton(font, tb.paste_x, BTN_LG, "paste", btn_w_paste, btn_y, TB_H, mx, my);
    drawToolbarButton(font, tb.reset_x, BTN_RESET, "reset", btn_w_reset, btn_y, TB_H, mx, my);
}

pub fn drawTooltipCheckbox(font: rl.Font, render_w: i32, enabled: bool, label_w: f32, mx: i32, my: i32) void {
    const label = if (enabled) TOOLTIP_LABEL else "[ ] tooltip";
    const chk_x = @as(f32, @floatFromInt(render_w)) - @as(f32, @floatFromInt(TOP_PAD)) - label_w;
    const chk_y = @as(f32, @floatFromInt(LINE1_H + LINE2_H)) + @as(f32, @floatFromInt(HINT_PAD_Y));
    const hover = @as(f32, @floatFromInt(mx)) >= chk_x and @as(f32, @floatFromInt(mx)) < chk_x + label_w and
        @as(f32, @floatFromInt(my)) >= chk_y and @as(f32, @floatFromInt(my)) < chk_y + FONT_SIZE_LG;
    rl.drawTextEx(font, label, .{ .x = chk_x, .y = chk_y }, FONT_SIZE_LG, 1, if (hover) COL_TEXT else COL_HINT);
}

pub fn drawCoordinateTooltip(
    font: rl.Font, render_w: i32, render_h: i32, dpi: i32, img_w: i32, img_h: i32, view: m.ViewState,
    enabled: bool, still_since: *f64, last_mx: *i32, last_my: *i32, mx: i32, my: i32,
) void {
    if (!enabled) return;
    if (my < TOTAL_TOP or my >= render_h) {
        still_since.* = rl.getTime();
        last_mx.* = mx;
        last_my.* = my;
        return;
    }
    const dpi_f: f64 = @floatFromInt(dpi);
    const phys_px = @as(f64, @floatFromInt(mx)) * dpi_f;
    const phys_py = (@as(f64, @floatFromInt(my)) - @as(f64, @floatFromInt(TOTAL_TOP))) * dpi_f;
    const w_f: f64 = @floatFromInt(img_w);
    const h_f: f64 = @floatFromInt(img_h);
    if (phys_px < 0 or phys_px >= w_f or phys_py < 0 or phys_py >= h_f) return;

    if (@abs(mx - last_mx.*) > 2 or @abs(my - last_my.*) > 2) {
        still_since.* = rl.getTime();
        last_mx.* = mx;
        last_my.* = my;
    }
    if (rl.getTime() - still_since.* < 2.0) return;

    const coord = pixelCenterToComplex(view, img_w, img_h, @floor(phys_px), @floor(phys_py));
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf, "x={e:.16}  y={e:.16}", .{coord.x, coord.y}) catch unreachable;

    const sz = rl.measureTextEx(font, text, FONT_SIZE_LG, 1);
    const tw = sz.x + 16;
    const th = sz.y + 8;
    const max_x = @as(f32, @floatFromInt(render_w)) - tw - 4;
    const max_y = @as(f32, @floatFromInt(render_h)) - th - 4;
    const tx = @min(max_x, @max(4, @as(f32, @floatFromInt(mx + 12))));
    const ty = @min(max_y, @max(@as(f32, @floatFromInt(TOTAL_TOP)), @as(f32, @floatFromInt(my + 12))));

    rl.drawRectangleRounded(.{ .x = tx, .y = ty, .width = tw, .height = th }, 0.3, 4, .{ .r = 30, .g = 30, .b = 40, .a = 200 });
    rl.drawTextEx(font, text, .{ .x = tx + 8, .y = ty + 4 }, FONT_SIZE_LG, 1, .white);
}

// ─── Tests ─────────────────────────────────────────────────────

const testing = std.testing;

test "TextBuf init" {
    const tb = TextBuf.init();
    try testing.expectEqual(@as(usize, 0), tb.len);
    try testing.expectEqual(@as(usize, 0), tb.cursor);
    try testing.expectEqual(@as(u8, 0), tb.buf[0]);
}
test "TextBuf format" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 3), tb.cursor);
}
test "TextBuf insertChar at cursor" {
    var tb = TextBuf.init();
    tb.format("ac", .{});
    tb.cursor = 1;
    tb.insertChar('b');
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 2), tb.cursor);
    try testing.expectEqualSlices(u8, "abc", tb.slice());
}
test "TextBuf insertChar at end" {
    var tb = TextBuf.init();
    tb.format("ab", .{});
    tb.insertChar('c');
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqualSlices(u8, "abc", tb.slice());
}
test "TextBuf insertChar at start" {
    var tb = TextBuf.init();
    tb.format("bc", .{});
    tb.cursor = 0;
    tb.insertChar('a');
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 1), tb.cursor);
    try testing.expectEqualSlices(u8, "abc", tb.slice());
}
test "TextBuf deleteBeforeCursor" {
    var tb = TextBuf.init();
    tb.format("abcd", .{});
    tb.cursor = 3;
    tb.deleteBeforeCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 2), tb.cursor);
    try testing.expectEqualSlices(u8, "abd", tb.slice());
}
test "TextBuf deleteBeforeCursor at 0" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    tb.cursor = 0;
    tb.deleteBeforeCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
}
test "TextBuf deleteAfterCursor" {
    var tb = TextBuf.init();
    tb.format("abcd", .{});
    tb.cursor = 1;
    tb.deleteAfterCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
    try testing.expectEqual(@as(usize, 1), tb.cursor);
    try testing.expectEqualSlices(u8, "acd", tb.slice());
}
test "TextBuf deleteAfterCursor at end" {
    var tb = TextBuf.init();
    tb.format("abc", .{});
    tb.cursor = 3;
    tb.deleteAfterCursor();
    try testing.expectEqual(@as(usize, 3), tb.len);
}
test "TextBuf beforeCursor" {
    var tb = TextBuf.init();
    tb.format("hello world", .{});
    tb.cursor = 5;
    try testing.expectEqualSlices(u8, "hello", tb.beforeCursor());
}
