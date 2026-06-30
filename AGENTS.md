# AGENTS.md — Mandelbrot Set Visualizer

## Project context

An interactive Mandelbrot viewer written in Zig 0.16 using raylib (via raylib-zig,
v5.6-dev targeting raylib 6.0).  Multi-threaded rendering, undo/redo with
cached pixel buffers, smooth coloring, cardioid/bulb periodicity checking, and
derivative-based interior detection.

## Primary reference document

[Techniques for computer generated pictures in complex dynamics – Arnaud Chéritat](https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set)

This document is the canonical source for all rendering algorithms.  Sections 3.1–3.6
describe escape-time coloring, potential-based coloring, interior detection,
boundary distance estimators, normal maps, and image trapping.  Section 4 discusses
mixing methods.

**Note on usefulness:** Much of the math (especially Sections 3.5–3.6) is visual
enhancement, not raw speed.  The biggest speed wins — derivative-based interior
detection (Section 3.4) and cardioid/bulb checking — are already implemented.
Future agents should focus on the visualization modes.

## What is already implemented

- Escape-time coloring with smooth iteration count (`mu` formula)
- HSL palette (blue → cyan → green → yellow → red), 1024 entries
- Multi-threaded rendering (up to 8 threads, horizontal striping)
- Cardioid/bulb periodicity pre-checks with bounding-box rejection
- Derivative-based interior detection (Section 3.4 of Chéritat)
- Periodicity orbit detection (Bolt's method — stores z at power-of-2 iterations)
- f32 inner loop (was f64 — 2× SIMD width, better cache)
- Undo/redo history with cached pixel buffers (←/→ keys)
- Power-of-2 iteration scaling (2^4 … 2^16, auto-scale on zoom)
- 30-second render timeout with Space-to-continue
- Unit tests for pure functions (`zig build test`)

## Future optimizations

### Perturbation theory (major speedup for deep zooms)

For very deep zooms (range < 1e-6), all pixel coordinates are within a tiny
neighbourhood of the reference point (usually the view centre).  The idea:

1. Compute one **reference orbit** `Z_n` in full f64/precision from the centre point.
2. For each pixel, compute only the **offset** `δ_n = z_n - Z_n` using the
   recurrence `δ_{n+1} = 2·Z_n·δ_n + δ_n² + δ_c`, where `δ_c = c - C` is
   the tiny pixel-to-reference offset in the complex plane.
3. When a pixel's offset grows large enough to escape (`|Z_n + δ_n| > 2`),
   the point is outside M.
4. When a pixel's offset grows larger than a glitch threshold (e.g.,
   `|δ_n| > |Z_n| / 1000`), the approximation breaks down — mark the pixel
   for "rebasing" to a new reference.

Reference: Chéritat Section 3.4 mentions "images and speed" improvements from
interior detection but does not detail perturbation.  See K. I. Martin's
"Perturbation theory for the Mandelbrot set" (2013) for the standard algorithm.

**Implementation sketch:**
- Store the full reference orbit (Z_n, n=0..max_iters) as an array of `(zx, zy)` pairs.
- Allocate ~8 MB for a 65536-iteration f32 reference orbit.
- The per-pixel inner loop uses f32 for δ_n, δ_c.  Runs ~10× faster since
  δ_n stays small (fewer bits to multiply).
- Glitch detection requires a separate pass or deferred rebase queue.
- Compatibility with the existing derivative interior detection: the reference
  orbit's derivative `D_n` must also be stored (or recomputed).

**Status:** Not yet implemented.  A significant architectural change — requires
pre-computing the reference orbit before spawnning render threads, and modifying
`renderStrip` to accept the reference data.

Per the Chéritat document, the following visualization modes should be added.
Each mode has a name, a short description, and a reference to the document section.

### Mode 1: Potential coloring (Section 3.3)
- Use the potential `V(c) = log|z|/2^n` instead of iteration count for coloring
- When `|z| > R` (R big, e.g., 1000), compute `V = log(|z|^2) / (2^n)`
- Color based on `V` (not `n`)
- Parameter: `R` (escape radius, default 1000.0)
- Parameter: `color_function` (a transfer function mapping V → color)

### Mode 2: Log-potential scale (Section 3.3.1)
- Extension of potential mode: color cycles on `log(V)` instead of V
- Parameter: `K` (period constant, default `ln(2)`)
- Parameter: `wave_function` (e.g., `0.5*(1+cos(2π*log(V)/K))`)
- Useful for deep zooms where potential varies across many orders of magnitude

