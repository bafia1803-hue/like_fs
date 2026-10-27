extends Node3D
## Model 3D maszyny, który odwzorowuje stan symulacji 2D:
## pozycję i obrót nadwozia, skręt kół (ten sam kąt co w fizyce), toczenie kół,
## obrót wózka przyczepy, rozkładanie rury kombajnu, motowidło, wał i poziom ziarna,
## strumień ziarna z rury oraz wywrot skrzyni przyczepy przy rozładunku,
## opuszczanie/podnoszenie narzędzi (węzeł "lift") i znaczniki siewnika ("marker_L/R"),
## nogi podporowe naczepy ("landing_legs") i rozładunek naczepy przez tylne drzwi
## (taśmociąg: ładunek ubywa od przodu – visual.fill_mode = "conveyor").
##
## Mapowanie osi: punkt 2D (x, y) [m] -> 3D (x, 0, y); obrót 3D wokół Y = -obrót 2D.

const Machines = preload("res://scripts/sim/machines/machines.gd")
const MAX_FRAME_TRAVEL_M: float = 4.0
const StreamScript = preload("res://scripts/views/view3d/grain_stream_3d.gd")
const TIPPER_MAX_DEG: float = 48.0
const TIPPER_LOWER_DEG_S: float = 14.0
const TAILGATE_MAX_DEG: float = 62.0
## Gra przenosi cały ładunek wywrotki w jednym kroku; widok dogrywa wysyp przez tyle sekund.
const POUR_SECONDS: float = 2.0
## Czas opuszczania/podnoszenia narzędzia (klawisz B).
const LIFT_SECONDS: float = 1.4
const MARKER_FOLDED_DEG: float = 100.0
## Nogi naczepy: o ile podnoszą się po podpięciu i w jakim czasie.
const LEGS_RAISE_M: float = 0.3
const LEGS_RAISE_SECONDS: float = 1.6
## Kąt otwarcia tylnych drzwi naczepy.
const DOOR_OPEN_DEG: float = 40.0
const Profiler = preload("res://scripts/core/util/profiler.gd")

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
var _tint_materials: Dictionary = {}   # material_id -> materiał ziarna w skrzyni
var _reel: Node3D
var _rollers: Array[Node3D] = []       # wał środkowy i wały skrzydeł ("roller", "roller_L"...)
var _roller_radius: float = 0.22
var _wings: Array[Dictionary] = []      # {"node", "side"} – skrzydła składane do góry
var _fill_height: float = 0.0
var _legs: Node3D
var _spinners: Array[Node3D] = []       # tarcze rozsiewacza ("spinner_L/R")
var _spread_emitters: Array[CPUParticles3D] = []
var _legs_y: float = 0.0
var _legs_raise: float = 0.0
var _conveyor: bool = false             # naczepa: ładunek ubywa od przodu
var _door_angle: float = 0.0
var _last_amount_ratio: float = 0.0
var _profile_ramp: bool = false         # trwa (albo trwał) rozładunek: powierzchnia pochyła
var _profile_level: float = 0.0         # wysokość ładunku (0..1) przed rozładunkiem
var _profile_offset: float = 0.0
var _profile_key := Vector2(-1, -1)
var _profile_mesh_size := Vector3.ZERO
var _profile_x := Vector2.ZERO
var _profile_material: Material
var _profile_uv := Vector2.ZERO
var _profile_color := Color(0, 0, 0, -1)
var _tipper: Node3D
var _tailgate: Node3D
var _tipper_angle: float = 0.0          # stopnie
var _lift: Node3D
var _lift_height: float = 0.0
var _markers: Array[Dictionary] = []    # {"node", "side"}
## 0 = podniesione (transport), 1 = opuszczone (praca). Animowane w stronę stanu z gry.
var _work_ratio: float = -1.0
var _ram_outer: MeshInstance3D
var _ram_inner: MeshInstance3D
var _pipe_stream: Node3D
var _tip_stream: Node3D
var _last_amount: float = -1.0
var _pipe_flow_hold: float = 0.0
var _tip_flow_hold: float = 0.0
var _pour_time: float = 0.0              # >0: trwa animacja wysypu
var _pour_from_ratio: float = 0.0        # zapełnienie na początku wysypu
var _pour_to_ratio: float = 0.0
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
	elif _kind == "towed_single_axle" or _kind == "towed_semitrailer":
		_body = machine.get("body")
	_load_model()
	_find_parts()
	_setup_fill()
	_current_pose = _physics_pose()
	_previous_pose = _current_pose
	transform = _current_pose


