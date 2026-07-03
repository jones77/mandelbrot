# Coordinate Tooltip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `[x] tooltip` checkbox (on by default) and `--tooltip`/`--no-tooltip` CLI flag that shows pixel-center coords after 2s mouse stillness.

**Architecture:** Three changes: CLI arg parsing in `main.zig`, checkbox UI + mouse tracking in `app.zig`'s App struct, tooltip rendering in `drawFrame`.

**Tech Stack:** Zig 0.16, raylib-zig v5.6-dev (`rl.drawRectangleRounded`, `rl.measureTextEx`, `rl.drawTextEx`)

## Global Constraints

- Use pixel-center convention for coordinate calculation
- Default tooltip state is enabled
- CLI flags: `--tooltip` enables, `--no-tooltip` disables
- Checkbox label: `[x] tooltip` / `[ ] tooltip`, right-aligned on second toolbar line
- Tooltip shows after 2 seconds of mouse stillness in viewport
- Coordinate format: `x={d:.8}  y={d:.8}` matching existing precision
- Tooltip snaps to pixel centers, drawn near cursor with rounded semi-transparent background
- Follow existing code conventions (same font, color palette from app.zig constants)

---

### Task 1: CLI Argument Parsing

**Files:**
- Modify: `src/main.zig:36-49`

**Interfaces:**
- Consumes: `std.process.Args` from `main()` args
- Produces: `tooltip_enabled: bool` passed to `App.init()`

- [ ] **Step 1: Add tooltip arg parsing alongside `parseMethodArg`**

```zig
// Add a new function or extend the existing one.
// In main.zig, add a tooltip_enabled variable after render_method:
const tooltip_enabled = parseTooltipArg(init.minimal.args);

// Add function:
fn parseTooltipArg(args: std.process.Args) bool {
    var it = args.iterate();
    _ = it.next() orelse return true;
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--no-tooltip")) return false;
        if (std.mem.eql(u8, arg, "--tooltip")) return true;
    }
    return true;
}
```

- [ ] **Step 2: Pass `tooltip_enabled` to `app.App.init()`**

```zig
// main.zig: change init call
var a = try app.App.init(render_method, tooltip_enabled);
```

- [ ] **Step 3: Update `App.init` signature** (stub — we fill the body in Task 2)

Update `app.zig` line 292:
```zig
pub fn init(render_method: m.RenderMethod, tooltip_enabled: bool) !App {
```

- [ ] **Step 4: Build check**

Run: `zig build` — expected: compile error about missing argument or type mismatch (we fix in Task 2)

- [ ] **Step 5: Commit**

```bash
git add src/main.zig src/app.zig
git commit -m "cli: add --tooltip/--no-tooltip flag"
```

---

### Task 2: App Struct Fields and Init

**Files:**
- Modify: `src/app.zig` (App struct, init, deinit)

**Interfaces:**
- Consumes: `tooltip_enabled: bool` from CLI
- Produces: App fields used by Tasks 3 and 4

- [ ] **Step 1: Add fields to App struct (after `btn_w_reset`)**

```zig
tooltip_enabled: bool,
tooltip_mouse_still_since: f64,
tooltip_last_mx: i32,
tooltip_last_my: i32,
```

- [ ] **Step 2: Initialize fields in `App.init()`**

In the App struct literal, after `btn_w_reset` line, add:
```zig
.tooltip_enabled = tooltip_enabled,
.tooltip_mouse_still_since = 0,
.tooltip_last_mx = 0,
.tooltip_last_my = 0,
```

- [ ] **Step 3: Add tooltip measurement init**

Before `return app;` in `init()`, add measurement for the checkbox label:
```zig
// No additional measurements needed — we compute checkbox_w on the fly in drawFrame
```

- [ ] **Step 4: Build check**

Run: `zig build` — expected: success

- [ ] **Step 5: Commit**

```bash
git add src/app.zig
git commit -m "app: add tooltip fields to App struct"
```

---

### Task 3: Checkbox UI Drawing and Click Handling

**Files:**
- Modify: `src/app.zig` (drawFrame + handleInput)

