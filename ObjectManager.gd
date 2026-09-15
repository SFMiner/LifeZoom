extends Node2D

# ObjectManager loads universal objects from a JSON definition and
# manages their lifecycle: instantiation, visibility, scaling and
# fading based on the current log‑scale zoom.  It connects to
# ZoomManager's `zoom_changed` signal and updates the objects when
# the zoom changes.  It also exposes a simple debug label showing
# the current scale and nearest landmark.

class_name ObjectManager

## Pixel threshold below which objects are hidden entirely.
const MIN_PX: float = 2.0
## Pixel threshold over which objects begin to fade in fully.
const FADE_IN_PX: float = 6.0
## Maximum multiple of the nominal target size before objects are hidden.
const MAX_DISPLAY_MULTIPLIER: float = 10.0
## Portion of the viewport width used as the nominal object width when fully visible.
const NOMINAL_RATIO: float = 0.8

const CLOSE_RATIO_THRESHOLD: float = 3.0
const EXTRA_ANGLE: float = 0.5

## Reference texture width used to normalise label sizes.  A texture of
## exactly this width renders its label at the raw font size; narrower and
## wider textures are compensated so that every label ends up the same size
## on screen.  See _load_objects().
const LABEL_REF_WIDTH: float = 1000.0

const INITIAL_ZOOM : float = -29.0
## A list of dictionaries loaded from the JSON file.  Each entry
## contains keys matching those defined in objects.json (id,
## display_name, real_size_m, image_path, pivot_normalized, notes).
var objects: Array = []

## The Sprite2D nodes created to represent each object.  Indices
## correspond to `objects`.
var sprites: Array = []

## Precomputed nominal log zoom for each object.  At this zoom the
## object's size on screen is roughly `NOMINAL_RATIO * viewport_width_px`.
var nominal_log_zoom: Array = []

## Precomputed log zoom values at which each object becomes too small
## to see (below MIN_PX).
var min_log_zoom_values: Array = []

## Precomputed log zoom values at which each object becomes too large
## (above MAX_DISPLAY_MULTIPLIER times the nominal size).
var max_log_zoom_values: Array = []

## Index of the object whose nominal zoom is closest to the current
## zoom.  Used for debug display.
var nearest_obj_idx: int = -1


var labels: Array = []

## Ring angle (radians) for each object, indexed alongside `objects`.
## Derived purely from the real-world size ratios between neighbouring
## objects, so it does NOT depend on zoom or viewport and is computed
## exactly once.  Recomputing this per frame from pixel radii caused
## sprites to teleport: ratios that sit on CLOSE_RATIO_THRESHOLD land on
## different sides of the comparison as floating-point rounding shifts
## with the zoom level, and because the angle is a running sum a single
## flip rotated every later object by EXTRA_ANGLE.
var ring_angles: Array = []

## Reference to the ZoomManager node.  Cached at runtime.
var zoom_manager: ZoomManager = null

## Label used to show debug information.  It is assigned in the
## scene's Main.tscn and updated by this manager.
var debug_label: Label = null

func _ready() -> void:
	# Locate the ZoomManager instance.  It should be a sibling in the
	# scene tree named "ZoomManager".  If not found, searches the
	# entire tree as a fallback.  Do not throw if missing – instead
	# degrade gracefully.
	zoom_manager = get_parent().get_node_or_null("ZoomManager")
	if zoom_manager == null:
		zoom_manager = get_tree().get_root().find_node("ZoomManager", true, false)

	# Load object definitions and spawn sprites.
	_load_objects()

	# Fix the ring layout once.  Angles are zoom- and viewport-independent.
	_compute_ring_angles()

	# Compute per‑object thresholds and global zoom bounds based on the
	# current viewport.  These will be recomputed if the viewport
	# changes size.
	_compute_thresholds()

	# Connect to zoom updates from the ZoomManager.
	if zoom_manager != null:
		zoom_manager.connect("zoom_changed", Callable(self, "_on_zoom_changed"))

	# Connect to viewport resizing; when the window changes size we
	# recompute thresholds for proper scaling.  Node2D doesn't emit
	# `resized`, so we listen to the viewport directly.
	var viewport := get_viewport()
	if viewport:
		viewport.connect("size_changed", Callable(self, "_on_viewport_size_changed"))

	# Initialise visible state using the current zoom.
	if zoom_manager:
		_on_zoom_changed(zoom_manager.log_zoom_current)

	# Attempt to locate a debug label within the scene to write
	# diagnostic information.  The label is optional; if it cannot
	# be found then the manager simply won't display debug text.
	var lbl : Label = $"../CanvasLayer/DebugLabel"
	if lbl and lbl is Label:
		debug_label = lbl