func _load_model() -> void:
	_model = instantiate_model(definition)
	_model.name = "Model"
	add_child(_model)


## Model 3D maszyny z kolorem lakieru z katalogu (używa go też podgląd w sklepie).
static func instantiate_model(model_definition: Dictionary) -> Node3D:
	var path := "res://models/machines/%s.glb" % str(model_definition["id"])
	var scene: PackedScene = load(path) as PackedScene if ResourceLoader.exists(path) else null
	var model: Node3D = scene.instantiate() if scene != null else _fallback_model(model_definition)
	var color := Color.from_string(str(model_definition.get("visual", {}).get("body_color", "#cccccc")), Color.GRAY)
	for child in model.find_children("*", "MeshInstance3D", true, false):
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
	return model


static func _fallback_model(model_definition: Dictionary) -> Node3D:
	# Maszyna bez modelu .glb: prosta bryła w kolorze z katalogu.
	var root := Node3D.new()
	var dims: Dictionary = model_definition["dimensions"]
	var box := BoxMesh.new()
	box.size = Vector3(float(dims["width_m"]), 1.2, float(dims["length_m"]))
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = box
	mesh_instance.position.y = 0.8
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.from_string(str(model_definition.get("visual", {}).get("body_color", "#cccccc")), Color.GRAY)
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
		elif node_name == "tipper":
			_tipper = node
		elif node_name == "tailgate":
			_tailgate = node
		elif node_name == "pipe":
			_pipe_node = node
		elif node_name == "grain_fill":
			_fill_node = node
		elif node_name == "reel":
			_reel = node
		elif node_name.begins_with("spinner"):
			_spinners.append(node)
		elif node_name == "landing_legs":
			_legs = node
			_legs_y = node.position.y
		elif node_name == "lift":
			_lift = node
			_lift_height = float(definition.get("visual", {}).get("lift_height_m", 0.4))
		elif node_name == "marker_L" or node_name == "marker_R":
			_markers.append({"node": node, "side": -1.0 if node_name.ends_with("L") else 1.0})
		elif node_name == "wing_L" or node_name == "wing_R":
			_wings.append({"node": node, "side": -1.0 if node_name.ends_with("L") else 1.0})
		elif node_name.begins_with("roller"):
			_rollers.append(node)
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
	elif definition.get("work") is Dictionary and definition["work"].get("input") is Dictionary:
		storage_id = str(definition["work"]["input"].get("storage_id", ""))   # np. nawóz w rozsiewaczu
	for storage in definition.get("storage_definitions", []):
		if str(storage["id"]) == storage_id or storage_id.is_empty():
			_fill_storage_id = str(storage["id"])
			_fill_capacity = float(storage["capacity_l"])
			break
	if _fill_capacity <= 0.0:
		_fill_node.visible = false
	_fill_height = _local_aabb(_fill_node).end.y
	if _tipper != null:
		_create_ram()
	_conveyor = str(definition.get("visual", {}).get("fill_mode", "")) == "conveyor"


func _physics_process(_delta: float) -> void:
	var started: int = Profiler.start()
	_physics_process_measured(_delta)
	Profiler.stop(Profiler.VIEW_MACHINES_PHYSICS, started)


func _physics_process_measured(_delta: float) -> void:
	if not is_instance_valid(machine) or not is_instance_valid(_body):
		return
	_previous_pose = _current_pose
	_current_pose = _physics_pose()
	# Teleport (start trasy, wczytanie) – bez rozmywania ruchu.
	if _previous_pose.origin.distance_to(_current_pose.origin) > MAX_FRAME_TRAVEL_M:
		_previous_pose = _current_pose


func _process(_delta: float) -> void:
	var started: int = Profiler.start()
	_process_measured(_delta)
	Profiler.stop(Profiler.VIEW_MACHINES, started)


