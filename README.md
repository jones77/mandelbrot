# Mandelbrot Set Visualizer

An interactive Mandelbrot set explorer written in [Zig](https://ziglang.org/).

## Features

- **1:1 box zoom** — click and drag a square selection to zoom in
- **Undo** — press Delete/Backspace to return to the previous zoom (up to 64 levels)
- **Iteration control** — mouse wheel adjusts escape-time detail (32–4096)
- **Reset** — press R to return to the default overview
- **HUD** — shows current complex-plane coordinates, visible range, and iteration limit
- **Cross-platform** — runs on macOS, Linux, and Windows 11 via raylib

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

| Action               | Input                           |
|----------------------|---------------------------------|
| Zoom in              | Left-drag a square, then release |
| Undo zoom            | Delete or Backspace             |
| Reset view           | R                               |
| More detail          | Mouse wheel up                  |
| Less detail          | Mouse wheel down                |
| Close window         | Esc or window close button      |

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

---

## Zig 0.16 vs 0.17 differences relevant to this project

Zig 0.17 is a development branch not yet released.  **raylib-zig targets
Zig 0.16.x** (its `build.zig.zon` declares `minimum_zig_version = "0.16.0"`).
If you use Zig 0.17 you may encounter build-system API changes:

- The `b.dependency()` / `root_module.addImport()` / `linkLibrary()` API
  used in this project is stable across both versions.
- If a deprecation or missing function arises, consult `zig build --help`
  and the [Zig 0.17 release notes](https://ziglang.org/download/0.17.0/release-notes.html)
  (once published).

---

## Alternative: using a system-installed raylib

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
```

Then edit `build.zig` to replace the `raylib_zig` dependency block with:

```zig
exe.linkSystemLibrary("raylib");
exe.linkLibC();
```

You can then remove the `dependencies` section from `build.zig.zon`.

---

## Project structure

```
mandelbrot/
├── README.md
├── build.zig          # zig build script
├── build.zig.zon      # package manifest
└── src/
    └── main.zig       # application source
```

---

## Zig learning resources

- [ziglang.org/learn](https://ziglang.org/learn/) — official guide
- [Zig Language Reference](https://ziglang.org/documentation/master/)
- [zig.guide](https://zig.guide/) — community intro
- [ziglings](https://codeberg.org/ziglings/exercises) — interactive exercises
- [Zig Showtime](https://zig.show/) — community projects
- [Zig community](https://ziglang.org/community/) — Discord / IRC / forums

---

## License

MIT
