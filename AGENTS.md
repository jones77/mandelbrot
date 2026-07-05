# AGENTS.md — Mandelbrot Set Visualizer

## Project context

Interactive Mandelbrot viewer in Zig 0.16 + raylib (via raylib-zig v5.6-dev).
**Must be cross-platform** — no macOS-only, Win32-only, or Linux-only code.
All platform-specific behaviour must go through raylib's abstractions.
Ten source files: `main.zig` (entry), `app.zig` (coordinator — history, animation,
rendering), `input.zig` (keyboard/mouse/textbox input), `ui.zig` (drawing, toolbar,
tooltips), `renderer.zig` (multi-threaded rendering), `mandelbrot.zig` (pure math +
tests), `pixel.zig` (pixel format constants), `log.zig` (timestamping & structured
logging), `test_runner.zig` (test harness — imports all files with test blocks),
`integration_tests.zig` (image-based tests).

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
