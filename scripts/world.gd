extends Node3D
## Świat gry. Symulacja (fizyka Rapier2D, zaczepy, praca na polu, trasy, zapis) działa
## w ukrytym węźle 2D "Simulation", a gracz widzi jej odwzorowanie w 3D (węzeł "View3D").
## Teren jest płaski, więc fizyka z widoku z góry daje ten sam wynik co pełne 3D.

signal world_ready
signal world_failed(message: String)
signal save_requested
signal menu_requested
signal quit_requested
const RouteSystemScript = preload("res://scripts/route_system.gd")
const RoutePanelScript = preload("res://scripts/route_panel.gd")
var _routes: Node2D

const EnvironmentScript = preload("res://scripts/world_environment_3d.gd")
const TerrainScript = preload("res://scripts/terrain_3d.gd")
const FieldViewScript = preload("res://scripts/field_view_3d.gd")
const MachineView3DScript = preload("res://scripts/machine_view_3d.gd")
const CameraRigScript = preload("res://scripts/camera_rig_3d.gd")
const RouteView3DScript = preload("res://scripts/route_view_3d.gd")

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

@export_file("*.json") var initial_save_path: String = "res://files/save.json"

var session: Dictionary = {}
var machines_by_id: Dictionary = {}
var _machines_root: Node2D
var _controlled_vehicle: RigidBody2D
var _vehicles: Array[RigidBody2D] = []
var _driver: Node
var _sim: Node2D
var _view3d: Node3D
var _camera_rig: Node3D
var _terrain: Node3D
var _status_label: Label
var _world_rect: Rect2 = Rect2()
var _world_loaded: bool = false
var _silo_timer: float = 0.0
## Panel diagnostyczny (F3). Domyślnie ukryty; komunikaty gry pokazuje krótki dymek u góry.
var _show_debug: bool = false
var _status_panel: PanelContainer
var _toast: Label
var _toast_time: float = 0.0
var _views_by_id: Dictionary = {}
var _hitches: Node2D
var _field_work: Node2D
var _grain_transfer: Node2D
var _message: String = "TAB przełącza pojazd. E podpina najbliższe zgodne narzędzie."
var _hud_timer: float = 0.0


func _ready() -> void:
	_sim = Node2D.new()
	_sim.name = "Simulation"
	# Rysunki 2D są ukryte; fizyka i logika działają niezależnie od widoczności.
	_sim.visible = false
	add_child(_sim)
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
	_sim.add_child(map_view)
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
	_sim.add_child(system)
	_hitches = system
	if not system.restore_connections():
		_show_error("Nie udało się odtworzyć połączeń. Szczegóły w Output.")
		get_tree().paused = true
		return

	var field_work = FieldWorkScript.new()
	field_work.name = "FieldWork"
	_sim.add_child(field_work)
	if not field_work.configure(session, machines_by_id, _hitches, UNITS_PER_METER):
		_show_error(field_work.last_error)
		get_tree().paused = true
		return
	_field_work = field_work
	field_work.work_message.connect(_on_work_message)

	var grain_transfer = GrainTransferScript.new()
	grain_transfer.name = "GrainTransfer"
	_sim.add_child(grain_transfer)
	if not grain_transfer.configure(session, machines_by_id, UNITS_PER_METER):
		_show_error(grain_transfer.last_error)
		get_tree().paused = true
		return
	_grain_transfer = grain_transfer

	var routes = RouteSystemScript.new()
	routes.name = "Routes"
	_sim.add_child(routes)
	if not routes.configure(session, _hitches, _field_work, UNITS_PER_METER):
		_show_error(routes.last_error)
		return
	_routes = routes
	routes.message.connect(show_save_message)
	var route_panel = RoutePanelScript.new()
	route_panel.configure(routes, self)
	get_node("Interface").add_child(route_panel)

	_create_view_3d()
	_world_loaded = true
	_status_panel.visible = _show_debug
	_focus_starting_machine()
	_update_hud()
	print("Wczytano maszyn: ", machines_by_id.size())
	world_ready.emit()


func _create_machines() -> void:
	_machines_root = Node2D.new()
	_machines_root.name = "Machines"
	_machines_root.z_index = 1
	_sim.add_child(_machines_root)
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
	_sim.add_child(driver)
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
	_silo_timer += delta
	if _silo_timer >= 0.5 and _terrain != null and _grain_transfer != null:
		_silo_timer = 0.0
		_terrain.call("update_silos", _grain_transfer.call("get_silos"))
	if _toast_time > 0.0:
		_toast_time -= delta
		_toast.modulate.a = clampf(_toast_time / 0.6, 0.0, 1.0)
		_toast.visible = _toast_time > 0.0
	_hud_timer += delta
	if _hud_timer >= 0.15:
		_hud_timer = 0.0
		_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if not _world_loaded:
		return
	if event is InputEventKey and event.pressed and not event.echo:
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
			KEY_F3:
				_show_debug = not _show_debug
				_status_panel.visible = _show_debug
				_update_hud()
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
		_notify(str(_hitches.call("toggle_for", _controlled_vehicle)))
		print(_message)


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
	_camera_rig.call("follow", _controlled_vehicle, true, _view_of(_controlled_vehicle))
	var model: Dictionary = _controlled_vehicle.get_meta("definition")
	_notify("Sterujesz: " + str(model["name"]))


