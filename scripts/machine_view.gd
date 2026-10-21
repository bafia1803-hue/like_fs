extends Node2D

# Definicja modelu służy wyłącznie do odczytu.
var definition: Dictionary = {}

# Stan konkretnego egzemplarza.
# To ten sam słownik, który znajduje się w session.
var instance_state: Dictionary = {}

var show_work_area: bool = true

var _units_per_meter: float = 40.0
var _body_size: Vector2 = Vector2.ZERO
var _body_color: Color = Color.WHITE
var _configured: bool = false
var _steering_override_enabled: bool = false
var _steering_override: float = 0.0


func configure(
	model_data: Dictionary,
	saved_state: Dictionary,
	units_per_meter: float
) -> void:
	definition = model_data
	instance_state = saved_state
	_units_per_meter = units_per_meter

	var dimensions: Dictionary = definition["dimensions"]

	_body_size = Vector2(
		float(dimensions["width_m"]),
		float(dimensions["length_m"])
	) * _units_per_meter

	var visual: Dictionary = definition["visual"]
	_body_color = Color.from_string(
		str(visual.get("body_color", "#888888")),
		Color.GRAY
	)

	name = str(instance_state["instance_id"])

	var saved_transform: Dictionary = instance_state["transform"]
	position = _vector(saved_transform["position_m"]) * _units_per_meter
	rotation = deg_to_rad(float(saved_transform["rotation_deg"]))

	_configured = true
	queue_redraw()


func _draw() -> void:
	if not _configured:
		return

	_draw_drawbar()
	_draw_body()
	_draw_axles()
	_draw_hitches()

	if show_work_area:
		_draw_work_area()

	draw_set_transform(Vector2.ZERO, 0.0)


func _draw_body() -> void:
	draw_set_transform(Vector2.ZERO, 0.0)

	var body_rect := Rect2(-_body_size / 2.0, _body_size)

	draw_rect(body_rect, _body_color)
	draw_rect(
		body_rect,
		_body_color.darkened(0.4),
		false,
		2.0
	)

	# Żółta krawędź wskazuje przód maszyny.
	draw_line(
		Vector2(-_body_size.x / 2.0, -_body_size.y / 2.0),
		Vector2(_body_size.x / 2.0, -_body_size.y / 2.0),
		Color("#ffe071"),
		4.0
	)


func _draw_drawbar() -> void:
	draw_set_transform(Vector2.ZERO, 0.0)

	if definition.has("front_carriage"):
		var carriage: Dictionary = definition["front_carriage"]
		var drawbar: Dictionary = carriage["drawbar"]

		var pivot: Vector2 = (
			_vector(carriage["pivot_in_body_m"])
			* _units_per_meter
		)

		var drawbar_angle: float = _carriage_angle()
		var drawbar_end: Vector2 = pivot + (
			Vector2.UP.rotated(drawbar_angle)
			* float(drawbar["length_m"])
			* _units_per_meter
		)

		draw_line(
			pivot,
			drawbar_end,
			Color("#bfc4ca"),
			float(drawbar["width_m"]) * _units_per_meter
		)

	elif definition.has("drawbar"):
		var drawbar: Dictionary = definition["drawbar"]

		var drawbar_start := Vector2(
			0.0,
			-_body_size.y / 2.0
		)

		var drawbar_end: Vector2 = drawbar_start + (
			Vector2.UP
			* float(drawbar["length_m"])
			* _units_per_meter
		)

		draw_line(
			drawbar_start,
			drawbar_end,
			Color("#bfc4ca"),
			float(drawbar["width_m"]) * _units_per_meter
		)