func _process_measured(_delta: float) -> void:
	if not is_instance_valid(machine) or not is_instance_valid(_body):
		return
	var fraction: float = Engine.get_physics_interpolation_fraction()
	transform = _previous_pose.interpolate_with(_current_pose, fraction)
	_update_steering()
	_update_carriage()
	_update_rolling()
	_update_work(_delta)
	_update_pipe()
	_update_tipper(_delta)    # przed _update_fill: wykrywa zrzut i ustawia animację wysypu
	_update_rear_door(_delta)
	_update_fill()
	_update_legs(_delta)
	_update_spreader(_delta)


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
	if not _rollers.is_empty() or _reel != null:
		if not motions.has("body"):
			motions["body"] = _member_motion("body")
		var travel_body: float = (motions["body"] as Vector2).x
		if not _rollers.is_empty() and (_lift == null or _work_ratio > 0.95):
			for roller in _rollers:
				roller.rotation.x -= travel_body / _roller_radius
		if _reel != null:
			_update_reel(travel_body)


## Stan pracy z gry: work_state.enabled i lowered (klawisz B).
func _is_working() -> bool:
	var work_state: Variant = instance_state.get("work_state")
	return work_state is Dictionary and bool(work_state.get("enabled", false)) and bool(work_state.get("lowered", false))


func _update_work(delta: float) -> void:
	# Skrzydła: kąt prosto z gry (postęp składania), żeby animacja trwała dokładnie folding.duration_s.
	if not _wings.is_empty() and machine.has_method("get_fold_progress"):
		var unfold: float = float(machine.call("get_fold_progress"))
		for entry in _wings:
			(entry["node"] as Node3D).rotation.z = float(entry["side"]) * PI * 0.5 * (1.0 - unfold)
	if _lift == null and _markers.is_empty():
		return
	var target: float = 1.0 if _is_working() else 0.0
	# Odpięty heder leży na ziemi (opuszczony), a nie wisi w powietrzu.
	if _kind == "rigid_mounted" and not Machines.is_attached(machine):
		target = 1.0
	if _work_ratio < 0.0:
		_work_ratio = target
	_work_ratio = move_toward(_work_ratio, target, delta / LIFT_SECONDS)
	var eased: float = smoothstep(0.0, 1.0, _work_ratio)
	if _lift != null:
		_lift.position.y = (1.0 - eased) * _lift_height
	for entry in _markers:
		# Znaczniki rozkładają się po opuszczeniu redlic (druga połowa ruchu).
		var unfold: float = smoothstep(0.35, 1.0, _work_ratio)
		(entry["node"] as Node3D).rotation.z = float(entry["side"]) * deg_to_rad(MARKER_FOLDED_DEG) * (1.0 - unfold)


func _update_reel(own_travel: float) -> void:
	# Heder jest sztywno zamocowany: jedzie razem z kombajnem. Motowidło kręci się tylko
	# podczas pracy (heder opuszczony) i jazdy do przodu.
	if not Machines.is_attached(machine) or not _is_working():
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
	# Strumień ziarna z wylotu, gdy logika przeładunku faktycznie przesypuje ziarno.
	if float(_pipe_2d.get("flow_l_per_s")) > 0.0:
		_pipe_flow_hold = 0.15
	else:
		_pipe_flow_hold = maxf(0.0, _pipe_flow_hold - get_process_delta_time())
	if _pipe_stream == null:
		if _pipe_flow_hold <= 0.0:
			return
		_pipe_stream = StreamScript.new()
		_pipe_stream.name = "PipeStream"
		add_child(_pipe_stream)
	var length: float = float(config.get("length_m", 5.0))
	var top: Vector3 = _pipe_node.to_global(Vector3(0.0, -0.55, length))
	_pipe_stream.call("update_stream", _pipe_flow_hold > 0.0, top, _surface_below(top), 0.24)


## Wysokość, na którą spada ziarno w danym punkcie: ładunek innej maszyny albo grunt (krata silosu).
func _surface_below(point: Vector3) -> float:
	for view in get_parent().get_children():
		if view == self or not view.has_method("grain_surface_height"):
			continue
		var height: float = float(view.call("grain_surface_height", point))
		if height >= 0.0:
			return height
	return 0.08


