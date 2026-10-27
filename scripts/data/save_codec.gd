extends RefCounted
## Zapis gry: migawka stanu świata (capture) i przygotowanie zapisu do wczytania (prepare_session:
## walidacja, migracje starszych formatów, wyrównanie zapisanych zestawów zaczepów).
## Jedyne miejsce migracji formatu zapisu.
const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const RouteCodec = preload("res://scripts/core/routes/route_codec.gd")
var last_error: String = ""

func capture(session: Dictionary, machines: Dictionary, fields: Node, units: float) -> Dictionary:
	var game: Dictionary = session["save_data"].duplicate(true)
	var instances: Array = []
	for machine in machines.values():
		var state: Dictionary = machine.get_meta("instance_state").duplicate(true)
		# Poza nadwozia (protokół maszyny: pose_body), nie węzła organizacyjnego.
		var pose: Transform2D = (machine.call("pose_body") as Node2D).global_transform
		state["transform"] = {"position_m": [pose.origin.x / units, pose.origin.y / units], "rotation_deg": rad_to_deg(pose.get_rotation())}
		for key in ["motion", "articulated_state", "steering_input", "parking_brake_engaged"]:
			state.erase(key)
		instances.append(state)
	game["machine_instances"] = instances
	# Trasy: próbki kodowane zwarto (core/routes/route_codec.gd); w pamięci zostają tablice.
	if game.get("recorded_routes") is Array:
		var routes: Array = []
		for route in game["recorded_routes"]:
			routes.append(RouteCodec.pack(route) if route is Dictionary else route)
		game["recorded_routes"] = routes
	fields.call("write_to_save", game)
	game["document_type"] = "save_game"
	game["last_saved_at_utc"] = Time.get_datetime_string_from_system(true)
	var clock: Dictionary = game.get("clock", {})
	clock["offline_progress_enabled"] = false
	clock["mode"] = "simulation_time"
	game["clock"] = clock
	return game

func prepare_session(base: Dictionary, saved_game: Dictionary) -> Dictionary:
	last_error = ""
	var game: Dictionary = saved_game.duplicate(true)
	var models: Dictionary = base["models_by_id"]
	var instances: Dictionary = {}
	if not game.get("references") is Dictionary or not game.get("player") is Dictionary:
		return _fail("Brak nagłówka zapisu.")
	for key in ["map", "machine_catalog"]:
		if not game["references"].get(key) is Dictionary:
			return _fail("Brak odwołania do konfiguracji: " + key)
		if game["references"][key].get("id") != base["save_data"]["references"][key]["id"]:
			return _fail("Zapis pochodzi z innej mapy lub katalogu: " + key)
	if not game.get("machine_instances") is Array or not game.get("connections") is Array:
		return _fail("Niepoprawna lista maszyn lub połączeń.")
	for value in game["machine_instances"]:
		if not value is Dictionary:
			return _fail("Niepoprawny wpis maszyny.")
		var state: Dictionary = value
		var id: String = str(state.get("instance_id", ""))
		var model_id: String = str(state.get("model_id", ""))
		if id.is_empty() or instances.has(id) or not models.has(model_id):
			return _fail("Nieznana lub powtórzona maszyna: " + id + " / " + model_id)
		var model: Dictionary = models[model_id]
		var transform: Dictionary = state.get("transform", {})
		if not _vec_valid(transform.get("position_m")) or not _number(transform.get("rotation_deg")):
			return _fail("Niepoprawna pozycja maszyny: " + id)
		if not _validate_storages(state, model):
			return {}
		state["motion"] = {"linear_velocity_m_per_s": [0.0, 0.0], "angular_velocity_deg_per_s": 0.0}
		state["steering_input"] = 0.0
		state["parking_brake_engaged"] = true
		state["articulated_state"] = {}
		if str(model["physics_kind"]) == "towed_turntable":
			state["articulated_state"] = {"front_carriage": {"relative_rotation_deg": 0.0, "relative_angular_velocity_deg_per_s": 0.0}}
		if model.get("work") is Dictionary:
			state["work_state"] = {"enabled": false, "lowered": false}
		else:
			state["work_state"] = null
		instances[id] = state
	var controlled: String = str(game["player"].get("controlled_machine_id", ""))
	if not instances.has(controlled) or str(models[instances[controlled]["model_id"]]["physics_kind"]) != "powered_vehicle":
		return _fail("Zapis nie wskazuje poprawnego pojazdu gracza.")
	if not game["player"].get("camera") is Dictionary:
		game["player"]["camera"] = {"target_instance_id": controlled, "zoom": 1.0, "rotation_offset_deg": 0.0}
	var used_parents: Dictionary = {}
	var used_children: Dictionary = {}
	for value in game["connections"]:
		if not value is Dictionary:
			return _fail("Niepoprawny wpis połączenia.")
		var link: Dictionary = value
		var parent_id: String = str(link.get("parent_instance_id", ""))
		var child_id: String = str(link.get("child_instance_id", ""))
		if not instances.has(parent_id) or not instances.has(child_id) or parent_id == child_id:
			return _fail("Połączenie odwołuje się do nieistniejącej maszyny.")
		if used_parents.has(parent_id) or used_children.has(child_id):
			return _fail("Maszyna występuje w kilku połączeniach.")
		var parent: Dictionary = instances[parent_id]
		var child: Dictionary = instances[child_id]
		var parent_model: Dictionary = models[parent["model_id"]]
		var child_model: Dictionary = models[child["model_id"]]
		if str(parent_model["physics_kind"]) != "powered_vehicle":
			return _fail("Ten etap obsługuje podpinanie narzędzi do pojazdów napędzanych.")
		var socket: Dictionary = _port(parent_model, str(link.get("parent_port_id", "")))
		var plug: Dictionary = _port(child_model, str(link.get("child_port_id", "")))
		if socket.is_empty() or plug.is_empty() or socket["role"] != "socket" or plug["role"] != "plug" or socket["type"] != plug["type"]:
			return _fail("Niezgodne zaczepy zapisanej pary.")
		if not _align_connection(parent, child, child_model, socket, plug):
			return {}
		used_parents[parent_id] = true
		used_children[child_id] = true
	if not _validate_fields(game, base["map_data"]):
		return {}
	if game.get("recorded_routes") is Array:
		var routes: Array = []
		for route in game["recorded_routes"]:
			var decoded: Dictionary = RouteCodec.unpack(route) if route is Dictionary else {}
			if decoded.is_empty():
				return _fail("Uszkodzona trasa w zapisie.")
			routes.append(decoded)
		game["recorded_routes"] = routes
	var result: Dictionary = base.duplicate(true)
	result["save_data"] = game
	result["instances_by_id"] = instances
	# Wszystkie odwołania wskazują te same słowniki co machine_instances.
	return result

