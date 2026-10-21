extends Node2D
## Jedno fizyczne nadwozie ze sztywnym dyszlem. Siewnik lub kultywator.
const AxleBodyScript = preload("res://scripts/passive_axle_body.gd")

var definition: Dictionary = {}
var instance_state: Dictionary = {}
var body: RigidBody2D
var attached: bool = false
var _units: float = 40.0
var _total_mass: float = 1.0


func configure(model: Dictionary, saved_state: Dictionary,
		materials: Array, units: float) -> void:
	definition = model
	instance_state = saved_state
	_units = units
	name = str(saved_state["instance_id"])
	_total_mass = float(model["physics"]["empty_mass_kg"])
	var storages: Dictionary = saved_state["storages"]
	for storage_value in storages.values():
		var storage: Dictionary = storage_value
		for material_value in materials:
			var material: Dictionary = material_value
			if material["id"] == storage["material_id"]:
				_total_mass += float(storage["amount_l"]) * float(material["bulk_density_kg_per_l"])
				break


func _ready() -> void:
	var axles: Array = definition["axles"]
	assert(axles.size() == 1, "Ten typ narzędzia wymaga dokładnie jednej osi.")
	var axle: Dictionary = axles[0]
	var physics_data: Dictionary = definition["physics"]
	var length_m: float = float(definition["dimensions"]["length_m"])
	var axle_y: float = -length_m / 2.0 + float(axle["distance_from_front_m"])
	var rigid_body = AxleBodyScript.new()
	rigid_body.name = "ImplementBody"
	rigid_body.configure(
		_total_mass, _total_mass, axle, Vector2(0.0, axle_y),
		physics_data, _units, float(physics_data.get("parking_brake_force_n", _total_mass * 12.0))
	)
	var collision: Dictionary = physics_data["body_collision"]
	rigid_body.add_rectangle(
		float(collision["width_m"]), float(collision["length_m"]),
		_vec(collision["center_m"]), float(collision["rotation_deg"])
	)
	var drawbar: Dictionary = definition["drawbar"]
	if bool(drawbar["collision_enabled"]):
		rigid_body.add_rectangle(
			float(drawbar["width_m"]), float(drawbar["length_m"]),
			Vector2(0.0, -length_m / 2.0 - float(drawbar["length_m"]) / 2.0)
		)
	var pose: Dictionary = instance_state["transform"]
	rigid_body.position = _vec(pose["position_m"]) * _units
	rigid_body.rotation = deg_to_rad(float(pose["rotation_deg"]))
	add_child(rigid_body)
	body = rigid_body
	var motion: Dictionary = instance_state["motion"]
	body.linear_velocity = _vec(motion["linear_velocity_m_per_s"]) * _units
	body.angular_velocity = deg_to_rad(float(motion["angular_velocity_deg_per_s"]))
	set_attached(false)


func get_hitch_body(_port: Dictionary) -> RigidBody2D:
	return body


func set_attached(value: bool) -> void:
	attached = value
	body.call("set_parking_brake", not value)
	instance_state["parking_brake_engaged"] = not value
	if not value:
		var work_state: Dictionary = instance_state["work_state"]
		work_state["enabled"] = false
		work_state["lowered"] = false


func snap_by(shift: Vector2) -> void:
	var velocity: Vector2 = body.linear_velocity
	var spin: float = body.angular_velocity
	body.global_position += shift
	body.call("synchronize_transform")
	body.linear_velocity = velocity
	body.angular_velocity = spin


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(body):
		return
	var pose: Dictionary = instance_state["transform"]
	pose["position_m"] = [body.position.x / _units, body.position.y / _units]
	pose["rotation_deg"] = rad_to_deg(body.rotation)
	var motion: Dictionary = instance_state["motion"]
	motion["linear_velocity_m_per_s"] = [body.linear_velocity.x / _units, body.linear_velocity.y / _units]
	motion["angular_velocity_deg_per_s"] = rad_to_deg(body.angular_velocity)


func get_diagnostics() -> String:
	return "%s | masa z zawartością: %.0f kg | %s" % [
		definition["name"], _total_mass, "podpięty" if attached else "odpięty"
	]


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func get_work_transform() -> Transform2D:
	return body.global_transform


func change_cargo_mass(delta_kg: float) -> void:
	_total_mass = maxf(1.0, _total_mass + delta_kg)
	body.mass = _total_mass
	body.set("supported_mass_kg", _total_mass)
	body.inertia = 0.0
