extends Node2D
## Trasy w widoku 2D: nagrywana (zielona) i podgląd wybranej (żółta) z okręgiem startu.
## Czyta record_path / preview_path z RouteSystem.

var routes: Node2D
var units: float = 40.0
var _record := Line2D.new()
var _preview := Line2D.new()
var _record_revision: int = -1
var _preview_revision: int = -1


func configure(route_system: Node2D, scale_units: float) -> void:
	name = "Routes2D"
	routes = route_system
	units = scale_units
	for pair in [[_record, Color("66ffb0")], [_preview, Color("ffd166")]]:
		var line: Line2D = pair[0]
		line.default_color = pair[1]
		line.width = 0.07 * units
		add_child(line)


func _process(_delta: float) -> void:
	if not is_instance_valid(routes):
		return
	if int(routes.get("record_revision")) != _record_revision:
		_record_revision = int(routes.get("record_revision"))
		_record.points = _scaled(routes.get("record_path"))
	if int(routes.get("preview_revision")) != _preview_revision:
		_preview_revision = int(routes.get("preview_revision"))
		_preview.points = _scaled(routes.get("preview_path"))
		queue_redraw()


func _scaled(points: PackedVector2Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p in points:
		result.append(p * units)
	return result


func _draw() -> void:
	var selected: Dictionary = routes.call("get_preview_route") if is_instance_valid(routes) else {}
	if selected.is_empty() or not selected.get("samples") is Array or (selected["samples"] as Array).is_empty():
		return
	var start_point: Array = selected["samples"][0]
	var p := Vector2(start_point[1], start_point[2]) * units
	var radius: float = float(routes.get("settings").get("start_distance_m", 3.0))
	draw_arc(p, radius * units, 0, TAU, 48, Color(1, 0.8, 0.3, 0.65), 2.0)
	draw_line(p, p + Vector2.UP.rotated(start_point[3]) * units, Color.YELLOW, 3.0)
