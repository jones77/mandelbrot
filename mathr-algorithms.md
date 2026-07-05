# Heiland-Allen — Cardioid and Bulb Checking

Extracted from Claude Heiland-Allen's blog post
https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html

Condensed reference for accelerating Mandelbrot rendering via cardioid/period-2
circle interior tests and bounding-box optimisation.

---

## 1. Implicit Curves

The Mandelbrot set's main cardioid (period 1) and the circle to its left
(period 2) have closed-form implicit functions.  For `c = x + iy`:

**Circle** (period 2, centred at `-1 + 0i`, radius `1/4`):

```
C₂(x, y) = (x + 1)² + y² - (1/4)²
```

Negative inside, zero on boundary, positive outside.

**Cardioid** (period 1):

```
C₁(x, y) = ((x - 1/4)² + y²)² + (x - 1/4)((x - 1/4)² + y²) - (1/4)y²
```

Evaluating these per-pixel saves iterating interior points to `max_iters`.

---

## 2. Bounding-Box Optimisation

If the entire view rectangle is far from the cardioid/circle, per-pixel tests
are wasted.  Analyse the AABB to decide whether the boundary of either shape
passes through it:

- **100% exterior to shape** — skip all per-pixel tests for that shape.
- **100% interior** — mark every pixel as interior immediately.
- **Boundary passes through** — run per-pixel tests as normal.

### Circle bounding box

- Right edge left of `-5/4` → exterior.
- Left edge right of `-3/4` → exterior.
- Bottom edge above `1/4` → exterior.
- Top edge below `-1/4` → exterior.
- All four corners inside → fully interior.
- Mixed corners → boundary passes through.

When all corners are outside but the box could surround the circle, check
the circle's extremal points (leftmost `-5/4`, rightmost `-3/4`, top `1/4`,
bottom `-1/4`).

### Cardioid bounding box

Same approach, but the cardioid's vertices are not rational.  However,
squaring the coordinates gives dyadic rationals that can be compared:

- `y² > 27/64` → exterior (above/below cardioid).
- `y² < 3/64` and `x > 1/4` → possibly interior (closer analysis needed).

---

## 3. Perturbation of Implicit Curves

For deep zooms, evaluate `C(X + x, Y + y)` using perturbation:

```
C(X + x, Y + y) = C(X, Y) + c(X, Y, x, y)
```

- Compute `C(X, Y)` in high precision, round to low precision.
- Compute `c(X, Y, x, y)` (the cancellation terms) in low precision.
- Some coefficients of `c` need high-precision calculation before rounding.

### Perturbed cardioid

```
c₁(X, Y, x, y) = aₓ x + aᵧ y + aₓ² x² + aₓᵧ xy + aᵧ² y²
                  + aₓ³ x³ + aₓ²ᵧ x²y + aₓᵧ² xy² + aᵧ³ y³
                  + x⁴ + 2x²y² + y⁴
```

Where:

```
aₓ    = (32XY² + 32X³ - 6X + 1) / 8
aᵧ    = (32Y³ + (32X² - 6)Y) / 8
aₓ²   = (16Y² + 48X² - 3) / 8
...
```

Use wxMaxima or similar CAS to derive all coefficients.

For fixed-point arithmetic, intermediate calculations need ~4× the fractional
bits.  For floating point, 53-bit (f64) is sufficient; avoid 24-bit (f32).

---

## 4. Perturbation of Bounding Boxes

The magic-number offsets for bounding-box checks must be computed at high
precision before rounding to low precision.  The relevant expressions:

```
X + 5/4,  X + 1,  X + 3/4,  X + 1/8,  X - 1/4,  X - 3/8
Y + 1/4,  Y - 1/4
Y² - 3/64,  Y² - 27/64
```

All addends are dyadic rationals → exact in binary fixed point or float.

---

## 5. Parametric Forms and Distance Estimates

Cardioid parametric form:

```
C₁(t) = ( (sin²(t) - (cos(t) - 1)² + 1) / 4,
          (cos(t) - 1) sin(t) / 2 )
```

Finding the exact distance to the cardioid curve requires solving a high-degree
polynomial.  In practice, bisection on `t = k·π/3` segments works.

Linear distance estimate via Taylor expansion gives a closed form `d(x, y)`,
but is inaccurate near the cusp.  Quadratic expansion produces a high-degree
polynomial.  Exact distance to the circle is trivial.

---

*Credits: All algorithms above are from Claude Heiland-Allen's blog post at
https://mathr.co.uk/blog/2022-11-19_cardioid_and_bulb_checking.html
Thanks to Heiland-Allen for the clear exposition and mathematical derivations.*