**Interfaces:**
- Consumes: App struct with `tooltip_enabled` field
- Produces: Toggleable checkbox in second toolbar line

- [ ] **Step 1: Add a constant for checkbox label**

At the end of the constant block in app.zig (before `const TextBuf`), add:
```zig
const TOOLTIP_LABEL = "[x] tooltip";
const TOOLTIP_LABEL_OFF = "[ ] tooltip";
```

- [ ] **Step 2: Measure checkbox width in init and store**

Add field in App struct:
```zig
tooltip_label_w: f32,
```

Initialize after the other btn_ measurements in `init()`:
```zig
app.tooltip_label_w = rl.measureTextEx(app.ui_font, TOOLTIP_LABEL, FONT_SIZE_LG, 1).x;
```

Actually, since width of `[x] tooltip` and `[ ] tooltip` differ slightly (the `x` has width), let me measure both or just use the larger one. Simplest: use the `[x] tooltip` width since it's slightly wider.

- [ ] **Step 3: Draw checkbox in drawFrame**

In `drawFrame`, after the hint text is drawn (line 956) and before the timeout indicator (line 1001-1005), add:

```zig
// Tooltip checkbox — right-aligned on second line
{
    const chk_label = if (self.tooltip_enabled) TOOLTIP_LABEL else TOOLTIP_LABEL_OFF;
    const chk_w = self.tooltip_label_w;
    const chk_x = @as(f32, @floatFromInt(self.render_w)) - TOP_PAD - chk_w;
    const chk_y = @as(f32, @floatFromInt(LINE1_H)) + HINT_PAD_Y;
    const hover = mx >= chk_x and mx < chk_x + chk_w and
        my >= LINE1_H + HINT_PAD_Y and my < LINE1_H + HINT_PAD_Y + FONT_SIZE_LG;
    rl.drawTextEx(self.ui_font, chk_label, .{ .x = chk_x, .y = chk_y }, FONT_SIZE_LG, 1,
        if (hover) COL_TEXT else COL_HINT);
}
```

Note: For the hover detection, I need to use physical mouse coords `mx` and `my` from `drawFrame` (which are already fetched at lines 948-949) and compare them with logical coordinates. This matches the existing pattern used by `drawToolbarButton`.

- [ ] **Step 4: Handle checkbox click in handleInput**

In `handleInput`, after the top bar interactions section and before the keyboard shortcuts, add a click handler for the checkbox. The checkbox is on the second line, so `my < TOTAL_TOP` still applies.

Actually, looking at the structure of `handleInput` more carefully:
- Lines 694-764: Top bar interactions (LINE1) — text box, buttons, arrows
- Lines 767-771: Click outside text box
- Lines 773-812: Keyboard shortcuts
- Lines 814-830: Text box active input
- Lines 832+: Drag handling

The second line (LINE2_H area) is between LINE1_H and TOTAL_TOP. The checkbox is in that area. I need to handle clicks there.

Let me add the checkbox click handling after the `tb_click_consumed` block but outside the `if (in_top)` block since clicking the hint bar area shouldn't deactivate the textbox.

Actually, looking more carefully at the `if (in_top)` block: it only fires on mouse press, and `in_top` is `my < TOTAL_TOP`. The second line is within the top area. So clicks on the second line ARE handled by the `if (in_top)` block.

Let me add the checkbox click handler within the `if (in_top)` block, after the other button clicks but before the closing brace. I need to check if the click is in the second line area (y between LINE1_H and TOTAL_TOP).

Actually, I should add it at the end of the `if (in_top)` block, as an else-if branch before the final closing:

```zig
// In handleInput, within the `if (in_top and rl.isMouseButtonPressed(.left))` block,
// after the reset button handler and before the closing brace:
if (mx >= tb_chk_x and mx < tb_chk_x + @as(i32, @intFromFloat(self.tooltip_label_w)) and my >= LINE1_H and my < TOTAL_TOP) {
    self.tooltip_enabled = !self.tooltip_enabled;
    tb_click_consumed = true;
}
```

Wait, but this is already inside `if (in_top and rl.isMouseButtonPressed(.left))`, and the check for `in_top` is already true. I just need to check the y range.

Let me think about this more carefully. The existing code flow for top bar clicks:

