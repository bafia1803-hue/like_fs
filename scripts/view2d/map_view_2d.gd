extends Node2D

var last_error: String = ""

var _world_rect: Rect2 = Rect2()
var _ground_color: Color = Color("#558a45")
var _field_draw_data: Array[Dictionary] = []
var _configured: bool = false


func configure(
	map_data: Dictionary,
	units_per_meter: float
) -> bool:
	last_error = ""
	_configured = false
	_field_draw_data.clear()

	if units_per_meter <= 0.0:
		return _fail("Skala świata musi być dodatnia.")

	var bounds_value: Variant = map_data.get("world_bounds")
	if not bounds_value is Dictionary:
		return _fail("Mapa nie zawiera world_bounds.")

	var bounds: Dictionary = bounds_value
	if not _valid_rectangle(bounds):
		return _fail("Niepoprawny prostokąt world_bounds.")

	_world_rect = Rect2(
		_vector(bounds["origin_m"]) * units_per_meter,
		_vector(bounds["size_m"]) * units_per_meter
	)

	var surface_value: Variant = map_data.get("default_surface")
	if not surface_value is Dictionary:
		return _fail("Mapa nie zawiera default_surface.")

	var surface: Dictionary = surface_value
	_ground_color = Color.from_string(
		str(surface.get("color", "#558a45")),
		Color("#558a45")
	)

	var fields_value: Variant = map_data.get("fields")
	if not fields_value is Array:
		return _fail("Mapa nie zawiera tablicy fields.")

	for field_value in fields_value:
		if not field_value is Dictionary:
			return _fail("Niepoprawny wpis pola.")

		var field: Dictionary = field_value
		var geometry_value: Variant = field.get("geometry")

		if not geometry_value is Dictionary:
			return _fail("Pole nie zawiera geometry.")

		var geometry: Dictionary = geometry_value
		if not _valid_rectangle(geometry):
			return _fail(
				"Niepoprawna geometria pola: "
				+ str(field.get("id", "?"))
			)

		var soil_value: Variant = field.get("soil_surface")
		if not soil_value is Dictionary:
			return _fail("Pole nie zawiera soil_surface.")

		var soil: Dictionary = soil_value
		var rotation_value: Variant = geometry.get("rotation_deg", 0)

		if not _is_number(rotation_value):
			return _fail("Obrót pola musi być liczbą.")

		_field_draw_data.append({
			"origin": _vector(geometry["origin_m"]) * units_per_meter,
			"size": _vector(geometry["size_m"]) * units_per_meter,
			"rotation": deg_to_rad(float(rotation_value)),
			"color": Color.from_string(
				str(soil.get("color", "#795137")),
				Color("#795137")
			)
		})

	_configured = true
	queue_redraw()
	return true


func get_world_rect() -> Rect2:
	return _world_rect


func _draw() -> void:
	if not _configured:
		return

	draw_rect(_world_rect, _ground_color)

	for field in _field_draw_data:
		var origin: Vector2 = field["origin"]
		var field_size: Vector2 = field["size"]
		var field_rotation: float = field["rotation"]
		var field_color: Color = field["color"]

		draw_set_transform(origin, field_rotation)

		var field_rect := Rect2(Vector2.ZERO, field_size)
		draw_rect(field_rect, field_color)

		# Ujemna szerokość daje cienką linię niezależną od zoomu.
		draw_rect(
			field_rect,
			field_color.darkened(0.3),
			false,
			-1.0
		)

	draw_set_transform(Vector2.ZERO, 0.0)

	draw_rect(
		_world_rect,
		Color("#263e24"),
		false,
		-1.0
	)


func _valid_rectangle(data: Dictionary) -> bool:
	if data.get("shape") != "rectangle":
		return false

	if not _valid_pair(data.get("origin_m")):
		return false

	if not _valid_pair(data.get("size_m")):
		return false

	var size_m: Vector2 = _vector(data["size_m"])
	return size_m.x > 0.0 and size_m.y > 0.0


func _valid_pair(value: Variant) -> bool:
	if not value is Array:
		return false

	var pair: Array = value
	if pair.size() != 2:
		return false

	return _is_number(pair[0]) and _is_number(pair[1])


func _is_number(value: Variant) -> bool:
	if not (value is int or value is float):
		return false

	return is_finite(float(value))


func _vector(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func _fail(message: String) -> bool:
	last_error = message
	push_error("MapView: " + message)
	return false
