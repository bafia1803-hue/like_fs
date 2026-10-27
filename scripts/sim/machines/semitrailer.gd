extends Node2D
## Naczepa (physics_kind "towed_semitrailer"): jedno nadwozie z osiami z tyłu, sworzeń z przodu.
## Podpina ją tylko tir (port typu "fifth_wheel": siodło ↔ sworzeń), klawiszem E.
##
## Kolizje na dwóch poziomach (collision_levels.gd): przód naczepy jest wysoko („high”),
## więc rama tira („low”) wjeżdża pod niego; kabina tira (oba poziomy) i ściana czołowa naczepy
## nadal się zderzają. Nogi podporowe (grupa "legs", „low”) mają kolizję tylko po odpięciu.
## Po podpięciu nogi podnoszą się (animacja w widoku), po odpięciu są od razu opuszczone.

const BodyScript = preload("res://scripts/sim/machines/semitrailer_body.gd")
const Levels = preload("res://scripts/sim/machines/collision_levels.gd")
const Profiler = preload("res://scripts/core/util/profiler.gd")

var definition: Dictionary = {}
var instance_state: Dictionary = {}
var body: RigidBody2D
var attached: bool = false
var _units: float = 40.0
var _total_mass: float = 1.0
var _carrier: RigidBody2D
var _leg_colliders: Array = []


func configure(model: Dictionary, saved_state: Dictionary, materials: Array, units: float) -> void:
	definition = model
	instance_state = saved_state
	_units = units
	name = str(saved_state["instance_id"])
	_total_mass = float(model["physics"]["empty_mass_kg"])
	for storage in saved_state["storages"].values():
		for material in materials:
			if material["id"] == storage["material_id"]:
				_total_mass += float(storage["amount_l"]) * float(material["bulk_density_kg_per_l"])
				break


func _ready() -> void:
	var rigid = BodyScript.new()
	rigid.name = "SemitrailerBody"
	rigid.configure(definition, _total_mass, _units)
	var pose: Dictionary = instance_state["transform"]
	rigid.position = _vec(pose["position_m"]) * _units
	rigid.rotation = deg_to_rad(float(pose["rotation_deg"]))
	var built: Dictionary = Levels.build(rigid, definition["physics"]["collision_shapes"], _units)
	_leg_colliders = built["groups"].get("legs", [])
	add_child(rigid)
	body = rigid
	set_attached(false)


func get_hitch_body(_port: Dictionary) -> RigidBody2D:
	return body


# Protokół maszyny (sim/machines/machines.gd)
func pose_body() -> Node2D:
	return body


func motion_body() -> RigidBody2D:
	return body


func cargo_body() -> RigidBody2D:
	return body


func is_attached() -> bool:
	return attached


func set_attached(value: bool) -> void:
	attached = value
	body.attached = value
	instance_state["parking_brake_engaged"] = not value
	for collider in _leg_colliders:
		collider.set_deferred("disabled", value)
	body.sleeping = false
	if not value:
		set_carrier(null)


## Tir, do którego naczepa jest podpięta (HitchSystem); null po odpięciu.
func set_carrier(carrier: RigidBody2D) -> void:
	if is_instance_valid(_carrier) and _carrier != carrier and _carrier.has_method("set_coupled_load_kg"):
		_carrier.call("set_coupled_load_kg", 0.0)
	_carrier = carrier
	_update_carrier_load()


func snap_by(shift: Vector2) -> void:
	var velocity: Vector2 = body.linear_velocity
	var spin: float = body.angular_velocity
	body.global_position += shift
	body.call("synchronize_transform")
	body.linear_velocity = velocity
	body.angular_velocity = spin
	Levels.sync(body)


func change_cargo_mass(delta_kg: float) -> void:
	_total_mass = maxf(1.0, _total_mass + delta_kg)
	body.mass = _total_mass
	body.total_mass_kg = _total_mass
	body.inertia = 0.0
	body.sleeping = false
	_update_carrier_load()


func _update_carrier_load() -> void:
	if is_instance_valid(_carrier) and _carrier.has_method("set_coupled_load_kg"):
		_carrier.call("set_coupled_load_kg", body.coupled_load_kg() if attached else 0.0)


func _physics_process(_delta: float) -> void:
	var started: int = Profiler.start()
	_physics_process_measured(_delta)
	Profiler.stop(Profiler.MACHINES_STATE, started)


func _physics_process_measured(_delta: float) -> void:
	if not is_instance_valid(body):
		return
	body.carrier_braking = attached and is_instance_valid(_carrier) and bool(_carrier.get("braking_now"))
	var pose: Dictionary = instance_state["transform"]
	pose["position_m"] = [body.position.x / _units, body.position.y / _units]
	pose["rotation_deg"] = rad_to_deg(body.rotation)
	var motion: Dictionary = instance_state["motion"]
	motion["linear_velocity_m_per_s"] = [body.linear_velocity.x / _units, body.linear_velocity.y / _units]
	motion["angular_velocity_deg_per_s"] = rad_to_deg(body.angular_velocity)


func get_diagnostics() -> String:
	return "%s | masa z ładunkiem: %.0f kg | nacisk na siodło: %.0f kg | %s" % [
		definition["name"], _total_mass, body.coupled_load_kg(), "podpięta" if attached else "na nogach"]


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
