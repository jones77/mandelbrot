# AGENTS.md — Mandelbrot Set Visualizer

## Project context

Interactive Mandelbrot viewer in Zig 0.16 + raylib (via raylib-zig v5.6-dev).
Six source files: `main.zig` (entry), `app.zig` (UI/history/clipboard),
`renderer.zig` (multi-threaded rendering), `mandelbrot.zig` (pure math + tests),
`pixel.zig` (pixel format constants), `log.zig` (timestamping & structured logging).

## Zig conventions

Follow `lib/std/*.zig` conventions. Key exemplars to read for patterns:
- `std/fmt.zig` — overall file structure (imports → constants → types → functions → test block)
- `std/array_list.zig` — type with methods, generics
- `std/testing.zig` — test helpers

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
zig build unit     # 58 pure-math tests (mandelbrot.zig), no raylib
```

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

## Debugging notes

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
```

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
```

### Event scopes

| Scope | Meaning | Example data |
|-------|---------|-------------|
| `app` | lifecycle, resize | dimensions, dpi |
| `anim` | animation start/end | direction, dur, from/to range |
| `drag` | drag-to-zoom | from/to range, iters |
| `history` | arrow navigation | entry index, target range, anim state; or `ignored` when at boundary |
| `iters` | iteration adjustment | inc/dec, old → new |
| `view` | reset to default | — |
| `ui` | textbox, clipboard | range, operation |
| `render` | timeout, continue | — |

### Interpreting logs

- `<10ms` gap between `[history]` and `[anim] start` → cached pixels restored (fast path)
- `>200ms` gap → `renderFresh` was called (dimension mismatch)
- Large gap between `[anim] start` and `[anim] end` → user was idle
- `[anim] end` missing → animation was cancelled (resize, new input)
- Timestamps are UTC, monotonic within a session
- No output = idle frames (nothing user-initiated occurred during those gaps)
