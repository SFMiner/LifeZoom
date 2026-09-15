# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An interactive educational visualization ("UniversalZoom" / LifeZoom) that zooms continuously across ~17 orders of magnitude, from a hydrogen atom (~1e-10 m) to Earth (~1.3e7 m). Not a game — no player, no win state. Scroll wheel is the only input.

`design_note.md` is the authoritative design document: it derives the zoom math, justifies the architecture, and lists the tuning constants. **Read it before changing any scaling/visibility logic.**

## Commands

Godot 4.5. No test suite, no CI, no build scripts. Godot is **not on PATH**, but a matching portable binary ships two levels up in the Gamedev folder (verified `4.5.stable.official`):

```bash
GODOT="/c/Users/seanm/Nextcloud2/Gamedev/Godot_v4.5-stable_win64.exe"

# Run the project
"$GODOT" --path .

# Open in editor
"$GODOT" -e --path .

# Headless script-error check (fast sanity pass without launching a window)
"$GODOT" --headless --path . --quit

# Export (presets defined in export_presets.cfg)
"$GODOT" --headless --path . --export-release "Web" ../export/index.html
"$GODOT" --headless --path . --export-release "Windows Desktop" ../UniversalZoom.exe
```

A `Godot_v4.7-stable_win64.exe` sits alongside it — don't use it, the project declares `config/features=PackedStringArray("4.5", "Forward Plus")`.

Both export targets write **outside** the project dir (`../export/`, `../UniversalZoom.exe`). Web export has `variant/thread_support=false`. A previous web build is already scattered across `Gamedev/GodotGames/` as loose `UniversalZoom.{html,js,wasm,pck,png}` files — those are stale output, not source.

## Where this repo lives

`Gamedev/` exists twice on the laptop under two different sync services, with **different** contents — this is a real tripwire, not a duplicate:

| Tree | Sync | Holds |
| :--- | :--- | :--- |
| `C:\Users\seanm\Nextcloud2\Gamedev\` | Nextcloud | **LifeZoom (this project)**, plus its own project set |
| `C:\Users\seanm\Proton Drive\seanminer\Other computers\SEANPC\GameDev\` | Proton Drive | the Gamedev `CLAUDE.md` learning log, plus older `universal_zoom` / `universal-zoom` attempts |

Consequences worth knowing:

- The Nextcloud tree has **no** `Gamedev/CLAUDE.md`, so the Gamedev domain learning log does *not* auto-load when working in LifeZoom. Durable Godot lessons learned here should be appended to the Proton Drive copy.
- `universal_zoom` and `universal-zoom` in the Proton tree are earlier takes on this same idea. Check them before re-solving a scaling problem, but they are not this codebase.

## Architecture

### The core decision: sprites rescale, the camera does not

`Camera2D` stays at zoom `(1,1)` permanently. Zooming is implemented by rescaling every `Sprite2D` each frame. This is deliberate — a naive camera zoom across 1e17 would need zoom factors from ~1e-14 to ~1e10 and lose precision in the 32-bit transform matrix. Do not "simplify" this into camera zoom.

### Zoom lives in natural-log space

`log_zoom` = `ln(metres_per_pixel)`. Everything derives from this one scalar:

```
metres_per_pixel = exp(log_zoom)
screen_px        = real_size_m / metres_per_pixel
scale_factor     = screen_px / texture_width_px
```

Larger `log_zoom` = zoomed **out**. Scroll wheel adjusts the target by ±0.25 (perceptually uniform steps), then `_process()` lerps `log_zoom_current` toward it.

### Three files, one signal

| File | Role |
| :--- | :--- |
| `ZoomManager.gd` (`Node`) | Owns zoom state, reads mouse wheel, lerps, emits `zoom_changed(log_zoom)` |
| `ObjectManager.gd` (`Node2D`) | Loads `objects.json`, spawns sprites+labels, recomputes scale/visibility/position on every `zoom_changed` |
| `UniversalObject.gd` (`Resource`) | Data-class schema mirroring a `objects.json` entry. **Currently unused at runtime** — the JSON is parsed into raw `Dictionary`s. |

`Main.tscn` is the only real scene: `Main(Node2D)` → `ZoomManager`, `Camera2D`, `ObjectManager`, `CanvasLayer/DebugLabel`. `ObjectManager` finds `ZoomManager` as a sibling via `get_parent().get_node_or_null("ZoomManager")` and connects itself; `ZoomManager` knows nothing about its listeners. Keep it that way — add new zoom-reactive systems as additional subscribers, not by coupling into `ObjectManager`.

`ObjectManager.tscn` is an empty leftover template, not used by `Main.tscn`.

### Data-driven object roster

`objects.json` is a flat array of ~45 entries, loaded at runtime from `res://objects.json`. Adding an object = adding a JSON entry + a PNG in `assets/` (59 PNGs currently). No GDScript change needed.

