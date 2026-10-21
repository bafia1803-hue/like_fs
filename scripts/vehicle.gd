extends RigidBody2D

const TiresScript = preload("res://scripts/tires.gd")
const MachineViewScript = preload("res://scripts/machine_view.gd")

var definition: Dictionary = {}
var instance_state: Dictionary = {}

var _units_per_meter: float = 40.0
var _drive: Dictionary = {}
var _physics: Dictionary = {}
var _axles: Array = []

var _view: Node2D

var _throttle_command: float = 0.0
var _steering_command: float = 0.0
var _brake_command: bool = true
var _steering_input: float = 0.0

var _load_weight_sum: float = 0.0
var _driven_wheel_count: int = 0
var _wheel_count: int = 0
var _largest_steering_angle_deg: float = 1.0
var _visual_steering_active: bool = false
var _visual_steering_override: float = 0.0


func configure(
	model_data: Dictionary,
	saved_state: Dictionary,
	materials: Array,
	units_per_meter: float
) -> void:
	definition = model_data
	instance_state = saved_state
	_units_per_meter = units_per_meter

	_drive = definition["drive"]
	_physics = definition["physics"]
	_axles = definition["axles"]

	name = str(instance_state["instance_id"])

	# Widok z góry: grawitacja nie przesuwa pojazdu po ekranie.
	gravity_scale = 0.0

	# Opory obliczamy w modelu opon.
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0

	center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector2.ZERO

	collision_layer = 1
	collision_mask = 1
	continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE

	var contact_material := PhysicsMaterial.new()
	contact_material.friction = 0.5
	contact_material.bounce = 0.0
	physics_material_override = contact_material

	mass = _calculate_mass(materials)

	var saved_transform: Dictionary = instance_state["transform"]
	position = _vector(saved_transform["position_m"]) * _units_per_meter
	rotation = deg_to_rad(float(saved_transform["rotation_deg"]))

	var motion: Dictionary = instance_state["motion"]
	linear_velocity = (
		_vector(motion["linear_velocity_m_per_s"])
		* _units_per_meter
	)
	angular_velocity = deg_to_rad(
		float(motion["angular_velocity_deg_per_s"])
	)

	_steering_input = clampf(
		float(instance_state.get("steering_input", 0.0)),
		-1.0,
		1.0
	)
	_brake_command = bool(
		instance_state.get("parking_brake_engaged", true)
	)

	for axle_value in _axles:
		var axle: Dictionary = axle_value

		_load_weight_sum += float(axle["load_weight"])
		_wheel_count += 2

		if bool(axle["driven"]):
			_driven_wheel_count += 2

		if bool(axle["steerable"]):
			_largest_steering_angle_deg = maxf(
				_largest_steering_angle_deg,
				float(axle["max_steering_deg"])
			)

	assert(_wheel_count > 0, "Pojazd musi mieć koła.")
	assert(_driven_wheel_count > 0, "Pojazd musi mieć napędzaną oś.")
	assert(_load_weight_sum > 0.0, "Niepoprawne obciążenia osi.")

	_create_collision()
	_create_view()


func set_controls(
	throttle: float,
	steering: float,
	braking: bool
) -> void:
	var brake_changed: bool = braking != _brake_command

	_throttle_command = clampf(throttle, -1.0, 1.0)
	_steering_command = clampf(steering, -1.0, 1.0)
	_brake_command = braking

	if (
		not is_zero_approx(_throttle_command)
		or not is_zero_approx(_steering_command)
		or brake_changed
	):
		sleeping = false


func get_speed_kmh() -> float:
	var forward: Vector2 = Vector2.UP.rotated(global_rotation)
	return linear_velocity.dot(forward) / _units_per_meter * 3.6


