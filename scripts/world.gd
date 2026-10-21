extends Node2D

signal world_ready
signal world_failed(message: String)
signal save_requested
signal menu_requested
signal quit_requested
const RouteSystemScript = preload("res://scripts/route_system.gd")
const RoutePanelScript = preload("res://scripts/route_panel.gd")
var _routes: Node2D

const SaveCodecScript = preload("res://scripts/save_codec.gd")
var saved_game: Dictionary = {}
var save_slot: int = 0
var managed_by_menu: bool = false

const DataLoaderScript = preload("res://scripts/data_loader.gd")
const MapViewScript = preload("res://scripts/map_view.gd")
const MachineViewScript = preload("res://scripts/machine_view.gd")
const VehicleScript = preload("res://scripts/vehicle.gd")
const PlayerDriverScript = preload("res://scripts/player_driver.gd")
const TrailerScript = preload("res://scripts/trailer.gd")
const HitchSystemScript = preload("res://scripts/hitch_system.gd")
const SingleAxleScript = preload("res://scripts/single_axle_implement.gd")
const MountedScript = preload("res://scripts/mounted_implement.gd")

const GrainTransferScript = preload("res://scripts/grain_transfer_system.gd")
const FieldWorkScript = preload("res://scripts/field_work_system.gd")

const UNITS_PER_METER: float = 40.0
const CAMERA_SPEED_SCREEN: float = 600.0

@export_file("*.json") var initial_save_path: String = "res://files/save.json"

var session: Dictionary = {}
var machines_by_id: Dictionary = {}
var _machines_root: Node2D
var _controlled_vehicle: RigidBody2D
var _vehicles: Array[RigidBody2D] = []
var _driver: Node
var _camera: Camera2D
var _status_label: Label
var _world_rect: Rect2 = Rect2()
var _world_loaded: bool = false
var _camera_follows_vehicle: bool = false
var _minimum_zoom: float = 0.01
var _maximum_zoom: float = 4.0
var _hitches: Node2D
var _field_work: Node2D
var _grain_transfer: Node2D
var _message: String = "TAB przełącza pojazd. E podpina najbliższe zgodne narzędzie."
var _hud_timer: float = 0.0


func _ready() -> void:
	_create_interface()
	var physics_engine: String = str(ProjectSettings.get_setting(
		"physics/2d/physics_engine", "DEFAULT"
	))
	print("Wybrany silnik fizyki 2D: ", physics_engine)
	if not physics_engine.to_lower().contains("rapier"):
		_show_error("Ten etap wymaga Rapier2D. Wybierz go w Project Settings → Physics → 2D → Physics Engine i uruchom ponownie edytor.")
		return

	var loader = DataLoaderScript.new()
	session = loader.load_session(initial_save_path)
	if session.is_empty():
		_show_error(loader.last_error)
		return

	var codec = SaveCodecScript.new()
	var source: Dictionary = session["save_data"] if saved_game.is_empty() else saved_game
	session = codec.prepare_session(session, source)
	if session.is_empty():
		_show_error(codec.last_error)
		return

	var map_view = MapViewScript.new()
	map_view.name = "MapView"
	if not map_view.configure(session["map_data"], UNITS_PER_METER):
		_show_error(map_view.last_error)
		map_view.free()
		return
	add_child(map_view)
	_world_rect = map_view.get_world_rect()
	_create_machines()
	if _controlled_vehicle == null:
		_show_error("Sterowana maszyna nie jest pojazdem fizycznym.")
		return

	var system = HitchSystemScript.new()
	system.name = "HitchSystem"
	var catalog: Dictionary = session["catalog_data"]
	system.configure(machines_by_id, session["save_data"],
		catalog["attachment_policy"], UNITS_PER_METER)
	add_child(system)
	_hitches = system
	if not system.restore_connections():
		_show_error("Nie udało się odtworzyć połączeń. Szczegóły w Output.")
		get_tree().paused = true
		return

	var field_work = FieldWorkScript.new()
	field_work.name = "FieldWork"
	add_child(field_work)
	if not field_work.configure(session, machines_by_id, _hitches, UNITS_PER_METER):
		_show_error(field_work.last_error)
		get_tree().paused = true
		return
	_field_work = field_work
	field_work.work_message.connect(_on_work_message)

	var grain_transfer = GrainTransferScript.new()
	grain_transfer.name = "GrainTransfer"
	add_child(grain_transfer)
	if not grain_transfer.configure(session, machines_by_id, UNITS_PER_METER):
		_show_error(grain_transfer.last_error)
		get_tree().paused = true
		return
	_grain_transfer = grain_transfer

	var routes = RouteSystemScript.new()
	routes.name = "Routes"
	add_child(routes)
	if not routes.configure(session, _hitches, _field_work, UNITS_PER_METER):
		_show_error(routes.last_error)
		return
	_routes = routes
	routes.message.connect(show_save_message)
	var route_panel = RoutePanelScript.new()
	route_panel.configure(routes, self)
	get_node("Interface").add_child(route_panel)

	_camera = Camera2D.new()
	_camera.name = "WorldCamera"
	_camera.position_smoothing_enabled = false
	add_child(_camera)
	_camera.make_current()
	_world_loaded = true
	call_deferred("_fit_camera_to_map")
	call_deferred("_focus_starting_machine")
	get_viewport().size_changed.connect(_fit_camera_to_map)
	_update_hud()
	print("Wczytano maszyn: ", machines_by_id.size())
	world_ready.emit()


