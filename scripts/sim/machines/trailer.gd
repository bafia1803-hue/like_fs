extends Node2D
## Węzeł organizacyjny pozostaje w (0,0). Poruszają się jego dwa ciała.
## Wszystkie pozycje zapisu odnoszą się do nadwozia, nie do tego węzła.

const AxleBodyScript = preload("res://scripts/sim/machines/passive_axle_body.gd")

var definition: Dictionary = {}
var instance_state: Dictionary = {}
var body: RigidBody2D
var carriage: RigidBody2D
var attached: bool = false

var _units: float = 40.0
var _total_mass: float = 1.0
var _front_load_share: float = 0.5
var _rear_load_share: float = 0.5
var _turntable: PinJoint2D
var _limit_warning_sent: bool = false


func configure(model_data: Dictionary, saved_state: Dictionary,
		materials: Array, scale_units: float) -> void:
	definition = model_data
	instance_state = saved_state
	_units = scale_units
	name = str(saved_state["instance_id"])
	_total_mass = float(definition["physics"]["empty_mass_kg"])
	var storages: Dictionary = saved_state["storages"]
	for storage_value in storages.values():
		var storage: Dictionary = storage_value
		for material_value in materials:
			var material: Dictionary = material_value
			if material["id"] == storage["material_id"]:
				_total_mass += float(storage["amount_l"]) * float(material["bulk_density_kg_per_l"])
				break


func _ready() -> void:
	var physics_data: Dictionary = definition["physics"]
	var carriage_data: Dictionary = definition["front_carriage"]
	var axles: Array = definition["axles"]
	var front_axle: Dictionary = {}
	var rear_axle: Dictionary = {}
	for axle_value in axles:
		var axle: Dictionary = axle_value
		if axle["id"] == carriage_data["axle_id"]:
			front_axle = axle
		else:
			rear_axle = axle
	assert(axles.size() == 2 and not front_axle.is_empty() and not rear_axle.is_empty(),
		"Ten typ przyczepy wymaga dwóch osi, w tym jednej na wózku.")

	var length_m: float = float(definition["dimensions"]["length_m"])
	var pivot_m: Vector2 = _vec(carriage_data["pivot_in_body_m"])
	var rear_y: float = -length_m / 2.0 + float(rear_axle["distance_from_front_m"])
	var wheelbase: float = rear_y - pivot_m.y
	assert(pivot_m.y < 0.0 and rear_y > 0.0 and wheelbase > 0.0,
		"Osie muszą leżeć po dwóch stronach środka nadwozia.")

	# Założenie: ładunek rozłożony równomiernie, środek ciężkości w środku nadwozia.
	var front_share: float = rear_y / wheelbase
	var rear_share: float = 1.0 - front_share
	_front_load_share = front_share
	_rear_load_share = rear_share
	var carriage_mass: float = float(carriage_data["mass_kg"])
	var brake_force: float = float(physics_data["parking_brake_force_n"])

	var rear_body = AxleBodyScript.new()
	rear_body.name = "TrailerBody"
	rear_body.configure(
		_total_mass - carriage_mass, _total_mass * rear_share,
		rear_axle, Vector2(0.0, rear_y), physics_data, _units,
		brake_force * rear_share
	)
	var collision: Dictionary = physics_data["body_collision"]
	rear_body.add_rectangle(
		float(collision["width_m"]), float(collision["length_m"]),
		_vec(collision["center_m"]), float(collision["rotation_deg"])
	)
	var saved_pose: Dictionary = instance_state["transform"]
	rear_body.position = _vec(saved_pose["position_m"]) * _units
	rear_body.rotation = deg_to_rad(float(saved_pose["rotation_deg"]))
	add_child(rear_body)
	body = rear_body

	var front_body = AxleBodyScript.new()
	front_body.name = "FrontCarriage"
	front_body.configure(
		carriage_mass, _total_mass * front_share,
		front_axle, Vector2.ZERO, physics_data, _units,
		brake_force * front_share
	)
	# Mała bryła obrotnicy i osobna kolizja dyszla.
	front_body.add_rectangle(0.4, 0.25, Vector2.ZERO)
	var drawbar: Dictionary = carriage_data["drawbar"]
	if bool(drawbar["collision_enabled"]):
		front_body.add_rectangle(
			float(drawbar["width_m"]), float(drawbar["length_m"]),
			Vector2(0.0, -float(drawbar["length_m"]) / 2.0)
		)
	front_body.position = body.position + (pivot_m * _units).rotated(body.rotation)
	# Zerowe wzajemne ustawienie w chwili utworzenia przegubu.
	front_body.rotation = body.rotation
	add_child(front_body)
	carriage = front_body

	_turntable = PinJoint2D.new()
	_turntable.name = "Turntable"
	_turntable.position = carriage.position
	_turntable.softness = 0.0
	_turntable.disable_collision = true
	add_child(_turntable)
	_turntable.node_a = _turntable.get_path_to(body)
	_turntable.node_b = _turntable.get_path_to(carriage)
	var limits: Dictionary = carriage_data["turntable_limit_deg"]
	_turntable.angular_limit_lower = deg_to_rad(float(limits["min"]))
	_turntable.angular_limit_upper = deg_to_rad(float(limits["max"]))
	_turntable.angular_limit_enabled = true

	var articulated: Dictionary = instance_state["articulated_state"]
	var front_state: Dictionary = articulated["front_carriage"]
	var relative_angle: float = float(front_state["relative_rotation_deg"])
	assert(relative_angle >= float(limits["min"]) and relative_angle <= float(limits["max"]),
		"Zapisany skręt przyczepy przekracza limit.")
	carriage.rotation = body.rotation + deg_to_rad(relative_angle)
	carriage.call("synchronize_transform")

	var motion: Dictionary = instance_state["motion"]
	body.linear_velocity = _vec(motion["linear_velocity_m_per_s"]) * _units
	body.angular_velocity = deg_to_rad(float(motion["angular_velocity_deg_per_s"]))
	var offset: Vector2 = carriage.position - body.position
	carriage.linear_velocity = body.linear_velocity + Vector2(-offset.y, offset.x) * body.angular_velocity
	carriage.angular_velocity = body.angular_velocity + deg_to_rad(
		float(front_state["relative_angular_velocity_deg_per_s"])
	)

	set_attached(false)