func _physics_process(delta: float) -> void:
	var previous_steering: float = _steering_input

	var steering_rate: float = float(_drive["steering_rate_deg_s"])

	if is_zero_approx(_steering_command):
		steering_rate = float(_drive["steering_return_deg_s"])

	_steering_input = move_toward(
		_steering_input,
		_steering_command,
		steering_rate / _largest_steering_angle_deg * delta
	)

	instance_state["steering_input"] = _steering_input
	instance_state["parking_brake_engaged"] = _brake_command

	# Aktualizujemy stan w pamięci. Zapis na dysk dojdzie później.
	var saved_transform: Dictionary = instance_state["transform"]
	saved_transform["position_m"] = [
		position.x / _units_per_meter,
		position.y / _units_per_meter
	]
	saved_transform["rotation_deg"] = rad_to_deg(rotation)

	var motion: Dictionary = instance_state["motion"]
	motion["linear_velocity_m_per_s"] = [
		linear_velocity.x / _units_per_meter,
		linear_velocity.y / _units_per_meter
	]
	motion["angular_velocity_deg_per_s"] = rad_to_deg(angular_velocity)

	if not is_equal_approx(previous_steering, _steering_input):
		_view.queue_redraw()


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _axles.is_empty():
		return

	var body_angle: float = state.transform.get_rotation()
	var forward: Vector2 = Vector2.UP.rotated(body_angle)

	var speed_m_per_s: float = (
		state.linear_velocity.dot(forward)
		/ _units_per_meter
	)

	# Wciśnięcie przeciwnego kierunku podczas jazdy hamuje.
	var braking: bool = (
		_brake_command
		or _throttle_command * speed_m_per_s < -0.1
	)

	var total_drive_force: float = 0.0

	if not braking and not is_zero_approx(_throttle_command):
		var speed_limit: float = float(_drive["forward_speed_kmh"]) / 3.6

		if _throttle_command < 0.0:
			speed_limit = float(_drive["reverse_speed_kmh"]) / 3.6

		var speed_in_drive_direction: float = (
			speed_m_per_s * signf(_throttle_command)
		)

		# Przy zbliżaniu się do limitu siła napędu maleje.
		var available_drive: float = clampf(
			1.0 - speed_in_drive_direction / maxf(speed_limit, 0.01),
			0.0,
			1.0
		)

		total_drive_force = (
			_throttle_command
			* float(_drive["engine_force_n"])
			* available_drive
		)

	var dimensions: Dictionary = definition["dimensions"]
	var body_length: float = float(dimensions["length_m"])

	for axle_value in _axles:
		var axle: Dictionary = axle_value

		var load_fraction: float = (
			float(axle["load_weight"])
			/ _load_weight_sum
			/ 2.0
		)

		var wheel_angle: float = body_angle

		if bool(axle["steerable"]):
			wheel_angle += deg_to_rad(
				float(axle["max_steering_deg"])
				* float(axle["steering_ratio"])
				* _steering_input
			)

		var wheel_drive: float = 0.0
		if bool(axle["driven"]):
			wheel_drive = total_drive_force / float(_driven_wheel_count)

		var wheel_brake: float = 0.0
		if braking:
			wheel_brake = float(_drive["brake_force_n"]) * load_fraction

		for side in [-1.0, 1.0]:
			var wheel_local := Vector2(
				side * float(axle["track_m"]) / 2.0,
				-body_length / 2.0 + float(axle["distance_from_front_m"])
			) * _units_per_meter

			var wheel_offset: Vector2 = wheel_local.rotated(body_angle)

			TiresScript.apply_wheel_force(
				state,
				wheel_offset,
				wheel_angle,
				mass * load_fraction,
				wheel_drive,
				wheel_brake,
				float(_physics["rolling_resistance_coefficient"]),
				float(axle["lateral_grip"]),
				float(_physics["lateral_response_time_s"]),
				_wheel_count,
				_units_per_meter
			)


func _create_collision() -> void:
	var collision_data: Dictionary = _physics["body_collision"]

	var shape := RectangleShape2D.new()
	shape.size = Vector2(
		float(collision_data["width_m"]),
		float(collision_data["length_m"])
	) * _units_per_meter

	var collider := CollisionShape2D.new()
	collider.name = "BodyCollision"
	collider.shape = shape
	collider.position = (
		_vector(collision_data["center_m"])
		* _units_per_meter
	)
	collider.rotation = deg_to_rad(
		float(collision_data["rotation_deg"])
	)

	add_child(collider)


func _create_view() -> void:
	var visual = MachineViewScript.new()
	visual.configure(definition, instance_state, _units_per_meter)

	# Pozycję świata przechowuje ciało fizyczne.
	# Jego widok musi znajdować się lokalnie w punkcie 0,0.
	visual.name = "Visual"
	visual.position = Vector2.ZERO
	visual.rotation = 0.0

	add_child(visual)
	_view = visual


func _calculate_mass(materials: Array) -> float:
	var result: float = float(_physics["empty_mass_kg"])
	var storages: Dictionary = instance_state["storages"]

	for storage_id in storages:
		var storage: Dictionary = storages[storage_id]
		var amount_l: float = float(storage["amount_l"])

		if amount_l <= 0.0:
			continue

		for material_value in materials:
			var material: Dictionary = material_value

			if material["id"] == storage["material_id"]:
				result += (
					amount_l
					* float(material["bulk_density_kg_per_l"])
				)
				break

	return result


func _vector(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


## Wyłącznie wizualny skręt dla odtwarzacza; fizyka nadal używa _steering_input.
func get_recorded_steering() -> float:
	return _steering_input

## Skręt kół do pokazania w widoku (2D i 3D): nagrany podczas odtwarzania trasy, inaczej bieżący.
func get_visual_steering() -> float:
	return _visual_steering_override if _visual_steering_active else _steering_input

func set_route_visual_steering(value: float) -> void:
	_visual_steering_active = true
	_visual_steering_override = clampf(value, -1.0, 1.0)
	if is_instance_valid(_view):
		_view.call("set_steering_override", value)

func clear_route_visual_steering() -> void:
	_visual_steering_active = false
	if is_instance_valid(_view):
		_view.call("clear_steering_override")