## Dla maszyn przyjmujących ziarno: wysokość powierzchni ładunku pod punktem, inaczej -1.
## Siewnik: wierzch zbiornika nasion (na niego sypie stacja nasion).
func grain_surface_height(point: Vector3) -> float:
	var work: Variant = definition.get("work")
	if work is Dictionary and str(work.get("operation", "")) == "sow":
		var dims: Dictionary = definition["dimensions"]
		var local_point: Vector3 = global_transform.affine_inverse() * point
		if absf(local_point.x) <= float(dims["width_m"]) * 0.5 and absf(local_point.z) <= float(dims["length_m"]) * 0.5:
			return _local_aabb(_model).end.y
		return -1.0
	if _fill_node == null or not definition.get("receiving") is Dictionary:
		return -1.0
	var area: Dictionary = definition["receiving"]["area"]
	var local: Vector3 = global_transform.affine_inverse() * point
	var center: Array = area["center_m"]
	if absf(local.x - float(center[0])) > float(area["width_m"]) * 0.5:
		return -1.0
	if absf(local.z - float(center[1])) > float(area["length_m"]) * 0.5:
		return -1.0
	var base_y: float = _fill_node.global_position.y
	if not _fill_node.visible:
		return base_y
	if _conveyor:
		return base_y + _fill_height * _profile_level
	return base_y + _fill_height * _fill_node.scale.y


func _update_fill() -> void:
	if _fill_node == null or _fill_capacity <= 0.0:
		return
	var storages: Dictionary = instance_state.get("storages", {})
	var storage: Dictionary = storages.get(_fill_storage_id, {})
	var ratio: float = clampf(float(storage.get("amount_l", 0.0)) / _fill_capacity, 0.0, 1.0)
	if _conveyor:
		_update_conveyor_fill(ratio, storage)
		return
	if _pour_time > 0.0:
		# W trakcie wysypu pokazujemy ziarno ubywające płynnie.
		ratio = lerpf(_pour_to_ratio, _pour_from_ratio, _pour_time / POUR_SECONDS)
	_fill_node.visible = ratio > 0.002
	# Mało ziarna: niska kupka na środku; więcej: wypełnia całą skrzynię.
	var spread: float = lerpf(0.45, 1.0, sqrt(ratio))
	_fill_node.scale = Vector3(spread, maxf(ratio, 0.02), spread)
	var material_id: String = str(storage.get("material_id", ""))
	if material_id != _fill_material_id:
		_fill_material_id = material_id
		_apply_fill_tint(material_id)


## Wywrotka: skrzynia podnosi się w czasie opóźnienia rozładunku, klapa się odchyla,
## ziarno wysypuje się do kraty. Stan rozładunku pochodzi z GrainTransfer (unloading_state).
func _update_tipper(delta: float) -> void:
	if _tipper == null:
		return
	var unloading: Dictionary = definition["unloading"] if definition.get("unloading") is Dictionary else {}
	var state: Dictionary = instance_state.get("unloading_state", {})
	var storage: Dictionary = instance_state.get("storages", {}).get(_fill_storage_id, {})
	var amount: float = float(storage.get("amount_l", 0.0))
	var in_zone: bool = not str(state.get("zone_id", "")).is_empty() and amount > 0.0
	# Duży spadek ładunku = gra właśnie zrzuciła całość: start animacji wysypu.
	if _last_amount >= 0.0 and amount < _last_amount - 1.0 and _fill_capacity > 0.0:
		_pour_from_ratio = clampf(_last_amount / _fill_capacity, 0.0, 1.0)
		_pour_to_ratio = clampf(amount / _fill_capacity, 0.0, 1.0)
		_pour_time = POUR_SECONDS
	_last_amount = amount
	var pouring: bool = _pour_time > 0.0
	_pour_time = maxf(0.0, _pour_time - delta)
	var delay: float = maxf(float(unloading.get("start_delay_seconds", 3.0)), 0.5)
	var target: float = TIPPER_MAX_DEG if in_zone or pouring else 0.0
	# Podnoszenie trwa tyle, ile opóźnienie rozładunku w machines.json.
	var rate: float = TIPPER_MAX_DEG / delay if target > _tipper_angle else TIPPER_LOWER_DEG_S
	_tipper_angle = move_toward(_tipper_angle, target, rate * delta)
	_tipper.rotation.x = deg_to_rad(_tipper_angle)
	var gate_open: float = clampf((_tipper_angle - 12.0) / 22.0, 0.0, 1.0)
	if _tailgate != null:
		_tailgate.rotation.x = -deg_to_rad(TAILGATE_MAX_DEG * gate_open)
	_update_ram()
	if pouring and gate_open > 0.5:
		_tip_flow_hold = 0.2
	else:
		_tip_flow_hold = maxf(0.0, _tip_flow_hold - delta)
	if _tip_stream == null:
		if _tip_flow_hold <= 0.0:
			return
		_tip_stream = StreamScript.new()
		_tip_stream.name = "TipStream"
		add_child(_tip_stream)
	var lip: Vector3 = _tipper.global_transform * Vector3(0.0, 0.05, 0.12)
	_tip_stream.call("update_stream", _tip_flow_hold > 0.0, lip, 0.08, 1.1)


