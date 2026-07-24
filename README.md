# Mandelbrot Set Visualizer

An interactive Mandelbrot set explorer written in [Zig](https://ziglang.org/).

## Features

- **Interactive viewer** — click-and-drag box zoom, scroll wheel, arrow-key undo/redo navigation
- **Three render methods** — auto (adaptive), perturbation (glitch-corrected), and direct f64
- **Deep zoom** — 128-bit float fallback resolves per-pixel coordinates down to range ≈1e-28
- **Reference orbit bank** — 1×1 grid minimizes glitch artifacts; single-reference avoids Voronoi seams
- **Cardioid/bulb pre-check** — O(1) interior detection, skips iteration for inside points
- **Smooth zoom animations** — animated transitions between history states
- **Coordinate display & clipboard** — view/edit coordinates in a textbox, copy/paste view state
- **Interactive toolbar** — left/right history arrows, iterations inc/dec controls, copy/paste/reset buttons, toggleable coordinate tooltip
- **Iteration control** — ± keys or toolbar buttons adjust detail; auto-scales on zoom
- **Undo/redo** — ← to undo, → to redo (up to 64 levels, instant from pixel cache)
- **Render timeout** — configurable limit with Space-to-continue, returns partial results
- **Cross-platform** — runs on macOS, Linux, and Windows via raylib; no platform-specific code

## Download

Pre-built binaries for macOS are available on the
[Releases](https://github.com/jones77/mandelbrot/releases) page.

1. Download `mandelbrot-macos-arm64.tar.gz` (Apple Silicon)
   or `mandelbrot-macos-x86_64.tar.gz` (Intel).
2. Extract and run:
   ```bash
   tar -xzf mandelbrot-macos-arm64.tar.gz
   ./mandelbrot
   ```
3. macOS may show a security warning on first run.
   Right-click the binary in Finder and select **Open**,
   or clear the quarantine flag:
   ```bash
   xattr -d com.apple.quarantine mandelbrot
   ```

---

## Quick start

### 1. Install Zig

| Platform | Zig 0.16 (stable) | Zig 0.17 (dev) |
|----------|-------------------|----------------|
| **macOS ARM** | [zig-aarch64-macos-0.16.0.tar.xz](https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz) | [zig-aarch64-macos-0.17.0-dev.1099+7db2ef610.tar.xz](https://ziglang.org/builds/zig-aarch64-macos-0.17.0-dev.1099+7db2ef610.tar.xz) |
| **macOS x86_64** | [zig-x86_64-macos-0.16.0.tar.xz](https://ziglang.org/download/0.16.0/zig-x86_64-macos-0.16.0.tar.xz) | [zig-x86_64-macos-0.17.0-dev.1099+7db2ef610.tar.xz](https://ziglang.org/builds/zig-x86_64-macos-0.17.0-dev.1099+7db2ef610.tar.xz) |
| **Linux x86_64** | [zig-x86_64-linux-0.16.0.tar.xz](https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz) | — |
| **Windows x86_64** | [zig-x86_64-windows-0.16.0.zip](https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip) | — |

Extract and add `zig` to your `PATH`.

### 2. Fetch the raylib dependency

```bash
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#v5.6-dev
```

This downloads raylib-zig (Zig bindings for raylib 6.0) and records the hash in
`build.zig.zon`.  Only needed once.

### 3. Build and run

```bash
zig build run
```

> **Linux users** may need additional libraries (X11, OpenGL, ALSA).
> See the [raylib wiki](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux).

---

## Controls

| Action               | Input                              |
|----------------------|------------------------------------|
| Zoom in              | Left-drag a square, then release   |
| Undo zoom            | ← or Delete or Backspace           |
| Redo zoom            | →                                  |
| Reset view           | R                                  |
| Double detail        | + key or on-screen [+] button      |
| Halve detail         | - key or on-screen [-] button      |
| Continue render      | Space (when timeout fires)         |
| Close window         | Esc or window close button         |

The selection box is always **1:1 (square)** — the longer side of the drag
determines the size, so aspect ratio stays correct.

---

## How it works

The **Mandelbrot set** is the set of complex numbers *c* where the iteration
*zₙ₊₁ = zₙ² + c* (starting from *z₀ = 0*) remains bounded.

- Points where |zₙ| > 2 after *n* iterations are **outside** the set.
- Points that never escape (up to the iteration limit) are **inside** (black).
- The colour of exterior points reflects *how fast* they escape.

### Further reading

- [Mandelbrot set – Wikipedia](https://en.wikipedia.org/wiki/Mandelbrot_set)
- [The Mandelbrot Set – Numberphile](https://www.youtube.com/watch?v=NGMRB4O922I)
- [Plotting algorithms – smooth coloring](https://en.wikipedia.org/wiki/Plotting_algorithms_for_the_Mandelbrot_set#Continuous_(smooth)_coloring)
- [Cardioid and bulb checking – Claude Heiland-Allen (mathr.co.uk)](https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html)

---

## Code walkthrough

The source is split into four files, keeping pure math separable from raylib.

### Structure

```
src/main.zig          — entry point (~30 lines)
src/app.zig           — App struct, UI, undo/redo history, clipboard
src/renderer.zig      — renderMandelbrot, renderStrip (threading, no raylib)
src/mandelbrot.zig    — pure math: palette, ViewState, computeReference,
                        perturbPixel, standardPixel, coordinate helpers
```

**mandelbrot.zig** contains all the Mandelbrot-specific computation:

- `Coord` / `ComplexPoint` / `OrbitPoint` / `RefOrbit` — helper types
- `computeReference()` — f64 reference orbit for perturbation
- `perturbPixel()` / `standardPixel()` — per-pixel iteration (f32)
- `continueStandard()` — f64 fallback for glitched perturbation pixels
- `smoothColor()` / `hslToRgb()` / `buildPalette()` — colour pipeline
- `screenToComplex()` / `constrainDragSquare()` — coordinate math
- `clearToOpaqueBlack()` / `nextPowerOf2()` — utilities

### Frame lifecycle

Each frame calls three App methods:

```
1. handleResize() — detect window resize, reallocate buffer, re-render
2. handleInput()  — buttons, drag, zoom, undo/redo, ± keys, reset, continue
3. drawFrame()    — clear, draw texture, selection rect, HUD, buttons
```

### Rendering pipeline

```
Mouse drag → constrainDragSquare() → screenToComplex() → new ViewState
  → renderMandelbrot() spawns 8 threads
    → each renderStrip() iterates z = z² + c for its row range
      → escape? colour from smoothColor()
      → derivative → 0? interior point, leave black
      → orbit periodic? interior point, leave black
      → timeout? return partial image
  → updateTexture() uploads RGBA buffer to GPU
```

### Interior detection (three layers, fastest first)

1. **Cardioid/bulb** — O(1) check on `c` itself, no iteration needed.
   Bounding-box test skips this when zoomed far from those shapes.
2. **Derivative** — `(P^n)'(c)` shrinks toward 0 for interior points.
   Threshold scales with `max_iters` (tighter at shallow zooms).
3. **Orbit periodicity** — `z` stored at power-of-2 iterations; if `z`
   returns to a previous value the orbit is periodic.

### References used

**Algorithm descriptions (human-readable documents)**

- [Techniques for computer generated pictures – Arnaud Chéritat](https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set)
  (CC-BY) — Sections 3.4 (interior detection), 3.5 (boundary/distance estimators),
  3.6 (visualisation modes)
- [Cardioid and bulb checking – Claude Heiland-Allen](https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html)
  — bounding-box optimisation for the per-pixel cardioid/bulb tests
- [Perturbation theory for the Mandelbrot set – K. I. Martin](http://superfractalthing.co.nf/sft_maths.pdf)
  — the δ recurrence and series approximation
- [Perturbation glitches – Claude Heiland-Allen](https://mathr.co.uk/blog/2014-03-31_perturbation_glitches.html)
  — glitch taxonomy and preperiodic reference point selection
- [Pauldelbrot's glitch criterion](https://fractalforums.org/fractal-mathematics-and-new-theories/28/glitch-detection/4269)
  — the `|Z+δ|² < G·|Z|²` test used in the perturbation path
- [Zhuoran's rebasing technique](https://fractalforums.org/fractal-mathematics-and-new-theories/28/zhuorans-new-perturbation-algorithm-glitch-free-and-much-faster/4443)
  — re-centering δ against the reference orbit when glitch is detected
- [DeepDrill – Dirk W. Hoffmann](https://dirkwhoffmann.github.io/DeepDrill/)
  (GPL v3) — practical reference for perturbation theory with series approximation
- [mightymandel – Claude Heiland-Allen](https://mightymandel.mathr.co.uk/)
  (GPL v3+) — GPU-based Mandelbrot explorer using perturbation

All implementation is original Zig code based on the algorithm descriptions above.
No code was copied from GPL-licensed projects. The mathematical formulas
(δ recurrence, cardioid test, glitch criterion) are not copyrightable.

If you have raylib installed system-wide:

```bash
# macOS
brew install raylib

# Ubuntu / Debian
sudo apt install libraylib-dev

# Fedora
sudo dnf install raylib-devel

# Windows (vcpkg)
vcpkg install raylib

# Windows - WSL
# Don't bother, see AGENTS.md for details.
```

Then replace the `raylib_zig` dependency block in `build.zig` with:

```zig
const raylib = b.dependency("raylib", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("raylib", raylib);
exe.linkSystemLibrary("raylib");
exe.linkLibC();
```

You can then remove the `dependencies` section from `build.zig.zon`.

---

## Zig learning resources

- [ziglang.org/learn](https://ziglang.org/learn/) — official guide
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [zig.guide](https://zig.guide/) — community intro
- [ziglings](https://codeberg.org/ziglings/exercises) — interactive exercises
- [Zig Showtime](https://zig.show/) — community projects
- [Zig community](https://ziglang.org/community/) — Discord / IRC / forums

---

## Creating a release

> This section is for maintainers.
> See [`AGENTS.md`](AGENTS.md#release-process) for the agent-executable workflow.

1. Update the version in `build.zig.zon`.
2. Build the release binary:
   ```bash
   zig build release
   ```
3. Archive it:
   ```bash
   tar -czf mandelbrot-macos-$(uname -m).tar.gz -C zig-out/bin mandelbrot
   ```
4. Create the GitHub release:
   ```bash
   gh release create v<VERSION> mandelbrot-macos-$(uname -m).tar.gz \
     --title "v<VERSION>"
   ```
5. Bump the version in `build.zig.zon` to the next dev version and commit.

## License

[The Unlicense](UNLICENSE) — public domain.