func _draw_axles() -> void:
	var dimensions: Dictionary = definition["dimensions"]
	var body_length_m: float = float(dimensions["length_m"])
	var steering_input: float = clampf(
		_steering_override if _steering_override_enabled else float(instance_state.get("steering_input", 0.0)),
		-1.0,
		1.0
	)

	for axle_value in definition["axles"]:
		var axle: Dictionary = axle_value

		var axle_center := Vector2(
			0.0,
			(
				-body_length_m / 2.0
				+ float(axle["distance_from_front_m"])
			) * _units_per_meter
		)

		var axle_angle: float = 0.0

		# Przednia oś przyczepy obraca się razem z wózkiem.
		if str(axle.get("body_member", "body")) == "front_carriage":
			var carriage: Dictionary = definition["front_carriage"]

			axle_center = (
				_vector(carriage["pivot_in_body_m"])
				* _units_per_meter
			)
			axle_angle = _carriage_angle()

		var half_track: float = (
			float(axle["track_m"])
			* _units_per_meter
			/ 2.0
		)

		var tire_size := Vector2(
			float(axle["tire_width_m"]),
			float(axle["tire_length_m"])
		) * _units_per_meter

		var wheel_steering_angle: float = 0.0

		if bool(axle.get("steerable", false)):
			wheel_steering_angle = deg_to_rad(
				float(axle["max_steering_deg"])
				* float(axle["steering_ratio"])
				* steering_input
			)

		# Belka osi.
		draw_set_transform(axle_center, axle_angle)
		draw_line(
			Vector2(-half_track, 0.0),
			Vector2(half_track, 0.0),
			Color("#93999e"),
			3.0
		)

		# Lewe i prawe koło.
		for side in [-1.0, 1.0]:
			var wheel_position: Vector2 = axle_center + (
				Vector2(side * half_track, 0.0)
				.rotated(axle_angle)
			)

			draw_set_transform(
				wheel_position,
				axle_angle + wheel_steering_angle
			)

			var tire_rect := Rect2(-tire_size / 2.0, tire_size)

			draw_rect(tire_rect, Color("#20242a"))
			draw_rect(
				tire_rect,
				Color("#a5abb3"),
				false,
				1.5
			)

			# Znacznik kierunku koła.
			draw_line(
				Vector2(0.0, -tire_size.y * 0.35),
				Vector2(0.0, tire_size.y * 0.35),
				Color("#656b73"),
				2.0
			)

	draw_set_transform(Vector2.ZERO, 0.0)


func _draw_hitches() -> void:
	draw_set_transform(Vector2.ZERO, 0.0)

	for port_value in definition["hitch_ports"]:
		var port: Dictionary = port_value

		var point: Vector2 = (
			_vector(port["position_m"])
			* _units_per_meter
		)

		if str(port.get("member", "body")) == "front_carriage":
			var carriage: Dictionary = definition["front_carriage"]
			var pivot: Vector2 = (
				_vector(carriage["pivot_in_body_m"])
				* _units_per_meter
			)

			point = pivot + point.rotated(_carriage_angle())

		var port_color := Color("#70e7ff")
		if str(port["role"]) == "plug":
			port_color = Color("#ffbd69")

		draw_circle(point, 0.12 * _units_per_meter, port_color)


func _draw_work_area() -> void:
	var work_value: Variant = definition.get("work")

	if not work_value is Dictionary:
		return

	var work: Dictionary = work_value
	var area: Dictionary = work["area"]

	if str(area.get("shape", "")) != "rectangle":
		return

	var area_center: Vector2 = (
		_vector(area["center_m"])
		* _units_per_meter
	)

	var area_size := Vector2(
		float(area["width_m"]),
		float(area["length_m"])
	) * _units_per_meter

	var area_rotation: float = deg_to_rad(
		float(area.get("rotation_deg", 0.0))
	)

	draw_set_transform(area_center, area_rotation)

	var area_rect := Rect2(-area_size / 2.0, area_size)

	draw_rect(
		area_rect,
		Color(0.2, 1.0, 0.8, 0.15)
	)
	draw_rect(
		area_rect,
		Color("#55ffd0"),
		false,
		2.0
	)

	draw_set_transform(Vector2.ZERO, 0.0)


func _carriage_angle() -> float:
	var articulated: Dictionary = instance_state.get(
		"articulated_state", {}
	)
	var carriage_state: Dictionary = articulated.get(
		"front_carriage", {}
	)

	return deg_to_rad(
		float(carriage_state.get("relative_rotation_deg", 0.0))
	)


func _vector(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func set_steering_override(value: float) -> void:
	value = clampf(value, -1.0, 1.0)
	if not _steering_override_enabled or not is_equal_approx(value, _steering_override):
		_steering_override_enabled = true
		_steering_override = value
		queue_redraw()

func clear_steering_override() -> void:
	if _steering_override_enabled:
		_steering_override_enabled = false
		queue_redraw()