### Mode 3: Boundary detection — Milnor's distance estimator (Section 3.5.1)
- Track derivative w.r.t. c: `der_c_{n+1} = 2*z_n*der_c_n + 1`
- Compute distance estimate: `d_n = 2*|z_n|*log(|z_n|) / |der_c|`
- Color boundary pixels black, outside pixels white (or colored)
- Parameter: `R` (escape radius, default 1000.0)
- Parameter: `thickness_factor` (boundary width, default 1.0)

### Mode 4: Boundary detection — antialiased (Section 3.5.2)
- Like mode 3 but `d_n/s` interpolates between boundary and outside colors
- Parameter: `thickness_factor` (default 1.414)

### Mode 5: Distance estimator coloring (Section 3.5.3)
- Color the outside as a function of the distance estimate `d_n`
- Example: parity of `floor(log(d_n) / period)` for banded effect

### Mode 6: Henriksen's boundary detection (Section 3.5.4)
- Alternative to Milnor's, more versatile across zoom depths
- Test `|z| < pixel_size * thickness_factor * |der|`
- Parameter: `R` (escape radius, default 10.0)
- Parameter: `thickness_factor` (default 0.25)
- Note: can optionally set `dc = pixel_size * thickness_factor` upfront to save a multiply

### Mode 7: Image trapping / fancy outside coloring (Section 3.6.1)
- Map the first escaped `z` value to a coordinate in a base image
- Requires loading a "trap" image (PNG or similar)
- Parameter: `trap_image_path`
- Parameter: `R` (escape radius, default 4.8)

### Mode 8: Normal map shading (Section 3.6.2)
- Compute a normal vector from the potential gradient: `u = z / der`
- Apply Lambertian shading: `t = dot(normalize(u + (0,0,1)), light_dir)`
- Parameter: `light_angle` (degrees, default 45)
- Parameter: `height_factor` (default 1.5)
- Can use distance estimator instead of potential (more complex, see 3.6.2.1)

### Mode 9: Radial strands / Stripe Average (Section 3.6.3)
- Track the argument of `z` after each iteration near the escape
- Requires averaging multiple values near the escape point
- Reference: Kerry Mitchell's Stripe Average method

## Mode configuration format

Modes shall be defined in `.toml` files under a `modes/` directory.  Example:

```toml
# modes/potential.toml
name = "Potential"
doc_section = "3.3"
description = "Color based on the continuous potential function V(c)"

[params]
R = 1000.0         # escape radius
color_scale = 1.0  # multiplier on V before color mapping

[palette]
# Override palette for this mode (optional)
hue_start = 240.0
saturation = 0.85
lightness_base = 0.45
lightness_range = 0.35
```

A default mode is the current escape-time coloring.  All modes must define at
least `name` and `doc_section`.  The `params` section is mode-specific.

## Pulldown menu for mode selection

Add a dropdown menu to the UI that:
- Lists all discovered `.toml` mode configs from `modes/`
- Shows the current mode name in the HUD bar
- Keyboard shortcut: `M` key opens/closes the dropdown
- On mode change, re-renders with the new mode's coloring algorithm
- The dropdown uses raylib GUI primitives (draw rectangles, text)

Implementation approach:
- Scan `modes/` directory at startup for `.toml` files
- Parse each into a `ModeConfig` struct
- Store them in an array
- Track `current_mode_index`
- The `renderStrip` function receives a `ModeConfig` and uses it to select
  the coloring algorithm at the per-pixel level

## Code review TODO items

- [ ] Extract the 30s timeout warning text ("TIMEOUT: ...") into a constant or helper
- [ ] `INTERIOR_EPSILON_SQ` may need tuning at very deep zooms (the document notes
      that epsilon=0.1 sometimes gives false positives near parabolic parameters)
- [ ] The `hslToRgb` function uses `f32` but the Mandelbrot math uses `f64` — this
      is fine for the palette (computed once) but could be noted
- [ ] Window resize invalidates pixel cache silently — a small "Resize clears history"
      hint in the HUD would help (low priority)

**Already fixed in earlier sessions:**
- [x] `zx`/`zy`/`dx`/`dy` in `renderStrip` → refactored into `Coord` struct with `normSq()` and `sq()`
- [x] `constrainDragSquare` return type → named `ComplexPoint` (was anonymous struct)
- [x] Button position constants (`screen_w - 68`, `-46`, `28`, etc.) → extracted to
      `BTN_SIZE`, `BTN_GAP`, `BTN_Y_OFFSET`, `HUD_HEIGHT` in the constants section

## Build & test

```bash
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#v5.6-dev  # once
zig build run      # run the app
zig build test     # run unit tests
```
