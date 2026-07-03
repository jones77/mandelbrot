# Coordinate Tooltip

## Summary

Add a checkbox toggle in the toolbar and a `--tooltip`/`--no-tooltip` CLI flag
that enables a 2-second hover tooltip showing the pixel-center complex
coordinate under the cursor.

## CLI

- `--tooltip` — enable tooltip at startup (default)
- `--no-tooltip` — disable tooltip at startup
- Parsed in `main.zig` alongside `--method`
- Stored as `tooltip_enabled: bool` in `App`

## UI: Checkbox toggle

- Text toggle `[x] tooltip` / `[ ] tooltip` right-aligned on the second toolbar line
- Clicking toggles `tooltip_enabled` flag
- Uses existing font and `COL_TEXT` / `COL_HINT` styling

## Tooltip logic

- When `tooltip_enabled` and mouse is in the viewport (below TOTAL_TOP):
  - Track mouse stillness: if position changes >2px, reset a timer
  - After 2s of stillness, draw tooltip near cursor
  - Tooltip vanishes on mouse movement

## Tooltip appearance

- Semi-transparent dark background (`rl.Color{ .r = 30, .g = 30, .b = 40, .a = 200 }`)
- Rounded rect via `rl.drawRectangleRounded`
- Text: `x=1.23456789  y=-0.12345678` (8 decimal places, matching existing format)
- Positioned near cursor with a small offset, clamped to viewport bounds
- Uses pixel-center convention: snap cursor to nearest pixel center for the
  displayed coordinate

## Coordinate mapping

Given the current view state, compute the pixel-center complex coordinate:
- Logical pixel coords: `lx = floor(phys_mx / dpi_scale)`, `ly = floor((phys_my / dpi_scale) - TOTAL_TOP)`
- Pixel-center: `cx = left + (lx + 0.5) * step_x`, `cy = top + (ly + 0.5) * step_y`
- Handle deep zoom offsets: use `center_x + offset_x`, `center_y + offset_y`
- Aspect ratio: same computation as drag-zoom uses

## Files changed

- `src/main.zig` — add `--tooltip`/`--no-tooltip` parsing
- `src/app.zig` — add field, checkbox drawing, mouse tracking, tooltip rendering
