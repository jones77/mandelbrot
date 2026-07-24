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

## Bug history

See `docs/session-summary-2026-07-05.md` and `git log` for debugging history: circle artifacts, banding at range < 4e-13, RefBank implementation, Voronoi stripes, f128 fallback, startup double-poll, idle-timer key-swallow, left-arrow timing.

## graphify

## Known issues

### WSL: raylib crash at startup — `int dist` overflow in `GetCurrentMonitor`

On WSL2, running the binary crashes with a signed integer overflow in raylib's
`rcore_desktop_glfw.c:887`:

```c
int dist = (dx*dx) + (dy*dy);  // overflow when monitor coords are large
```

The GLFW X11 backend on WSL can report monitor positions with large absolute
coordinates (e.g. from a virtual desktop spanning multiple monitors). When
`dx` or `dy` exceed ~46340, `dx*dx` overflows a 32-bit signed `int`.

**Where:** `zig-pkg/raylib-5.6.0-dev-.../src/platforms/rcore_desktop_glfw.c`,
line 887 in `GetCurrentMonitor()`.

**Workaround:** None in project code — this is a raylib bug.  The binary is
still buildable (`zig build` exits 0); it just can't run under WSL without
an X server that provides sensible monitor bounds.  On real Linux with a
physical display the coordinates are small enough that overflow never occurs.

**Fix upstream:** Change `int dist` to `long long dist` (or use `ll` suffix
on the computation).  Not applied here because it's a vendored dependency
and the user may re-fetch.

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
