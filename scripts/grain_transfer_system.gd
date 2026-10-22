extends Node2D
## Przeładunek ziarna (warstwa gry): rura kombajnu, wywrotka, silosy, skup zboża. Nie rysuje.
const Storage = preload("res://scripts/grain_storage.gd")
const PipeScript = preload("res://scripts/unloading_pipe.gd")
var last_error: String = ""
var _units: float = 40.0
var _materials: Dictionary = {}
var _pipes: Array[Dictionary] = []
var _receivers: Array[Dictionary] = []
var _tippers: Array[Dictionary] = []
var _silos: Array[Dictionary] = []
var _sell_points: Array[Dictionary] = []   # skup: wywrotka sprzedaje ziarno za pieniądze
var _status: Dictionary = {}
var _economy: Node

func configure(session: Dictionary, machines: Dictionary, units: float) -> bool:
	_units = units
	for material in session["catalog_data"]["materials"]:
		_materials[str(material["id"])] = material
	var save: Dictionary = session["save_data"]
	if not save.has("unload_point_states"):
		save["unload_point_states"] = []
	var saved_points: Array = save["unload_point_states"]
	var known_ids: Dictionary = {}
	for definition in session["map_data"].get("unload_points", []):
		var id: String = str(definition["id"])
		if known_ids.has(id):
			return _fail("Powtórzony silos: " + id)
		known_ids[id] = true
		if not _valid_area(definition["area"]) or float(definition["capacity_l"]) <= 0.0:
			return _fail("Niepoprawny obszar lub pojemność silosu: " + id)
		var saved: Dictionary = {}
		for entry in saved_points:
			if str(entry["id"]) == id:
				saved = entry
				break
		if saved.is_empty():
			saved = {"id": id, "contents_l": {}}
			saved_points.append(saved)
		for material in saved.get("contents_l", {}):
			if not definition["accepted_material_ids"].has(material) or float(saved["contents_l"][material]) < 0.0:
				return _fail("Niepoprawna zawartość silosu: " + id)
		if Storage.silo_total(saved) > float(definition["capacity_l"]) + 0.000001:
			return _fail("Zapis silosu przekracza pojemność: " + id)
		_silos.append({"definition": definition, "state": saved,
			"polygon": Storage.rectangle(Transform2D.IDENTITY, definition["area"], units)})

	for definition in session["map_data"].get("sell_points", []):
		if not _valid_area(definition["area"]):
			return _fail("Niepoprawny obszar skupu: " + str(definition.get("id", "?")))
		_sell_points.append({"definition": definition, "sold_l": 0.0, "earned": 0.0,
			"polygon": Storage.rectangle(Transform2D.IDENTITY, definition["area"], units)})

	var ids: Array = machines.keys()
	ids.sort()
	for id in ids:
		if not register_machine(str(id), machines[id]):
			return false
	return true


## Skup płaci przez ekonomię (ustawiane przez świat).
func set_economy(economy: Node) -> void:
	_economy = economy


