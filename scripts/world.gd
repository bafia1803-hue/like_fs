extends Node3D
## Świat gry: łączy trzy oddzielne warstwy.
##
## 1. Warstwa gry ("Simulation", Node2D): fizyka Rapier2D, maszyny, zaczepy, praca na polu,
##    przeładunek ziarna, usługi farmy, trasy, zapis. Nic nie rysuje.
## 2. Widoki ("View2D", "View3D"): tylko czytają stan gry przez metody get_* poniżej
##    i rysują go po swojemu. Można je przełączać klawiszem V; nieaktywny widok jest
##    odłączony od drzewa sceny, więc nie zużywa czasu.
## 3. Interfejs ("Interface"): panel tras, informator, komunikaty, przyciski.

signal world_ready
signal world_failed(message: String)
signal save_requested
signal menu_requested
signal quit_requested

const RouteSystemScript = preload("res://scripts/route_system.gd")
const RoutePanelScript = preload("res://scripts/route_panel.gd")
const SaveCodecScript = preload("res://scripts/save_codec.gd")
const DataLoaderScript = preload("res://scripts/data_loader.gd")
const VehicleScript = preload("res://scripts/vehicle.gd")
const PlayerDriverScript = preload("res://scripts/player_driver.gd")
const TrailerScript = preload("res://scripts/trailer.gd")
const HitchSystemScript = preload("res://scripts/hitch_system.gd")
const SingleAxleScript = preload("res://scripts/single_axle_implement.gd")
const MountedScript = preload("res://scripts/mounted_implement.gd")
const GrainTransferScript = preload("res://scripts/grain_transfer_system.gd")
const FieldWorkScript = preload("res://scripts/field_work_system.gd")
const ObstaclesScript = preload("res://scripts/static_obstacles.gd")
const FarmServicesScript = preload("res://scripts/farm_services.gd")
const View2DScript = preload("res://scripts/view2d/view_2d.gd")
const View3DScript = preload("res://scripts/view3d/view_3d.gd")
const InformatorScript = preload("res://scripts/ui/informator.gd")

const UNITS_PER_METER: float = 40.0
const SETTINGS_PATH: String = "user://settings.cfg"
const VIEW_2D: String = "2d"
const VIEW_3D: String = "3d"
const SLEEP_DARKEN_SECONDS: float = 1.6
const SLEEP_HOLD_SECONDS: float = 0.5
const SLEEP_BRIGHTEN_SECONDS: float = 1.9

@export_file("*.json") var initial_save_path: String = "res://files/save.json"

var saved_game: Dictionary = {}
var save_slot: int = 0
var managed_by_menu: bool = false

var session: Dictionary = {}
var machines_by_id: Dictionary = {}
var view_mode: String = VIEW_3D

var _sim: Node2D
var _machines_root: Node2D
var _controlled_vehicle: RigidBody2D
var _vehicles: Array[RigidBody2D] = []
var _driver: Node
var _hitches: Node2D
var _field_work: Node2D
var _grain_transfer: Node2D
var _farm: Node2D
var _routes: Node2D
var _world_rect: Rect2 = Rect2()
var _world_loaded: bool = false

var _views: Dictionary = {}              # tryb -> węzeł widoku
var _interface: CanvasLayer
var _informator: Control
var _view_button: Button
## Panel diagnostyczny (F3). Domyślnie ukryty; komunikaty gry pokazuje krótki dymek u góry.
var _show_debug: bool = false
var _status_panel: PanelContainer
var _status_label: Label
var _toast: Label
var _toast_time: float = 0.0
var _message: String = ""
var _hud_timer: float = 0.0
var _sleep_curtain: ColorRect
var _sleeping: bool = false
var _sleep_message: String = ""


