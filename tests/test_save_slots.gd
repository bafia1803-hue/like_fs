extends SceneTree
const ManagerScript = preload("res://scripts/save_manager.gd")
const CodecScript = preload("res://scripts/save_codec.gd")
const FieldScript = preload("res://scripts/field_work_system.gd")
var checks: int = 0
var failures: int = 0

class BodyMachine extends Node2D:
	var body: RigidBody2D
	var _ground_body: RigidBody2D

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, text: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error("FAIL: " + text)

func _read(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))

func _run() -> void:
	var template: Dictionary = _read("res://files/save.json")
	var catalog: Dictionary = _read("res://files/machines.json")
	var map: Dictionary = _read("res://files/map.json")
	var models: Dictionary = {}
	for model in catalog["machines"]:
		models[str(model["id"])] = model
	var base: Dictionary = {"save_data": template, "catalog_data": catalog, "map_data": map, "models_by_id": models}
	var codec = CodecScript.new()
	var session: Dictionary = codec.prepare_session(base, template)
	_check(not session.is_empty(), "Nowa gra z szablonu")
	var scene := Node2D.new()
	root.add_child(scene)
	var machines: Dictionary = {}
	for id in session["instances_by_id"]:
		var state: Dictionary = session["instances_by_id"][id]
		var model: Dictionary = models[state["model_id"]]
		var body := RigidBody2D.new()
		body.freeze = true
		body.gravity_scale = 0.0
		body.position = Vector2(state["transform"]["position_m"][0], state["transform"]["position_m"][1]) * 40.0
		body.rotation = deg_to_rad(float(state["transform"]["rotation_deg"]))
		var machine: Node2D = body
		if str(model["physics_kind"]) != "powered_vehicle":
			var wrapper := BodyMachine.new()
			wrapper.body = body
			if str(model["physics_kind"]) == "rigid_mounted":
				wrapper._ground_body = body
			wrapper.add_child(body)
			machine = wrapper
		machine.set_meta("definition", model)
		machine.set_meta("instance_state", state)
		scene.add_child(machine)
		machines[id] = machine
	var fields = FieldScript.new()
	scene.add_child(fields)
	fields.set_physics_process(false)
	_check(fields.configure(session, machines, null, 40.0), "Uruchomienie pól")
	var grid = fields.fields[0]
	grid.sow(0, "wheat")
	grid.advance(10.0)
	grid.sow(1, "barley")
	grid.advance(3.25)
	session["save_data"]["unload_point_states"] = [{"id": "silo_01", "contents_l": {"wheat_grain": 2345.5}}]
	session["instances_by_id"]["combine_01"]["storages"]["grain"] = {"material_id": "wheat_grain", "amount_l": 789.25}
	machines["combine_01"].global_position = Vector2(1234.0, 5678.0)
	machines["combine_01"].linear_velocity = Vector2(100, 50)
	machines["header_01"].body.global_position = Vector2(3000, 4000)
	# Migawka czyta aktualne ciała, a nie pozycję organizacyjnego węzła przyczepy.
	machines["trailer_01"].body.global_position = Vector2(2222, 3333)
	var snapshot: Dictionary = codec.capture(session, machines, fields, 40.0)
	for state in snapshot["machine_instances"]:
		_check(not state.has("motion") and not state.has("articulated_state"), "Brak prędkości i zawiasów w pliku: " + str(state["instance_id"]))
	var manager = ManagerScript.new()
	manager.directory = "user://slot_tests_%d" % Time.get_ticks_usec()
	_check(manager.write_slot(1, snapshot), "Zapis slotu 1")
	_check(manager.write_slot(2, template), "Zapis slotu 2")
	_check(not manager.slot_info(3)["occupied"], "Niezależny pusty slot 3")
	var loaded: Dictionary = manager.read_slot(1)["game"]
	var restored: Dictionary = codec.prepare_session(base, loaded)
	_check(not restored.is_empty(), "Odczyt pełnej migawki")
	_check(restored["instances_by_id"]["combine_01"]["motion"]["linear_velocity_m_per_s"] == [0.0, 0.0], "Po wczytaniu prędkość wynosi zero")
	_check(restored["instances_by_id"]["combine_01"]["transform"]["position_m"] == [30.85, 141.95], "Pozycja aktualnego ciała")
	_check(restored["instances_by_id"]["trailer_01"]["transform"]["position_m"] == [55.55, 83.325], "Pozycja nadwozia przyczepy")
	_check(restored["instances_by_id"]["header_01"]["transform"]["position_m"] == [75.0, 100.0], "Pozycja odpiętego ruchomego hedera")
	_check(restored["instances_by_id"]["combine_01"]["storages"]["grain"]["amount_l"] == 789.25, "Ziarno kombajnu")
	_check(loaded["unload_point_states"][0]["contents_l"]["wheat_grain"] == 2345.5, "Ziarno silosu")
	_check(loaded["field_states"][0]["growth_simulation"]["elapsed"] == 3.25, "Wspólny zegar wzrostu")
	var fields_restored = FieldScript.new()
	scene.add_child(fields_restored)
	fields_restored.set_physics_process(false)
	_check(fields_restored.configure(restored, machines, null, 40.0), "Odtworzenie siatki i partii")
	grid.advance(26.75)
	fields_restored.fields[0].advance(26.75)
	_check(grid.states == fields_restored.fields[0].states, "Dalszy wzrost identyczny po wczytaniu")
	_check(grid.crops == fields_restored.fields[0].crops, "Gatunki roślin zachowane")
	# Kopia awaryjna i odrzucenie uszkodzonego pliku głównego.
	var newer: Dictionary = snapshot.duplicate(true)
	newer["name"] = "Nowszy"
	_check(manager.write_slot(1, newer), "Kolejny zapis tworzy backup")
	var corrupt := FileAccess.open(manager.slot_path(1), FileAccess.WRITE)
	corrupt.store_string("{broken"); corrupt.close()
	_check(manager.read_slot(1)["game"]["name"] == snapshot["name"], "Odczyt poprzedniej poprawnej kopii")
	_check(not manager.last_warning.is_empty(), "Komunikat o odzyskaniu kopii")
	_check(manager.write_slot(1, newer), "Zapis po odzyskaniu nie niszczy dobrej kopii")
	_check(manager.slot_info(1)["loadable"], "Slot znowu dostępny")
	_check(not manager.write_slot(4, snapshot), "Odrzucenie nieistniejącego slotu")
	# Błąd dysku/katalogu: nie zgłasza powodzenia.
	var blocked_path: String = manager.directory.path_join("blocked")
	var blocked := FileAccess.open(blocked_path, FileAccess.WRITE)
	blocked.store_string("not a directory"); blocked.close()
	var failed_manager = ManagerScript.new()
	failed_manager.directory = blocked_path
	_check(not failed_manager.write_slot(1, snapshot), "Błąd zapisu nie jest sukcesem")
	# Rekonstrukcja dyszla z geometrii podpiętych maszyn, bez zapisanego kąta.
	var articulated: Dictionary = template.duplicate(true)
	var tractor: Dictionary = articulated["machine_instances"][0]
	var trailer: Dictionary = articulated["machine_instances"][1]
	var socket: Dictionary = models["tractor_basic"]["hitch_ports"][0]
	var plug: Dictionary = models["trailer_basic"]["hitch_ports"][0]
	var parent_angle: float = 0.7
	var body_angle: float = 0.3
	var relative: float = deg_to_rad(23.0)
	tractor["transform"]["rotation_deg"] = rad_to_deg(parent_angle)
	trailer["transform"]["rotation_deg"] = rad_to_deg(body_angle)
	var anchor := Vector2(35, 55) + Vector2(socket["position_m"][0], socket["position_m"][1]).rotated(parent_angle)
	var pivot: Array = models["trailer_basic"]["front_carriage"]["pivot_in_body_m"]
	var position: Vector2 = anchor - Vector2(pivot[0], pivot[1]).rotated(body_angle) - Vector2(plug["position_m"][0], plug["position_m"][1]).rotated(body_angle + relative)
	trailer["transform"]["position_m"] = [position.x, position.y]
	articulated["connections"] = [{"parent_instance_id": "tractor_01", "parent_port_id": socket["id"], "child_instance_id": "trailer_01", "child_port_id": plug["id"]}]
	var derived: Dictionary = codec.prepare_session(base, articulated)
	_check(not derived.is_empty(), "Odtworzenie podpiętej przyczepy")
	_check(absf(float(derived["instances_by_id"]["trailer_01"]["articulated_state"]["front_carriage"]["relative_rotation_deg"]) - 23.0) < 0.001, "Kąt zawiasu wyliczony z położeń")
	articulated["connections"][0]["child_instance_id"] = "missing"
	_check(codec.prepare_session(base, articulated).is_empty(), "Odrzucenie uszkodzonego połączenia")
	var broken_field: Dictionary = snapshot.duplicate(true)
	broken_field["field_states"][0]["growth_simulation"]["pending"] = [[9999999, 1]]
	_check(codec.prepare_session(base, broken_field).is_empty(), "Walidacja indeksów partii wzrostu")
	# Usuwamy wyłącznie własny, unikalny katalog testu.
	for file_name in DirAccess.get_files_at(manager.directory):
		DirAccess.remove_absolute(manager.directory.path_join(file_name))
	DirAccess.remove_absolute(manager.directory)
	scene.free()
	print("SAVE SLOTS: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
