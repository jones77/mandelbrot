# AGENTS.md — Mandelbrot Set Visualizer

## Project context

An interactive Mandelbrot viewer written in Zig 0.16 using raylib (via raylib-zig,
v5.6-dev targeting raylib 6.0).  Multi-threaded rendering, undo/redo with
cached pixel buffers, smooth coloring, cardioid/bulb periodicity checking, and
derivative-based interior detection.

## Primary reference documents

[Techniques for computer generated pictures in complex dynamics – Arnaud Chéritat](https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set)

[Cardioid and bulb checking – Claude Heiland-Allen (mathr.co.uk)](https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html)

The Chéritat document is the main reference for visualisation modes and rendering
algorithms (Sections 3.1–3.6).  A condensed summary for implementing the various
colouring modes is at `docs/cheritat-algorithms.md`.  The mathr.co.uk article was
used for cardioid/bulb bounding‑box optimisation.

**Note on usefulness:** Much of the math (especially Sections 3.5–3.6 of Chéritat)
is visual enhancement, not raw speed.  The biggest speed wins — derivative-based
interior detection (Section 3.4) and cardioid/bulb checking — are already
implemented.  Future agents should focus on the visualisation modes.

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

## Architectural decisions

### App struct + methods (not module-level functions)

All mutable state lives in a single `App` struct: `ViewState`, undo history,
window dimensions, the raylib image and texture, and drag state.  Each frame
is three method calls: `handleResize`, `handleInput`, `drawFrame`.  This
kept `main()` from growing past ~25 lines and makes the frame lifecycle
explicit.  Methods that modify app state are on `*App`; pure computation
functions stay at module level.

### Command pattern for undo/redo

Zoom and iteration changes both snapshot the current view + pixel buffer
before mutating.  The history is a fixed-size `[64]HistoryEntry` ring
buffer with a `ptr` into it — undo decrements, redo increments.  Entries
are freed only when a new action would overwrite them (truncate future).
The pixel cache makes undo/redo instant (memcpy instead of re-render).

### f32 inner loop for speed

The hot path uses `f32` (was `f64`) to double SIMD width on NEON and
halve memory traffic.  View‑level maths (`range`, `center`, bounding‑box
checks) stay in `f64` — only per‑pixel `c`, `z`, and derivative are
cast down.  The smooth‑colouring `mu` is cast back to `f64` for the
palette function (an exact conversion).  At extreme zoom depths f32
precision degrades — see perturbation theory below for the long‑term fix.

### Pixel buffer cache for undo history

Each history entry holds a `[]u8` (RGBA) copy of the full frame at that
zoom level.  At 900×800 that's ~2.75 MB per entry; 64 entries is ~176 MB
worst case.  The trade‑off — memory for instant undo/redo — is worth it
for an interactive viewer.  Resize clears history (cached pixels are the
wrong size).

### Interior detection strategy (three layers)

1. **Cardioid/bulb pre‑check** (O(1), no iteration): tests if `c` is in
   the main cardioid or period‑2 bulb.  Bounding‑box rejection skips this
   entirely when the view is far from those shapes.
2. **Derivative tracking** (per iteration): `(P^n)'(c)` → 0 for interior
   points.  Scaled epsilon: `1e-6 × (max_iters / DEFAULT_MAX_ITERS)`.
3. **Orbit periodicity** (per iteration): stores `z` at power‑of‑2
   iteration counts; if `z` returns within `1e-8` of a stored value the
   orbit is periodic → inside M.

Layers 2 and 3 stop iteration early for interior points, which is the
main speed win at high iteration counts.  Layer 1 catches the most
common case (main body) with zero iteration cost.

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

### f64 fallback for deep zooms (range < 1e-7)

At range 1e-8 with a 900×800 window, the per-pixel step is ~1e-11.  f32
has ~7 decimal digits, so coordinates at |c| ≈ 2 are rounded to ~2.4e-7 —
far larger than the pixel step.  Adjacent pixels become indistinguishable
and the image gets blocky.

**Implementation:** compare `range / min(screen_w, screen_h)` against a
threshold (≈ 2e-7).  Below it, use `f64` for the entire inner loop
(original precision, half the SIMD width).  The `Coord` struct can be
generic or replaced by raw `f64` scalars in an alternate hot path.

### SIMD via @Vector

The hot loop is trivially parallel across lanes.  Zig's `@Vector(4, f32)`
lets NEON compute 4 pixels per instruction.  The main challenge is lane
divergence — when one pixel escapes, its lane must be masked out so the
other three continue.

**Implementation sketch:**
- Bundle `zx, zy, cx, cy, dx, dy` into `@Vector(4, f32)` groups.
- Escape check: `escaped = zx*zx + zy*zy > 4.0` → `@reduce(.Or, escaped)`
  to determine if any lane escaped.
- Mask out escaped lanes by zeroing their coordinates (so |z| stays 0)
  and track iteration count per lane.
- Interior detection is trickier with divergence; may need per-lane state.
- Expected gain: ~2× on M1 (4-wide NEON, but divergence hurts).

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

*(All items resolved — no open tasks.)*

**Already fixed in earlier sessions:**
- [x] `zx`/`zy`/`dx`/`dy` in `renderStrip` → refactored into `Coord` struct with `normSq()` and `sq()`
- [x] `constrainDragSquare` return type → named `ComplexPoint` (was anonymous struct)
- [x] Button position constants (`screen_w - 68`, `-46`, `28`, etc.) → extracted to
      `BTN_SIZE`, `BTN_GAP`, `BTN_Y_OFFSET`, `HUD_HEIGHT` in the constants section
- [x] The 30s timeout warning text → extracted to `logTimeout()` helper
- [x] "Resize clears history" hint → now displayed in bottom-right corner of HUD
- [x] The `hslToRgb` function uses `f32` but the Mandelbrot math uses `f64` — this
      is fine for the palette (computed once) but could be noted
- [x] `INTERIOR_BASE_EPSILON_SQ` scaled linearly with `max_iters` so deeper zooms
      relax the derivative threshold (false positives near parabolic params are
      less likely at higher iteration counts)

## Build & test

```bash
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#v5.6-dev  # once
zig build run      # run the app
zig build test     # run unit tests
```
