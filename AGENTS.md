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