func _create_machines() -> void:
	_machines_root = Node2D.new()
	_machines_root.name = "Machines"
	_machines_root.z_index = 1
	add_child(_machines_root)
	var models: Dictionary = session["models_by_id"]
	var instances: Dictionary = session["instances_by_id"]
	var catalog: Dictionary = session["catalog_data"]
	var materials: Array = catalog["materials"]

	for instance_id in instances:
		var saved_state: Dictionary = instances[instance_id]
		var model_data: Dictionary = models[str(saved_state["model_id"])]
		# Ten etap wczytuje maszyny w zapisanej pozie, ale zatrzymane.
		var motion: Dictionary = saved_state["motion"]
		motion["linear_velocity_m_per_s"] = [0.0, 0.0]
		motion["angular_velocity_deg_per_s"] = 0.0
		saved_state["parking_brake_engaged"] = true
		var machine: Node2D
		match str(model_data["physics_kind"]):
			"powered_vehicle":
				var vehicle = VehicleScript.new()
				vehicle.configure(model_data, saved_state, materials, UNITS_PER_METER)
				machine = vehicle
				_vehicles.append(vehicle)
			"towed_turntable":
				var articulated: Dictionary = saved_state["articulated_state"]
				var front: Dictionary = articulated["front_carriage"]
				front["relative_angular_velocity_deg_per_s"] = 0.0
				var trailer = TrailerScript.new()
				trailer.configure(model_data, saved_state, materials, UNITS_PER_METER)
				machine = trailer
			"towed_single_axle":
				var implement = SingleAxleScript.new()
				implement.configure(model_data, saved_state, materials, UNITS_PER_METER)
				machine = implement
			"rigid_mounted":
				var mounted = MountedScript.new()
				mounted.configure(model_data, saved_state, materials, UNITS_PER_METER)
				machine = mounted
			_:
				machine = _create_parked_machine(model_data, saved_state)
		machine.set_meta("definition", model_data)
		machine.set_meta("instance_state", saved_state)
		_machines_root.add_child(machine)
		machines_by_id[instance_id] = machine

	var save_data: Dictionary = session["save_data"]
	var player: Dictionary = save_data["player"]
	_controlled_vehicle = machines_by_id.get(str(player["controlled_machine_id"])) as RigidBody2D
	if _controlled_vehicle == null:
		return
	var driver = PlayerDriverScript.new()
	driver.name = "PlayerDriver"
	driver.configure(_controlled_vehicle)
	add_child(driver)
	_driver = driver