func _create_ram() -> void:
	var steel := StandardMaterial3D.new()
	steel.albedo_color = Color("#8e8983")
	steel.roughness = 0.6
	var chrome := StandardMaterial3D.new()
	chrome.albedo_color = Color("#d9d6cf")
	chrome.roughness = 0.35
	for pair in [["RamOuter", 0.09, steel], ["RamInner", 0.055, chrome]]:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = pair[1]
		cylinder.bottom_radius = pair[1]
		cylinder.height = 1.0
		cylinder.radial_segments = 8
		cylinder.rings = 1
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = pair[0]
		mesh_instance.mesh = cylinder
		mesh_instance.material_override = pair[2]
		_model.add_child(mesh_instance)
		if pair[0] == "RamOuter":
			_ram_outer = mesh_instance
		else:
			_ram_inner = mesh_instance
	_update_ram()


## Siłownik teleskopowy między ramą a przodem skrzyni.
func _update_ram() -> void:
	if _ram_outer == null:
		return
	var hinge: Vector3 = _tipper.position
	var base := Vector3(0.0, hinge.y - 0.34, -0.9)
	var top: Vector3 = _tipper.transform * Vector3(0.0, 0.0, -0.9 - hinge.z)
	var axis: Vector3 = top - base
	var length: float = maxf(axis.length(), 0.05)
	var up: Vector3 = axis / length
	var side: Vector3 = up.cross(Vector3.RIGHT)
	if side.length_squared() < 0.01:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	var basis := Basis(up.cross(side), up, side)
	var outer_len: float = minf(length, 0.45)
	_ram_outer.transform = Transform3D(basis.scaled(Vector3(1.0, outer_len, 1.0)), base + up * outer_len * 0.5)
	_ram_inner.transform = Transform3D(basis.scaled(Vector3(1.0, length, 1.0)), base + up * length * 0.5)


## Odcień ziarna w skrzyni: pszenica – kolor modelu, jęczmień ciemniejszy, owies jaśniejszy.
func _apply_fill_tint(material_id: String) -> void:
	var kind: String = "barley" if material_id.begins_with("barley") else ("oats" if material_id.begins_with("oats") else "")
	var targets: Array = []
	if _fill_node is MeshInstance3D:
		targets.append(_fill_node)
	targets.append_array(_fill_node.find_children("*", "MeshInstance3D", true, true))
	for child in targets:
		var mesh_instance: MeshInstance3D = child
		if kind.is_empty():
			mesh_instance.material_override = null
			continue
		if not _tint_materials.has(kind):
			var source: Material = mesh_instance.mesh.surface_get_material(0)
			if not source is BaseMaterial3D:
				continue
			var tinted: BaseMaterial3D = source.duplicate()
			if kind == "barley":
				tinted.albedo_color = Color(1.0, 0.97, 0.8)
			else:
				# Owies: jaśniej – kolor podbity lekką emisją w odcieniu słomy.
				tinted.emission_enabled = true
				tinted.emission = Color("#5a5030")
			_tint_materials[kind] = tinted
		mesh_instance.material_override = _tint_materials.get(kind)


# ---------------------------------------------------------------------------
# Naczepa: taśmociąg, tylne drzwi, nogi podporowe
# ---------------------------------------------------------------------------

## Ładunek naczepy jako bryła z „profilem”: przekroje wzdłuż skrzyni, każdy z własną wysokością.
## Podczas rozładunku taśmą poziom opada od tyłu do przodu (pochyła powierzchnia), poza tym
## ziarno leży równo. Profil: h(u) = clamp(c + PROFILE_SLOPE·u, 0, h0), u = 0 przy tylnej
## ścianie, 1 przy przedniej; c dobierane tak, by objętość = zapełnienie.
const PROFILE_SECTIONS: int = 24
const PROFILE_SLOPE: float = 1.6

