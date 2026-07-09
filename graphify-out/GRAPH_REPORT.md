# Graph Report - .  (2026-07-08)

## Corpus Check
- Corpus is ~45,598 words - fits in a single context window. You may not need a graph.

## Summary
- 172 nodes · 264 edges · 12 communities (8 shown, 4 thin omitted)
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 20 edges (avg confidence: 0.81)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Mandelbrot Math & Rendering Core
- App Coordinator (Animation, History, Render)
- Allocator & Input Handling
- Numerical Precision & Deep Zoom
- UI Rendering (Toolbar, Tooltip)
- Integration Testing
- Reference Orbit Bank (RefBank)
- Graphify Extraction Pipeline
- OpenCode Plugin Config
- Plugin Dependencies
- Graphify JS Plugin

## God Nodes (most connected - your core abstractions)
1. `App` - 26 edges
2. `logEvent()` - 18 edges
3. `Mandelbrot Set Visualizer` - 16 edges
4. `TextBuf` - 12 edges
5. `smoothIteration()` - 7 edges
6. `truncateFuture()` - 5 edges
7. `isoNow()` - 5 edges
8. `RefBank` - 5 edges
9. `drawToolbar()` - 5 edges
10. `Perturbation Rendering` - 5 edges

## Surprising Connections (you probably didn't know these)
- `Perturbation Theory (K.I. Martin)` --conceptually_related_to--> `Perturbation Rendering`  [INFERRED]
  README.md → AGENTS.md
- `get()` --calls--> `logEvent()`  [INFERRED]
  src/allocator.zig → src/log.zig
- `deinit()` --calls--> `logEvent()`  [INFERRED]
  src/allocator.zig → src/log.zig
- `handleInput()` --calls--> `logEvent()`  [INFERRED]
  src/input.zig → src/log.zig
- `Mandelbrot Set Visualizer` --references--> `graphify Knowledge Graph Tool`  [EXTRACTED]
  AGENTS.md → .opencode/skills/graphify/SKILL.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Numerical Precision Techniques** — AGENTS_f128_fallback, AGENTS_per_component_fold_eps, AGENTS_prefer_z_norm_sq, AGENTS_about_1e28_floor, AGENTS_coordinate_display_precision [INFERRED 0.95]
- **Mandelbrot Rendering Pipeline Components** — AGENTS_perturbation_rendering, AGENTS_cardioid_bulb_precheck, AGENTS_glitch_detection, AGENTS_rebasing_technique, AGENTS_refbank_architecture, AGENTS_f128_fallback [INFERRED 0.95]
- **Graphify Extraction Pipeline Steps** — _opencode_skills_graphify_SKILL_extraction_pipeline, _opencode_skills_graphify_SKILL_ast_extraction, _opencode_skills_graphify_SKILL_semantic_extraction, _opencode_skills_graphify_SKILL_community_detection [EXTRACTED 1.00]

## Communities (12 total, 4 thin omitted)

### Community 0 - "Mandelbrot Math & Rendering Core"
Cohesion: 0.06
Nodes (23): buildPalette(), ComplexPoint, continueStandard(), Coord, DragDeltaResult, F128Px, hslToRgb(), OrbitPoint (+15 more)

### Community 1 - "App Coordinator (Animation, History, Render)"
Cohesion: 0.18
Nodes (4): App, computeAnimDuration(), truncateFuture(), logEvent()

### Community 2 - "Allocator & Input Handling"
Cohesion: 0.12
Nodes (19): deinit(), get(), DragState, HistoryEntry, parseField(), parseViewState(), pushHistory(), ZoomAnimation (+11 more)

### Community 3 - "Numerical Precision & Deep Zoom"
Cohesion: 0.11
Nodes (24): The Roughly 1e-28 Floor, Cardioid/Bulb Pre-Check, Coordinate Display Precision Limitation, f128 Fallback for rebaseFallback, Glitch Detection, Mandelbrot Set Visualizer, Per-Component fold_eps Trap, Perturbation Rendering (+16 more)

### Community 4 - "UI Rendering (Toolbar, Tooltip)"
Cohesion: 0.12
Nodes (7): drawCoordinateTooltip(), drawToolbar(), drawToolbarArrow(), drawToolbarButton(), pixelCenterToComplex(), TextBuf, ToolbarLayout

### Community 5 - "Integration Testing"
Cohesion: 0.15
Nodes (4): RenderTestCase, buildRefBank(), generateGridPoints(), GridPoint

### Community 7 - "Graphify Extraction Pipeline"
Cohesion: 0.50
Nodes (4): AST Extraction, Community Detection, Graphify Extraction Pipeline, Semantic Extraction

## Knowledge Gaps
- **34 isolated node(s):** `$schema`, `plugin`, `@opencode-ai/plugin`, `DragState`, `ZoomAnimation` (+29 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `App` connect `App Coordinator (Animation, History, Render)` to `Allocator & Input Handling`?**
  _High betweenness centrality (0.157) - this node is a cross-community bridge._
- **Why does `RefBank` connect `Reference Orbit Bank (RefBank)` to `Mandelbrot Math & Rendering Core`?**
  _High betweenness centrality (0.036) - this node is a cross-community bridge._
- **Are the 16 inferred relationships involving `logEvent()` (e.g. with `deinit()` and `get()`) actually correct?**
  _`logEvent()` has 16 INFERRED edges - model-reasoned connections that need verification._
- **What connects `$schema`, `plugin`, `@opencode-ai/plugin` to the rest of the system?**
  _39 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Mandelbrot Math & Rendering Core` be split into smaller, more focused modules?**
  _Cohesion score 0.06401137980085349 - nodes in this community are weakly interconnected._
- **Should `Allocator & Input Handling` be split into smaller, more focused modules?**
  _Cohesion score 0.11666666666666667 - nodes in this community are weakly interconnected._
- **Should `Numerical Precision & Deep Zoom` be split into smaller, more focused modules?**
  _Cohesion score 0.10507246376811594 - nodes in this community are weakly interconnected._