extends Node2D
## Trasy w widoku 2D: nagrywany przejazd (zielona linia) oraz – przy oczekującym przejeździe –
## półprzezroczysty „zestaw widmo” na miejscu startu z czerwonym znacznikiem.
## Czyta record_path i armed z RouteSystem; pozę widma liczy RoutePreview.

const RoutePreviewScript = preload("res://scripts/routes/route_preview.gd")

var routes: Node2D
var units: float = 40.0
var models: Dictionary = {}
var _record := Line2D.new()
var _record_revision: int = -1
var _armed_id: String = ""
var _parts: Array = []


func configure(route_system: Node2D, scale_units: float, catalog_models: Dictionary = {}) -> void:
	name = "Routes2D"
	routes = route_system
	units = scale_units
	models = catalog_models
	_record.default_color = Color("66ffb0")
	_record.width = 0.07 * units
	add_child(_record)


func _process(_delta: float) -> void:
	if not is_instance_valid(routes):
		return
	if int(routes.get("record_revision")) != _record_revision:
		_record_revision = int(routes.get("record_revision"))
		var points := PackedVector2Array()
		for p in routes.get("record_path"):
			points.append(p * units)
		_record.points = points
	var armed: Dictionary = routes.get("armed")
	var armed_id: String = str(armed.get("route", {}).get("id", "")) if not armed.is_empty() else ""
	if armed_id != _armed_id:
		_armed_id = armed_id
		_parts = []
		if not armed.is_empty():
			var preview = RoutePreviewScript.new()
			if preview.setup(armed["route"], models):
				_parts = preview.parts_at(0.0)
		queue_redraw()


func _draw() -> void:
	if _parts.is_empty():
		return
	# Cały zestaw jednym kolorem z tą samą przezroczystością (bez nakładania się części).
	var color := Color(0.75, 0.88, 1.0, 0.45)
	for part in _parts:
		var model: Dictionary = part["model"]
		var body: Transform2D = part["transforms"]["body"]
		var dims: Dictionary = model["dimensions"]
		var half := Vector2(float(dims["width_m"]), float(dims["length_m"])) * 0.5
		var polygon := PackedVector2Array()
		for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
			polygon.append((body * corner) * units)
		draw_colored_polygon(polygon, color)
		polygon.append(polygon[0])
		draw_polyline(polygon, Color(1, 1, 1, 0.8), 2.0)
	var start: Transform2D = _parts[0]["transforms"]["body"]
	var p: Vector2 = start.origin * units
	draw_circle(p, 0.9 * units, Color(1.0, 0.2, 0.15, 0.55))
	draw_line(p, p + Vector2.UP.rotated(start.get_rotation()) * 2.5 * units, Color(1.0, 0.25, 0.2, 0.9), 4.0)