func _update_conveyor_fill(ratio: float, storage: Dictionary) -> void:
	if _profile_mesh_size == Vector3.ZERO:
		_init_profile()
	var state: Dictionary = instance_state.get("unloading_state", {})
	var flowing: bool = float(state.get("flow_l_per_s", 0.0)) > 0.0
	if ratio <= 0.0005 or ratio > _last_amount_ratio + 0.0005:
		_profile_ramp = false            # pusta albo dosypana: ziarno leży równo
	if flowing and not _profile_ramp:
		_profile_ramp = true
		_profile_level = maxf(_profile_level, ratio)
	if not _profile_ramp:
		_profile_level = ratio
		_profile_offset = ratio
	else:
		_profile_offset = _solve_profile(ratio, _profile_level)
	_last_amount_ratio = ratio
	_fill_node.visible = ratio > 0.002
	_fill_node.scale = Vector3.ONE
	var key := Vector2(snappedf(_profile_offset, 0.002), snappedf(_profile_level, 0.002))
	if key != _profile_key:
		_profile_key = key
		_build_profile_mesh()
	var material_id: String = str(storage.get("material_id", ""))
	if material_id != _fill_material_id:
		_fill_material_id = material_id
		_apply_fill_tint(material_id)


func _init_profile() -> void:
	var mesh: Mesh = (_fill_node as MeshInstance3D).mesh if _fill_node is MeshInstance3D else null
	if mesh == null:
		_profile_mesh_size = Vector3.ONE
		return
	var box: AABB = mesh.get_aabb()
	_profile_mesh_size = box.size
	_profile_x = Vector2(box.position.x, box.end.x)
	_profile_material = mesh.surface_get_material(0)
	# Kolor modeli pochodzi z tekstury palety (UV) – nowa bryła używa UV ziarna z oryginału.
	var arrays: Array = mesh.surface_get_arrays(0)
	var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
	if uvs is PackedVector2Array and not (uvs as PackedVector2Array).is_empty():
		_profile_uv = uvs[0]
	var colors: Variant = arrays[Mesh.ARRAY_COLOR]
	if colors is PackedColorArray and not (colors as PackedColorArray).is_empty():
		_profile_color = colors[0]


## Objętość (0..1) profilu o przesunięciu c i maksymalnej wysokości h0.
func _profile_volume(c: float, h0: float) -> float:
	var sum: float = 0.0
	for i in 64:
		var u: float = (i + 0.5) / 64.0
		sum += clampf(c + PROFILE_SLOPE * u, 0.0, h0)
	return sum / 64.0


func _solve_profile(volume: float, h0: float) -> float:
	var low: float = -PROFILE_SLOPE
	var high: float = h0
	for i in 30:
		var mid: float = (low + high) * 0.5
		if _profile_volume(mid, h0) < volume:
			low = mid
		else:
			high = mid
	return (low + high) * 0.5


func _profile_height(u: float) -> float:
	var h0: float = _profile_level
	return clampf(_profile_offset + (PROFILE_SLOPE * u if _profile_ramp else 0.0), 0.0, h0) * _profile_mesh_size.y


func _build_profile_mesh() -> void:
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	tool.set_uv(_profile_uv)
	if _profile_color.a >= 0.0:
		tool.set_color(_profile_color)
	var x0: float = _profile_x.x
	var x1: float = _profile_x.y
	var length: float = _profile_mesh_size.z
	var heights: Array[float] = []
	for i in PROFILE_SECTIONS + 1:
		heights.append(maxf(_profile_height(float(i) / PROFILE_SECTIONS), 0.002))
	for i in PROFILE_SECTIONS:
		var za: float = -length * float(i) / PROFILE_SECTIONS
		var zb: float = -length * float(i + 1) / PROFILE_SECTIONS
		var ha: float = heights[i]
		var hb: float = heights[i + 1]
		_quad(tool, Vector3(x0, ha, za), Vector3(x1, ha, za), Vector3(x1, hb, zb), Vector3(x0, hb, zb))      # wierzch
		_quad(tool, Vector3(x0, 0, za), Vector3(x0, ha, za), Vector3(x0, hb, zb), Vector3(x0, 0, zb))        # lewy bok
		_quad(tool, Vector3(x1, ha, za), Vector3(x1, 0, za), Vector3(x1, 0, zb), Vector3(x1, hb, zb))        # prawy bok
	_quad(tool, Vector3(x0, 0, 0), Vector3(x1, 0, 0), Vector3(x1, heights[0], 0), Vector3(x0, heights[0], 0))
	var zf: float = -length
	_quad(tool, Vector3(x1, 0, zf), Vector3(x0, 0, zf), Vector3(x0, heights[-1], zf), Vector3(x1, heights[-1], zf))
	tool.generate_normals()
	var mesh: ArrayMesh = tool.commit()
	if _profile_material != null:
		mesh.surface_set_material(0, _profile_material)
	(_fill_node as MeshInstance3D).mesh = mesh