func _load_objects() -> void:
	# Reads objects from the JSON file located alongside this script.
	var path = "res://objects.json"
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("Unable to open objects definition: {0}".format([path]))
		return
	var json_text := file.get_as_text()
	file.close()
	var data = JSON.parse_string(json_text)
	if typeof(data) != TYPE_ARRAY:
		push_warning("Invalid objects.json format: expected an array.")
		return
	objects = data
	# Create a Sprite2D for each entry.
	for obj_dict in objects:
		var tex := load(obj_dict["image_path"])
		if tex == null:
			push_warning("Failed to load texture for %s" % obj_dict["id"])
			continue
		var sprite := Sprite2D.new()
		sprite.texture = tex
		# Centre the sprite so that (0,0) is its pivot.  We'll apply
		# additional offset based on pivot_normalized below.
		sprite.centered = true
		sprite.position = Vector2.ZERO
		sprite.visible = false
		# Apply pivot_normalized: if the pivot is not at the centre
		# (0.5,0.5) we shift the sprite's offset so that scaling and
		# rotation behave correctly.  When centered=true, the origin is
		# the centre of the texture.  We convert the normalised pivot
		# into pixel space and subtract the difference.
		if obj_dict.has("pivot_normalized"):
			var pivot_n: Vector2 = Vector2(obj_dict["pivot_normalized"][0], obj_dict["pivot_normalized"][1])
			var tex_size := Vector2(tex.get_width(), tex.get_height())
			# pivot_n is in [0,1]; the default pivot when centered is (0.5,0.5).
			var delta: Vector2 = (pivot_n - Vector2(0.5, 0.5)) * tex_size
			sprite.offset = -delta
		var lbl: Label = Label.new()
		# Use display_name if available, fall back to id
		lbl.text = obj_dict["display_name"] if obj_dict.has("display_name") else obj_dict.get("id", "")
		# Optional: override font size
		lbl.add_theme_font_size_override("font_size", 100)
		lbl.visible = false
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		
		
		# Labels are children of the sprite and inherit its scale, which is
		# normalised by texture width (scale_factor = screen_px / img_w).
		# That made rendered font size inversely proportional to the source
		# image's pixel width — a 1430px texture drew its label at a third
		# the size of a 500px one.  Pre-multiplying by img_w / LABEL_REF_WIDTH
		# cancels the img_w term, leaving effective size proportional to
		# screen_px alone, so labels still grow and shrink with their object.
		# Zoom-independent, so it is set once here rather than per frame.
		var lbl_img_w: float = float(tex.get_width())
		if lbl_img_w > 0.0:
			lbl.scale = Vector2.ONE * (lbl_img_w / LABEL_REF_WIDTH)

		sprite.add_child(lbl)
		var shift_x : float
		var shift_y : float
		if obj_dict.has("position_shift"):
			shift_x = obj_dict.position_shift[0]
			shift_y = obj_dict.position_shift[1]
		lbl.position = Vector2(-600 + shift_x, -1000 + shift_y)
		labels.append(lbl)
		nominal_log_zoom.resize(objects.size())
		min_log_zoom_values.resize(objects.size())
		max_log_zoom_values.resize(objects.size())
		add_child(sprite)
		sprites.append(sprite)
	# Initialise arrays for thresholds to the same size as objects.
	


func _compute_ring_angles() -> void:
	# Lay the objects out on a ring around object 0.  Each object advances
	# one radian from the previous, plus EXTRA_ANGLE when neighbouring
	# objects are close in size and would otherwise crowd each other.
	# The ratio is taken from real_size_m directly rather than from pixel
	# radii: the two are mathematically identical (the metres-per-pixel
	# factor cancels) but the real-size form is evaluated once and is
	# therefore stable, whereas the pixel form re-rounded every frame.
	ring_angles.resize(objects.size())
	if objects.size() == 0:
		return
	ring_angles[0] = 0.0
	var cumulative_angle: float = -PI / 2.0
	for idx in range(1, objects.size()):
		var prev_size: float = objects[idx - 1]["real_size_m"]
		var size_i: float = objects[idx]["real_size_m"]
		var ratio: float = prev_size / size_i
		if ratio < 1.0:
			ratio = 1.0 / ratio
		var angle_step: float = 1.0
		if ratio < CLOSE_RATIO_THRESHOLD:
			angle_step += EXTRA_ANGLE
		cumulative_angle += angle_step
		ring_angles[idx] = cumulative_angle