func _align_connection(parent: Dictionary, child: Dictionary, model: Dictionary,
		socket: Dictionary, plug: Dictionary) -> bool:
	var parent_angle: float = deg_to_rad(float(parent["transform"]["rotation_deg"]))
	var angle: float = deg_to_rad(float(child["transform"]["rotation_deg"]))
	var anchor: Vector2 = _vec(parent["transform"]["position_m"]) + _vec(socket["position_m"]).rotated(parent_angle)
	var offset: Vector2
	match str(model["physics_kind"]):
		"towed_turntable":
			if str(plug["member"]) != "front_carriage":
				_fail("Nieobsługiwane mocowanie przyczepy.")
				return false
			var pivot_local: Vector2 = _vec(model["front_carriage"]["pivot_in_body_m"])
			var pivot: Vector2 = _vec(child["transform"]["position_m"]) + pivot_local.rotated(angle)
			var plug_local: Vector2 = _vec(plug["position_m"])
			var vector_to_anchor: Vector2 = anchor - pivot
			if vector_to_anchor.length_squared() < 0.000001 or plug_local.length_squared() < 0.000001:
				_fail("Nie można odtworzyć kierunku dyszla.")
				return false
			var relative: float = wrapf(vector_to_anchor.angle() - plug_local.angle() - angle, -PI, PI)
			var limits: Dictionary = model["front_carriage"]["turntable_limit_deg"]
			relative = clampf(relative, deg_to_rad(float(limits["min"])), deg_to_rad(float(limits["max"])))
			child["articulated_state"]["front_carriage"]["relative_rotation_deg"] = rad_to_deg(relative)
			offset = pivot_local.rotated(angle) + plug_local.rotated(angle + relative)
		"towed_single_axle", "towed_semitrailer":
			offset = _vec(plug["position_m"]).rotated(angle)
		"rigid_mounted":
			angle = parent_angle + deg_to_rad(float(socket.get("mount_rotation_deg", 0.0)) - float(plug.get("mount_rotation_deg", 0.0)))
			child["transform"]["rotation_deg"] = rad_to_deg(angle)
			offset = _vec(plug["position_m"]).rotated(angle)
		_:
			_fail("Nieobsługiwany typ podpiętej maszyny.")
			return false
	var position: Vector2 = anchor - offset
	child["transform"]["position_m"] = [position.x, position.y]
	return true

