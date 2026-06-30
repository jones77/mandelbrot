# AGENTS.md — Mandelbrot Set Visualizer

## Project context

Interactive Mandelbrot viewer in Zig 0.16 + raylib (via raylib-zig v5.6-dev).
Four source files: `main.zig` (entry), `app.zig` (UI/history/clipboard),
`renderer.zig` (multi-threaded rendering), `mandelbrot.zig` (pure math + tests).

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

## Known bugs and fixes

### f32 overflow in perturbation
Z overflows f32 ~7 iters post-escape. Escape check ran before Z_norm_sq
overflow check, sending f32-inf into rebaseFallback via @as(f64, Zx).
Produced -inf mu → NaN in smoothColor.
**Fix:** Z_norm_sq check before escape check; use ref.zx (f64) directly.

### f32 precision in standardPixel
f32 loop degrades over thousands of iterations, rounding |z|² below 4.0
for exterior pixels → classified interior (black circle).
**Fix:** Use rebaseFallback (f64) when max_iters > 2048 and ref is interior.

### Perturbation path order
Perturbation first (if ref_orbit), then f64 fallback, then standardPixel.
δ computed from cx_f64 - orbit[0].zx (f64) not cx - orbit[0].zx (f32→f64).