func _ready() -> void:
	_sim = Node2D.new()
	_sim.name = "Simulation"
	add_child(_sim)
	_create_interface()
	var physics_engine: String = str(ProjectSettings.get_setting("physics/2d/physics_engine", "DEFAULT"))
	print("Wybrany silnik fizyki 2D: ", physics_engine)
	if not physics_engine.to_lower().contains("rapier"):
		_show_error("Ten etap wymaga Rapier2D. Wybierz go w Project Settings → Physics → 2D → Physics Engine i uruchom ponownie edytor.")
		return
	if not _create_simulation():
		return
	var route_panel = RoutePanelScript.new()
	route_panel.configure(_routes, self)
	_interface.add_child(route_panel)
	_create_views()
	_world_loaded = true
	_status_panel.visible = _show_debug
	_informator.call("configure", self)
	_update_hud()
	print("Wczytano maszyn: ", machines_by_id.size())
	world_ready.emit()


# ---------------------------------------------------------------------------
# Warstwa gry
# ---------------------------------------------------------------------------

func _create_simulation() -> bool:
	var loader = DataLoaderScript.new()
	session = loader.load_session(initial_save_path)
	if session.is_empty():
		_show_error(loader.last_error)
		return false
	var codec = SaveCodecScript.new()
	var source: Dictionary = session["save_data"] if saved_game.is_empty() else saved_game
	session = codec.prepare_session(session, source)
	if session.is_empty():
		_show_error(codec.last_error)
		return false
	var map_data: Dictionary = session["map_data"]
	var bounds: Dictionary = map_data.get("world_bounds", {})
	if (bounds.get("origin_m", []) as Array).size() != 2 or (bounds.get("size_m", []) as Array).size() != 2:
		_show_error("Mapa nie zawiera poprawnego world_bounds.")
		return false
	_world_rect = Rect2(_vec(bounds["origin_m"]) * UNITS_PER_METER, _vec(bounds["size_m"]) * UNITS_PER_METER)

	var obstacles = ObstaclesScript.new()
	_sim.add_child(obstacles)
	if not obstacles.configure(map_data, UNITS_PER_METER):
		_show_error(obstacles.last_error)
		return false

	_create_machines()
	if _controlled_vehicle == null:
		_show_error("Sterowana maszyna nie jest pojazdem fizycznym.")
		return false

	var system = HitchSystemScript.new()
	system.name = "HitchSystem"
	var catalog: Dictionary = session["catalog_data"]
	system.configure(machines_by_id, session["save_data"], catalog["attachment_policy"], UNITS_PER_METER)
	_sim.add_child(system)
	_hitches = system
	if not system.restore_connections():
		_show_error("Nie udało się odtworzyć połączeń. Szczegóły w Output.")
		get_tree().paused = true
		return false

	var field_work = FieldWorkScript.new()
	field_work.name = "FieldWork"
	_sim.add_child(field_work)
	if not field_work.configure(session, machines_by_id, _hitches, UNITS_PER_METER):
		_show_error(field_work.last_error)
		get_tree().paused = true
		return false
	_field_work = field_work
	field_work.work_message.connect(_on_work_message)

	var grain_transfer = GrainTransferScript.new()
	grain_transfer.name = "GrainTransfer"
	_sim.add_child(grain_transfer)
	if not grain_transfer.configure(session, machines_by_id, UNITS_PER_METER):
		_show_error(grain_transfer.last_error)
		get_tree().paused = true
		return false
	_grain_transfer = grain_transfer

	var farm = FarmServicesScript.new()
	_sim.add_child(farm)
	if not farm.configure(session, machines_by_id, grain_transfer, UNITS_PER_METER):
		_show_error(farm.last_error)
		get_tree().paused = true
		return false
	_farm = farm

	var routes = RouteSystemScript.new()
	routes.name = "Routes"
	_sim.add_child(routes)
	if not routes.configure(session, _hitches, _field_work, UNITS_PER_METER):
		_show_error(routes.last_error)
		return false
	_routes = routes
	routes.message.connect(show_save_message)
	return true


