extends Node2D
## Usługi farmy (warstwa gry, bez rysowania):
## - load_points: załadunek ziarna z silosu do przyczepy stojącej pod wylotem,
## - seed_points: zakup materiału siewnego do siewnika (pobiera pieniądze wg cennika).
## Silosy i ich zawartość należą do GrainTransfer (zrzut przez kratę, zapis gry).
##
## Napełnianie rusza na żądanie gracza: maszyna pod wylotem dostaje ofertę (offer_for),
## gracz wybiera ziarno (request_fill), a punkt napełnia ją stopniowo, dopóki stoi pod wylotem.
## Nie wolno mieszać rodzajów: do przyczepy z pszenicą nie wejdzie jęczmień (tak samo nasiona).

const Storage = preload("res://scripts/grain_storage.gd")

var last_error: String = ""
var _units: float = 40.0
var _materials: Dictionary = {}
var _machines: Dictionary = {}
var _transfer: Node
var _points: Array[Dictionary] = []      # {"kind", "definition", "flow_l_per_s", "target_id"}
var _status: Dictionary = {}             # instance_id -> tekst
var _economy: Node

signal service_message(machine_id: String, text: String)


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
			if kind == "load" and _transfer.call("get_silo_state", str(definition.get("silo_id", ""))).is_empty():
				return _fail("Punkt %s wskazuje nieznany silos." % str(definition.get("id", "?")))
			if kind == "seed" and (definition.get("sells_material_ids", []) as Array).is_empty():
				return _fail("Stacja nasion bez listy nasion: " + str(definition.get("id", "?")))
			if float(definition.get("max_transfer_l_per_s", 0.0)) <= 0.0:
				return _fail("Wydajność punktu musi być dodatnia: " + str(definition.get("id", "?")))
			_points.append({"kind": kind, "definition": definition, "flow_l_per_s": 0.0, "target_id": ""})
	return true


## Zakup nasion płaci przez ekonomię (ustawiane przez świat).
func set_economy(economy: Node) -> void:
	_economy = economy


func _physics_process(delta: float) -> void:
	step(delta)


## Publiczny krok (także do testów).
func step(delta: float) -> void:
	if delta <= 0.0:
		return
	_status.clear()
	for point in _points:
		point["flow_l_per_s"] = 0.0
		point["target_id"] = ""
		var machine: Node2D = _machine_at(point)
		var request: Dictionary = point.get("request", {})
		if machine == null:
			point["request"] = {}
			continue
		var id: String = _id_of(machine)
		point["target_id"] = id
		var definition: Dictionary = point["definition"]
		if request.is_empty() or str(request["machine_id"]) != id:
			point["request"] = {}
			_status[id] = "%s: wybierz ziarno przyciskiem na dole ekranu" % definition["name"]
			continue
		if not _stopped(machine, float(definition.get("max_speed_m_per_s", 0.3))):
			_status[id] = "%s: zatrzymaj się pod wylotem" % definition["name"]
			continue
		var result: Dictionary = _fill(point, machine, str(request["material"]), delta)
		var moved: float = float(result["moved"])
		point["flow_l_per_s"] = moved / delta
		if moved <= 0.0:
			# Koniec: pełna maszyna, pusty silos albo brak pieniędzy.
			point["request"] = {}
			service_message.emit(id, str(result["reason"]))
		else:
			_status[id] = str(result["status"])


## Maszyna stojąca pod wylotem punktu (albo null).
func _machine_at(point: Dictionary) -> Node2D:
	var definition: Dictionary = point["definition"]
	var outlet := Vector2(float(definition["outlet_m"][0]), float(definition["outlet_m"][1])) * _units
	var ids: Array = _machines.keys()
	ids.sort()
	for id in ids:
		var machine: Node2D = _machines[id]
		if not is_instance_valid(machine):
			continue
		var model: Dictionary = machine.get_meta("definition")
		var body: Node2D = _cargo_body(machine)
		if body == null:
			continue
		if point["kind"] == "load":
			if model.get("receiving") is Dictionary and Geometry2D.is_point_in_polygon(outlet, Storage.rectangle(body.global_transform, model["receiving"]["area"], _units)):
				return machine
		else:
			var work: Variant = model.get("work")
			if work is Dictionary and str(work.get("operation", "")) == "sow":
				var dims: Dictionary = model["dimensions"]
				var footprint := {"center_m": [0.0, 0.0], "width_m": dims["width_m"], "length_m": dims["length_m"], "rotation_deg": 0.0}
				if Geometry2D.is_point_in_polygon(outlet, Storage.rectangle(body.global_transform, footprint, _units)):
					return machine
	return null


