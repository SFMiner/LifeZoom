# Universal Zoom Design Note

## Overview

The goal of the *universal zoom* viewer is to let a user smoothly zoom
from sub‑atomic length scales (≈10⁻¹⁰ m) up to planetary scales
(≈10⁷ m).  At each scale only representative objects are shown: a
hydrogen atom, a water molecule, DNA, a virus, a cell, an insect, a
human, a city block, a mountain, a continent and the Earth.  As the
user scrolls the mouse wheel the application transitions smoothly
between these scales, scaling sprites appropriately and hiding them
when they are too small to see or have grown excessively large.

Two competing approaches were considered for implementing the zoom:

1. **Camera‑zoom approach** – store each object at its real size in
   metres, put them into the scene at their origin, and simply adjust
   `Camera2D.zoom` logarithmically.  Visibility decisions would be
   based on the object’s projected size through the camera.
2. **Sprite re‑scaling approach** – keep the camera’s zoom fixed at
   `(1,1)` and apply a per‑object scale so that the on‑screen width
   equals the real‑world size divided by the current metres‑per‑pixel
   factor (which is derived from a global logarithmic zoom value).  A
   `ZoomManager` singleton stores the zoom in natural log space and
   updates all objects whenever it changes.

### Comparison

| Aspect                | Camera‑zoom                   | Sprite re‑scaling                                                       |
|-----------------------|------------------------------|-------------------------------------------------------------------------|
| **Numerical stability** | Requires the camera’s zoom to cover ~10¹⁷ range.  Even though GDScript uses 64‑bit floats, extremely large or small scale factors can lead to precision loss in the renderer.  Re‑normalising the world or using nested cameras would add complexity. | Each object is scaled individually and only when it is visible.  The per‑object scale spans roughly two orders of magnitude around its nominal scale.  Objects outside this range are simply hidden, avoiding 1×10¹⁷ multipliers in the transform. |
| **Implementation complexity** | Simple in theory – a single camera scales everything.  However, mapping from metres to Godot units, clamping extremes and computing visibility thresholds still require per‑object calculations. | Slightly more code because every object must recompute its scale on zoom change.  Nevertheless, the logic is straightforward and localised to `ObjectManager`. |
| **Culling efficiency**   | Because all objects remain in the scene and inherit the camera transform, large objects that are currently invisible still incur transform updates.  Additional logic is required to disable processing outside a useful range. | Since each object’s scale is computed explicitly, the manager knows exactly when its size falls below a minimum pixel threshold and can disable the node entirely. |
| **Integrating new assets** | Objects must be authored at real size (metres mapped to engine units).  Artists need to work in vastly different coordinate spaces. | Objects are authored at arbitrary pixel sizes (≤1000×1000 px).  The resource file simply stores the real diameter, and the code takes care of converting it to screen units. |

### Choice

The second approach – **sprite re‑scaling** – was selected.  Although
the user initially favoured the camera‑zoom method, the dynamic range
required (≈10¹⁷) forces `Camera2D.zoom` into values as small as
10⁻¹⁴ and as large as 10¹⁰.  Godot’s rendering pipeline uses 32‑bit
transform matrices internally, and such extremes can cause jitter,
z‑fighting or the disappearance of objects.  Re‑normalising the world
periodically to mitigate these issues would complicate the code and
break the conceptual simplicity of a single global scale.  By contrast
the sprite re‑scaling approach encapsulates the huge dynamic range in
a single scalar (`log_zoom`) and keeps the actual transforms within
sensible bounds.  Each object is only active near its nominal zoom and
is hidden otherwise, so the system maintains numerical precision and
achieves good performance.

## Mathematical Mapping

Define `log_zoom` as the natural logarithm of the number of metres per
screen pixel:

```text
metres_per_pixel = exp(log_zoom)
```

For an object of real diameter `d` metres and an image whose texture
is `W` pixels wide, its projected width on the screen at the current
zoom is

```text
screen_px = d / metres_per_pixel.
```

To display the object at the correct size, we set the sprite’s scale
factor so that its texture width times the scale equals
`screen_px`:

```text
scale_factor = screen_px / W = (d / exp(log_zoom)) / W.
```

Thus the sprite’s `scale` property becomes `(scale_factor, scale_factor)`.

### Nominal and Visibility Thresholds

Let `width_px` be the current viewport width in pixels.  Define a
nominal target width `target_px` as `NOMINAL_RATIO × width_px` (with
`NOMINAL_RATIO = 0.8`).  The nominal log zoom for an object is the
value of `log_zoom` at which its real size maps onto the nominal
width:

