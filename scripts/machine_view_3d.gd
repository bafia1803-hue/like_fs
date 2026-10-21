extends Node3D
## Model 3D maszyny, który odwzorowuje stan symulacji 2D:
## pozycję i obrót nadwozia, skręt kół (ten sam kąt co w fizyce), toczenie kół,
## obrót wózka przyczepy, rozkładanie rury kombajnu, motowidło, wał i poziom ziarna.
##
## Mapowanie osi: punkt 2D (x, y) [m] -> 3D (x, 0, y); obrót 3D wokół Y = -obrót 2D.

const MAX_FRAME_TRAVEL_M: float = 4.0

var machine: Node2D
var definition: Dictionary = {}
var instance_state: Dictionary = {}
var units: float = 40.0

var _model: Node3D
var _kind: String = ""
var _body: Node2D
var _carriage: Node2D
var _steer: Array[Dictionary] = []      # {"node", "axle"}
var _wheels: Array[Dictionary] = []     # {"node", "radius", "x", "member"}
var _carriage_node: Node3D
var _pipe_node: Node3D
var _pipe_2d: Node2D
var _fill_node: Node3D
var _fill_storage_id: String = ""
var _fill_capacity: float = 0.0
var _fill_material_id: String = ""
var _barley_material: Material
var _reel: Node3D
var _roller: Node3D
var _roller_radius: float = 0.22
var _last: Dictionary = {}               # member -> {"pos": Vector2, "rot": float}
# Fizyka liczy 60 razy na sekundę; między krokami interpolujemy pozę, by ruch był płynny
# także na monitorach 120/144 Hz.
var _previous_pose := Transform3D()
var _current_pose := Transform3D()


func configure(machine_node: Node2D, scale_units: float) -> void:
	machine = machine_node
	units = scale_units
	definition = machine.get_meta("definition")
	instance_state = machine.get_meta("instance_state")
	_kind = str(definition.get("physics_kind", ""))
	name = "View_" + str(instance_state["instance_id"])
	_body = machine
	if _kind == "towed_turntable":
		_body = machine.get("body")
		_carriage = machine.get("carriage")
	elif _kind == "towed_single_axle":
		_body = machine.get("body")
	_load_model()
	_find_parts()
	_setup_fill()
	_current_pose = _physics_pose()
	_previous_pose = _current_pose
	transform = _current_pose


func _load_model() -> void:
	var path := "res://models/machines/%s.glb" % str(definition["id"])
	var scene: PackedScene = load(path) as PackedScene if ResourceLoader.exists(path) else null
	if scene != null:
		_model = scene.instantiate()
	else:
		_model = _fallback_model()
	_model.name = "Model"
	add_child(_model)
	var color := Color.from_string(str(definition.get("visual", {}).get("body_color", "#cccccc")), Color.GRAY)
	for child in _model.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = child
		var mesh: Mesh = mesh_instance.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var material: Material = mesh.surface_get_material(i)
			if material is BaseMaterial3D and material.resource_name == "paint":
				var paint: BaseMaterial3D = material.duplicate()
				paint.albedo_color = color
				mesh_instance.set_surface_override_material(i, paint)


func _fallback_model() -> Node3D:
	# Maszyna bez modelu .glb: prosta bryła w kolorze z katalogu.
	var root := Node3D.new()
	var dims: Dictionary = definition["dimensions"]
	var box := BoxMesh.new()
	box.size = Vector3(float(dims["width_m"]), 1.2, float(dims["length_m"]))
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = box
	mesh_instance.position.y = 0.8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_string(str(definition.get("visual", {}).get("body_color", "#cccccc")), Color.GRAY)
	material.roughness = 0.9
	mesh_instance.material_override = material
	root.add_child(mesh_instance)
	return root