func _create_machines() -> void:
	_machines_root = Node2D.new()
	_machines_root.name = "Machines"
	_sim.add_child(_machines_root)
	var models: Dictionary = session["models_by_id"]
	var instances: Dictionary = session["instances_by_id"]
	var catalog: Dictionary = session["catalog_data"]
	var materials: Array = catalog["materials"]

	for instance_id in instances:
		var saved_state: Dictionary = instances[instance_id]
		var model_data: Dictionary = models[str(saved_state["model_id"])]
		# Maszyny wczytujemy w zapisanej pozie, ale zatrzymane.
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
	body.position = _vec(saved_pose["position_m"]) * UNITS_PER_METER
	body.rotation = deg_to_rad(float(saved_pose["rotation_deg"]))
	var collision_data: Dictionary = model_data["physics"]["body_collision"]
	var shape := RectangleShape2D.new()
	shape.size = Vector2(float(collision_data["width_m"]), float(collision_data["length_m"])) * UNITS_PER_METER
	var collider := CollisionShape2D.new()
	collider.name = "BodyCollision"
	collider.shape = shape
	collider.position = _vec(collision_data["center_m"]) * UNITS_PER_METER
	collider.rotation = deg_to_rad(float(collision_data["rotation_deg"]))
	body.add_child(collider)
	return body


# ---------------------------------------------------------------------------
# Interfejs dla widoków i UI (tylko odczyt)
# ---------------------------------------------------------------------------

func get_units_per_meter() -> float:
	return UNITS_PER_METER

func get_world_rect_m() -> Rect2:
	return Rect2(_world_rect.position / UNITS_PER_METER, _world_rect.size / UNITS_PER_METER)

func get_map_data() -> Dictionary:
	return session["map_data"]

func get_catalog() -> Dictionary:
	return session["catalog_data"]

func get_machines() -> Dictionary:
	return machines_by_id

func get_controlled_vehicle() -> RigidBody2D:
	return _controlled_vehicle

func get_attached_machine(vehicle: Node) -> Node2D:
	return _hitches.call("get_attached_machine", vehicle) as Node2D

func get_field_grids() -> Array:
	return _field_work.get("fields")

func get_farming_settings() -> Dictionary:
	return _field_work.get("settings")

func get_route_system() -> Node2D:
	return _routes

func get_silos() -> Array:
	return _grain_transfer.call("get_silos")

func get_farm_points() -> Array:
	return _farm.call("get_points")

## Komunikaty przeładunku i usług farmy dotyczące danej maszyny.
func get_machine_statuses(machine: Node) -> PackedStringArray:
	var result := PackedStringArray()
	var id: String = str(machine.get_meta("instance_state")["instance_id"])
	for source in [_grain_transfer, _farm]:
		var text: String = str(source.call("get_status", id))
		if not text.is_empty():
			result.append(text)
	return result


# ---------------------------------------------------------------------------
# Widoki
# ---------------------------------------------------------------------------

func _create_views() -> void:
	view_mode = _load_view_mode()
	for mode in [VIEW_2D, VIEW_3D]:
		var view: Node = View2DScript.new() if mode == VIEW_2D else View3DScript.new()
		add_child(view)
		view.call("setup", self)
		_views[mode] = view
	_apply_view_mode()


func _apply_view_mode() -> void:
	for mode in _views:
		var view: Node = _views[mode]
		var active: bool = mode == view_mode
		# Nieaktywny widok jest odłączony od drzewa: nie rysuje i nie liczy niczego.
		if active and not view.is_inside_tree():
			add_child(view)
		elif not active and view.is_inside_tree():
			remove_child(view)
		view.call("set_active", active)
	var active_view: Node = _views[view_mode]
	active_view.call("follow", _controlled_vehicle)
	if _view_button != null:
		_view_button.text = "Widok 2D (V)" if view_mode == VIEW_3D else "Widok 3D (V)"