func _validate_storages(state: Dictionary, model: Dictionary) -> bool:
	if not state.get("storages") is Dictionary:
		_fail("Brak zbiorników maszyny: " + str(state["instance_id"]))
		return false
	for definition in model.get("storage_definitions", []):
		var storage: Dictionary = state["storages"].get(str(definition["id"]), {})
		if not _number(storage.get("amount_l")):
			_fail("Niepoprawna ilość materiału w zbiorniku.")
			return false
		var amount: float = float(storage["amount_l"])
		# Starsze zapisy: nasiona pszenicy/jęczmienia -> jedno ziarno siewne, gatunek jako ustawienie siewnika.
		var legacy: String = str(storage.get("material_id", ""))
		if legacy in ["wheat_seed", "barley_seed"] and definition["accepted_material_ids"].has("seed"):
			storage["material_id"] = "seed"
			if not state.has("seed_crop_id"):
				state["seed_crop_id"] = legacy.trim_suffix("_seed")
		if amount < 0.0 or amount > float(definition["capacity_l"]) + 0.000001:
			_fail("Zawartość zbiornika przekracza aktualną pojemność: " + str(state["instance_id"]))
			return false
		if amount > 0.0 and not definition["accepted_material_ids"].has(storage.get("material_id")):
			_fail("Nieobsługiwany materiał w zbiorniku.")
			return false
		if amount == 0.0:
			storage["material_id"] = null
	return true

func _validate_fields(game: Dictionary, map_data: Dictionary) -> bool:
	if not game.get("field_states") is Array:
		_fail("Brak stanów pól.")
		return false
	var states: Dictionary = {}
	for saved in game["field_states"]:
		if not saved is Dictionary or states.has(str(saved.get("field_id", ""))):
			_fail("Niepoprawna lista pól.")
			return false
		states[str(saved["field_id"])] = saved
	for field in map_data["fields"]:
		var id: String = str(field["id"])
		if not states.has(id):
			# Pole dodane do mapy po utworzeniu zapisu: zaczyna jako puste.
			var fresh: Dictionary = {"field_id": id}
			game["field_states"].append(fresh)
			states[id] = fresh
			push_warning("Zapis nie zawiera pola %s — dodano je jako puste." % id)
		var saved: Dictionary = states[id]
		if saved.has("growth_simulation") and (int(saved["growth_simulation"].get("columns", 0)) != int(field["grid"]["columns"]) or int(saved["growth_simulation"].get("rows", 0)) != int(field["grid"]["rows"])):
			# Pole na mapie zmieniło rozmiar: starego stanu komórek nie da się przenieść.
			saved.erase("growth_simulation")
			push_warning("Pole %s ma nowy rozmiar na mapie — zaczyna jako puste." % id)
		if not saved.has("growth_simulation"):
			continue # Początkowe pole z szablonu jest odczytywane przez istniejący FieldWork.
		var growth: Dictionary = saved["growth_simulation"]
		var columns: int = int(field["grid"]["columns"])
		var rows: int = int(field["grid"]["rows"])
		var count: int = columns * rows
		if not ["field_cells_v3", "field_cells_v2", "growth_batches_v1"].has(str(growth.get("encoding", ""))) or int(growth.get("columns", 0)) != columns or int(growth.get("rows", 0)) != rows:
			_fail("Niezgodna siatka pola: " + id)
			return false
		if str(growth["encoding"]) == "field_cells_v3":
			# Bajt na komórkę (faza | gatunek | nawożenie), deflate + base64 – patrz field_grid.gd.
			var packed: PackedByteArray = FieldCells.unpack_cells(growth, count)
			if packed.is_empty():
				_fail("Uszkodzony zapis pola: " + id)
				return false
			for index in count:
				if (packed[index] & 7) > 5:
					_fail("Niepoprawna komórka pola: " + id)
					return false
			continue
		for key in ["states", "crops", "generations"]:
			if not growth.get(key) is Array or growth[key].size() != count:
				_fail("Niekompletna siatka pola: " + id)
				return false
		for index in count:
			if not _integer(growth["states"][index], 0, 5) or not _integer(growth["generations"][index], 0, 2147483647) or not growth["crops"][index] is String:
				_fail("Niepoprawna komórka pola: " + id)
				return false
	return true

func _port(model: Dictionary, id: String) -> Dictionary:
	for port in model["hitch_ports"]:
		if str(port["id"]) == id:
			return port
	return {}

func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))

func _vec_valid(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _number(value[0]) and _number(value[1])

func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

func _integer(value: Variant, minimum: int, maximum: int) -> bool:
	return _number(value) and float(value) == floorf(float(value)) and float(value) >= minimum and float(value) <= maximum

func _fail(message: String) -> Dictionary:
	last_error = message
	return {}