func _create_parked_machine(model_data: Dictionary, saved_state: Dictionary) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.name = str(saved_state["instance_id"])
	body.collision_layer = 1
	body.collision_mask = 1
	var saved_pose: Dictionary = saved_state["transform"]
	var position_m: Array = saved_pose["position_m"]
	body.position = Vector2(float(position_m[0]), float(position_m[1])) * UNITS_PER_METER
	body.rotation = deg_to_rad(float(saved_pose["rotation_deg"]))
	var physics_data: Dictionary = model_data["physics"]
	var collision_data: Dictionary = physics_data["body_collision"]
	var shape := RectangleShape2D.new()
	shape.size = Vector2(float(collision_data["width_m"]), float(collision_data["length_m"])) * UNITS_PER_METER
	var collider := CollisionShape2D.new()
	collider.name = "BodyCollision"
	collider.shape = shape
	var center_m: Array = collision_data["center_m"]
	collider.position = Vector2(float(center_m[0]), float(center_m[1])) * UNITS_PER_METER
	collider.rotation = deg_to_rad(float(collision_data["rotation_deg"]))
	body.add_child(collider)
	var visual = MachineViewScript.new()
	visual.configure(model_data, saved_state, UNITS_PER_METER)
	visual.name = "Visual"
	visual.position = Vector2.ZERO
	visual.rotation = 0.0
	body.add_child(visual)
	return body


func _process(delta: float) -> void:
	if not _world_loaded:
		return
	var clock: Dictionary = session["save_data"].get("clock", {})
	clock["elapsed_world_s"] = float(clock.get("elapsed_world_s", 0.0)) + delta
	session["save_data"]["clock"] = clock
	var direction := Vector2(
		float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_UP))
	)
	if direction.length_squared() > 0.0:
		_camera_follows_vehicle = false
		_camera.position += direction.normalized() * CAMERA_SPEED_SCREEN * delta / _camera.zoom.x
	elif _camera_follows_vehicle and is_instance_valid(_controlled_vehicle):
		_camera.position = _controlled_vehicle.position
	_hud_timer += delta
	if _hud_timer >= 0.15:
		_hud_timer = 0.0
		_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not _world_loaded:
		return
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_change_zoom(1.15)
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_change_zoom(1.0 / 1.15)
			get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F9:
				save_requested.emit()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				menu_requested.emit()
				get_viewport().set_input_as_handled()
			KEY_HOME:
				_fit_camera_to_map()
				get_viewport().set_input_as_handled()
			KEY_F:
				_focus_starting_machine()
				get_viewport().set_input_as_handled()
			KEY_TAB:
				call_deferred("_switch_vehicle")
				get_viewport().set_input_as_handled()
			KEY_E:
				# Zmiany przegubów wykonujemy poza callbackami fizyki.
				call_deferred("_toggle_attachment")
				get_viewport().set_input_as_handled()


func _toggle_attachment() -> void:
	if _world_loaded and is_instance_valid(_controlled_vehicle):
		_message = str(_hitches.call("toggle_for", _controlled_vehicle))
		print(_message)
		_update_hud()


func _switch_vehicle() -> void:
	if _routes != null and not _routes.recording.is_empty():
		show_save_message("Zakończ nagrywanie przed przełączeniem pojazdu.")
		return
	if not _world_loaded or _vehicles.size() < 2:
		return
	var current: int = _vehicles.find(_controlled_vehicle)
	_controlled_vehicle = _vehicles[(current + 1) % _vehicles.size()]
	_driver.call("configure", _controlled_vehicle)
	var save_data: Dictionary = session["save_data"]
	var player: Dictionary = save_data["player"]
	var state: Dictionary = _controlled_vehicle.get_meta("instance_state")
	player["controlled_machine_id"] = state["instance_id"]
	var camera_state: Dictionary = player["camera"]
	camera_state["target_instance_id"] = state["instance_id"]
	_camera_follows_vehicle = true
	_camera.position = _controlled_vehicle.position
	var model: Dictionary = _controlled_vehicle.get_meta("definition")
	_message = "Sterujesz: " + str(model["name"])
	_update_hud()