func _compute_thresholds() -> void:
	# Determine the viewport width to compute target pixel sizes.  Use
	# get_visible_rect() to avoid including any camera zoom factor.
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var width_px := vp_size.x
	# The nominal pixel width for an object to occupy when fully visible.
	var target_px := width_px * NOMINAL_RATIO
	# Precompute thresholds for each object.
	for i in objects.size():
		var obj = objects[i]
		var real_size = obj["real_size_m"]
		# log(metres per pixel) at which the object is nominal size.
		nominal_log_zoom[i] = log(real_size / target_px)
		# At log_zoom values larger than this, the object becomes too small (< MIN_PX).
		min_log_zoom_values[i] = log(real_size / MIN_PX)
		# At log_zoom values smaller than this, the object becomes too large (> max display).
		max_log_zoom_values[i] = log(real_size / (target_px * MAX_DISPLAY_MULTIPLIER))
	# Update global bounds on the zoom manager.  Each object defines
	# a range [max_log_zoom_values[i], min_log_zoom_values[i]] in
	# which it is visible.  The overall allowed zoom range must
	# encompass all such ranges, so we take the minimum of the lower
	# bounds and the maximum of the upper bounds.
	var global_min
	var global_max 
	if zoom_manager != null and objects.size() > 0:
		global_min = max_log_zoom_values[0]
		global_max = min_log_zoom_values[0]
		for v in max_log_zoom_values:
			if v < global_min:
				global_min = v
		# global_max is the largest of the min_log_zoom values (zoom out limit).
		for v in min_log_zoom_values:
			if v > global_max:
				global_max = v
		zoom_manager.set_zoom_bounds(global_min, global_max)
		# Pick an initial zoom midway between the extremes.
		print(INITIAL_ZOOM)
		zoom_manager.set_initial_zoom(INITIAL_ZOOM)

	# Clamp the initial zoom to ensure it’s within the allowed range
	
	
func _on_viewport_size_changed() -> void:
	# Recompute thresholds when the viewport is resized.  This ensures
	# objects scale appropriately if the window size changes.
	_compute_thresholds()
	# Force update with the current zoom to apply new thresholds.
	if zoom_manager != null:
		_on_zoom_changed(zoom_manager.log_zoom_current)

