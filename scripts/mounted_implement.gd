extends Node2D
## Heder: na ziemi statyczny lub dynamiczny (JSON), po podpięciu sztywna część kombajnu.

var definition: Dictionary = {}
var instance_state: Dictionary = {}
var attached: bool = false
var _units: float = 40.0
var _parking_parent: Node
var _ground_body: PhysicsBody2D
var _carrier: RigidBody2D
var _carrier_collision: CollisionShape2D
var _added_mass: float = 0.0


func configure(model: Dictionary, saved_state: Dictionary,
		_materials: Array, units: float) -> void:
	definition = model
	instance_state = saved_state
	_units = units
	name = str(saved_state["instance_id"])
	var pose: Dictionary = saved_state["transform"]
	position = _vec(pose["position_m"]) * _units
	rotation = deg_to_rad(float(pose["rotation_deg"]))


func _ready() -> void:
	_parking_parent = get_parent()
	call_deferred("_ensure_ground_body")


func _ensure_ground_body() -> void:
	if not attached and not is_instance_valid(_ground_body):
		_create_ground_body()


func get_hitch_position(port: Dictionary) -> Vector2:
	if not attached and is_instance_valid(_ground_body):
		return _ground_body.to_global(_vec(port["position_m"]) * _units)
	return to_global(_vec(port["position_m"]) * _units)


func attach_to_carrier(carrier: RigidBody2D, socket: Dictionary, plug: Dictionary) -> void:
	assert(not attached, "Narzędzie jest już podpięte.")
	# Przy odtwarzaniu zapisu dołączenie może nastąpić przed deferred tworzeniem bryły.
	if is_instance_valid(_ground_body):
		global_transform = _ground_body.global_transform
		_ground_body.get_parent().remove_child(_ground_body)
		_ground_body.queue_free()
		_ground_body = null
	_carrier = carrier
	reparent(carrier, false)
	rotation = deg_to_rad(
		float(socket.get("mount_rotation_deg", 0.0)) - float(plug.get("mount_rotation_deg", 0.0))
	)
	position = _vec(socket["position_m"]) * _units - (
		_vec(plug["position_m"]) * _units
	).rotated(rotation)
	# Mocowanie na krawędziach daje styczne nadwozia, bez sztucznej przerwy.
	_carrier_collision = _make_collider()
	_carrier_collision.position = position + _carrier_collision.position.rotated(rotation)
	_carrier_collision.rotation += rotation
	carrier.add_child(_carrier_collision)
	var mounting: Dictionary = definition["mounting"]
	if bool(mounting["mass_added_to_carrier_when_attached"]):
		_added_mass = float(definition["physics"]["empty_mass_kg"])
		carrier.mass += _added_mass
	carrier.inertia = 0.0
	carrier.sleeping = false
	attached = true
	instance_state["parking_brake_engaged"] = false
	_update_state()


func detach_from_carrier() -> void:
	if not attached:
		return
	var old_carrier: RigidBody2D = _carrier
	# Prędkość punktu mocowania: ruch postępowy + ruch wynikający z obrotu.
	var offset: Vector2 = global_position - old_carrier.global_position
	var spin: float = old_carrier.angular_velocity
	var velocity: Vector2 = old_carrier.linear_velocity + Vector2(-offset.y, offset.x) * spin
	old_carrier.remove_child(_carrier_collision)
	_carrier_collision.queue_free()
	_carrier_collision = null
	old_carrier.mass = maxf(old_carrier.mass - _added_mass, 0.001)
	old_carrier.inertia = 0.0
	old_carrier.sleeping = false
	_added_mass = 0.0
	# Zachowujemy rzeczywistą pozycję i obrót w świecie.
	reparent(_parking_parent, true)
	_carrier = null
	attached = false
	instance_state["parking_brake_engaged"] = true
	var work_state: Dictionary = instance_state["work_state"]
	work_state["enabled"] = false
	work_state["lowered"] = false
	_create_ground_body(velocity, spin)
	_update_state()


func _create_ground_body(velocity: Vector2 = Vector2.ZERO, spin: float = 0.0) -> void:
	var mounting: Dictionary = definition["mounting"]
	var physics_data: Dictionary = definition["physics"]
	var dynamic: bool = str(mounting.get("detached_physics", "static")) == "dynamic"
	if dynamic:
		var rigid := RigidBody2D.new()
		rigid.mass = maxf(0.001, float(physics_data["empty_mass_kg"]))
		rigid.gravity_scale = 0.0
		rigid.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
		rigid.angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
		rigid.linear_damp = maxf(0.0, float(physics_data.get("detached_linear_damp", 3.0)))
		rigid.angular_damp = maxf(0.0, float(physics_data.get("detached_angular_damp", 5.0)))
		rigid.linear_velocity = velocity
		rigid.angular_velocity = spin
		var material := PhysicsMaterial.new()
		material.bounce = 0.0
		material.friction = 0.8
		rigid.physics_material_override = material
		_ground_body = rigid
	else:
		_ground_body = StaticBody2D.new()
	_ground_body.name = name + "_GroundBody"
	_ground_body.collision_layer = 1
	_ground_body.collision_mask = 1
	_ground_body.add_child(_make_collider())
	# Oddzielny obiekt fizyki pod nieruchomym Machines.
	# Korzeń wizualny śledzi go, ale nie przesuwa go przez hierarchię.
	_parking_parent.add_child(_ground_body)
	_ground_body.global_transform = global_transform


func _make_collider() -> CollisionShape2D:
	var data: Dictionary = definition["physics"]["body_collision"]
	var shape := RectangleShape2D.new()
	shape.size = Vector2(float(data["width_m"]), float(data["length_m"])) * _units
	var collider := CollisionShape2D.new()
	collider.name = "HeaderCollision"
	collider.shape = shape
	collider.position = _vec(data["center_m"]) * _units
	collider.rotation = deg_to_rad(float(data["rotation_deg"]))
	return collider


func _physics_process(_delta: float) -> void:
	_update_state()


func _update_state() -> void:
	if not attached and is_instance_valid(_ground_body):
		global_transform = _ground_body.global_transform
	var pose: Dictionary = instance_state["transform"]
	# Konwencja projektu: korzeń World i Machines mają transformację jednostkową.
	pose["position_m"] = [global_position.x / _units, global_position.y / _units]
	pose["rotation_deg"] = rad_to_deg(global_rotation)
	var velocity := Vector2.ZERO
	var spin: float = 0.0
	if attached and is_instance_valid(_carrier):
		var offset: Vector2 = global_position - _carrier.global_position
		spin = _carrier.angular_velocity
		velocity = _carrier.linear_velocity + Vector2(-offset.y, offset.x) * spin
	elif _ground_body is RigidBody2D:
		var rigid: RigidBody2D = _ground_body as RigidBody2D
		velocity = rigid.linear_velocity
		spin = rigid.angular_velocity
	var motion: Dictionary = instance_state["motion"]
	motion["linear_velocity_m_per_s"] = [velocity.x / _units, velocity.y / _units]
	motion["angular_velocity_deg_per_s"] = rad_to_deg(spin)


func get_diagnostics() -> String:
	var status: String = "odłożony; nieruchomy"
	if attached:
		status = "zamocowany sztywno; kolizja i masa na kombajnie"
	elif _ground_body is RigidBody2D:
		status = "odłożony; ruchomy"
	return "%s | %s" % [definition["name"], status]


func _notification(what: int) -> void:
	# Usunięcie egzemplarza usuwa też jego osobną bryłę leżącą na ziemi.
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_ground_body):
		_ground_body.queue_free()


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func get_work_transform() -> Transform2D:
	return global_transform