```zig
if (in_top and rl.isMouseButtonPressed(.left)) {
    const tb_y = ...;  // LINE1 (first bar)
    // first bar interactions
    // ...
    // The reset click is last
    if (mx >= tb.reset_x ...) { ... }
    
    // ← I'll add checkbox handling here, checking for second line clicks
}
```

So I'll add an else-if chain after the reset button handler for the second toolbar line.

```zig
// After the reset check:
if (my >= LINE1_H) {
    // Second line click — check tooltip checkbox
    const chk_x = self.render_w - @as(i32, @intFromFloat(TOP_PAD + self.tooltip_label_w));
    if (mx >= chk_x and mx < chk_x + @as(i32, @intFromFloat(self.tooltip_label_w)) and my >= LINE1_H and my < TOTAL_TOP) {
        self.tooltip_enabled = !self.tooltip_enabled;
        tb_click_consumed = true;
    }
}
```

Hmm, but `render_w` is i32, `TOP_PAD` is i32, and `self.tooltip_label_w` is f32. The existing code uses `@as(i32, @intFromFloat(...))` for f32→i32 conversion. Let me be careful.

- [ ] **Step 5: Build check**

Run: `zig build` — expected: success

- [ ] **Step 6: Run to check**

Run: `zig build run` — expected: checkbox appears in second toolbar line, clickable

- [ ] **Step 7: Commit**

```bash
git add src/app.zig
git commit -m "ui: add tooltip checkbox toggle in toolbar"
```

---

### Task 4: Tooltip Rendering

**Files:**
- Modify: `src/app.zig` (drawFrame + helper functions)

**Interfaces:**
- Consumes: App struct with mouse tracking fields, `tooltip_enabled`, view state
- Produces: Tooltip rendered at cursor after 2s stillness

- [ ] **Step 1: Add constants for tooltip**

Add after the TOOLTIP_LABEL constants:
```zig
const TOOLTIP_DELAY_S: f64 = 2.0;
const TOOLTIP_MOVE_THRESHOLD_PX: i32 = 2;
const TOOLTIP_OFFSET_X: i32 = 12;
const TOOLTIP_OFFSET_Y: i32 = 12;
const TOOLTIP_PAD_X: i32 = 8;
const TOOLTIP_PAD_Y: i32 = 4;
```

- [ ] **Step 2: Add a pixel-to-complex conversion method**

Add to `App`:
```zig
/// Convert viewport pixel indices to pixel-center complex coordinate.
/// px, py are pixel indices (0..w-1, 0..h-1).
fn pixelCenterToComplex(self: *const App, px: f64, py: f64) struct { x: f64, y: f64 } {
    _ = self;
    _ = px;
    _ = py;
    // Implementation in Step 3
}
```

- [ ] **Step 3: Implement the coordinate mapping**

`pixelCenterToComplex` converts physical pixel indices (0..image.width-1) to
complex coords via the pixel-center convention — same formula as the renderer.

```zig
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
```

- [ ] **Step 4: Add mouse tracking and tooltip rendering to drawFrame**

`rl.getMouseX/Y()` returns **logical** coordinates (same plane as `render_w`).
The image is in **physical** pixels, so multiply mouse coords by `dpi_scale`.

Add at the end of `drawFrame`, before `rl.endDrawing()`:

