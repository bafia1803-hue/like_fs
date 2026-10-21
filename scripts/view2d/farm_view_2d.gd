extends Node2D
## Farma w widoku 2D: plac, przeszkody, krata zrzutu, punkty załadunku i stacja nasion,
## stany silosów i przepływy. Czyta dane mapy i stan gry przez interfejs świata.

var world: Node
var units: float = 40.0
var _map: Dictionary = {}
var _timer: float = 0.0


func configure(world_node: Node) -> void:
	name = "Farm2D"
	world = world_node
	units = float(world.call("get_units_per_meter"))
	_map = world.call("get_map_data")
	queue_redraw()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= 0.25:
		_timer = 0.0
		queue_redraw()


func _draw() -> void:
	var font: Font = ThemeDB.fallback_font
	for surface in _map.get("surfaces", []):
		var rect := Rect2(_vec(surface["origin_m"]) * units, _vec(surface["size_m"]) * units)
		draw_rect(rect, Color(str(surface.get("color", "#cdbfa6"))))
		draw_rect(rect, Color("#8f8471"), false, 2.0)
	# kraty zrzutu z zawartością silosu
	var amounts: Dictionary = {}
	for silo in world.call("get_silos"):
		amounts[str(silo["id"])] = silo
	for point in _map.get("unload_points", []):
		var polygon := _rect_polygon(point["area"])
		draw_colored_polygon(polygon, Color(str(point.get("color", "#727a80"))))
		_outline(polygon, Color("#e9cf73"), 3.0)
		for index in range(1, 8):
			var ratio: float = float(index) / 8.0
			draw_line(polygon[0].lerp(polygon[3], ratio), polygon[1].lerp(polygon[2], ratio), Color("#41484c"), 2.0)
		var silo: Dictionary = amounts.get(str(point["id"]), {})
		var label: String = "%s  %.0f / %.0f l" % [point["name"], float(silo.get("amount_l", 0.0)), float(silo.get("capacity_l", 0.0))]
		draw_string(font, polygon[0] + Vector2(0, -12), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color.WHITE)
	# przeszkody
	for obstacle in _map.get("static_obstacles", []):
		var center: Vector2 = _vec(obstacle["center_m"]) * units
		var fill := Color("#9a8f80")
		var model: String = str(obstacle.get("visual", {}).get("model", ""))
		if model == "silo_tower":
			fill = Color("#c9c6bf")
		elif model == "barn":
			fill = Color("#b5503d")
		if str(obstacle["shape"]) == "circle":
			var radius: float = float(obstacle["radius_m"]) * units
			draw_circle(center, radius, fill)
			draw_arc(center, radius, 0, TAU, 32, Color("#4d4846"), 2.0)
		else:
			var polygon := _rect_polygon({"center_m": obstacle["center_m"], "width_m": obstacle["width_m"],
				"length_m": obstacle["length_m"], "rotation_deg": obstacle.get("rotation_deg", 0.0)})
			draw_colored_polygon(polygon, fill)
			_outline(polygon, Color("#4d4846"), 2.0)
		if float(obstacle.get("radius_m", 1.0)) > 1.0 or str(obstacle["shape"]) == "rectangle":
			draw_string(font, center + Vector2(-40, 6), str(obstacle.get("name", "")), HORIZONTAL_ALIGNMENT_CENTER, 80, 18, Color.WHITE)
	# punkty załadunku i stacje nasion
	var flows: Dictionary = {}
	for state in world.call("get_farm_points"):
		flows[str(state["definition"]["id"])] = float(state["flow_l_per_s"])
	for kind in ["load_points", "seed_points"]:
		for point in _map.get(kind, []):
			var polygon := _rect_polygon(point["area"])
			var color := Color("#ffd166") if kind == "load_points" else Color("#7fd1ff")
			draw_colored_polygon(polygon, Color(color, 0.18))
			_outline(polygon, color, 3.0)
			var outlet: Vector2 = _vec(point["outlet_m"]) * units
			var flowing: bool = float(flows.get(str(point["id"]), 0.0)) > 0.0
			draw_circle(outlet, 0.35 * units, Color("#f2c64d") if flowing else Color("#4d4846"))
			draw_string(font, polygon[0] + Vector2(0, -10), str(point["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)


func _rect_polygon(area: Dictionary) -> PackedVector2Array:
	var half := Vector2(float(area["width_m"]), float(area["length_m"])) * units * 0.5
	var pose := Transform2D(deg_to_rad(float(area.get("rotation_deg", 0.0))), _vec(area["center_m"]) * units)
	return PackedVector2Array([pose * Vector2(-half.x, -half.y), pose * Vector2(half.x, -half.y),
		pose * half, pose * Vector2(-half.x, half.y)])


func _outline(polygon: PackedVector2Array, color: Color, width: float) -> void:
	var closed := polygon.duplicate()
	closed.append(polygon[0])
	draw_polyline(closed, color, width, true)


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
