extends Node

# ZoomManager is responsible for handling user input (mouse wheel) and
# converting it into a continuous logarithmic zoom value.  It emits a
# `zoom_changed(log_zoom: float)` signal whenever the zoom changes, so
# interested listeners (ObjectManager, UI, etc.) can react to changes.
#
# The zoom is stored in natural logarithmic space: `log_zoom` is the
# natural logarithm of the number of metres represented by one screen
# pixel.  For example, log_zoom = 0.0 means 1 m per pixel, while
# log_zoom = -10.0 means 4.54×10⁻⁵ m per pixel (≈0.1 µm per pixel).
#
# To maintain a smooth user experience, the manager interpolates
# `log_zoom_current` toward `log_zoom_target` over time.

class_name ZoomManager

signal zoom_changed(log_zoom: float)

## How quickly the current zoom approaches the target zoom (units per second).
@export var lerp_speed: float = 8.0

## Current natural‑log zoom.  This property represents the log of the
## metres per pixel at the present moment.  It is automatically
## interpolated toward `log_zoom_target` in `_process()`.
var log_zoom_current: float = 0.0

## Target natural‑log zoom.  When the user scrolls the mouse wheel
## this value is adjusted directly.  `_process()` will cause
## `log_zoom_current` to lerp toward this value each frame.
var log_zoom_target: float = 0.0

## Minimum allowed log zoom.  Limiting the range prevents the user
## from zooming to the point that all objects are invisible or
## precision is lost.  These bounds should be configured by
## ObjectManager after loading its objects.
var log_zoom_min: float = -30.0
var log_zoom_max: float = 30.0

func _ready() -> void:
	# Start processing so that _process() runs each frame.
	set_process(true)

	# Initialise both current and target zoom to the same value.  A
	# default of 0.0 means 1 metre per pixel; this can be adjusted by
	# ObjectManager via set_initial_zoom().
	log_zoom_current = 0.0
	log_zoom_target = log_zoom_current

func set_zoom_bounds(min_val: float, max_val: float) -> void:
#    Configure the minimum and maximum allowable log zoom values.  The
#    zoom manager will clamp user input to this range.  Typical
 #   values are derived from the smallest and largest objects in the
  #  dataset together with the size of the viewport.
	log_zoom_min = min_val
	log_zoom_max = max_val
	log_zoom_target = clamp(log_zoom_target, log_zoom_min, log_zoom_max)
	log_zoom_current = clamp(log_zoom_current, log_zoom_min, log_zoom_max)

func set_initial_zoom(value: float) -> void:
#    Set both the current and target zoom to the provided value.
#    Useful for initialising the zoom to a meaningful value (for
#    example, focusing on a mid‑range object when the scene loads).
	log_zoom_current = value
	log_zoom_target = value

func _input(event: InputEvent) -> void:
	# Respond to mouse wheel scrolling.  Godot reports scroll up
	# with button_index == MOUSE_BUTTON_WHEEL_UP and scroll down with
	# MOUSE_BUTTON_WHEEL_DOWN.  Each scroll step adjusts the target
	# log zoom by a fixed amount.  Positive deltas zoom out
	# (increase metres per pixel), negative deltas zoom in.
	if event is InputEventMouseButton and event.is_pressed():
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				log_zoom_target -= 0.25  # zoom in (fewer metres per pixel)
			MOUSE_BUTTON_WHEEL_DOWN:
				log_zoom_target += 0.25  # zoom out (more metres per pixel)
			_:
				return
		log_zoom_target = clamp(log_zoom_target, log_zoom_min, log_zoom_max)

func _process(delta: float) -> void:
	# Smoothly interpolate the current zoom toward the target zoom.
	# A simple exponential approach is used here.  Increase
	# `lerp_speed` to snap more quickly or decrease for smoother,
	# slower movement.
	if abs(log_zoom_current - log_zoom_target) > 0.00001:
		log_zoom_current = lerp(log_zoom_current, log_zoom_target, lerp_speed * delta)
		emit_signal("zoom_changed", log_zoom_current)