```json
{
  "id": "hydrogen_atom",
  "display_name": "Hydrogen Atom",   // "\n" is honored — labels wrap
  "real_size_m": 1e-10,              // real-world diameter, metres
  "image_path": "res://assets/hydrogen.png",
  "pivot_normalized": [0.5, 0.5],    // converted to Sprite2D.offset
  "position_shift": [0, 1400],       // manual per-object label nudge
  "notes": "..."                     // documentation only
}
```

Entries are ordered smallest → largest, and **order is load-bearing**: index 0 is pinned at the origin and every other object is placed on a ring around it.

### Precomputed thresholds

`_compute_thresholds()` runs at `_ready()` and again on viewport `size_changed`. Per object it caches:

- `nominal_log_zoom[i]` — object fills `NOMINAL_RATIO` (0.8) of viewport width
- `min_log_zoom_values[i]` — beyond this, object is under `MIN_PX` (2 px) → hidden
- `max_log_zoom_values[i]` — below this, object exceeds `MAX_DISPLAY_MULTIPLIER` (10×) nominal → hidden

It then unions these into global bounds and pushes them into `ZoomManager.set_zoom_bounds()`, so the user can never scroll to a state where nothing is visible. Anything that changes viewport size or the object roster must re-run this.

`INITIAL_ZOOM = -29.0` is hardcoded in `ObjectManager` and pushed via `set_initial_zoom()` — that's the atomic end of the range.

### Label layout

Labels are children of their sprite (so they inherit sprite transform). Layout is a hand-tuned orbital arrangement: base angle `-PI/2`, `+1.0` rad per object (`+1.5` when adjacent objects are within `CLOSE_RATIO_THRESHOLD` = 3× in size), radius `1.1 * (radius0 + radius_i)`. Combined with the per-object `position_shift` and a hardcoded `Vector2(-600, -1000)` base offset, this is empirical, not principled — expect to re-tune by eye after roster changes.

## Known dead / broken code in `ObjectManager.gd`

Several paths are inert. Don't mistake them for working features, and don't "fix" them silently — confirm intent first.

- **Line 331** — `var radius0_px: float = radius_px_arr.size() > 0 if radius_px_arr[0] else 0.0` is a mis-ordered GDScript ternary (`value if cond else other`). It assigns the *array length*, not `radius_px_arr[0]`. All ring distances are consequently wrong.
- **Line 67** — fallback `get_tree().get_root().find_node(...)` uses a Godot 3 API removed in Godot 4 (it's `find_child` now). Only reached if `ZoomManager` isn't a sibling, in which case it errors instead of degrading.
- **Alpha fading is computed but never applied** (lines 267–280 commented out). Objects pop in/out at the 2 px and 10× thresholds rather than fading.
- **`nearest_obj_idx` is never assigned** (lines 284–287 commented out), so the debug label always reports "None".
- **Line 358** — `"{0:.3e}".format(...)` uses Python-style format specs that GDScript's `String.format()` does not support; they render literally.
- `_load_objects()` calls `.resize()` on the three threshold arrays inside the per-object loop. Harmless but redundant.
- `ObjectManager.bak` and `Main.tscn29419340.tmp` are stray untracked artifacts, not source.

## Conventions

- Tabs for indentation (matches the existing GDScript and the JSON, which is also tab-indented).
- `.gitattributes` forces `eol=lf` on all text files.
- Scene/script UIDs (`uid://...`) are tracked in `.uid` files and referenced in `Main.tscn`. If you hand-write a `.tscn`, the `ext_resource` `uid` must match the script's `.uid` file or the reference breaks.