```zig
// Tooltip: 2s hover delay, pixel-center coords
if (self.tooltip_enabled) {
    const viewport_y = TOTAL_TOP;
    if (my >= viewport_y and my < self.render_h) {
        const dpi_f: f64 = @floatFromInt(self.dpi_scale);
        // Convert logical mouse coords → physical pixel position
        const phys_px = @as(f64, @floatFromInt(mx)) * dpi_f;
        const phys_py = (@as(f64, @floatFromInt(my)) - @as(f64, @floatFromInt(TOTAL_TOP))) * dpi_f;
        const w_f: f64 = @floatFromInt(self.image.width);
        const h_f: f64 = @floatFromInt(self.image.height);

        const in_viewport = phys_px >= 0 and phys_px < w_f and phys_py >= 0 and phys_py < h_f;

        if (in_viewport) {
            const moved_x = @abs(mx - self.tooltip_last_mx) > TOOLTIP_MOVE_THRESHOLD_PX;
            const moved_y = @abs(my - self.tooltip_last_my) > TOOLTIP_MOVE_THRESHOLD_PX;
            if (moved_x or moved_y) {
                self.tooltip_mouse_still_since = rl.getTime();
                self.tooltip_last_mx = mx;
                self.tooltip_last_my = my;
            }

            const still_for = rl.getTime() - self.tooltip_mouse_still_since;
            if (still_for >= TOOLTIP_DELAY_S) {
                // Draw tooltip near (mx, my) — pixel-center using physical pixel indices
                const px: f64 = @floor(phys_px);
                const py: f64 = @floor(phys_py);
                const coord = self.pixelCenterToComplex(px, py);

                var tooltip_buf: [128]u8 = undefined;
                const tooltip_text = std.fmt.bufPrintZ(&tooltip_buf, "x={d:.8}  y={d:.8}", .{ coord.x, coord.y }) catch unreachable;

                const tt_size = rl.measureTextEx(self.ui_font, tooltip_text, FONT_SIZE_LG, 1);
                const tt_w = tt_size.x + @as(f32, @floatFromInt(TOOLTIP_PAD_X * 2));
                const tt_h = tt_size.y + @as(f32, @floatFromInt(TOOLTIP_PAD_Y * 2));

                // Position near cursor, clamped to viewport
                const c_x: f32 = @floatFromInt(mx + TOOLTIP_OFFSET_X);
                const c_y: f32 = @floatFromInt(my + TOOLTIP_OFFSET_Y);
                const tt_x = @min(@as(f32, @floatFromInt(self.render_w)) - tt_w - @as(f32, @floatFromInt(TOP_PAD)), @max(@as(f32, @floatFromInt(TOP_PAD)), c_x));
                const tt_y = @min(@as(f32, @floatFromInt(self.render_h)) - tt_h - @as(f32, @floatFromInt(TOP_PAD)), @max(@as(f32, @floatFromInt(TOTAL_TOP)), c_y));

                const bg = rl.Rectangle{ .x = tt_x, .y = tt_y, .width = tt_w, .height = tt_h };
                rl.drawRectangleRounded(bg, 0.3, 4, .{ .r = 30, .g = 30, .b = 40, .a = 200 });
                rl.drawTextEx(self.ui_font, tooltip_text, .{ .x = tt_x + @as(f32, @floatFromInt(TOOLTIP_PAD_X)), .y = tt_y + @as(f32, @floatFromInt(TOOLTIP_PAD_Y)) }, FONT_SIZE_LG, 1, .white);
            }
        }
    } else {
        // Mouse outside viewport — reset tracking
        self.tooltip_mouse_still_since = rl.getTime();
        self.tooltip_last_mx = mx;
        self.tooltip_last_my = my;
    }
}
```

Wait, I need to initialize `tooltip_mouse_still_since` to the current time in init, so it doesn't immediately show a tooltip at startup.

- [ ] **Step 5: Init mouse tracking time in App.init**

raylib is already initialized by the time `App.init()` runs, so use `rl.getTime()`:
```zig
.tooltip_mouse_still_since = rl.getTime(),
```

- [ ] **Step 6: Build check**

Run: `zig build` — expected: success

- [ ] **Step 7: Run to verify**

Run: `zig build run` — expected: hover mouse in viewport for 2s → tooltip appears with pixel-center coords. Click checkbox to toggle. `--no-tooltip` disables at start.

- [ ] **Step 8: Commit**

```bash
git add src/app.zig
git commit -m "feat: add coordinate tooltip with 2s hover delay"
```

---

### Task 5: Update Tests (if needed)

**Files:**
- Check: `src/integration_tests.zig`

The tooltip is a UI feature and the existing tests don't test UI interaction, so no test changes needed.

- [ ] **Step 1: Verify existing tests still pass**

Run: `zig build test && zig build unit`
Expected: All tests pass

- [ ] **Step 2: Commit if any changes**

```bash
# Only if changes made
git commit -m "test: update for tooltip changes"
```