```text
log_zoom_nominal = ln(d / target_px).
```

An object becomes too small to see when its projected width falls
below `MIN_PX` pixels (here `MIN_PX=2`).  Solving `screen_px = MIN_PX`
gives the log‑zoom bound at which the object disappears while zooming
out:

```text
log_zoom_min = ln(d / MIN_PX).
```

Similarly, to avoid huge blurry sprites we hide the object once its
projected width exceeds `MAX_DISPLAY_MULTIPLIER × target_px` (with
`MAX_DISPLAY_MULTIPLIER=10`).  The corresponding bound while zooming
in is

```text
log_zoom_max = ln(d / (target_px × MAX_DISPLAY_MULTIPLIER)).
```

These per‑object bounds are computed whenever the viewport size
changes.  The global minimum and maximum log zoom across all objects
become the clamp for `ZoomManager` to ensure that scrolling beyond
useful values is disabled.

### Fading

To avoid popping when an object appears or disappears, alpha fading is
applied near the thresholds.  The alpha ramps from 0 to 1 between
`MIN_PX` and `FADE_IN_PX` (here `FADE_IN_PX=6`), and ramps back to 0
between `0.9 × (target_px × MAX_DISPLAY_MULTIPLIER)` and the maximum
size.

## Implementation Summary

The project is structured as follows under `res://universal_zoom`:

| File                     | Purpose |
|-------------------------|---------|
| `assets/*.png`          | Simple semi‑abstract images for each object (hydrogen, water, DNA, virus, cell, insect, human, city block, mountain, continent and Earth).  Transparent backgrounds allow blending. |
| `objects.json`          | Data definitions for each object: ID, display name, real size in metres, image path and pivot information.  Used to populate the scene at runtime. |
| `UniversalObject.gd`    | A small `Resource` class describing an object.  Not used directly in this demo but provided for extensibility. |
| `ZoomManager.gd`        | Singleton responsible for handling mouse wheel input, maintaining the logarithmic zoom value and emitting a `zoom_changed` signal.  Stores the current and target zoom and interpolates between them for smooth motion. |
| `ObjectManager.gd`      | Node2D that loads objects, instantiates their sprites and updates their visibility, scale and alpha when `zoom_changed` fires.  Also computes per‑object log‑zoom bounds and updates global bounds in `ZoomManager`. |
| `Main.tscn`             | Scene combining a `ZoomManager`, a `Camera2D`, an `ObjectManager` and a `CanvasLayer` with a `Label` to display debug information. |
| `design_note.md`        | This document, providing justification and mathematical detail. |

## Running the Demo

1. **Import into Godot 4.5**: Clone or copy the `universal_zoom` folder
   into your Godot project directory.  Open the project in the Godot
   editor.  Ensure that the images in `assets` are recognised as
   textures.

2. **Set the main scene**: In Project Settings → General → Application
   → Run → Main Scene, choose `res://universal_zoom/Main.tscn`.

3. **Run** the project.  Use the mouse wheel to zoom in and out.  The
   label in the top‑left corner displays the current metres‑per‑pixel
   value, the nearest object and the current logarithmic zoom value.

4. **Extending**: To add new objects, append entries to
   `objects.json` with the appropriate real sizes and images.  The
   manager automatically incorporates them on the next run.  To change
   culling behaviour, adjust the constants `MIN_PX`, `FADE_IN_PX`,
   `MAX_DISPLAY_MULTIPLIER` or `NOMINAL_RATIO` in `ObjectManager.gd`.

## Unit Testing

Although Godot’s built‑in GUT framework is not included here, the
logic can be tested with simple assertions in a debug run:

1. At log zoom `log(d / target_px)`, verify that the object’s sprite
   width equals the configured `target_px` (within floating point
   tolerance).
2. At log zoom `log(d / MIN_PX) + ε` and `log(d / MIN_PX) − ε`,
   verify that the object transitions from visible to invisible.  Use
   a small epsilon to ensure the fading threshold works correctly.
3. Ensure that the current zoom value remains clamped within
   `log_zoom_min` and `log_zoom_max` as reported by `ObjectManager`.

Because the zoom computation is purely mathematical and depends only
on the viewport size and the real sizes from `objects.json`, these
tests can be executed in a headless Godot run or even ported to a
Python unit test harness for continuous integration.