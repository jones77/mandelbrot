const std = @import("std");
const rl = @import("raylib");
const m = @import("mandelbrot.zig");
const logEvent = @import("log.zig").logEvent;
const ui = @import("ui.zig");
const app = @import("app.zig");

const TOTAL_TOP = ui.TOTAL_TOP;
const LINE1_H = ui.LINE1_H;
const TB_H = ui.TB_H;
const ASCII_PRN_MIN = ui.ASCII_PRN_MIN;
const ASCII_PRN_MAX = ui.ASCII_PRN_MAX;
const TOP_PAD = ui.TOP_PAD;
const MIN_SELECTION_PX: f64 = 8.0;

pub const DragState = struct {
    start_x: f64,
    start_y: f64,
    current_x: f64,
    current_y: f64,
    active: bool,
};

pub fn handleInput(self: *app.App) !void {
    const left_pressed = rl.isKeyPressed(.left);
    const right_pressed = rl.isKeyPressed(.right);
    const left_down = rl.isKeyDown(.left);
    const right_down = rl.isKeyDown(.right);
    if (left_pressed or right_pressed or left_down or right_down) {
        logEvent(.history, "keytrace pressed(l={},r={}) down(l={},r={}) anim={s} ptr={d} len={d}", .{
            left_pressed, right_pressed, left_down, right_down,
            if (self.anim.active) "active" else "idle",
            self.history_ptr, self.history_len,
        });
    }

    const mx = rl.getMouseX();
    const my = rl.getMouseY();
    const in_top = my < TOTAL_TOP;
    var tb_click_consumed = false;

    if (in_top and rl.isMouseButtonPressed(.left)) {
        const tb_y: i32 = (LINE1_H - TB_H) / 2;
        const tb = ui.ToolbarLayout.compute(self.render_w);
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
            if (mx >= tb.arrow_l_x and mx < tb.arrow_l_x + ui.BTN_ARROW and my >= tb_y and my < tb_y + TB_H) { try self.navigateHistoryBack(); tb_click_consumed = true; }
            if (mx >= tb.arrow_r_x and mx < tb.arrow_r_x + ui.BTN_ARROW and my >= tb_y and my < tb_y + TB_H) { try self.navigateHistoryForward(); tb_click_consumed = true; }
            if (mx >= tb.inc_x and mx < tb.inc_x + ui.BTN_ITER and my >= tb_y and my < tb_y + TB_H) { try self.adjustIters(true); tb_click_consumed = true; }
            if (mx >= tb.dec_x and mx < tb.dec_x + ui.BTN_ITER and my >= tb_y and my < tb_y + TB_H) { try self.adjustIters(false); tb_click_consumed = true; }
            if (mx >= tb.copy_x and mx < tb.copy_x + ui.BTN_LG and my >= tb_y and my < tb_y + TB_H) {
                const VIEW_FMT = "x={d:.8} y={d:.8} range={e:.8} iters={d}";
                var buf: [256]u8 = undefined;
                rl.setClipboardText(std.fmt.bufPrintZ(&buf, VIEW_FMT, .{self.view.center_x, self.view.center_y, self.view.range, self.view.max_iters}) catch unreachable);
                logEvent(.ui, "clipboard copy", .{});
                tb_click_consumed = true;
            }
            if (mx >= tb.paste_x and mx < tb.paste_x + ui.BTN_LG and my >= tb_y and my < tb_y + TB_H) {
                const clip = std.mem.sliceTo(rl.getClipboardText(), 0);
                if (clip.len > 0) {
                    self.tb_buf.format("{s}", .{clip});
                    if (app.parseViewState(self.tb_buf.buf[0..self.tb_buf.len])) |_| { self.tb_active = false; try self.textBoxApply(); }
                    else { self.syncTextBox(); }
                    logEvent(.ui, "clipboard paste", .{});
                }
                tb_click_consumed = true;
            }
            if (mx >= tb.reset_x and mx < tb.reset_x + ui.BTN_RESET and my >= tb_y and my < tb_y + TB_H) { try self.resetView(); tb_click_consumed = true; }
            if (my >= LINE1_H and my < TOTAL_TOP) {
                const chk_x = self.render_w - TOP_PAD - @as(i32, @intFromFloat(self.tooltip_label_w));
                if (mx >= chk_x and mx < self.render_w - TOP_PAD) { self.tooltip_enabled = !self.tooltip_enabled; tb_click_consumed = true; }
            }
        }
    }

    if (self.tb_active and rl.isMouseButtonPressed(.left) and !in_top) {
        self.tb_active = false;
        self.syncTextBox();
        tb_click_consumed = true;
    }

    if (!self.tb_active) {
        if (left_pressed) {
            try self.navigateHistoryBack();
        } else if (right_pressed) {
            try self.navigateHistoryForward();
        }
    } else {
        if (left_pressed) self.logInputEvent("left", "skipped", "tb_active");
        if (right_pressed) self.logInputEvent("right", "skipped", "tb_active");
    }

    if (rl.isKeyPressed(.equal) or rl.isKeyPressed(.kp_add)) {
        try self.adjustIters(true);
    } else if (rl.isKeyPressed(.minus) or rl.isKeyPressed(.kp_subtract)) {
        try self.adjustIters(false);
    }
    if (rl.isKeyPressed(.r)) try self.resetView();
    if (self.render_timed_out and rl.isKeyPressed(.space)) { logEvent(.render, "continue", .{}); _ = try self.renderFresh(false); }

    if (self.tb_active) {
        if (rl.isKeyPressed(.left)) self.tb_buf.moveCursorLeft();
        if (rl.isKeyPressed(.right)) self.tb_buf.moveCursorRight();
        if (rl.isKeyPressed(.home)) self.tb_buf.moveHome();
        if (rl.isKeyPressed(.end)) self.tb_buf.moveEnd();
        if (rl.isKeyPressed(.backspace)) self.tb_buf.deleteBeforeCursor();
        if (rl.isKeyPressed(.delete)) self.tb_buf.deleteAfterCursor();
        if (rl.isKeyPressed(.enter) or rl.isKeyPressed(.kp_enter)) { self.tb_active = false; try self.textBoxApply(); }
        if (rl.isKeyPressed(.escape)) { self.tb_active = false; self.syncTextBox(); }
        var ch = rl.getCharPressed();
        while (ch != 0) {
            if (ch >= ASCII_PRN_MIN and ch < ASCII_PRN_MAX + 1) self.tb_buf.insertChar(@as(u8, @intCast(ch)));
            ch = rl.getCharPressed();
        }
        return;
    }

    if (!tb_click_consumed and !in_top and rl.isMouseButtonPressed(.left)) {
        const now = rl.getTime();
        const dx = mx - self.last_click_x;
        const dy = my - self.last_click_y;
        const dist = @sqrt(@as(f64, @floatFromInt(dx * dx + dy * dy)));
        const DOUBLE_CLICK_TIME: f64 = 0.3;
        const DOUBLE_CLICK_DIST: f64 = 10.0;
        if (self.last_click_time > 0 and (now - self.last_click_time) < DOUBLE_CLICK_TIME and dist < DOUBLE_CLICK_DIST) {
            try self.handleDoubleClickZoom(mx, my);
            self.last_click_time = 0;
            self.last_click_x = 0;
            self.last_click_y = 0;
        } else {
            self.last_click_time = now;
            self.last_click_x = mx;
            self.last_click_y = my;
            self.drag.start_x = @floatFromInt(rl.getMouseX());
            self.drag.start_y = @floatFromInt(rl.getMouseY());
            self.drag.current_x = self.drag.start_x;
            self.drag.current_y = self.drag.start_y;
            self.drag.active = true;
        }
    }
    if (self.drag.active and rl.isMouseButtonDown(.left)) {
        const sq = m.constrainDragSquare(self.drag.start_x, self.drag.start_y, @floatFromInt(rl.getMouseX()), @floatFromInt(rl.getMouseY()));
        self.drag.current_x = sq.x;
        self.drag.current_y = sq.y;
    }
    if (self.drag.active and rl.isMouseButtonReleased(.left)) {
        self.cancelAnimation();
        defer self.drag.active = false;
        const size = @abs(self.drag.current_x - self.drag.start_x);
        if (size >= MIN_SELECTION_PX) {
            const sel_cx = (self.drag.start_x + self.drag.current_x) / 2.0;
            const sel_cy = (self.drag.start_y + self.drag.current_y) / 2.0;
            const dpi_f = @as(f64, @floatFromInt(self.dpi_scale));
            const phys_size = size * dpi_f;
            const new_range = self.view.range * (phys_size / @as(f64, @floatFromInt(@min(self.image.width, self.image.height))));
            logEvent(.drag, "zoom from {d:.6} to {d:.6} iters={d}", .{self.view.range, new_range, self.view.max_iters});
            const aspect = @as(f64, @floatFromInt(self.image.width)) / @as(f64, @floatFromInt(self.image.height));
            const delta = m.computeDragDelta(self.view,
                (sel_cx * dpi_f / @as(f64, @floatFromInt(self.image.width)) - 0.5) * self.view.range,
                ((sel_cy - @as(f64, @floatFromInt(TOTAL_TOP))) * dpi_f / @as(f64, @floatFromInt(self.image.height)) - 0.5) * (self.view.range / aspect));
            app.truncateFuture(&self.history, &self.history_len, self.history_ptr + 1);
            const from_view = self.view;
            const to_view = m.ViewState{.center_x=delta.center_x,.center_y=delta.center_y,.offset_x=delta.offset_x,.offset_y=delta.offset_y,.range=new_range,.max_iters=self.view.max_iters};
            try self.captureAnimationFrame();
            self.view = to_view;
            _ = try self.renderFresh(true);
            self.anim.from_view = from_view;
            self.anim.to_view = to_view;
            self.anim.duration = app.computeAnimDuration(from_view, to_view);
            self.anim.start_time = rl.getTime();
            self.anim.active = true;
            logEvent(.anim, "start in dur={d:.3} from={d:.6} to={d:.6}", .{self.anim.duration, from_view.range, to_view.range});
            if (self.history_len < 64) try self.saveSnapshot();
        }
    }
    self.syncTextBox();
}