func toggle_view() -> void:
	view_mode = VIEW_2D if view_mode == VIEW_3D else VIEW_3D
	_apply_view_mode()
	_save_view_mode()
	_notify("Widok " + view_mode.to_upper())


func get_active_view() -> Node:
	return _views.get(view_mode)


func _load_view_mode() -> String:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) == OK:
		var mode: String = str(config.get_value("view", "mode", VIEW_3D))
		if mode == VIEW_2D or mode == VIEW_3D:
			return mode
	return VIEW_3D


func _save_view_mode() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	config.set_value("view", "mode", view_mode)
	config.save(SETTINGS_PATH)


func _exit_tree() -> void:
	# Odłączone widoki nie są dziećmi świata, więc zwalniamy je ręcznie.
	for view in _views.values():
		if is_instance_valid(view) and not view.is_inside_tree():
			view.queue_free()


# ---------------------------------------------------------------------------
# Sterowanie i HUD
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if not _world_loaded:
		return
	var clock: Dictionary = session["save_data"].get("clock", {})
	clock["elapsed_world_s"] = float(clock.get("elapsed_world_s", 0.0)) + delta
	session["save_data"]["clock"] = clock
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
				get_active_view().call("show_overview")
				get_viewport().set_input_as_handled()
			KEY_F:
				get_active_view().call("follow", _controlled_vehicle)
				get_viewport().set_input_as_handled()
			KEY_B:
				if is_instance_valid(_controlled_vehicle):
					_notify(str(_field_work.call("toggle_work", _controlled_vehicle)))
				get_viewport().set_input_as_handled()
			KEY_N:
				sleep()
				get_viewport().set_input_as_handled()
			KEY_V:
				toggle_view()
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


## Sen: ekran ciemnieje do czerni, w pełnej ciemności rośliny przechodzą do kolejnej fazy,
## potem ekran się rozjaśnia. Razem SLEEP_*_SECONDS (ok. 4 s).
##
## Blokada sterowania: na czas snu pauzujemy całe drzewo gry (get_tree().paused).
## Wszystkie skrypty świata są PAUSABLE, więc same przestają dostawać klawisze, kliknięcia
## i kroki fizyki – bez sprawdzania flagi "śpię" w każdym miejscu. Działa tylko to, co ma
## PROCESS_MODE_ALWAYS: zasłona z animacją oraz odświeżanie stanu pól (żeby po rozjaśnieniu
## były już widoczne nowe rośliny). Zasłona dodatkowo łapie myszkę nad interfejsem.
func sleep() -> void:
	if _sleeping or not _world_loaded:
		return
	_sleeping = true
	get_tree().paused = true
	_sleep_curtain.color.a = 0.0
	_sleep_curtain.visible = true
	var tween: Tween = _sleep_curtain.create_tween()
	# Zapadanie zmroku: szybko na początku, wolniej pod koniec.
	tween.tween_property(_sleep_curtain, "color:a", 1.0, SLEEP_DARKEN_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_pass_night)
	tween.tween_interval(SLEEP_HOLD_SECONDS)
	# Świt: wolno na początku, szybciej pod koniec.
	tween.tween_property(_sleep_curtain, "color:a", 0.0, SLEEP_BRIGHTEN_SECONDS) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_wake_up)


func _pass_night() -> void:
	var grown: int = int(_field_work.call("sleep"))
	_sleep_message = "Noc minęła — rośliny urosły." if grown > 0 else "Noc minęła — na polu nic nie rośnie."


func _wake_up() -> void:
	_sleep_curtain.visible = false
	get_tree().paused = false
	_sleeping = false
	_notify(_sleep_message)


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
	var player: Dictionary = session["save_data"]["player"]
	var state: Dictionary = _controlled_vehicle.get_meta("instance_state")
	player["controlled_machine_id"] = state["instance_id"]
	var camera_state: Dictionary = player["camera"]
	camera_state["target_instance_id"] = state["instance_id"]
	get_active_view().call("follow", _controlled_vehicle)
	var model: Dictionary = _controlled_vehicle.get_meta("definition")
	_notify("Sterujesz: " + str(model["name"]))


