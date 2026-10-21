extends Node2D
## Wyłącznie geometria i animacja. Rura nie ma żadnego CollisionObject2D.
const Storage = preload("res://scripts/grain_storage.gd")
var config: Dictionary = {}
var state: Dictionary = {}
var units: float = 40.0
var extension: float = 0.0
var idle_seconds: float = 0.0
var flow_l_per_s: float = 0.0

func configure(data: Dictionary, saved_state: Dictionary, world_units: float) -> void:
	config = data
	state = saved_state
	units = world_units
	extension = clampf(float(state.get("extension", 0.0)), 0.0, 1.0)
	idle_seconds = maxf(0.0, float(state.get("idle_seconds", 0.0)))
	z_index = 10
	queue_redraw()

## Zwraca liczbę sekund tego kroku, przez które rura była całkowicie otwarta.
func advance(want_open: bool, delta: float) -> float:
	var open_seconds: float = 0.0
	if want_open:
		idle_seconds = 0.0
		var duration: float = maxf(0.001, float(config["extend_seconds"]))
		var remaining: float = (1.0 - extension) * duration
		extension = minf(1.0, extension + delta / duration)
		if extension >= 1.0:
			open_seconds = maxf(0.0, delta - remaining)
	else:
		var hold: float = minf(delta, maxf(0.0, float(config.get("close_delay_seconds", 0.0)) - idle_seconds))
		idle_seconds += delta
		if extension >= 1.0:
			open_seconds = hold
		var duration: float = maxf(0.001, float(config["retract_seconds"]))
		extension = maxf(0.0, extension - (delta - hold) / duration)
	state["extension"] = extension
	state["idle_seconds"] = idle_seconds
	queue_redraw()
	return open_seconds

func _mirror(point: Vector2) -> Vector2:
	return Vector2(-point.x, point.y) if str(config["side"]) == "right" else point

func pivot_local() -> Vector2:
	return _mirror(Storage.vector(config["pivot_in_body_m"])) * units

func tip_local() -> Vector2:
	var angle: float = lerpf(float(config["folded_angle_deg"]), float(config["deployed_angle_deg"]), extension)
	var direction := Vector2.from_angle(deg_to_rad(angle))
	return pivot_local() + _mirror(direction) * float(config["length_m"]) * units

func outlet_world() -> Vector2:
	return to_global(tip_local())

func detection_polygon() -> PackedVector2Array:
	var area: Dictionary = config["detection_area"]
	var polygon: PackedVector2Array = Storage.rectangle(Transform2D.IDENTITY, area, units)
	for index in polygon.size():
		polygon[index] = to_global(_mirror(polygon[index]))
	return polygon

func set_flow(value: float) -> void:
	flow_l_per_s = value
	queue_redraw()

func _draw() -> void:
	if config.is_empty():
		return
	if bool(config.get("show_detection_area", false)):
		var polygon: PackedVector2Array = detection_polygon()
		for index in polygon.size():
			polygon[index] = to_local(polygon[index])
		draw_colored_polygon(polygon, Color(0.2, 0.8, 1.0, 0.12))
		polygon.append(polygon[0])
		draw_polyline(polygon, Color(0.2, 0.8, 1.0, 0.6), 1.5)
	var pivot: Vector2 = pivot_local()
	var tip: Vector2 = tip_local()
	var width: float = maxf(2.0, float(config.get("width_m", 0.18)) * units)
	draw_line(pivot, tip, Color("#333638"), width + 3.0, true)
	draw_line(pivot, tip, Color(str(config.get("color", "#ddd7c5"))), width, true)
	draw_circle(pivot, width * 0.7, Color("#626971"))
	draw_circle(tip, width * 0.65, Color("#34383a"))
	if flow_l_per_s > 0.0:
		draw_circle(tip, width * 0.45, Color("#f2c64d"))
