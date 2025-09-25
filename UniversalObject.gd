extends Resource

# A simple data container representing an object in the universal zoom demo.
# Each instance stores the object's unique identifier, its display name,
# real-world diameter in metres, the path to its texture, and any other
# metadata needed for presentation.

class_name UniversalObject

## Unique identifier for this object.
@export var id: String

## Human‑friendly name shown in debug UI.
@export var display_name: String

## Real diameter of the represented object in metres.  This value is used
## together with the global zoom factor to compute the on‑screen size.
@export var real_size_m: float = 1.0

## Path to the PNG image for this object.  Should use the `res://`
## prefix so it can be loaded at runtime within the Godot project.
@export var image_path: String

## Normalised pivot point in texture coordinates (0,0 is top‑left, 1,1 is bottom‑right).
## A value of (0.5, 0.5) centres the image around its middle.
@export var pivot_normalized: Vector2 = Vector2(0.5, 0.5)

## Optional notes describing the object.  Not used by the game logic but
## helpful for documentation and debugging.
@export var notes: String = ""
