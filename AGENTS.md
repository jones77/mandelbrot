# AGENTS.md — Mandelbrot Set Visualizer

## Project context

Interactive Mandelbrot viewer in Zig 0.16 + raylib (via raylib-zig v5.6-dev).
**Must be cross-platform** — no macOS-only, Win32-only, or Linux-only code.
All platform-specific behaviour must go through raylib's abstractions.
Eleven source files: `main.zig` (entry), `app.zig` (coordinator — history, animation,
rendering), `input.zig` (keyboard/mouse/textbox input), `ui.zig` (drawing, toolbar,
tooltips), `renderer.zig` (multi-threaded rendering), `mandelbrot.zig` (pure math +
tests), `pixel.zig` (pixel format constants), `log.zig` (timestamping & structured
logging), `refbank.zig` (reference orbit bank grid), `test_runner.zig` (test harness —
imports all files with test blocks), `integration_tests.zig` (image-based tests).

## Zig conventions

Follow `lib/std/*.zig` conventions. Key exemplars to read for patterns:
- `std/fmt.zig` — overall file structure (imports → constants → types → functions → test block)
- `std/array_list.zig` — type with methods, generics
- `std/testing.zig` — test helpers

Language reference: https://ziglang.org/documentation/0.16.0/
Standard library: https://ziglang.org/documentation/0.16.0/std/

## References

Use the local summary at `cheritat-algorithms.md` for algorithm reference.
Do NOT fetch the Chéritat website — the local file covers all needed content
(Sections 3.1–3.6).

[Heiland-Allen](https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html)
— cardioid/bulb bounding-box optimisation.  Summary at `mathr-algorithms.md`.
Do NOT fetch the website — the local file covers all needed content.

## Naming conventions

**Do not create files or directories named `util`, `utils`, or `utilities`.**
Every file and directory must describe what the code inside *does* (e.g.
`pixel.zig` for pixel format constants, `log.zig` for structured logging).
Names like "utils" are too vague to convey purpose and encourage bloat.

## Build & test

```
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#v5.6-dev  # once
zig build run      # run app
zig build test     # full suite — all test blocks in main.zig's module tree
zig build unit     # pure-math tests (mandelbrot.zig), no raylib
zig build build-san # build with DebugAllocator (use-after-free, double-free)
zig build run-san  # run with DebugAllocator
zig build test-san # test suite with DebugAllocator
```

## Reading files efficiently

Re-reading a file after every `edit` or `write` call wastes context.
**Do not re-read a file to confirm a change.**  The edit tool signals
success or failure.  If you need to verify, read only the affected
lines using `offset` and `limit`, not the entire file.

## Critical architecture: pixel-center convention

**The renderer uses pixel-center sampling.** Every pixel-to-complex mapping
must use this formula:

```
cx = left + (px + 0.5) * range_x / w
cy = top  + (py + 0.5) * range_y / h
```

This is the standard convention in Mandelbrot explorers — each pixel samples
the centre of its cell, and the w×h cells evenly cover `[left, right] × [top, bottom]`.

**Common mistake:** using `px * range_x / w` (left-edge) or `px * range_x / (w-1)`
changes the centering by ~0.5px. These produce *visible* artifacts at the set
boundary even though every pixel is still "correctly" classified for the sampled
coordinate. The ground-truth tests in `integration_tests.zig` use the same
pixel-center formula, so they only verify self-consistency — they cannot catch
formula errors.

**Invariant to enforce:** the mapping must satisfy:
- Pixel 0 samples at `left + 0.5 * step_x` (half step inside the left edge)
- Pixel `w-1` samples at `right - 0.5 * step_x` (half step before the right edge)
- Adjacent pixels are exactly `step_x = range_x / w` apart

See `test "pixel-center mapping invariant"` in `integration_tests.zig`.

## Integration tests