func get_hitch_body(port_data: Dictionary) -> RigidBody2D:
	if str(port_data["member"]) == "front_carriage":
		return carriage
	return body


func set_attached(value: bool) -> void:
	attached = value
	body.call("set_parking_brake", not value)
	carriage.call("set_parking_brake", not value)
	instance_state["parking_brake_engaged"] = not value


func is_stopped(max_speed_m_per_s: float) -> bool:
	return (
		body.linear_velocity.length() / _units <= max_speed_m_per_s
		and carriage.linear_velocity.length() / _units <= max_speed_m_per_s
		and absf(body.angular_velocity) <= 0.1
		and absf(carriage.angular_velocity) <= 0.1
	)


func can_snap_by(shift: Vector2) -> bool:
	if shift.length_squared() < 0.000001:
		return true
	return not body.test_move(body.global_transform, shift) and not carriage.test_move(carriage.global_transform, shift)


func snap_by(shift: Vector2) -> void:
	# Podpinanie w ruchu: żadnego zerowania prędkości.
	var body_velocity: Vector2 = body.linear_velocity
	var body_spin: float = body.angular_velocity
	var carriage_velocity: Vector2 = carriage.linear_velocity
	var carriage_spin: float = carriage.angular_velocity
	body.global_position += shift
	carriage.global_position += shift
	body.call("synchronize_transform")
	carriage.call("synchronize_transform")
	body.linear_velocity = body_velocity
	body.angular_velocity = body_spin
	carriage.linear_velocity = carriage_velocity
	carriage.angular_velocity = carriage_spin