## Oferta dla maszyny stojącej przy punkcie: {"point_id", "kind", "title", "active", "options": [...]}.
## Każda opcja: {"material", "label", "detail", "enabled", "reason"}. Pusty słownik, gdy nic.
func offer_for(machine: Node2D) -> Dictionary:
	for point in _points:
		if _machine_at(point) != machine:
			continue
		var definition: Dictionary = point["definition"]
		var model: Dictionary = machine.get_meta("definition")
		var storage_id: String = str(model["receiving"]["storage_id"]) if point["kind"] == "load" else str(model["work"]["input"]["storage_id"])
		var storage: Dictionary = machine.get_meta("instance_state")["storages"].get(storage_id, {})
		var storage_def: Dictionary = Storage.storage_definition(model, storage_id)
		var options: Array = []
		var materials: Array = []
		if point["kind"] == "load":
			var silo: Dictionary = _transfer.call("get_silo_state", str(definition["silo_id"]))
			for material in storage_def.get("accepted_material_ids", []):
				materials.append(str(material))
			for material in materials:
				var stock: float = float(silo["contents_l"].get(material, 0.0))
				var option := {"material": material, "label": _material_name(material), "detail": "w silosie %.0f l" % stock, "enabled": true, "reason": ""}
				_check_option(option, storage, storage_def, material)
				if option["enabled"] and stock <= 0.0:
					option["enabled"] = false
					option["reason"] = "brak w silosie"
				options.append(option)
		else:
			for material in definition.get("sells_material_ids", []):
				if not storage_def.get("accepted_material_ids", []).has(material):
					continue
				var price: float = float(_economy.prices.seed_buy_price(str(material))) if _economy != null else -1.0
				var option := {"material": str(material), "label": _material_name(str(material)),
					"detail": "%.2f %s/l" % [price, _economy.prices.currency() if _economy != null else "zł"], "enabled": price >= 0.0, "reason": ""}
				_check_option(option, storage, storage_def, str(material))
				options.append(option)
		var request: Dictionary = point.get("request", {})
		return {"point_id": str(definition["id"]), "kind": str(point["kind"]), "title": str(definition["name"]),
			"machine_id": _id_of(machine), "active": not request.is_empty(), "options": options,
			"storage": "%.0f / %.0f l" % [float(storage.get("amount_l", 0.0)), float(storage_def.get("capacity_l", 0.0))]}
	return {}


func _check_option(option: Dictionary, storage: Dictionary, storage_def: Dictionary, material: String) -> void:
	var amount: float = float(storage.get("amount_l", 0.0))
	if amount > 0.0 and str(storage.get("material_id", "")) != material:
		option["enabled"] = false
		option["reason"] = "w środku jest " + _material_name(str(storage.get("material_id", ""))).to_lower()
	elif Storage.space_for(storage, storage_def, material) <= 0.0:
		option["enabled"] = false
		option["reason"] = "pełne"


## Gracz wybrał ziarno: punkt zaczyna napełniać maszynę. Zwraca komunikat.
func request_fill(point_id: String, machine_id: String, material: String) -> String:
	for point in _points:
		if str(point["definition"]["id"]) != point_id:
			continue
		var machine: Node2D = _machines.get(machine_id)
		if machine == null or _machine_at(point) != machine:
			return "Maszyna nie stoi pod wylotem."
		for option in offer_for(machine).get("options", []):
			if str(option["material"]) == material:
				if not bool(option["enabled"]):
					return "Nie można: " + str(option["reason"]) + "."
				point["request"] = {"machine_id": machine_id, "material": material}
				return "%s: %s" % [point["definition"]["name"], _material_name(material).to_lower()]
		return "Ten punkt nie ma takiego ziarna."
	return "Nieznany punkt."


## Przerywa napełnianie danej maszyny.
func cancel_fill(machine_id: String) -> void:
	for point in _points:
		if str(point.get("request", {}).get("machine_id", "")) == machine_id:
			point["request"] = {}


func _fill(point: Dictionary, machine: Node2D, material: String, delta: float) -> Dictionary:
	var definition: Dictionary = point["definition"]
	var model: Dictionary = machine.get_meta("definition")
	var state: Dictionary = machine.get_meta("instance_state")
	var is_load: bool = point["kind"] == "load"
	var storage_id: String = str(model["receiving"]["storage_id"]) if is_load else str(model["work"]["input"]["storage_id"])
	var storage: Dictionary = state["storages"].get(storage_id, {})
	var storage_def: Dictionary = Storage.storage_definition(model, storage_id)
	var title: String = str(definition["name"])
	var room: float = Storage.space_for(storage, storage_def, material)
	if room <= 0.0:
		return {"moved": 0.0, "reason": "%s: pełne, koniec napełniania." % title}
	var moved: float = minf(float(definition["max_transfer_l_per_s"]) * delta, room)
	var price: float = 0.0
	if is_load:
		var contents: Dictionary = _transfer.call("get_silo_state", str(definition["silo_id"]))["contents_l"]
		moved = minf(moved, float(contents.get(material, 0.0)))
		if moved <= 0.0:
			return {"moved": 0.0, "reason": "%s: silos pusty." % title}
		_take_from_silo(contents, material, moved)
	else:
		price = float(_economy.prices.seed_buy_price(material)) if _economy != null else -1.0
		if price < 0.0:
			return {"moved": 0.0, "reason": "%s: brak tych nasion." % title}
		if price > 0.0:
			moved = minf(moved, floorf(float(_economy.get_money()) / price * 1000.0) / 1000.0)
		if moved <= 0.0 or not _economy.spend(moved * price, "Zakup nasion"):
			return {"moved": 0.0, "reason": "%s: brak pieniędzy na nasiona." % title}
	storage["material_id"] = material
	storage["amount_l"] = float(storage.get("amount_l", 0.0)) + moved
	_change_mass(machine, moved * _density(material))
	var text: String = "%s: %.0f l/s" % [title, moved / delta]
	if price > 0.0:
		text += " (%.2f %s/l)" % [price, _economy.prices.currency()]
	return {"moved": moved, "status": text}


func _id_of(machine: Node) -> String:
	return str(machine.get_meta("instance_state")["instance_id"])


func _material_name(material: String) -> String:
	if material.begins_with("wheat"):
		return "Pszenica"
	if material.begins_with("barley"):
		return "Jęczmień"
	return str(_materials.get(material, {}).get("name", material))


func _take_from_silo(contents: Dictionary, material: String, amount: float) -> void:
	contents[material] = float(contents[material]) - amount
	if float(contents[material]) <= 0.000001:
		contents.erase(material)


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
