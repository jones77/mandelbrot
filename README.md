# Mandelbrot Set Visualizer

An interactive Mandelbrot set explorer written in [Zig](https://ziglang.org/).

## Features

- **Pan & zoom** — click and drag a **1:1 (square) selection box** to zoom into any
  region. The selection is automatically constrained to a square so the aspect
  ratio stays correct.
- **Undo** — press **Delete** or **Backspace** to return to the previous zoom
  level (up to 64 levels of history).
- **Iteration control** — use the **mouse wheel** to increase or decrease the
  escape-time iteration limit (more iterations = more detail near the set
  boundary).
- **Reset** — press **R** to jump back to the default overview.
- **HUD** — the bottom bar shows the current complex-plane coordinates, visible
  range, and iteration count.
- **Cross-platform** — runs on macOS, Linux, and Windows 11.

---

## Quick start

### 1. Install Zig

| Platform | Zig 0.16 (stable) | Zig 0.17 (dev) |
|----------|-------------------|----------------|
| **macOS ARM** | [zig-aarch64-macos-0.16.0.tar.xz](https://ziglang.org/download/0.16.0/zig-aarch64-macos-0.16.0.tar.xz) | [zig-aarch64-macos-0.17.0-dev.1099+7db2ef610.tar.xz](https://ziglang.org/builds/zig-aarch64-macos-0.17.0-dev.1099+7db2ef610.tar.xz) |
| **macOS x86** | See [ziglang.org/download](https://ziglang.org/download/) | See [ziglang.org/builds](https://ziglang.org/builds/) |
| **Linux** | See [ziglang.org/download](https://ziglang.org/download/) | — |
| **Windows** | See [ziglang.org/download](https://ziglang.org/download/) | — |

Extract the archive and add the `zig` binary to your `PATH`.

### 2. Fetch the raylib dependency

This project uses [raylib-zig](https://github.com/Not-Nik/raylib-zig) for
windowing and graphics.  Run the following command **once** to download it
and record the package hash:

```bash
cd mandelbrot
zig fetch --save https://github.com/Not-Nik/raylib-zig/archive/refs/tags/5.5-devel.tar.gz
```

This adds raylib-zig to `build.zig.zon` with the correct hash.  You only
need to do this once.

### 3. Build and run

```bash
zig build run
```

That's it!  A window will open showing the Mandelbrot set.

> **Note:** On Linux you may need to install a few system libraries that raylib
> depends on (X11, OpenGL, etc.).  See the [raylib wiki](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux)
> for details.

---

## Controls

| Action | Input |
|--------|-------|
| **Zoom in** | Left-click and drag to draw a square selection, then release |
| **Zoom out (undo)** | `Delete` or `Backspace` |
| **Reset view** | `R` |
| **More iterations** | Scroll wheel ↑ |
| **Fewer iterations** | Scroll wheel ↓ |
| **Close window** | `Esc` or window close button |

The selection box is always **1:1 (square)** — the longer side of your drag
determines the square's size.  This keeps the aspect ratio correct for the
complex plane.

---

## How it works (the maths)

The **Mandelbrot set** is the set of complex numbers *c* for which the
recurrence

```
z₀ = 0
zₙ₊₁ = zₙ² + c
```

remains **bounded** (does not escape to infinity).

- If after some number of iterations |zₙ| > 2, the point is **outside** the set.
- If the iteration limit is reached without escaping, the point is **inside**
  the set (coloured black).
- The colour of exterior points is determined by **how quickly** they escaped
  (the iteration count), giving the familiar psychedelic bands.

### Further reading

- [Mandelbrot set – Wikipedia](https://en.wikipedia.org/wiki/Mandelbrot_set)
- [The Mandelbrot Set – Numberphile (YouTube)](https://www.youtube.com/watch?v=NGMRB4O922I)
- [Mandelbrot Set Explained (interactive)](https://www.maths.tcd.ie/~dwilkins/mandelbrot/index.html)
- [Smooth iteration count coloring](https://en.wikipedia.org/wiki/Plotting_algorithms_for_the_Mandelbrot_set#Continuous_(smooth)_coloring)

---

## Project structure

```
mandelbrot/
├── README.md          <- you are here
├── build.zig          <- Zig build script
├── build.zig.zon      <- package manifest (dependencies)
└── src/
    └── main.zig       <- application source code
```

---

## Alternative: using system raylib

If you already have raylib installed via your package manager:

```bash
# macOS
brew install raylib

# Ubuntu / Debian
sudo apt install libraylib-dev

# Fedora
sudo dnf install raylib-devel
```

Then edit `build.zig` — comment out **Option A** and uncomment **Option B**:

```zig
// ---- Option B: Link against a system-installed raylib ----
exe.linkSystemLibrary("raylib");
exe.linkLibC();
```

You can then remove (or comment out) the `dependencies` section in
`build.zig.zon` and build with:

```bash
zig build run
```

---

## Zig learning resources

- **[ziglang.org/learn](https://ziglang.org/learn/)** — official getting-started guide
- **[Zig Language Reference](https://ziglang.org/documentation/master/)** — the canonical language reference
- **[zig.guide](https://zig.guide/)** — community-written intro
- **[ziglings](https://codeberg.org/ziglings/exercises)** — interactive exercises to learn Zig
- **[Zig SHOWTIME](https://zig.show/)** — community projects and inspiration
- **[Zig Discord / IRC](https://ziglang.org/community/)** — friendly community

---

## License

MIT — do whatever you want with this code.