func _find_parts() -> void:
	var axles: Dictionary = {}
	for axle in definition.get("axles", []):
		axles[str(axle["id"])] = axle
	for node in _model.find_children("*", "Node3D", true, false):
		var node_name: String = str(node.name)
		var parts: PackedStringArray = node_name.split("_")
		if node_name.begins_with("steer_") and parts.size() >= 3:
			var axle_id: String = "_".join(parts.slice(1, parts.size() - 1))
			if axles.has(axle_id):
				_steer.append({"node": node, "axle": axles[axle_id]})
		elif node_name.begins_with("spin_") and parts.size() >= 3:
			var axle_id: String = "_".join(parts.slice(1, parts.size() - 1))
			if axles.has(axle_id):
				var axle: Dictionary = axles[axle_id]
				var member: String = str(axle.get("body_member", "body"))
				var side: float = -1.0 if parts[parts.size() - 1] == "L" else 1.0
				_wheels.append({"node": node, "radius": maxf(0.05, float(axle["tire_length_m"]) * 0.5),
					"x": side * float(axle["track_m"]) * 0.5, "member": member})
		elif node_name == "carriage":
			_carriage_node = node
		elif node_name == "pipe":
			_pipe_node = node
		elif node_name == "grain_fill":
			_fill_node = node
		elif node_name == "reel":
			_reel = node
		elif node_name == "roller":
			_roller = node
			var aabb := _local_aabb(node)
			_roller_radius = maxf(0.05, aabb.size.y * 0.5)


func _local_aabb(node: Node3D) -> AABB:
	var result := AABB()
	for child in node.find_children("*", "MeshInstance3D", true, true):
		result = result.merge((child as MeshInstance3D).get_aabb())
	if node is MeshInstance3D:
		result = result.merge((node as MeshInstance3D).get_aabb())
	return result


func _setup_fill() -> void:
	if _fill_node == null:
		return
	var storage_id: String = ""
	if definition.get("receiving") is Dictionary:
		storage_id = str(definition["receiving"]["storage_id"])
	elif definition.get("unloading") is Dictionary:
		storage_id = str(definition["unloading"].get("source_storage_id", ""))
	for storage in definition.get("storage_definitions", []):
		if str(storage["id"]) == storage_id or storage_id.is_empty():
			_fill_storage_id = str(storage["id"])
			_fill_capacity = float(storage["capacity_l"])
			break
	if _fill_capacity <= 0.0:
		_fill_node.visible = false


func _physics_process(_delta: float) -> void:
	if not is_instance_valid(machine) or not is_instance_valid(_body):
		return
	_previous_pose = _current_pose
	_current_pose = _physics_pose()
	# Teleport (start trasy, wczytanie) – bez rozmywania ruchu.
	if _previous_pose.origin.distance_to(_current_pose.origin) > MAX_FRAME_TRAVEL_M:
		_previous_pose = _current_pose


func _process(_delta: float) -> void:
	if not is_instance_valid(machine) or not is_instance_valid(_body):
		return
	var fraction: float = Engine.get_physics_interpolation_fraction()
	transform = _previous_pose.interpolate_with(_current_pose, fraction)
	_update_steering()
	_update_carriage()
	_update_rolling()
	_update_pipe()
	_update_fill()


func _physics_pose() -> Transform3D:
	var t: Transform2D = _body.global_transform
	var p: Vector2 = t.origin / units
	return Transform3D(Basis(Vector3.UP, -t.get_rotation()), Vector3(p.x, 0.0, p.y))


func _update_steering() -> void:
	if _steer.is_empty():
		return
	var steering: float = 0.0
	if machine.has_method("get_visual_steering"):
		steering = float(machine.call("get_visual_steering"))
	else:
		steering = float(instance_state.get("steering_input", 0.0))
	for entry in _steer:
		var axle: Dictionary = entry["axle"]
		var angle_deg: float = float(axle["max_steering_deg"]) * float(axle["steering_ratio"]) * steering
		(entry["node"] as Node3D).rotation.y = -deg_to_rad(angle_deg)


func _update_carriage() -> void:
	if _carriage_node == null or not is_instance_valid(_carriage):
		return
	var relative: float = wrapf(_carriage.global_rotation - _body.global_rotation, -PI, PI)
	_carriage_node.rotation.y = -relative


