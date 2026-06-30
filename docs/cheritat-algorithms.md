# Chéritat Wiki — Algorithms Summary

Extracted from Arnaud Chéritat's "Techniques for computer generated pictures in complex dynamics"
https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set

This is a condensed reference for implementing visualisation modes. See the full wiki
for images, caveats, and mathematical derivations.

---

## 1. Potential-based coloring (Section 3.3)

Definition: `V(c) = lim_{n→∞} log⁺|P_cⁿ(0)| / 2ⁿ` where log⁺(x) = 0 if x<1 else log(x).
V(c)=0 exactly on M. Sets V=x are equipotentials.

**Algorithm:** Iterate until |z| > R (R large, e.g. 1000). When |z| > R:
  `V(c) ≈ log|z| / 2ⁿ`
Colour based on V(c) instead of iteration count n.

```
V ≈ log(|z|²) / (2×2ⁿ)     // using squared modulus
```

Parameters: `R` (escape radius, default 1000), `color_function(V) → Color`.

---

## 2. Log-potential scale (Section 3.3.1)

For deep zooms, colour using log(V) instead of V. Choose a period K > 0:
  `x = log(V) / K`
  `color = g(x)`   with g(x+1) = g(x)

A simple periodic function:
  `g(x) = 255 × (1 + cos(2πx)) / 2`   per-channel

K = ln(2) is a natural starting choice. Larger K works better when M gets
"furry" at deep zooms.

Parameters: `K` (period constant, default ln(2)), `wave_function`.

---

## 3. Milnor's distance estimator (Section 3.5.1)

When |z_n| > R, the distance from z₀ to M is approximated by:
  `d_n = 2·|z_n|·log|z_n| / |ρ_n|`

where `ρ_n = dz_n/dc` is computed iteratively:
  `ρ₀ = 0`
  `ρ_{n+1} = 2·z_n·ρ_n + 1`

**Algorithm (per pixel):**
```
z = c
ρ = 1+0j    // derivative w.r.t c (start at 1 since dz₀/dc = 1)
for n in 0..N:
  if |z| > R:
    // outside — compute distance estimate
    d = 2·|z|·log|z| / |ρ|
    if d < thickness_factor × pixel_size:
      color = boundary_color
    else:
      color = outside_color
    break
  new_z = z² + c
  new_ρ = 2·z·ρ + 1    // note: ρ updated BEFORE z
  z = new_z
  ρ = new_ρ
```

Alias: `der_c` for `ρ`. Parameter: `R` (escape radius, default 1000),
`thickness_factor` (default 1.0).

Comparing squares to avoid sqrt:
  `|z|²·(log|z|²)² < |thickness_factor · pixel_size · ρ|²`

---

## 4. Antialiased boundary (Section 3.5.2)

Same as Milnor's but interpolate between boundary and outside colours:
  `t = d_n / (thickness_factor × pixel_size)`
  `t = min(t, 1)`
  `color = lerp(boundary_color, outside_color, t)`

Parameter: `thickness_factor` (default 1.414).

Smooths the outside but not the inside — a cheap antialiasing trick.

---

## 5. Distance estimator coloring (Section 3.5.3)

Colour the outside as a function of d_n directly. Example:
  colour = alternating bands according to parity of floor(log(d_n) / constant)

No algorithm given — many possible choices.

---

## 6. Henriksen's boundary detection (Section 3.5.4)

More versatile than Milnor's — adapts to other families (Julia sets, bifurcation loci).
Uses the idea that ∂M is the closure of points where the critical orbit is periodic.

**Algorithm:**
```
z = c
dc = 1+0j
der = dc
for n in 0..N:
  if |z| < |pixel_size × thickness_factor × der|:
    → BOUNDARY
    break
  if |z| > R:
    → OUTSIDE    (R small, e.g. 10)
    break
  new_z = z² + c
  new_der = der·2·z + dc
  z = new_z
  der = new_der
```

Key difference from Milnor's: der starts with `dc` (not 1), and the recurrence
adds `dc` (not 1). This makes the "1" term track the pixel-size scaling.

Optimisation: absorb `pixel_size × thickness_factor` into `dc`:
  `dc = pixel_size × thickness_factor + 0j`
  test: `|z| < |der|`   (saves a multiply per iteration)

Parameter: `R` (escape radius, default 10), `thickness_factor` (default 0.25).

### Variant (Section 3.5.4.1)
Replace `z` by `z+c` to avoid detecting centers of hyperbolic components:
  test: `|z + c|² < |der + dc|²`

### Another variant (Section 3.5.4.2)
Use spherical metric instead of Euclidean:
  `rsq = |z + c|²`
  test: `rsq·(1 + rsq·0.25) < |der + dc|²`

---

## 7. Image trapping (Section 3.6.1)

When |z_n| > R (R small, e.g. 4.8), use the first escaped z value as a
coordinate into a base image (PNG or similar). Map (z.re, z.im) to texture
coordinates and sample the trap image.

Parameter: `trap_image_path`, `R` (escape radius, default 4.8).

Often combined with boundary detection and interior detection.

---

## 8. Normal map shading (Section 3.6.2)

After |z_n| > R, compute a normal vector from the potential gradient:
  `u = z / der`           (complex number)
  `u = u / |u|`           (normalise — now a unit vector in the complex plane)
  normal vector = (u.re, u.im, 1)

Apply Lambertian shading:
  `light_dir = (cos θ, sin θ, h)`      // θ = light_angle, h = height_factor
  `t = u.re·lx + u.im·ly + h`
  `t = max(t / (1 + h), 0)`
  `color = lerp(black, white, t)`

Parameters: `light_angle` (degrees, default 45), `height_factor` (default 1.5).

### Variation (Section 3.6.2.1)
Use Milnor's distance estimator instead of potential. Requires tracking
`d²z/dc²` alongside `dz/dc`:
```
new_z = z² + c
new_der = 2·der·z + 1
new_der2 = 2·(der2·z + der²)
z = new_z
der = new_der
der2 = new_der2
```

Then:
```
lo = ½·log(|z|²)
u = z·der·((1+lo)·conj(der²) - lo·conj(z·der2))
u = u / |u|
```
Proceed with Lambertian shading as above.

---

## 9. Radial strands / Stripe Average (Section 3.6.3)

References "Triangle Inequality Average" (Kerry Mitchell) and "Stripe Average".
Stripe Average follows external rays (important in the theoretical study of M).
No algorithm given — see Jussi Härkönen's Master's Thesis (2007).

---

## Mixing modes (Section 4)

Multiple techniques can be combined: compute separate images and merge with
layers/transparency in an image editor, or select per-pixel colouring algorithm
programmatically.

---

*Credits: All algorithms above are from Arnaud Chéritat's wiki page at
https://www.math.univ-toulouse.fr/~cheritat/wiki-draw/index.php/Mandelbrot_set
The page credits Peitgen & Richter ("The Beauty of Fractals"), Peitgen & Saupe
("The Science of Fractal Images"), Robert Munafo (Mu-Ency), and discussions with
Xavier Buff, Christian Henriksen, and John H. Hubbard.*