func _on_zoom_changed(log_zoom: float) -> void:
	# Determine the target and fade out thresholds based on current
	# viewport width.  They are recomputed here in case the viewport
	# changed since the last computation.
	var vp_size: Vector2 = get_viewport().get_visible_rect().size
	var width_px := vp_size.x
	var target_px := width_px * NOMINAL_RATIO
	var fade_out_threshold := target_px * MAX_DISPLAY_MULTIPLIER

	# Track which object is closest to its nominal zoom.  Used for
	# debug UI.
	nearest_obj_idx = -1
	var nearest_delta: float = 1e30

	# Precompute metres_per_pixel once for efficiency.
	var metres_per_pixel := exp(log_zoom)
	# Arrays to store per‑object screen sizes and radii in pixels for
	# subsequent position calculations.
	var screen_px_arr: Array = []
	var radius_px_arr: Array = []

	# Loop through each object, computing its on‑screen size, updating
	# visibility, scaling, fading, and tracking the nearest object.
	for i in objects.size():
		var obj = objects[i]
		var sprite: Sprite2D = sprites[i]
		var real_size: float = obj["real_size_m"]
		# Pixels the object spans at the current zoom.  Larger log_zoom
		# means more metres per pixel (farther zoomed out).
		var screen_px: float = real_size / metres_per_pixel
		# Store for later distance computations.
		screen_px_arr.append(screen_px)
		var radius_px: float = screen_px * 0.5
		radius_px_arr.append(radius_px)
		# Visibility and culling based on pixel size.
		if screen_px < MIN_PX or screen_px > fade_out_threshold:
			sprite.visible = false
			continue
		# Object is within the visible range.
		sprite.visible = true
		# Determine scale factor so that the texture width matches
		# screen_px.  Use the texture's width for both axes to
		# preserve aspect ratio.
		var tex: Texture2D = sprite.texture
		var img_w: float = float(tex.get_width())
		# Avoid division by zero in case of missing texture.
		var scale_factor: float = 1.0
		if img_w > 0.0:
			scale_factor = screen_px / img_w
		sprite.scale = Vector2(scale_factor, scale_factor)
		# Fade in/out near thresholds.  Fade in when the object is
		# small (between MIN_PX and FADE_IN_PX).  Fade out when the
		# object is large (between 90% of fade_out_threshold and
		# 100%).
		var alpha: float = 1.0
		# Fade in from invisible at MIN_PX to opaque at FADE_IN_PX.
		if screen_px <= FADE_IN_PX:
			alpha = clamp((screen_px - MIN_PX) / (FADE_IN_PX - MIN_PX), 0.0, 1.0)
		# Fade out when near the maximum size.  Start fading when
		# reaching 90% of the maximum allowed size.
		var fade_start := fade_out_threshold * 0.9
		if screen_px >= fade_start:
			var fade_range := fade_out_threshold - fade_start
			alpha = min(alpha, clamp((fade_out_threshold - screen_px) / fade_range, 0.0, 1.0))
		# Apply the alpha via modulation.  Keep RGB intact.
#		var modulate_colour := sprite.modulate
#		modulate_colour.a = alpha
#		sprite.modulate = modulate_colour
		# Track nearest object by comparing the difference between
		# current log zoom and its nominal zoom.  The object with
		# minimal absolute difference is considered closest.
#		var delta_z: float = abs(log_zoom - nominal_log_zoom[i])
#		if delta_z < nearest_delta:
#			nearest_delta = delta_z
#			nearest_obj_idx = i
		
#		if i < labels.size():
#			labels[i].scale = Vector2(scale_factor * 12, scale_factor * 12)
	
		
		
	for i in objects.size():
		if i >= labels.size():
			continue
		var lbl: Label = labels[i]
		var sp: Sprite2D = sprites[i]
		lbl.visible = sp.visible
		if not sp.visible:
			continue
		# Use the precomputed radius in pixels to offset the label above the sprite
		var rad_px: float
		if i < radius_px_arr.size():
			rad_px = radius_px_arr[i]
		else:
			rad_px = 0.0
#		lbl.position = sp.position + Vector2(0.0, -(rad_px + 8.0)) 
		# Match the alpha of the label to the sprite so it fades in/out together
#		var lbl_mod: Color = lbl.modulate
#		lbl_mod.a = sp.modulate.a
#		lbl.modulate = lbl_mod
	
		
	# After processing all objects for visibility and scale, compute their
	# positions relative to the centre.  The first object (index 0)
	# remains centred.  Each subsequent object is placed at an angular
	# offset of -1 radian (clockwise) from the one before, with a
	# radial distance proportional to the sum of its radius and the
	# first object's radius.  A margin factor is used to prevent
	# overlapping.
	var MARGIN_FACTOR: float = 1.1
	if objects.size() > 0:
		# centre the first object
		sprites[0].position = Vector2.ZERO
		var radius0_px: float = radius_px_arr[0]
		for idx in range(1, objects.size()):
			var radius_i_px: float = radius_px_arr[idx]
			# Distance is based on the sum of the first object's radius and this object's radius.
			var distance_px: float = MARGIN_FACTOR * (radius0_px + radius_i_px)
			var dir_vec: Vector2 = Vector2(cos(ring_angles[idx]), sin(ring_angles[idx]))
			sprites[idx].position = dir_vec * distance_px


	# Update debug UI if present.
	if debug_label != null:
		var nearest_name := "None"
		if nearest_obj_idx >= 0 and nearest_obj_idx < objects.size():
			nearest_name = objects[nearest_obj_idx]["display_name"]
		# Reuse metres_per_pixel already computed.
		debug_label.text = "Metres per pixel: {0:.3e}\nNearest object: {1}\nlog_zoom: {2:.2f}".format([metres_per_pixel, nearest_name, log_zoom])