## Przejazd punktu członu wzdłuż jego osi od ostatniej klatki (m) i zmiana kąta (rad).
func _member_motion(member: String) -> Vector2:
	var node: Node2D = _carriage if member == "front_carriage" and is_instance_valid(_carriage) else _body
	var t: Transform2D = node.global_transform
	var pos: Vector2 = t.origin / units
	var rot: float = t.get_rotation()
	var result := Vector2.ZERO
	if _last.has(member):
		var previous: Dictionary = _last[member]
		var forward := Vector2.UP.rotated(rot)
		var travel: float = (pos - (previous["pos"] as Vector2)).dot(forward)
		var turn: float = angle_difference(float(previous["rot"]), rot)
		if absf(travel) < MAX_FRAME_TRAVEL_M:
			result = Vector2(travel, turn)
	_last[member] = {"pos": pos, "rot": rot}
	return result


func _update_rolling() -> void:
	var motions: Dictionary = {}
	for entry in _wheels:
		var member: String = entry["member"]
		if not motions.has(member):
			motions[member] = _member_motion(member)
		var motion: Vector2 = motions[member]
		# Koło po zewnętrznej stronie zakrętu pokonuje dłuższą drogę.
		var travel: float = motion.x - float(entry["x"]) * motion.y
		(entry["node"] as Node3D).rotation.x -= travel / float(entry["radius"])
	if _roller != null or _reel != null:
		if not motions.has("body"):
			motions["body"] = _member_motion("body")
		var travel_body: float = (motions["body"] as Vector2).x
		if _roller != null:
			_roller.rotation.x -= travel_body / _roller_radius
		if _reel != null:
			_update_reel(travel_body)


func _update_reel(own_travel: float) -> void:
	# Heder jest sztywno zamocowany: jedzie razem z kombajnem. Motowidło kręci się tylko podczas jazdy do przodu.
	if not bool(machine.get("attached")):
		return
	if own_travel > 0.0:
		_reel.rotation.x -= own_travel / 0.5 * 1.25


func _update_pipe() -> void:
	if _pipe_node == null:
		return
	if not is_instance_valid(_pipe_2d):
		_pipe_2d = _body.get_node_or_null("UnloadingPipe") as Node2D
		if _pipe_2d == null:
			return
	var config: Dictionary = _pipe_2d.get("config")
	var extension: float = float(_pipe_2d.get("extension"))
	var angle: float = deg_to_rad(lerpf(float(config["folded_angle_deg"]), float(config["deployed_angle_deg"]), extension))
	var direction := Vector2.from_angle(angle)
	if str(config.get("side", "left")) == "right":
		direction.x = -direction.x
	_pipe_node.rotation.y = atan2(direction.x, direction.y)


func _update_fill() -> void:
	if _fill_node == null or _fill_capacity <= 0.0:
		return
	var storages: Dictionary = instance_state.get("storages", {})
	var storage: Dictionary = storages.get(_fill_storage_id, {})
	var ratio: float = clampf(float(storage.get("amount_l", 0.0)) / _fill_capacity, 0.0, 1.0)
	_fill_node.visible = ratio > 0.002
	# Mało ziarna: niska kupka na środku; więcej: wypełnia całą skrzynię.
	var spread: float = lerpf(0.45, 1.0, sqrt(ratio))
	_fill_node.scale = Vector3(spread, maxf(ratio, 0.02), spread)
	var material_id: String = str(storage.get("material_id", ""))
	if material_id != _fill_material_id:
		_fill_material_id = material_id
		_apply_fill_tint(material_id.begins_with("barley"))


func _apply_fill_tint(barley: bool) -> void:
	var targets: Array = []
	if _fill_node is MeshInstance3D:
		targets.append(_fill_node)
	targets.append_array(_fill_node.find_children("*", "MeshInstance3D", true, true))
	for child in targets:
		var mesh_instance: MeshInstance3D = child
		if not barley:
			mesh_instance.material_override = null
			continue
		if _barley_material == null:
			var source: Material = mesh_instance.mesh.surface_get_material(0)
			if source is BaseMaterial3D:
				_barley_material = source.duplicate()
				(_barley_material as BaseMaterial3D).albedo_color = Color(1.0, 0.97, 0.8)
		mesh_instance.material_override = _barley_material
