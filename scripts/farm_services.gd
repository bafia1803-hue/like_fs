extends Node2D
## Usługi farmy (warstwa gry, bez rysowania):
## - load_points: załadunek ziarna z silosu do przyczepy stojącej pod wylotem,
## - seed_points: napełnianie siewnika materiałem siewnym z ziarna w silosie.
## Silosy i ich zawartość należą do GrainTransfer (zrzut przez kratę, zapis gry).
## Wszystko działa automatycznie, gdy maszyna stoi pod wylotem (jak rozładunek przez kratę).

const Storage = preload("res://scripts/grain_storage.gd")

var last_error: String = ""
var _units: float = 40.0
var _materials: Dictionary = {}
var _machines: Dictionary = {}
var _transfer: Node
var _points: Array[Dictionary] = []      # {"kind", "definition", "flow_l_per_s", "target_id"}
var _status: Dictionary = {}             # instance_id -> tekst


func configure(session: Dictionary, machines: Dictionary, grain_transfer: Node, units: float) -> bool:
	name = "FarmServices"
	_units = units
	_machines = machines
	_transfer = grain_transfer
	for material in session["catalog_data"]["materials"]:
		_materials[str(material["id"])] = material
	var map_data: Dictionary = session["map_data"]
	for kind in ["load", "seed"]:
		for definition in map_data.get(kind + "_points", []):
			if not definition is Dictionary or (definition.get("outlet_m", []) as Array).size() != 2:
				return _fail("Niepoprawny punkt %s_points." % kind)
			if _transfer.call("get_silo_state", str(definition.get("silo_id", ""))).is_empty():
				return _fail("Punkt %s wskazuje nieznany silos." % str(definition.get("id", "?")))
			if float(definition.get("max_transfer_l_per_s", 0.0)) <= 0.0:
				return _fail("Wydajność punktu musi być dodatnia: " + str(definition.get("id", "?")))
			_points.append({"kind": kind, "definition": definition, "flow_l_per_s": 0.0, "target_id": ""})
	return true


func _physics_process(delta: float) -> void:
	step(delta)


## Publiczny krok (także do testów).
func step(delta: float) -> void:
	if delta <= 0.0:
		return
	_status.clear()
	var ids: Array = _machines.keys()
	ids.sort()
	for point in _points:
		point["flow_l_per_s"] = 0.0
		point["target_id"] = ""
		var definition: Dictionary = point["definition"]
		var outlet := Vector2(float(definition["outlet_m"][0]), float(definition["outlet_m"][1])) * _units
		for id in ids:
			var machine: Node2D = _machines[id]
			if not is_instance_valid(machine):
				continue
			var moved: float = 0.0
			if point["kind"] == "load":
				moved = _try_load(point, machine, outlet, delta)
			else:
				moved = _try_seed(point, machine, outlet, delta)
			if moved >= 0.0:
				point["target_id"] = str(id)
				point["flow_l_per_s"] = moved / delta
				break


## Zwraca ilość przeniesioną w tym kroku albo -1, gdy maszyna nie stoi pod wylotem.
func _try_load(point: Dictionary, machine: Node2D, outlet: Vector2, delta: float) -> float:
	var model: Dictionary = machine.get_meta("definition")
	if not model.get("receiving") is Dictionary:
		return -1.0
	var body: Node2D = _cargo_body(machine)
	if body == null:
		return -1.0
	var receiving: Dictionary = model["receiving"]
	if not Geometry2D.is_point_in_polygon(outlet, Storage.rectangle(body.global_transform, receiving["area"], _units)):
		return -1.0
	var id: String = str(machine.get_meta("instance_state")["instance_id"])
	var definition: Dictionary = point["definition"]
	if not _stopped(machine, float(definition.get("max_speed_m_per_s", 0.3))):
		_status[id] = "%s: zatrzymaj się pod wylotem" % definition["name"]
		return 0.0
	var state: Dictionary = machine.get_meta("instance_state")
	var storage_id: String = str(receiving["storage_id"])
	var storage: Dictionary = state["storages"].get(storage_id, {})
	var storage_def: Dictionary = Storage.storage_definition(model, storage_id)
	var silo: Dictionary = _transfer.call("get_silo_state", str(definition["silo_id"]))
	var contents: Dictionary = silo["contents_l"]
	var material: String = ""
	if float(storage.get("amount_l", 0.0)) > 0.0:
		material = str(storage.get("material_id", ""))
	else:
		material = _largest(contents, storage_def.get("accepted_material_ids", []))
	if material.is_empty() or float(contents.get(material, 0.0)) <= 0.0:
		_status[id] = "%s: w silosie brak tego ziarna" % definition["name"]
		return 0.0
	var room: float = Storage.space_for(storage, storage_def, material)
	if room <= 0.0:
		_status[id] = "%s: przyczepa pełna" % definition["name"]
		return 0.0
	var moved: float = minf(float(definition["max_transfer_l_per_s"]) * delta, minf(room, float(contents[material])))
	_take_from_silo(contents, material, moved)
	storage["material_id"] = material
	storage["amount_l"] = float(storage.get("amount_l", 0.0)) + moved
	_change_mass(machine, moved * _density(material))
	_status[id] = "%s: %.0f l/s" % [definition["name"], moved / delta]
	return moved