func _update_hud() -> void:
	if not _show_debug:
		return
	var lines: PackedStringArray = PackedStringArray()
	var model: Dictionary = _controlled_vehicle.get_meta("definition")
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
	_camera_rig.call("follow", _controlled_vehicle, true, _view_of(_controlled_vehicle))


func _view_of(machine: Node) -> Node3D:
	var state: Dictionary = machine.get_meta("instance_state")
	return _views_by_id.get(str(state["instance_id"])) as Node3D


func _fit_camera_to_map() -> void:
	if not _world_loaded:
		return
	_camera_rig.call("show_overview")


## Widok 3D symulacji: otoczenie, pola, modele maszyn, trasy i kamera.
func _create_view_3d() -> void:
	_view3d = Node3D.new()
	_view3d.name = "View3D"
	add_child(_view3d)
	var environment_node = EnvironmentScript.new()
	environment_node.name = "Environment"
	_view3d.add_child(environment_node)
	var map_data: Dictionary = session["map_data"]
	var terrain = TerrainScript.new()
	terrain.configure(map_data)
	_view3d.add_child(terrain)
	_terrain = terrain
	terrain.call("update_silos", _grain_transfer.call("get_silos"))
	var definitions: Dictionary = {}
	for field_data in map_data["fields"]:
		definitions[str(field_data["id"])] = field_data
	for grid in _field_work.get("fields"):
		var field_view = FieldViewScript.new()
		field_view.configure(grid, definitions[str(grid.field_id)], _field_work.get("settings"))
		_view3d.add_child(field_view)
	var machines_3d := Node3D.new()
	machines_3d.name = "Machines3D"
	_view3d.add_child(machines_3d)
	var ids: Array = machines_by_id.keys()
	ids.sort()
	for id in ids:
		var view = MachineView3DScript.new()
		view.configure(machines_by_id[id], UNITS_PER_METER)
		machines_3d.add_child(view)
		_views_by_id[id] = view
	var route_view = RouteView3DScript.new()
	route_view.configure(_routes, UNITS_PER_METER)
	_view3d.add_child(route_view)
	var rig = CameraRigScript.new()
	rig.name = "CameraRig"
	_view3d.add_child(rig)
	var rect_m := Rect2(_world_rect.position / UNITS_PER_METER, _world_rect.size / UNITS_PER_METER)
	rig.configure(rect_m, UNITS_PER_METER)
	_camera_rig = rig


func _create_interface() -> void:
	var layer := CanvasLayer.new()
	layer.name = "Interface"
	add_child(layer)
	var panel := PanelContainer.new()
	panel.name = "StatusPanel"
	panel.position = Vector2(12, 10)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.11, 0.09, 0.42)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	panel.add_theme_stylebox_override("panel", style)
	layer.add_child(panel)
	_status_panel = panel
	_toast = Label.new()
	_toast.name = "Toast"
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_top = 18
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast.add_theme_font_size_override("font_size", 18)
	_toast.add_theme_color_override("font_color", Color("#fffaf0"))
	_toast.add_theme_color_override("font_outline_color", Color(0.12, 0.1, 0.08, 0.9))
	_toast.add_theme_constant_override("outline_size", 6)
	_toast.visible = false
	layer.add_child(_toast)
	_status_label = Label.new()
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color.WHITE)
	_status_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_status_label.add_theme_constant_override("shadow_offset_x", 1)
	_status_label.add_theme_constant_override("shadow_offset_y", 1)
	_status_label.text = "Wczytywanie świata..."
	panel.add_child(_status_label)
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
	_status_panel.visible = true
	world_failed.emit(message)
	push_error(message)
	_status_label.text = "Nie udało się uruchomić świata.\n" + message
	_status_label.add_theme_color_override("font_color", Color("#ff8c8c"))


func _on_work_message(vehicle: RigidBody2D, text: String) -> void:
	if vehicle == _controlled_vehicle:
		_notify(text)


func capture_save() -> Dictionary:
	if not _world_loaded:
		return {}
	if _routes != null:
		_routes.before_save()
	var codec = SaveCodecScript.new()
	return codec.capture(session, machines_by_id, _field_work, UNITS_PER_METER)


func show_save_message(text: String) -> void:
	_notify(text)


## Krótki komunikat u góry ekranu (podpięcie, zapis, zmiana pojazdu itp.).
func _notify(text: String) -> void:
	_message = text
	if text.is_empty() or _toast == null:
		return
	_toast.text = text
	_toast.visible = true
	_toast.modulate.a = 1.0
	_toast_time = 3.5
	if _world_loaded:
		_update_hud()