## Dodaje maszynę do przeładunku (także kupioną w trakcie gry).
func register_machine(id: String, machine: Node2D) -> bool:
	var model: Dictionary = machine.get_meta("definition")
	var saved: Dictionary = machine.get_meta("instance_state")
	if not saved.has("unloading_state"):
		saved["unloading_state"] = {}
	var runtime: Dictionary = saved["unloading_state"]
	var body: RigidBody2D = _body_of(machine)
	var receiving: Dictionary = model.get("receiving", {})
	if not receiving.is_empty():
		var target: Dictionary = saved["storages"].get(str(receiving["storage_id"]), {})
		var storage_def: Dictionary = Storage.storage_definition(model, str(receiving["storage_id"]))
		if body == null or target.is_empty() or storage_def.is_empty() or not _valid_area(receiving["area"]):
			return _fail("Niepoprawny odbiornik ziarna: " + id)
		_receivers.append({"machine": machine, "body": body, "area": receiving["area"],
			"storage": target, "definition": storage_def})
	var unloading: Dictionary = model.get("unloading", {})
	var mode: String = str(unloading.get("mode", ""))
	if mode.is_empty():
		return true
	var source: Dictionary = saved["storages"].get(str(unloading["source_storage_id"]), {})
	var source_def: Dictionary = Storage.storage_definition(model, str(unloading["source_storage_id"]))
	if body == null or source.is_empty() or source_def.is_empty() or float(unloading["max_transfer_l_per_s"]) <= 0.0:
		return _fail("Niepoprawny rozładunek maszyny: " + id)
	var record: Dictionary = {"id": id, "machine": machine, "body": body,
		"source": source, "source_definition": source_def, "config": unloading, "state": runtime}
	match mode:
		"pipe":
			var pipe_config: Dictionary = unloading["pipe"]
			if not ["left", "right"].has(str(pipe_config["side"])) or not _valid_area(pipe_config["detection_area"]):
				return _fail("Niepoprawna strona lub obszar rury: " + id)
			if float(pipe_config["length_m"]) <= 0.0 or float(pipe_config["extend_seconds"]) <= 0.0 or float(pipe_config["retract_seconds"]) <= 0.0:
				return _fail("Długość i czas ruchu rury muszą być dodatnie: " + id)
			if not runtime.has("pipe"):
				runtime["pipe"] = {}
			var pipe = PipeScript.new()
			pipe.name = "UnloadingPipe"
			pipe.configure(pipe_config, runtime["pipe"], _units)
			body.add_child(pipe)
			record["pipe"] = pipe
			_pipes.append(record)
		"tipper":
			if float(unloading["start_delay_seconds"]) < 0.0:
				return _fail("Opóźnienie rozładunku nie może być ujemne: " + id)
			_tippers.append(record)
		_:
			return _fail("Nieznany tryb rozładunku: " + mode)
	return true


## Usuwa maszynę z przeładunku (sprzedaż).
func unregister_machine(machine: Node2D) -> void:
	for list in [_receivers, _pipes, _tippers]:
		for index in range(list.size() - 1, -1, -1):
			if list[index]["machine"] == machine:
				list.remove_at(index)
	var state: Dictionary = machine.get_meta("instance_state")
	_status.erase(str(state["instance_id"]))


func _physics_process(delta: float) -> void:
	step(delta)

## Publiczny krok do testów; wykonywany także dla maszyn niekontrolowanych przez gracza.
func step(delta: float) -> void:
	if delta <= 0.0:
		return
	# Najpierw wywrotki, potem rury: nowe ziarno nie przechodzi przez oba etapy w jednym kroku.
	for record in _tippers:
		if is_instance_valid(record["machine"]):
			_update_tipper(record, delta)
	for record in _pipes:
		if is_instance_valid(record["machine"]):
			_update_pipe(record, delta)

func _update_pipe(record: Dictionary, delta: float) -> void:
	var pipe = record["pipe"]
	var config: Dictionary = record["config"]
	var source: Dictionary = record["source"]
	var amount: float = float(source["amount_l"])
	var capacity: float = float(record["source_definition"]["capacity_l"])
	var threshold: float = clampf(float(config.get("full_trigger_ratio", 0.999)), 0.01, 1.0)
	var full: bool = amount >= capacity * threshold
	var near: bool = _receiver_near(pipe.detection_polygon())
	var want_open: bool = amount > 0.0 and (full or near)
	var open_seconds: float = pipe.advance(want_open, delta)
	pipe.set_flow(0.0)
	var id: String = record["id"]
	if amount <= 0.0:
		_status[id] = "Rura: pusty zbiornik"
		return
	if pipe.extension < 1.0 or open_seconds <= 0.0:
		_status[id] = "Rura: %.0f%%" % (pipe.extension * 100.0)
		return
	var target: Dictionary = _target_at(pipe.outlet_world(), "pipe")
	if target.is_empty():
		_status[id] = "Rura rozłożona: końcówka poza odbiornikiem"
		return
	var moved: float = _move(record, target, float(config["max_transfer_l_per_s"]) * open_seconds)
	pipe.set_flow(moved / delta)
	_status[id] = "Przeładunek: %.1f l/s" % (moved / delta) if moved > 0.0 else "Odbiornik pełny lub niezgodny rodzaj ziarna"

