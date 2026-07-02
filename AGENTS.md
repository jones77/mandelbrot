# AGENTS.md — Mandelbrot Set Visualizer

## Project context

Interactive Mandelbrot viewer in Zig 0.16 + raylib (via raylib-zig v5.6-dev).
Four source files: `main.zig` (entry), `app.zig` (UI/history/clipboard),
`renderer.zig` (multi-threaded rendering), `mandelbrot.zig` (pure math + tests).

## Zig conventions

Follow `lib/std/*.zig` conventions. Key exemplars to read for patterns:
- `std/fmt.zig` — overall file structure (imports → constants → types → functions → test block)
- `std/array_list.zig` — type with methods, generics
- `std/testing.zig` — test helpers

## References

[Chéritat](https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set)
— visualisation modes (Sections 3.1–3.6). Summary at `cheritat-algorithms.md`.
Do not fetch full page without asking (~135k tokens).

[Heiland-Allen](https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html)
— cardioid/bulb bounding-box optimisation.

## Build & test

```
zig fetch --save git+https://github.com/raylib-zig/raylib-zig#v5.6-dev  # once
zig build run      # run app
zig build test     # full suite
zig build unit     # 37 pure-math tests, no raylib, prints output
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