func _update_hud() -> void:
	var lines: PackedStringArray = PackedStringArray()
	var model: Dictionary = _controlled_vehicle.get_meta("definition")
	lines.append("TAB: pojazd | W/S: jazda | A/D: skręt | Spacja: hamulec | E: zaczep")
	lines.append("F: śledź pojazd | Home: mapa | Strzałki: kamera | Kółko: zoom")
	lines.append("%s | %.1f km/h | masa: %.0f kg" % [model["name"],
		float(_controlled_vehicle.get_meta("route_speed_m_s", 0.0)) * 3.6 if not str(_controlled_vehicle.get_meta("route_mode", "")).is_empty() else float(_controlled_vehicle.call("get_speed_kmh")), _controlled_vehicle.mass])
	lines.append(str(_hitches.call("get_diagnostics", _controlled_vehicle)))
	var implement: Node2D = _hitches.call("get_attached_machine", _controlled_vehicle) as Node2D
	if implement != null and implement.has_method("get_diagnostics"):
		lines.append(str(implement.call("get_diagnostics")))
	if _field_work != null:
		lines.append(str(_field_work.call("get_diagnostics", _controlled_vehicle)))
	if _grain_transfer != null:
		lines.append(str(_grain_transfer.call("get_diagnostics", _controlled_vehicle, implement)))
	lines.append(_message)
	_status_label.text = "\n".join(lines)


func _focus_starting_machine() -> void:
	if not _world_loaded or not is_instance_valid(_controlled_vehicle):
		return
	_camera_follows_vehicle = true
	_camera.position = _controlled_vehicle.position
	_camera.zoom = Vector2.ONE * clampf(1.0, _minimum_zoom, _maximum_zoom)


func _change_zoom(multiplier: float) -> void:
	_camera.zoom = Vector2.ONE * clampf(_camera.zoom.x * multiplier, _minimum_zoom, _maximum_zoom)


func _fit_camera_to_map() -> void:
	if not _world_loaded:
		return
	_camera_follows_vehicle = false
	var viewport_size: Vector2 = get_viewport_rect().size
	var available := Vector2(maxf(viewport_size.x - 80.0, 1.0), maxf(viewport_size.y - 200.0, 1.0))
	var fit_zoom: float = minf(available.x / _world_rect.size.x, available.y / _world_rect.size.y)
	_minimum_zoom = fit_zoom / 4.0
	_maximum_zoom = maxf(4.0, fit_zoom * 4.0)
	_camera.position = _world_rect.get_center()
	_camera.zoom = Vector2.ONE * fit_zoom


func _create_interface() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Interface"
	add_child(layer)
	_status_label = Label.new()
	_status_label.position = Vector2(16, 12)
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.add_theme_font_size_override("font_size", 16)
	_status_label.add_theme_color_override("font_color", Color.WHITE)
	_status_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_status_label.add_theme_constant_override("shadow_offset_x", 1)
	_status_label.add_theme_constant_override("shadow_offset_y", 1)
	_status_label.text = "Wczytywanie świata..."
	layer.add_child(_status_label)
	if managed_by_menu:
		var controls := Control.new()
		controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
		layer.add_child(controls)
		var bar := HBoxContainer.new()
		bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
		bar.offset_left = -490
		bar.offset_top = -62
		bar.offset_right = -16
		bar.offset_bottom = -16
		bar.add_theme_constant_override("separation", 10)
		controls.add_child(bar)
		for label in ["Zapisz (F9)", "Menu (Esc)", "Wyjdź"]:
			var button := Button.new()
			button.text = label
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.focus_mode = Control.FOCUS_NONE
			bar.add_child(button)
			match label:
				"Zapisz (F9)": button.pressed.connect(func(): save_requested.emit())
				"Menu (Esc)": button.pressed.connect(func(): menu_requested.emit())
				"Wyjdź": button.pressed.connect(func(): quit_requested.emit())


func _show_error(message: String) -> void:
	world_failed.emit(message)
	push_error(message)
	_status_label.text = "Nie udało się uruchomić świata.\n" + message
	_status_label.add_theme_color_override("font_color", Color("#ff8c8c"))


func _on_work_message(vehicle: RigidBody2D, text: String) -> void:
	if vehicle == _controlled_vehicle:
		_message = text


func capture_save() -> Dictionary:
	if not _world_loaded:
		return {}
	if _routes != null:
		_routes.before_save()
	var codec = SaveCodecScript.new()
	return codec.capture(session, machines_by_id, _field_work, UNITS_PER_METER)


func show_save_message(text: String) -> void:
	_message = text
	if _world_loaded:
		_update_hud()