func _update_hud() -> void:
	if not _show_debug or not _world_loaded:
		return
	var lines: PackedStringArray = PackedStringArray()
	var model: Dictionary = _controlled_vehicle.get_meta("definition")
	lines.append("%s | %.1f km/h | masa: %.0f kg" % [model["name"],
		float(_controlled_vehicle.get_meta("route_speed_m_s", 0.0)) * 3.6 if not str(_controlled_vehicle.get_meta("route_mode", "")).is_empty() else float(_controlled_vehicle.call("get_speed_kmh")), _controlled_vehicle.mass])
	lines.append(str(_hitches.call("get_diagnostics", _controlled_vehicle)))
	var implement: Node2D = get_attached_machine(_controlled_vehicle)
	if implement != null and implement.has_method("get_diagnostics"):
		lines.append(str(implement.call("get_diagnostics")))
	lines.append(str(_field_work.call("get_diagnostics", _controlled_vehicle)))
	lines.append(str(_grain_transfer.call("get_diagnostics", _controlled_vehicle, implement)))
	lines.append(_message)
	_status_label.text = "\n".join(lines)


func _create_interface() -> void:
	_interface = CanvasLayer.new()
	_interface.name = "Interface"
	add_child(_interface)
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
	_interface.add_child(panel)
	_status_panel = panel
	_status_label = Label.new()
	_status_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.add_theme_color_override("font_color", Color.WHITE)
	_status_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_status_label.add_theme_constant_override("shadow_offset_x", 1)
	_status_label.add_theme_constant_override("shadow_offset_y", 1)
	_status_label.text = "Wczytywanie świata..."
	panel.add_child(_status_label)
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
	_interface.add_child(_toast)
	_informator = InformatorScript.new()
	_interface.add_child(_informator)
	_create_sleep_curtain()
	var controls := Control.new()
	controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_interface.add_child(controls)
	var bar := HBoxContainer.new()
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	bar.offset_top = -62
	bar.offset_right = -16
	bar.offset_bottom = -16
	bar.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	bar.add_theme_constant_override("separation", 10)
	controls.add_child(bar)
	var labels: Array = ["Sen (N)", "Widok 2D (V)"]
	if managed_by_menu:
		labels.append_array(["Zapisz (F9)", "Menu (Esc)", "Wyjdź"])
	for label in labels:
		var button := Button.new()
		button.text = label
		button.custom_minimum_size = Vector2(140, 0)
		button.focus_mode = Control.FOCUS_NONE
		bar.add_child(button)
		match label:
			"Sen (N)":
				button.pressed.connect(func(): if _world_loaded: sleep())
			"Widok 2D (V)":
				_view_button = button
				button.pressed.connect(func(): if _world_loaded: toggle_view())
			"Zapisz (F9)": button.pressed.connect(func(): save_requested.emit())
			"Menu (Esc)": button.pressed.connect(func(): menu_requested.emit())
			"Wyjdź": button.pressed.connect(func(): quit_requested.emit())


func _create_sleep_curtain() -> void:
	var layer := CanvasLayer.new()
	layer.name = "SleepCurtain"
	layer.layer = 100                       # nad całym interfejsem
	layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(layer)
	_sleep_curtain = ColorRect.new()
	_sleep_curtain.color = Color(0.0, 0.0, 0.0, 0.0)
	_sleep_curtain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_sleep_curtain.mouse_filter = Control.MOUSE_FILTER_STOP
	_sleep_curtain.process_mode = Node.PROCESS_MODE_ALWAYS
	_sleep_curtain.visible = false
	layer.add_child(_sleep_curtain)


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


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