func _quad(tool: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	for p in [a, b, c, a, c, d]:
		tool.add_vertex(p)


## Tylne drzwi naczepy uchylają się nad miejscem rozładunku; strumień ziarna, gdy płynie.
func _update_rear_door(delta: float) -> void:
	if _tipper != null or _tailgate == null:
		return
	var state: Dictionary = instance_state.get("unloading_state", {})
	var storage: Dictionary = instance_state.get("storages", {}).get(_fill_storage_id, {})
	var open: bool = not str(state.get("zone_id", "")).is_empty() and float(storage.get("amount_l", 0.0)) > 0.0
	var unloading: Dictionary = definition["unloading"] if definition.get("unloading") is Dictionary else {}
	var delay: float = maxf(float(unloading.get("start_delay_seconds", 2.0)), 0.3)
	_door_angle = move_toward(_door_angle, DOOR_OPEN_DEG if open else 0.0, DOOR_OPEN_DEG / delay * delta)
	_tailgate.rotation.x = -deg_to_rad(_door_angle)
	if float(state.get("flow_l_per_s", 0.0)) > 0.0:
		_tip_flow_hold = 0.2
	else:
		_tip_flow_hold = maxf(0.0, _tip_flow_hold - delta)
	if _tip_stream == null:
		if _tip_flow_hold <= 0.0 or _fill_node == null:
			return
		_tip_stream = StreamScript.new()
		_tip_stream.name = "DoorStream"
		add_child(_tip_stream)
	var lip: Vector3 = _model.to_global(_fill_node.position + Vector3(0.0, 0.1, 0.35))
	_tip_stream.call("update_stream", _tip_flow_hold > 0.0, lip, 0.08, 1.6)


## Nogi podporowe: po podpięciu podnoszą się (animacja), po odpięciu od razu stoją na ziemi.
func _update_legs(delta: float) -> void:
	if _legs == null:
		return
	if Machines.is_attached(machine):
		_legs_raise = move_toward(_legs_raise, 1.0, delta / LEGS_RAISE_SECONDS)
	else:
		_legs_raise = 0.0
	_legs.position.y = _legs_y + LEGS_RAISE_M * smoothstep(0.0, 1.0, _legs_raise)


# ---------------------------------------------------------------------------
# Rozsiewacz nawozu: tarcze kręcą się i rzucają granulki na boki i do tyłu (low poly)
# ---------------------------------------------------------------------------
# Granulki to proste CPUParticles3D (bez fizyki i kolizji): wspólna siatka, materiał bez
# cieniowania, symulacja 30 razy/s. Trzy strumienie odpowiadają trójkątowi obszaru pracy:
# dwa długie na boki (do krawędzi trójkąta) i jeden krótki do tyłu (środek podstawy).

const SPREAD_SIDE_AMOUNT: int = 70
const SPREAD_REAR_AMOUNT: int = 45
const SPREAD_FPS: int = 30
var _granule_mesh: BoxMesh


## Granulki lecą tylko gdy rozsiewacz pracuje (B), jedzie i ma nawóz.
func _update_spreader(delta: float) -> void:
	if _spinners.is_empty():
		return
	if _spread_emitters.is_empty():
		for spinner in _spinners:
			_spread_emitters.append(_make_side_emitter(spinner))
		_spread_emitters.append(_make_rear_emitter())
	var storage: Dictionary = instance_state.get("storages", {}).get(_fill_storage_id, {})
	var has_material: bool = float(storage.get("amount_l", 0.0)) > 0.0
	var motion: float = 0.0
	if Machines.is_attached(machine):
		motion = Machines.speed_m_s(machine, units)
	var working: bool = _is_working() and has_material
	for spinner in _spinners:
		if working:
			spinner.rotation.y += delta * 22.0 * (1.0 if str(spinner.name).ends_with("R") else -1.0)
	for emitter in _spread_emitters:
		emitter.emitting = working and motion > 0.3


func _new_emitter(emitter_name: String, amount: int, lifetime: float) -> CPUParticles3D:
	if _granule_mesh == null:
		_granule_mesh = BoxMesh.new()
		_granule_mesh.size = Vector3(0.07, 0.07, 0.07)
		var material := StandardMaterial3D.new()
		material.albedo_color = Color("#f4f1e8")
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_granule_mesh.material = material
	var emitter := CPUParticles3D.new()
	emitter.name = emitter_name
	emitter.amount = amount
	emitter.lifetime = lifetime
	emitter.fixed_fps = SPREAD_FPS
	emitter.fract_delta = true
	emitter.local_coords = false
	emitter.emitting = false
	emitter.mesh = _granule_mesh
	emitter.gravity = Vector3(0.0, -9.8, 0.0)
	emitter.scale_amount_min = 0.6
	emitter.scale_amount_max = 1.2
	return emitter


## Strumień na bok: między tylną osią a krawędzią trójkąta, aż do końca podstawy.
func _make_side_emitter(spinner: Node3D) -> CPUParticles3D:
	var side: float = 1.0 if str(spinner.name).ends_with("R") else -1.0
	var emitter: CPUParticles3D = _new_emitter("Spread_" + str(spinner.name), SPREAD_SIDE_AMOUNT, 0.9)
	# Model: przód w −Z, więc „do tyłu i na bok” to (±x, w górę, +z).
	var edge_deg: float = _spread_edge_deg()            # kąt krawędzi trójkąta od osi poprzecznej
	var center_deg: float = edge_deg + (90.0 - edge_deg) * 0.35
	var flat := Vector2(side * cos(deg_to_rad(center_deg)), sin(deg_to_rad(center_deg)))
	emitter.direction = Vector3(flat.x, 0.32, flat.y)
	emitter.spread = (90.0 - edge_deg) * 0.3
	var reach: float = _spread_reach_m()
	# Lot z ~0,45 m przy składowej pionowej 0,32 trwa ok. 0,85 s – prędkość dobrana do zasięgu.
	emitter.initial_velocity_min = reach * 0.6 / 0.85
	emitter.initial_velocity_max = reach * 1.05 / 0.85
	# Obok tarczy, nie na niej: kierunek wyrzutu nie może kręcić się razem z tarczą.
	spinner.get_parent().add_child(emitter)
	emitter.position = spinner.position + Vector3(0.0, 0.05, 0.0)
	return emitter


## Strumień do tyłu: wachlarz między tarczami, krótki – do podstawy trójkąta za maszyną.
func _make_rear_emitter() -> CPUParticles3D:
	var emitter: CPUParticles3D = _new_emitter("Spread_Rear", SPREAD_REAR_AMOUNT, 0.6)
	emitter.direction = Vector3(0.0, 0.35, 1.0)
	emitter.spread = 55.0
	var depth: float = _spread_depth_m()
	emitter.initial_velocity_min = depth * 0.5 / 0.5
	emitter.initial_velocity_max = depth * 1.0 / 0.5
	var parent: Node3D = _spinners[0].get_parent()
	parent.add_child(emitter)
	var center := Vector3.ZERO
	for spinner in _spinners:
		center += spinner.position
	emitter.position = center / _spinners.size() + Vector3(0.0, 0.05, 0.1)
	return emitter


## Głębokość trójkąta rozrzutu za tarczami (m): od wierzchołka do podstawy.
func _spread_depth_m() -> float:
	var points: Array = definition.get("work", {}).get("area", {}).get("polygon_m", [])
	if points.size() < 3:
		return 3.0
	return maxf(1.0, absf(float(points[1][1]) - float(points[0][1])))


## Kąt (stopnie) krawędzi trójkąta rozrzutu od osi poprzecznej maszyny (np. 17° dla 20 m × 3 m).
func _spread_edge_deg() -> float:
	var points: Array = definition.get("work", {}).get("area", {}).get("polygon_m", [])
	if points.size() < 3:
		return 20.0
	var apex := Vector2(float(points[0][0]), float(points[0][1]))
	var corner := Vector2(float(points[1][0]), float(points[1][1]))
	var edge: Vector2 = corner - apex
	return rad_to_deg(atan2(absf(edge.y), absf(edge.x)))


## Zasięg rozrzutu na bok (m): połowa podstawy trójkąta.
func _spread_reach_m() -> float:
	var area: Dictionary = definition.get("work", {}).get("area", {})
	return maxf(2.0, float(area.get("width_m", 20.0)) * 0.5)