func _update_tipper(record: Dictionary, delta: float) -> void:
	var config: Dictionary = record["config"]
	var state: Dictionary = record["state"]
	var source: Dictionary = record["source"]
	var body: RigidBody2D = record["body"]
	var outlet: Vector2 = body.to_global(Storage.vector(config["outlet_in_body_m"]) * _units)
	var target: Dictionary = _target_at(outlet, "tipper")
	if target.is_empty() or float(source["amount_l"]) <= 0.0:
		state["zone_id"] = ""
		state["start_elapsed_seconds"] = 0.0
		_status[record["id"]] = "Przyczepa: pusta" if float(source["amount_l"]) <= 0.0 else "Przyczepa: poza miejscem rozładunku"
		return
	var id: String = str(target["definition"]["id"])
	if str(state.get("zone_id", "")) != id:
		state["zone_id"] = id
		state["start_elapsed_seconds"] = 0.0
	var delay: float = float(config["start_delay_seconds"])
	var elapsed: float = clampf(float(state.get("start_elapsed_seconds", 0.0)), 0.0, delay)
	var usable: float = maxf(0.0, delta - maxf(0.0, delay - elapsed))
	state["start_elapsed_seconds"] = minf(delay, elapsed + delta)
	if usable <= 0.0:
		_status[record["id"]] = "Rozładunek za %.1f s" % (delay - float(state["start_elapsed_seconds"]))
		return
	# Skrzynia podniesiona: cały ładunek przechodzi w jednym kroku (bez limitu l/s).
	# Widok 3D dogrywa krótką animację wysypu.
	var moved: float = _move(record, target, INF)
	if str(target["kind"]) == "sell":
		_status[record["id"]] = "Sprzedano %.0f l" % moved if moved > 0.0 else "Skup nie przyjmuje tego ziarna"
	else:
		_status[record["id"]] = "Zrzucono %.0f l" % moved if moved > 0.0 else "Silos pełny lub nie przyjmuje tego ziarna"

func _receiver_near(polygon: PackedVector2Array) -> bool:
	for receiver in _receivers:
		if not is_instance_valid(receiver["body"]):
			continue
		if not Geometry2D.intersect_polygons(polygon, _receiver_polygon(receiver)).is_empty():
			return true
	for silo in _silos:
		if bool(silo["definition"].get("accepts_pipe", true)) and not Geometry2D.intersect_polygons(polygon, silo["polygon"]).is_empty():
			return true
	return false

func _receiver_polygon(receiver: Dictionary) -> PackedVector2Array:
	var body: RigidBody2D = receiver["body"]
	return Storage.rectangle(body.global_transform, receiver["area"], _units)

func _target_at(point: Vector2, kind: String) -> Dictionary:
	# Skrzynia fizycznie zasłania kratę silosu; pełna przyczepa też nie przepuszcza ziarna.
	if kind == "pipe":
		for receiver in _receivers:
			if is_instance_valid(receiver["body"]) and Geometry2D.is_point_in_polygon(point, _receiver_polygon(receiver)):
				return {"kind": "machine", "machine": receiver["machine"],
					"storage": receiver["storage"], "definition": receiver["definition"]}
	for silo in _silos:
		var definition: Dictionary = silo["definition"]
		var allowed: bool = bool(definition.get("accepts_pipe" if kind == "pipe" else "accepts_trailer", true))
		if allowed and Geometry2D.is_point_in_polygon(point, silo["polygon"]):
			return {"kind": "silo", "storage": silo["state"], "definition": definition}
	for sell in _sell_points:
		var definition: Dictionary = sell["definition"]
		var allowed: bool = bool(definition.get("accepts_pipe" if kind == "pipe" else "accepts_trailer", true))
		if allowed and Geometry2D.is_point_in_polygon(point, sell["polygon"]):
			return {"kind": "sell", "point": sell, "definition": definition}
	return {}

func _move(record: Dictionary, target: Dictionary, limit_l: float) -> float:
	var source: Dictionary = record["source"]
	var material: String = str(source["material_id"])
	if str(target["kind"]) == "sell":
		return _sell(record, target, limit_l)
	var to_silo: bool = str(target["kind"]) == "silo"
	var moved: float = Storage.transfer(source, target["storage"], target["definition"], limit_l, to_silo)
	if moved <= 0.0:
		return 0.0
	var mass_kg: float = moved * float(_materials.get(material, {}).get("bulk_density_kg_per_l", 0.0))
	_change_mass(record["machine"], -mass_kg)
	if not to_silo:
		_change_mass(target["machine"], mass_kg)
	return moved