`src/integration_tests.zig` contains 8 image-based tests that need raylib
(for Image allocation). They are included in `zig build test` via the import
in `main.zig`. The test helpers (`expectPixelBlack`, `countNonBlack`, etc.)
are in this file.

Key tests for regression detection:
- **default view renders** — baseline: auto, f64, perturbation paths
- **cross-algorithm classification** — all 3 methods agree on every pixel
- **golden pixel (WellKnown)** — pre-verified coordinates match renderer
- **ground truth at 128 / 2048 iters** — every pixel vs independent f64
- **pixel-center mapping invariant** — geometry of the mapping formula
- **deep zoom smoke** — perturbation + f64 fallback at Seahorse Valley
- **timeout** — custom atomic clock, verifies partial render
- **RefBank 1×1 matches single-reference** — every pixel same via bank center vs direct
- **RefBank 3×3 consistent at deep zoom** — all pixels produce finite mu at range 1e-8

## Debugging notes

### Guarding against uninitialised struct fields

Zig's `= undefined` in a struct literal field (e.g. `.history = undefined`)
leaves bytes truly uninitialised — no zeroing, no `0xAA` fill, just whatever
was in memory.  (Contrast with `var x: T = undefined` in Debug mode, which
DOES get `0xAA` fill — struct literal fields are a different code path.)

When that field contains slices or allocator-managed pointers, garbage
pointer/length values can corrupt the allocator if accidentally read.

**Bad pattern — uninitialised array of entries containing `[]u8`:**
```zig
var app = App{
    .history = undefined,    // 64 HistoryEntry structs, garbage []u8
    .history_len = 0,        // bounds check trusts history_len,
    .history_ptr = 0,        // which is itself a usize — stale bytes here defeat it
};
```

**Good pattern — `@memset` to zero after the struct literal:**
```zig
var app = App{
    .history = undefined,
    .history_len = 0,
    .history_ptr = 0,
    // ... other fields ...
};

// Every .pixels slice gets .ptr=null, .len=0.  pushHistory overwrites
// entries as they are used.  Any accidental read hits a zero-length
// slice or a w/h dimension mismatch, both caught by existing guards.
@memset(std.mem.asBytes(&app.history), 0);
```

This pattern applies whenever a struct literal contains an array or struct
field whose bytes could be read before explicit initialisation.  Simple
local buffers (`var buf: [128]u8 = undefined`) are fine — they are written
by `bufPrint` etc. before any read.  The risk is **struct/array fields
containing slices, pointers, or allocator handles** that downstream code
unwittingly dereferences.