func _try_seed(point: Dictionary, machine: Node2D, outlet: Vector2, delta: float) -> float:
	var model: Dictionary = machine.get_meta("definition")
	var work: Variant = model.get("work")
	if not work is Dictionary or str(work.get("operation", "")) != "sow":
		return -1.0
	var body: Node2D = _cargo_body(machine)
	if body == null:
		return -1.0
	var dims: Dictionary = model["dimensions"]
	var footprint := {"center_m": [0.0, 0.0], "width_m": dims["width_m"], "length_m": dims["length_m"], "rotation_deg": 0.0}
	if not Geometry2D.is_point_in_polygon(outlet, Storage.rectangle(body.global_transform, footprint, _units)):
		return -1.0
	var id: String = str(machine.get_meta("instance_state")["instance_id"])
	var definition: Dictionary = point["definition"]
	if not _stopped(machine, float(definition.get("max_speed_m_per_s", 0.3))):
		_status[id] = "%s: zatrzymaj się pod wylotem" % definition["name"]
		return 0.0
	var state: Dictionary = machine.get_meta("instance_state")
	var storage_id: String = str(work["input"]["storage_id"])
	var storage: Dictionary = state["storages"].get(storage_id, {})
	var storage_def: Dictionary = Storage.storage_definition(model, storage_id)
	var mapping: Dictionary = definition.get("grain_to_seed", {})
	var silo: Dictionary = _transfer.call("get_silo_state", str(definition["silo_id"]))
	var contents: Dictionary = silo["contents_l"]
	var grain: String = ""
	if float(storage.get("amount_l", 0.0)) > 0.0:
		var current_seed: String = str(storage.get("material_id", ""))
		for key in mapping:
			if str(mapping[key]) == current_seed:
				grain = str(key)
	else:
		var allowed: Array = []
		for key in mapping:
			if storage_def.get("accepted_material_ids", []).has(str(mapping[key])):
				allowed.append(str(key))
		grain = _largest(contents, allowed)
	if grain.is_empty() or float(contents.get(grain, 0.0)) <= 0.0:
		_status[id] = "%s: w silosie brak ziarna na nasiona" % definition["name"]
		return 0.0
	var seed: String = str(mapping[grain])
	var room: float = Storage.space_for(storage, storage_def, seed)
	if room <= 0.0:
		_status[id] = "%s: siewnik pełny" % definition["name"]
		return 0.0
	var moved: float = minf(float(definition["max_transfer_l_per_s"]) * delta, minf(room, float(contents[grain])))
	_take_from_silo(contents, grain, moved)
	storage["material_id"] = seed
	storage["amount_l"] = float(storage.get("amount_l", 0.0)) + moved
	_change_mass(machine, moved * _density(seed))
	_status[id] = "%s: %.0f l/s" % [definition["name"], moved / delta]
	return moved


func _take_from_silo(contents: Dictionary, material: String, amount: float) -> void:
	contents[material] = float(contents[material]) - amount
	if float(contents[material]) <= 0.000001:
		contents.erase(material)


func _largest(contents: Dictionary, allowed: Array) -> String:
	var best: String = ""
	var best_amount: float = 0.0
	for material in contents:
		if allowed.has(str(material)) and float(contents[material]) > best_amount:
			best = str(material)
			best_amount = float(contents[material])
	return best


func _cargo_body(machine: Node2D) -> Node2D:
	if machine is RigidBody2D:
		return machine
	var body: Variant = machine.get("body")
	return body as Node2D


func _stopped(machine: Node2D, limit_m_per_s: float) -> bool:
	var body := _cargo_body(machine) as RigidBody2D
	return body == null or body.linear_velocity.length() / _units <= limit_m_per_s


func _change_mass(machine: Node2D, delta_kg: float) -> void:
	if machine.has_method("change_cargo_mass"):
		machine.call("change_cargo_mass", delta_kg)
	elif machine is RigidBody2D:
		var body: RigidBody2D = machine
		body.mass = maxf(0.001, body.mass + delta_kg)
		body.inertia = 0.0
		body.sleeping = false


func _density(material: String) -> float:
	return float(_materials.get(material, {}).get("bulk_density_kg_per_l", 0.0))


## Stan punktów dla widoków: [{"kind", "definition", "flow_l_per_s", "target_id"}].
func get_points() -> Array[Dictionary]:
	return _points


## Komunikat dla maszyny stojącej przy punkcie (pusty, gdy brak).
func get_status(instance_id: String) -> String:
	return str(_status.get(instance_id, ""))


func _fail(message: String) -> bool:
	last_error = message
	push_error(message)
	return false