## Skup: ziarno znika z przyczepy, a gracz dostaje pieniądze wg cennika.
func _sell(record: Dictionary, target: Dictionary, limit_l: float) -> float:
	var source: Dictionary = record["source"]
	var material: String = str(source["material_id"])
	if _economy == null or not target["definition"].get("accepted_material_ids", []).has(material):
		return 0.0
	var price: float = float(_economy.prices.grain_sell_price(material))
	if price <= 0.0:
		return 0.0
	var moved: float = minf(limit_l, float(source["amount_l"]))
	if moved <= 0.0:
		return 0.0
	source["amount_l"] = float(source["amount_l"]) - moved
	if float(source["amount_l"]) <= 0.000001:
		source["amount_l"] = 0.0
		source["material_id"] = null
	_change_mass(record["machine"], -moved * float(_materials.get(material, {}).get("bulk_density_kg_per_l", 0.0)))
	var point: Dictionary = target["point"]
	point["sold_l"] = float(point["sold_l"]) + moved
	point["earned"] = float(point["earned"]) + moved * price
	_economy.earn(moved * price, "Sprzedaż ziarna")
	return moved


func _change_mass(machine: Node2D, delta_kg: float) -> void:
	if machine.has_method("change_cargo_mass"):
		machine.call("change_cargo_mass", delta_kg)
	elif machine is RigidBody2D:
		var body: RigidBody2D = machine as RigidBody2D
		body.mass = maxf(0.001, body.mass + delta_kg)
		body.inertia = 0.0
		body.sleeping = false

func _body_of(machine: Node2D) -> RigidBody2D:
	if machine is RigidBody2D:
		return machine as RigidBody2D
	if machine.has_method("get_cargo_body"):
		return machine.call("get_cargo_body") as RigidBody2D
	return null

func get_diagnostics(vehicle: RigidBody2D, attached_tool: Node2D = null) -> String:
	var parts := PackedStringArray()
	var state: Dictionary = vehicle.get_meta("instance_state")
	var id: String = str(state["instance_id"])
	if _status.has(id):
		parts.append(str(_status[id]))
	if attached_tool != null:
		var tool_state: Dictionary = attached_tool.get_meta("instance_state")
		var tool_id: String = str(tool_state["instance_id"])
		if _status.has(tool_id):
			parts.append(str(_status[tool_id]))
	for silo in _silos:
		parts.append("%s: %.1f / %.0f l" % [silo["definition"]["name"], Storage.silo_total(silo["state"]), float(silo["definition"]["capacity_l"])])
	return " | ".join(parts)

func _valid_area(area: Dictionary) -> bool:
	return str(area.get("shape", "")) == "rectangle" and float(area.get("width_m", 0.0)) > 0.0 and float(area.get("length_m", 0.0)) > 0.0

func _fail(message: String) -> bool:
	last_error = message
	push_error(message)
	return false

## Stan silosów dla widoku 3D.
func get_silos() -> Array:
	var result: Array = []
	for silo in _silos:
		var definition: Dictionary = silo["definition"]
		result.append({"id": str(definition["id"]), "name": str(definition["name"]),
			"amount_l": Storage.silo_total(silo["state"]), "capacity_l": float(definition["capacity_l"])})
	return result


## Słownik stanu silosu (ten sam, który trafia do zapisu): {"id", "contents_l": {materiał: litry}}.
func get_silo_state(id: String) -> Dictionary:
	for silo in _silos:
		if str(silo["definition"]["id"]) == id:
			return silo["state"]
	return {}


## Bieżący komunikat przeładunku dla maszyny (pusty, gdy brak).
func get_status(instance_id: String) -> String:
	return str(_status.get(instance_id, ""))


## Punkty skupu dla widoków: [{"id", "name", "area", "sold_l", "earned"}].
func get_sell_points() -> Array:
	var result: Array = []
	for sell in _sell_points:
		var definition: Dictionary = sell["definition"]
		result.append({"id": str(definition["id"]), "name": str(definition["name"]), "area": definition["area"],
			"sold_l": float(sell["sold_l"]), "earned": float(sell["earned"])})
	return result