References: [`@memset`](https://ziglang.org/documentation/0.16.0/#memset),
[`std.mem.asBytes`](https://ziglang.org/documentation/0.16.0/std/#std.mem.asBytes),
[`undefined`](https://ziglang.org/documentation/0.16.0/#undefined).

### Ground-truth tests prove self-consistency, not correctness
The ground-truth tests (`groundTruthInterior` + renderer comparison) use the
SAME pixel-to-complex formula as the renderer. If the formula is wrong, both
agree on the wrong answer. To catch formula errors, use mapping invariants
(see pixel-center section above).

### How the pixel-mapping bug was found
The user reported a "thick black line along the real axis" that other
Mandelbrot explorers didn't show. The working commit f678ecc was identified
and compared against HEAD. Bisecting narrowed it to the divisor change
(`w-1` → `w`) in 440c813. Neither divisor was correct — the fix was pixel
centers: `(px + 0.5) * range_x / w` (commit 0ef123a).

### Uninitialised struct field bug (2026-07-04)
The user reported that after the first drag-to-zoom, pressing the left arrow
key to navigate back did nothing on the first press, but worked on the second.
Environment-dependent: worked on a clean launch, failed after other macOS apps
had used the same memory.

**Root cause:** The `[64]HistoryEntry` array was `.history = undefined` in the
`App` struct literal.  While all reads were logically bounded by `history_len`,
the bounds check itself reads `history_len` — a `usize` field.  When the stack
bytes at that struct offset happened to be zero (clean launch), `history_len`
was 0 and everything worked.  When those bytes contained stale non-zero values
(from prior allocator use by other processes), `history_len` appeared to be a
non-zero value, making downstream code (`truncateFuture`, `startZoomAnimation`)
believe uninitialised entries were valid.

**Fix:** `@memset(std.mem.asBytes(&app.history), 0)` after the struct literal
so every entry has `w=0, h=0, pixels.len=0`.

**Note:** `zig build test-san` catches the downstream heap corruption
(use-after-free, double-free) that eventually results from stale history
data, but does NOT catch the root cause — reads of uninitialised struct
fields.  That would require MemorySanitizer, which Zig doesn't support.

### Startup double-poll bug (2026-07-04)

A separate issue from the history initialisation: the `rl.pollInputEvents()` +
queue-drain logic at startup (double-poll) was supposed to clear stale OS
events, but it actually CAUSED the first key press to be swallowed.  A stale
event for `.left` left `currentKeyState[left]=1`, and the second poll copied
that 1 into `previousKeyState`, so the user's real press saw no 0→1 transition.

**Fix:** removed all startup polling entirely.  The main loop's first
`PollInputEvents` processes stale and real events together.  A stale event may
cause a phantom transition on the very first frame, but window-creation events
are rarely arrow keys, so the trade-off favours never losing a real press.

### Idle-timer key-swallow bug (2026-07-04, resolved 2026-07-05)

**Symptom:** after the zoom-in animation ends, the first left-arrow press
sometimes produced no `isKeyDown` and no `isKeyPressed` — no trace at all.
A second press immediately after worked.  It was intermittent and
environment-dependent.

**Root cause:** Same as the uninitialised-history bug — the `[64]HistoryEntry`
array was not zeroed, so stale stack bytes could corrupt `history_ptr`,
`history_len`, or animation state that downstream code (`navigateHistoryBack`,
`startZoomAnimation`) read.  When the stale bytes happened to be zero
(clean launch) the bug didn't appear; after other processes used the memory
it appeared intermittently.

**Fix:** `@memset(std.mem.asBytes(&app.history), 0)` resolved both variants.
The idle-timer scenario and the drag-to-zoom scenario were different
manifestations of the same root cause.

## Numerical precision lessons

This codebase has uncovered several patterns of floating-point failure in
Mandelbrot rendering.  These notes apply to any deep-zoom renderer.

### Why we use |z|², not |z|

The Mandelbrot iterate checks `|z|² > 4` (the escape radius), so we never
need `|z| = sqrt(re² + im²)` directly.  This sidesteps two problems:

1. **Overflow in the squaring step:** computing `re² + im²` directly can
   overflow to infinity when |re| or |im| exceeds `sqrt(DBL_MAX)` (~1e154
   for f64).  A numerically stable `|z|` function would factor out the
   larger component:
   ```
   absr = |re|,  absi = |im|
   if absr > absi:  return absr * sqrt(1 + (absi/absr)²)
   else:            return absi * sqrt(1 + (absr/absi)²)
   ```
   But we don't need this because we work with |z|² throughout.  The
   escape check is `|z|² > 4`, and the smooth iteration formula uses
   `½·log(|z|²)` (no sqrt).

2. **Overflow is already handled:** in `renderPerturbationPixel`, when
   `Z_norm_sq = Zx² + Zy²` overflows to infinity, the `!isFinite` check
   triggers a rebase fallback.  For `rebaseFallback`, the |z|² > 4 check
   triggers before |z| can grow large enough to overflow.

Rule of thumb: **always prefer |z|² over |z| when the escape radius is
fixed** — you avoid the sqrt, the overflow-sensitive division in the
stable-abs formula, and the rsqrt instruction's precision loss.

### The per-component fold_eps trap in `computeDragDelta`

`computeDragDelta` decides whether a drag delta is large enough to be
added to `center_x`/`center_y` directly, or whether it must be stored
in `offset_x`/`offset_y` to avoid precision loss.  The threshold is
`fold_eps = |component| · eps(f64)` — if the delta is smaller than this,
adding it to the component rounds away.

**Wrong approach:** compute one `fold_eps` from `max(|cx|,|cy|)` and use
it for both axes:

```zig
// BAD — propagates the x-magnitude to the y-threshold
const center_mag = @max(@abs(view.center_x), @abs(view.center_y));
const fold_eps = center_mag * std.math.floatEps(f64);
```

This causes phantom y-shift when zooming on the real axis: |cx| ≈ 1.485
gives `fold_eps ≈ 3.3e-16` for **both** axes.  But at `center_y = 0`,
there is **zero precision loss** in adding any small delta to zero
(`0 + small = small` — f64 near 0 has subnormals).  Small y-deltas
accumulate in `offset_y` instead of folding into `center_y`.  Over many
zooms, `offset_y` grows to ~fold_eps while `center_y` stays at 0,
pushing the viewport off the real axis into exterior territory →
colored horizontal bands where the image should be solid black.

**Fix:** compute fold thresholds per component:

```zig
const fold_eps_x = @abs(view.center_x) * std.math.floatEps(f64);
const fold_eps_y = @abs(view.center_y) * std.math.floatEps(f64);
```

When `center_y = 0`, `fold_eps_y = 0` and every delta folds immediately.
This is correct — zero has no precision loss with any addend.

**General principle:**
- Each floating-point addition's precision is determined by the **larger
  operand's magnitude**, not the other operand's.
- When folding a delta into a center coordinate, the fold threshold must
  be derived from that **component's own magnitude**, not from a
  cross-component aggregate.
- Near zero, f64 has denormal representation (~5e-324 min positive),
  so the fold threshold is essentially zero.  Aggregating from a
  different (large) component loses this property.

### A coordinate is only as precise as its display format

The textbox format is `x={d:.8} y={d:.8} range={e:.8} iters={d}`.  At
deep zoom (range ~5e-17), `center_y = 2e-16` displays as `y=0.00000000`
because 8 decimal places round 2e-16 to zero.  When the user pastes
these coordinates back, `parseViewState` creates a ViewState with
`center_y = 0`, silently dropping the sub-ULP y-shift that was living
in `offset_y` (which is not displayed or parsed at all).

**Lesson:** if a coordinate component can carry meaningful sub-ULP
precision through the offset mechanism, the display format must
accommodate it.  Either display offsets explicitly, or display the
sum `center + offset` with enough precision.  The current format
`{d:.8}` only needs 8 decimal places at normal zoom (range ~3), but
at range ~5e-17 the meaningful y-values are ~1e-17, requiring roughly
`{d:.17}` to avoid round-trip loss.

### The roughly-1e-28 floor

**Every** finite-decimal constant like `0.1`, `0.01`, `1e-17` is a
**repeating fraction in binary** — IEEE 754 binary floating point can
only store it approximately.  This means:

- `1e-17` as an `f64` literal is not exactly `10⁻¹⁷` — it's the closest
  representable binary value, off by ~`1.1e-33` (half a ULP at that scale).
- Adding it 100 times and multiplying by 100 compound that error
  **differently**:
  ```zig
  // one rounding step
  100.0 * delta_y  // ~1e-30 error

  // 100 rounding steps, each at increasing scale
  delta_y + delta_y + ...  // slightly different error
  ```

**Rule of thumb:** tests that compare results from different operation
sequences on the same decimal constant need a tolerance — the two paths
round differently.  To get exact equality, use powers-of-two constants
(e.g. `0x1.0p-57` instead of `1e-17`), which are exact in binary.

**When it matters:** in production rendering, this scale of error
(~1e-30) is invisible — it's far below the precision needed to classify
a pixel as interior/exterior.  It only surfaces in assertions that
compare two fp expressions for the "same" value derived via different
arithmetic.

## Zoom depth limits

The question "how deep can we go?" comes up whenever a user sees artifacts
at extreme zoom.  The answer depends on which part of the set you're in.

### The fundamental bottleneck

f64 has a ULP (unit in the last place) of about `2e-16 × |value|`.
Adding a small offset to a large coordinate rounds away if the offset is
smaller than ~1 ULP.  The offset mechanism (`offset_x`/`offset_y`) works
around this for accumulated deltas, but the per-pixel computation
`(px+0.5) * range/w` must resolve each pixel's position through the
`left`/`top` formulas.

**f128 fallback (2026-07-08):** The fallback path (`rebaseFallback`) now
uses f128 arithmetic internally.  f128 has a 112-bit mantissa (ULP ≈
2.4e-34 at |coord| ≈ 1), which resolves per-pixel coordinate differences
down to `range/w ≈ 1e-32`.  This extends the fallback precision limit
from `range ≈ 4e-13` (f64 ULP wall) to `range ≈ 1e-28` (the perturbation
path's own limit).  The f128 `pixel_cx/pixel_cy` values are computed in
the renderer from view-state fields using f128 arithmetic, so the entire
`left + (px+0.5)*step` computation is quad-precision.

**Practical floors:**

| Component | Limit | Why |
|-----------|-------|-----|
| **x-pixels on antenna (f64 fallback)** | `range ≈ 1e-28` | f128 fallback resolves down to ~2.4e-34; perturbation path's dcx subnormals are the new floor |
| **x-pixels on antenna (perturbation)** | `range ≈ 1e-28` | dcx/dy approach f64 subnormal range at this scale |
| **y-pixels on real axis** | essentially unlimited | center_y=0 means zero precision loss (subnormals) |
| **y-pixels off real axis** | same as x-axis | f128 fallback covers all practical zoom levels |

### What happens at each regime

| Range | Can distinguish x-pixels? | Notes |
|-------|--------------------------|-------|
| `> 4e-13` | Yes | All render paths — f64 is sufficient |
| `4e-13` to `1e-28` | Yes (f128 fallback) | `rebaseFallbackF128` preserves per-pixel C when perturbation fails; perturbation path works directly |
| `< 1e-28` | No | `range/w` step rounds to zero even in f128; dcx/dcy enter subnormal range |

### f128 implementation details

The f128 pixel coordinate is computed in `renderStrip`:
```zig
const pixel_step_f128 = cfg.range_x_f128 / @as(f128, @floatFromInt(w));
const cx_f128 = cfg.left_f128 + (@as(f128, @floatFromInt(px)) + 0.5) * pixel_step_f128;
```

`cfg.left_f128` is computed from the view state in f128, preserving the
small `range/2` term that rounds away in f64.  The function
`rebaseFallbackF128(zx: f128, zy: f128, cx: f128, cy: f128, ...)` performs
the full Mandelbrot recurrence in f128 — all 6 fallback sites in
`renderPerturbationPixel` now call it.

On Apple Silicon, f128 is software-emulated (~20-50× per op), but the
fallback is rare: it only fires when perturbation can't continue
(glitch, overflow, |δ| > |Z|).  At extreme zoom where the viewport is
mostly deep-interior, the boundary layer needing fallback is a tiny
fraction of pixels.

### The real-axis trap: when perturbation also fails

Even at extreme zoom on the real axis (y ≈ 0, x in [-2, 0.25]), the
f128 fallback now distinguishes per-pixel x-coordinates.  The reference
orbit may overflow, but `rebaseFallbackF128` starts each pixel from its
own `C = cx_f128 + i*cy_f128` and iterates in quad precision, so adjacent
pixels with `|cx₁ - cx₂| ≈ 1e-32` produce different iteration counts.
The horizontal banding artifact is resolved.

The all-interior case (pure black) still applies identically — f128 just
gives correct uniform black.

**Performance note:** The f128 fallback is correct but slower.  At the
deepest zoom levels where the entire viewport is interior, no fallback
is needed at all (cardioid/bulb pre-check or perturbation handles it).
Only the boundary fringe where |z|² > 4 triggers f128 — typically a
few hundred pixels max, adding ~50–200ms to the render.

### Split-coordinate fallback design (superseded)

The split-coordinate design previously described here (Kahan summation
in f64) is **superseded** by the f128 fallback.  Using quad precision
directly is simpler, more robust, and handles all cases uniformly.  The
only remaining gap is the fundamental f128 floor at range < 1e-28,
where even `f128(px+0.5)*range/w` rounds to zero — no practical
Mandelbrot viewer can meaningfully display at that scale.

### When to suspect a precision limit

1. **Image is uniformly colored bands** (no interior black) at extreme zoom
   — check that offsets aren't pushing the viewport into exterior territory.
   Paste the coordinates (resets offsets) to confirm.
2. **Two adjacent double-clicks on the same point don't produce the same
   image** — offsets accumulated between clicks may have shifted the viewport.
3. **`[drag] zoom` log entries show center_y drifting away from 0** on the
   real axis — indicates the old fold_eps bug.  Fix already applied in
   commit with per-component fold thresholds.
4. **Horizontal stripes at range < 4e-13 on the real axis** — expected
   f64 precision limit, not a bug (see split-coordinate fallback design
   above if fixing this is desired).

## RefBank architecture

`src/refbank.zig` implements a grid-based reference orbit bank that
replaces the previous single-reference perturbation renderer.

### Why RefBank

Single-reference perturbation fails when the pixel's δ (distance from the
reference orbit) is large, triggering glitch detection.  This happens
when the viewport contains features far from the reference point —
especially at moderate zoom where the reference is chosen from the
viewport center but edge pixels have large δ.

The RefBank distributes reference orbits in a grid across the viewport
so each pixel uses the nearest escaping reference, minimizing δ and
reducing glitch triggers.

### Grid layout

- **`.auto` and `.perturbation` modes:** 1×1 grid (single center reference).
  Previously used a 3×3 grid (10 references) in `.auto` mode at deep zoom
  (`pixel_step < 1e-12`), but this was removed in 2026-07-08 because the
  Voronoi cell boundaries between different escaping references produced
  visible horizontal stripe artifacts at extreme depth (range ~1.77e-16).
  Single-reference perturbation avoids the seam problem entirely.
- **`.f64` mode:** No RefBank — uses direct f64 `rebaseFallback`.

### Integration in render pipeline

1. `renderMandelbrot` in `renderer.zig` calls `refbank.buildRefBank()`
   before spawning threads.
2. `RenderConfig.ref_bank` carries the `?m.RefBank` into each thread.
3. `renderStrip` does per-pixel `bank.nearest(cx_f64, cy_f64)` lookup
   to find the closest escaping reference, then calls
   `renderPerturbationPixel(cx - ref.cx, cy - ref.cy, ref.orbit, ...)`.
4. If no escaping reference exists (all interior), the RefBank is
   deallocated and the render falls through to `rebaseFallback` or
   `standardPixel`.

### Memory

Each reference orbit allocates `max_iters` entries of `RefOrbit` (16 bytes
each).  A 1×1 bank at 8192 iterations allocates 8192 × 16 = ~128 KB.
The bank is freed after rendering via `ref_bank.deinit()`.

### Logging

```
2026-07-05T21:53:03.960Z [refbank] grid=1x1 total=1 escaped=1 range=2.9000e0
```

## Release process

### Prerequisites

- `gh` CLI installed and authenticated (`gh auth status`)
- Clean working tree (`git status --porcelain` should be empty)
- All tests pass: `zig build test && zig build unit`

### Cutting a release

1. **Bump version** in `build.zig.zon` (the `.version` field).
2. **Build the release binary:**
   ```bash
   zig build release
   ```
   This always builds with `ReleaseSafe`, regardless of the default
   optimization mode. The binary lands at `zig-out/bin/mandelbrot`.
3. **Create the archive:**
   ```bash
   ARCH=$(uname -m)
   # arm64 → arm64, x86_64 → x86_64
   tar -czf mandelbrot-macos-${ARCH}.tar.gz -C zig-out/bin mandelbrot
   ```
4. **Create the GitHub release and upload the archive:**
   ```bash
   ARCH=$(uname -m)
   VERSION=$(grep -o '"[0-9.]*"' build.zig.zon | head -1 | tr -d '"')
   gh release create "v${VERSION}" mandelbrot-macos-${ARCH}.tar.gz \
     --title "v${VERSION}" \
     --notes "See [README.md](https://github.com/jones77/mandelbrot/blob/main/README.md) for usage instructions."
   ```
5. **Verify:** visit `https://github.com/jones77/mandelbrot/releases`
6. **Clean up:** `rm mandelbrot-macos-*.tar.gz`

### Post-release

- Bump the version in `build.zig.zon` to the next dev version
  (e.g. `0.0.2-dev`) and commit.

## Agent debugging

Events logged to stderr with ISO 8601 UTC timestamps:

```
2026-07-02T12:34:56.789Z [app]    init 900x740 dpi=1 method=auto
2026-07-02T12:34:57.801Z [drag]   zoom from 3.50000000 to 0.38900000 iters=4096
2026-07-02T12:34:59.124Z [anim]   start in dur=0.500 from=3.50000000 to=0.38900000
2026-07-02T12:36:21.721Z [anim]   end
2026-07-02T12:36:23.456Z [history] back entry=0 range=3.50000000 anim=idle
2026-07-02T12:36:23.789Z [anim]   start out dur=0.500 from=0.38900000 to=3.50000000
2026-07-02T12:37:22.345Z [anim]   end
```

Capture to a file and analyse:

```
zig build run 2> debug.log
grep '\[anim\]' debug.log           # all animation events
grep '\[drag\]' debug.log           # all drag-zoom events
grep -E '\[(anim|drag|history)\]' debug.log   # user interactions
grep 'ignored' debug.log            # missed navigation attempts
grep 'keytrace' debug.log           # raw key state (pressed/down every frame a key is active)
```

### Event scopes

| Scope | Meaning | Example data |
|-------|---------|-------------|
| `app` | lifecycle, resize | dimensions, dpi |
| `anim` | animation start/end | direction, dur, from/to range |
| `drag` | drag-to-zoom | from/to range, iters |
| `history` | arrow navigation | entry index, target range, anim state; `ignored` when at boundary; `skipped` when `tb_active` blocks input |
| `iters` | iteration adjustment | inc/dec, old → new |
| `view` | reset to default | — |
| `ui` | textbox, clipboard | range, operation |
| `keytrace` | raw key state | left/right isKeyPressed, isKeyDown, history ptr/len, anim state |
| `render` | timeout, continue | — |
| `alloc` | allocator initialization | DebugAllocator or page_allocator |
| `refbank` | reference bank build | grid dimensions, total/escaped counts, range |

### Interpreting logs

- `<10ms` gap between `[history]` and `[anim] start` → cached pixels restored (fast path)
- `>200ms` gap → `renderFresh` was called (dimension mismatch)
- Large gap between `[anim] start` and `[anim] end` → user was idle
- `[anim] end` missing → animation was cancelled (resize, new input)
- `[history] left/right skipped` → the textbox was active (`tb_active=true`), so the
  arrow key was consumed by cursor movement instead of history navigation.
  Indicates the user clicked into the textbox without dismissing it.
- `[history] keytrace` → raw per-frame key state (left/right `isKeyPressed`, `isKeyDown`,
  history ptr/len).  Only logged on frames where at least one is `true`.
- Timestamps are UTC, monotonic within a session
- No output = idle frames (nothing user-initiated occurred during those gaps)
- `[refbank] grid=1x1 total=1 escaped=6 range=2.9e0` → 1×1 bank built with
  1 reference orbit, 6 escaped, covering the given viewport range

## Session history

| Date | Issue | Root cause | Fix |
|------|-------|-----------|-----|
| 2026-07-05 | Circle artifacts at deep zoom | Glitch-detection fallback started all glitching pixels from Z=C at iter 0 → same orbit → circular bands | Changed to continue from per-pixel Z (`rebase_zx`) and current iteration (`iter`) |
| 2026-07-05 | Horizontal banding at range < 4e-13 on real axis | Reference orbit overflows to infinity → scratch-start fallback loses per-pixel x-variation (f64 ULP limit) | Not yet fixed (see split-coordinate fallback design); RefBank partially mitigates |
| 2026-07-05 | RefBank implementation | Single-reference perturbation fails at moderate zoom due to large δ at edge pixels | 3×3 grid of reference orbits; per-pixel nearest escaping reference lookup |
| 2026-07-08 | Voronoi stripe artifacts at deep zoom | 3×3 RefBank grid creates visible seams at Voronoi cell boundaries between different escaping references (range ~1.77e-16) | Removed adaptive 3×3 grid; always use 1×1 single-reference in `.auto` and `.perturbation` modes |
| 2026-07-08 | f128 fallback for rebaseFallback | f64 fallback loses per-pixel C variation at range < 4e-13 (|C+step| rounds to |C|) — causes horizontal banding on real axis, colorful patches off-axis | `rebaseFallbackF128(zx, zy, cx, cy, ...)` — f128 arithmetic preserves 112-bit mantissa, resolves down to ~range/w ≈ 1e-32; f128 pixel coords computed in renderStrip from f128 view-state fields; all 6 fallback sites in renderPerturbationPixel call it |
| 2026-07-04 | Startup double-poll bug | Stale OS event caused phantom key state → first press swallowed | Removed all startup polling |
| 2026-07-04 | Idle-timer key-swallow bug | Uninitialised `[64]HistoryEntry` — stale stack bytes corrupted `history_ptr` | `@memset` zero after struct literal |
| 2026-07-04 | Drag-to-zoom key-swallow bug | Same uninitialised history as idle-timer variant | Same fix |
| 2026-07-07 | Left-arrow first press lost after zoom | Raylib `isKeyPressed()` missed quick taps where GLFW_PRESS + GLFW_RELEASE both fire within a single `PollInputEvents` interval (in raylib 5.6.0-dev, polling happens at the end of `EndDrawing`, after `WaitForTargetFPS` creates a ~14ms window where events accumulate). `currentKeyState` net = 0, `previousKeyState` = 0 → `IsKeyPressed` returns false. | Use `getKeyPressed()` (reads from raylib's key-pressed queue, populated by the PRESS callback) as a fallback when `isKeyPressed` misses the arrow. `getKeyPressed()` catches the event because the PRESS callback queues it regardless of a subsequent RELEASE in the same poll. |

**Note on left-arrow bugs:** left-arrow navigation failures are almost always related to the input polling mechanism, not to renders, animations, or history state. The two previous instances (2026-07-04) were caused by uninitialised memory corrupting `history_ptr` — those manifested as `history back ignored` or `skipped tb_active` in the log. The 2026-07-07 instance manifests as **no keytrace log at all** (`isKeyPressed` and `isKeyDown` both false). If a left-arrow bug is reported and the keytrace shows a press event, look at history/state/logic. If no keytrace appears, it's a polling timing issue and the fix is to use `getKeyPressed()` as a fallback.

Details in `docs/session-summary-2026-07-05.md`.
