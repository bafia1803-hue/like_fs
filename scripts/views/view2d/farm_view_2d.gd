extends Node2D
## Farma w widoku 2D: plac, przeszkody, krata zrzutu, punkty załadunku i stacja nasion,
## stany silosów i przepływy. Czyta dane mapy i stan gry przez interfejs świata.
const Profiler = preload("res://scripts/core/util/profiler.gd")

var query: RefCounted
var units: float = 40.0
var _map: Dictionary = {}
var _timer: float = 0.0


func configure(world_query: RefCounted) -> void:
	name = "Farm2D"
	query = world_query
	units = float(query.units())
	_map = query.map_data()
	queue_redraw()


func _process(delta: float) -> void:
	var started: int = Profiler.start()
	_process_measured(delta)
	Profiler.stop(Profiler.VIEW_2D, started)


func _process_measured(delta: float) -> void:
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
	for silo in query.silos():
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
	# plac sklepu
	var shop: Dictionary = query.shop_data()
	if shop.get("lot") is Dictionary:
		var lot := Rect2(_vec(shop["lot"]["origin_m"]) * units, _vec(shop["lot"]["size_m"]) * units)
		draw_rect(lot, Color("#f2f0e8"), false, 4.0)
		draw_string(font, lot.position + Vector2(0, -12), "Plac sklepu", HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color.WHITE)
	# skup zboża
	for point in query.sell_points():
		var polygon := _rect_polygon(point["area"])
		draw_colored_polygon(polygon, Color("#6b7d55"))
		_outline(polygon, Color("#9be37a"), 3.0)
		for index in range(1, 8):
			var ratio: float = float(index) / 8.0
			draw_line(polygon[0].lerp(polygon[3], ratio), polygon[1].lerp(polygon[2], ratio), Color("#41484c"), 2.0)
		draw_string(font, polygon[0] + Vector2(0, -12), str(point["name"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color.WHITE)
	# pola na sprzedaż
	var economy: RefCounted = query.economy()
	for grid in query.field_grids():
		if bool(grid.owned):
			continue
		var price: float = float(query.field_price(str(grid.field_id)))
		var center: Vector2 = grid.to_global(Vector2(grid.columns, grid.rows) * float(grid.cell_m) * units * 0.5)
		var text: String = "%s — na sprzedaż: %s" % [grid.field_name, economy.call("format", price)]
		draw_string(font, center + Vector2(-260, 0), text, HORIZONTAL_ALIGNMENT_CENTER, 520, 40, Color("#ffd98a"))
	# przeszkody
	for obstacle in _map.get("static_obstacles", []):
		var center: Vector2 = _vec(obstacle["center_m"]) * units
		var fill := Color("#9a8f80")
		var model: String = str(obstacle.get("visual", {}).get("model", ""))
		if model == "silo_tower":
			fill = Color("#c9c6bf")
		elif model == "barn":
			fill = Color("#b5503d")
		elif model == "shop_building":
			fill = Color("#3f8f9b")
		elif model == "grain_buyer":
			fill = Color("#a27a4c")
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
	for state in query.farm_points():
		flows[str(state["definition"]["id"])] = float(state["flow_l_per_s"])
	for kind in ["load_points", "supply_points"]:
		for point in _map.get(kind, []):
			var polygon := _rect_polygon(point["area"])
			var color := Color("#ffd166") if kind == "load_points" else Color("#7fd1ff")
			draw_colored_polygon(polygon, Color(color, 0.18))
			_outline(polygon, color, 3.0)
			var flowing: bool = float(flows.get(str(point["id"]), 0.0)) > 0.0
			if point.has("outlet_m"):
				var outlet: Vector2 = _vec(point["outlet_m"]) * units
				draw_circle(outlet, 0.35 * units, Color("#f2c64d") if flowing else Color("#4d4846"))
			elif flowing:
				draw_circle(_vec(point["area"]["center_m"]) * units, 0.5 * units, Color("#7fd1ff"))
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