func get_diagnostics() -> String:
	var angle_deg: float = rad_to_deg(wrapf(carriage.global_rotation - body.global_rotation, -PI, PI))
	var pivot_m: Vector2 = _vec(definition["front_carriage"]["pivot_in_body_m"])
	var error_m: float = body.to_global(pivot_m * _units).distance_to(carriage.global_position) / _units
	return "Obrotnica: %.1f° | błąd położenia osi: %.3f m | %s" % [
		angle_deg, error_m, "podpięta" if attached else "odpięta"
	]


func _physics_process(delta: float) -> void:
	if not is_instance_valid(carriage):
		return
	_damp_turntable(delta)
	var relative_angle: float = wrapf(carriage.global_rotation - body.global_rotation, -PI, PI)
	var articulated: Dictionary = instance_state["articulated_state"]
	var front_state: Dictionary = articulated["front_carriage"]
	front_state["relative_rotation_deg"] = rad_to_deg(relative_angle)
	front_state["relative_angular_velocity_deg_per_s"] = rad_to_deg(carriage.angular_velocity - body.angular_velocity)
	var pose: Dictionary = instance_state["transform"]
	pose["position_m"] = [body.position.x / _units, body.position.y / _units]
	pose["rotation_deg"] = rad_to_deg(body.rotation)
	var motion: Dictionary = instance_state["motion"]
	motion["linear_velocity_m_per_s"] = [body.linear_velocity.x / _units, body.linear_velocity.y / _units]
	motion["angular_velocity_deg_per_s"] = rad_to_deg(body.angular_velocity)
	var limits: Dictionary = definition["front_carriage"]["turntable_limit_deg"]
	if not _limit_warning_sent and (
		rad_to_deg(relative_angle) < float(limits["min"]) - 3.0
		or rad_to_deg(relative_angle) > float(limits["max"]) + 3.0
	):
		_limit_warning_sent = true
		push_warning("Przekroczony limit obrotnicy. Sprawdź Rapier2D i częstotliwość fizyki. " + get_diagnostics())


func _damp_turntable(delta: float) -> void:
	var relative_speed: float = carriage.angular_velocity - body.angular_velocity
	if absf(relative_speed) < 0.0001:
		return
	var data: Dictionary = definition["front_carriage"]
	var torque_nm: float = clampf(
		-relative_speed * float(data["angular_damping_nm_per_rad_s"]),
		-float(data["max_friction_torque_nm"]), float(data["max_friction_torque_nm"])
	)
	var inverse_sum: float = float(body.get("inverse_inertia_value")) + float(carriage.get("inverse_inertia_value"))
	if inverse_sum <= 0.0:
		return
	var max_torque: float = absf(relative_speed) / inverse_sum / maxf(delta, 0.000001)
	var torque: float = clampf(torque_nm * _units * _units, -max_torque, max_torque)
	carriage.apply_torque(torque)
	body.apply_torque(-torque)


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


# Protokół maszyny (sim/machines/machines.gd)
func pose_body() -> Node2D:
	return body


func motion_body() -> RigidBody2D:
	return body


func cargo_body() -> RigidBody2D:
	return body


func is_attached() -> bool:
	return attached


func change_cargo_mass(delta_kg: float) -> void:
	# Masa ziarna obciąża nadwozie; naciski na obie osie liczymy od całej masy.
	var empty_mass: float = float(definition["physics"]["empty_mass_kg"])
	_total_mass = maxf(empty_mass, _total_mass + delta_kg)
	var carriage_mass: float = float(definition["front_carriage"]["mass_kg"])
	body.mass = maxf(0.001, _total_mass - carriage_mass)
	body.set("supported_mass_kg", _total_mass * _rear_load_share)
	carriage.set("supported_mass_kg", _total_mass * _front_load_share)
	body.inertia = 0.0
	body.sleeping = false
	carriage.sleeping = false
