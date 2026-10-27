extends Node2D
## Usługi farmy (warstwa gry, bez rysowania):
## - load_points: załadunek ziarna z silosu do przyczepy stojącej pod wylotem (wybór ziarna),
## - supply_points: magazyn przy wiacie – zakup ziarna siewnego i nawozu do siewnika/rozsiewacza.
##   Maszyna wjeżdża w obszar (area) i staje; zakup rusza od razu przyciskiem na dole ekranu
##   (każda maszyna przyjmuje jeden rodzaj: siewnik ziarno siewne, rozsiewacz nawóz),
##   materiał przybywa stopniowo i kosztuje wg cennika (supply_buy_per_l). Bez rur i strumieni.
## Silosy i ich zawartość należą do GrainTransfer (zrzut przez kratę, zapis gry).
## Nie wolno mieszać rodzajów: do przyczepy z pszenicą nie wejdzie jęczmień.
## Zasady (miejsce, zakup za pieniądze): core/services/fill_rules.gd.

const Storage = preload("res://scripts/core/storage/storage_rules.gd")
const FillRules = preload("res://scripts/core/services/fill_rules.gd")
const Machines = preload("res://scripts/sim/machines/machines.gd")
const Vec = preload("res://scripts/core/util/vec.gd")
const Profiler = preload("res://scripts/core/util/profiler.gd")

signal service_message(machine_id: String, text: String)

var last_error: String = ""
var _context: RefCounted
var _units: float = 40.0
var _points: Array[Dictionary] = []      # {"kind", "definition", "flow_l_per_s", "target_id", "request"}
var _status: Dictionary = {}             # instance_id -> tekst


func setup(context: RefCounted) -> bool:
	name = "FarmServices"
	_context = context
	_units = context.units
	var map_data: Dictionary = context.map_data()
	for definition in map_data.get("load_points", []):
		if not definition is Dictionary or (definition.get("outlet_m", []) as Array).size() != 2:
			return _fail("Niepoprawny punkt load_points.")
		if context.transfer.get_silo_state(str(definition.get("silo_id", ""))).is_empty():
			return _fail("Punkt %s wskazuje nieznany silos." % str(definition.get("id", "?")))
		if not _add_point("load", definition):
			return false
	for definition in map_data.get("supply_points", []):
		if not definition is Dictionary or not definition.get("area") is Dictionary:
			return _fail("Niepoprawny punkt supply_points.")
		if (definition.get("sells_material_ids", []) as Array).is_empty():
			return _fail("Magazyn bez listy towarów: " + str(definition.get("id", "?")))
		if not _add_point("supply", definition):
			return false
	return true


func _add_point(kind: String, definition: Dictionary) -> bool:
	if float(definition.get("max_transfer_l_per_s", 0.0)) <= 0.0:
		return _fail("Wydajność punktu musi być dodatnia: " + str(definition.get("id", "?")))
	_points.append({"kind": kind, "definition": definition, "flow_l_per_s": 0.0, "target_id": "", "request": {}})
	return true


func _machines() -> Dictionary:
	return _context.machines.by_id


func _physics_process(delta: float) -> void:
	var started: int = Profiler.start()
	_physics_process_measured(delta)
	Profiler.stop(Profiler.SERVICES, started)


func _physics_process_measured(delta: float) -> void:
	step(delta)


## Krok napełniania (publiczny także dla testów).
func step(delta: float) -> void:
	if delta <= 0.0:
		return
	_status.clear()
	for point in _points:
		point["flow_l_per_s"] = 0.0
		point["target_id"] = ""
		var definition: Dictionary = point["definition"]
		var request: Dictionary = point["request"]
		var served: Node2D = null
		if not request.is_empty():
			served = _machines().get(str(request["machine_id"])) as Node2D
			if not is_instance_valid(served) or not _serves(point, served):
				point["request"] = {}
				served = null
		# Podpowiedź dla maszyn w zasięgu punktu, które nie są obsługiwane.
		for machine in _machines_at(point):
			if machine != served:
				_status[Machines.id(machine)] = "%s: %s" % [definition["name"],
					"wybierz ziarno przyciskiem na dole ekranu" if point["kind"] == "load" else "kup przyciskiem na dole ekranu"]
		if served == null:
			continue
		var id: String = Machines.id(served)
		point["target_id"] = id
		if Machines.speed_m_s(served, _units) > float(definition.get("max_speed_m_per_s", 0.3)):
			_status[id] = "%s: zatrzymaj się" % definition["name"]
			continue
		var result: Dictionary = _fill(point, served, str(request["material"]), delta)
		var moved: float = float(result["moved"])
		point["flow_l_per_s"] = moved / delta
		if moved <= 0.0:
			# Koniec: pełna maszyna, pusty silos albo brak pieniędzy.
			point["request"] = {}
			service_message.emit(id, str(result["reason"]))
		else:
			_status[id] = str(result["status"])


## Maszyny w zasięgu punktu (posortowane po id).
func _machines_at(point: Dictionary) -> Array:
	var result: Array = []
	for id in _context.machines.sorted_ids():
		var machine: Node2D = _machines()[id]
		if is_instance_valid(machine) and _serves(point, machine):
			result.append(machine)
	return result


## Czy punkt może obsłużyć maszynę w jej obecnym położeniu.
##   load: wylot silosu nad skrzynią (receiving.area),
##   supply: środek maszyny w obszarze magazynu, a maszyna ma zbiornik pracy (work.input).
func _serves(point: Dictionary, machine: Node2D) -> bool:
	var model: Dictionary = Machines.model(machine)
	var definition: Dictionary = point["definition"]
	var pose: Node2D = _pose_node(machine)
	if point["kind"] == "load":
		var outlet: Vector2 = Vec.v2(definition["outlet_m"]) * _units
		return model.get("receiving") is Dictionary and Geometry2D.is_point_in_polygon(outlet, Storage.rectangle(pose.global_transform, model["receiving"]["area"], _units))
	var work: Variant = model.get("work")
	if not work is Dictionary or not work.get("input") is Dictionary:
		return false
	var storage_def: Dictionary = Storage.storage_definition(model, str(work["input"]["storage_id"]))
	var sells: Array = definition.get("sells_material_ids", [])
	var accepted: bool = false
	for material in storage_def.get("accepted_material_ids", []):
		accepted = accepted or sells.has(material)
	return accepted and Geometry2D.is_point_in_polygon(pose.global_position, Storage.rectangle(Transform2D.IDENTITY, definition["area"], _units))


## Węzeł pozy dla punktów farmy: nadwozie maszyny; zawieszane narzędzie – jego własny węzeł
## (śledzi bryłę na ziemi albo nośnik).
func _pose_node(machine: Node2D) -> Node2D:
	return machine if Machines.kind(machine) == "rigid_mounted" else Machines.pose_body(machine)


## Zbiornik, który punkt napełnia: skrzynia (load) albo zbiornik pracy (supply).
func _storage_id(point: Dictionary, model: Dictionary) -> String:
	return str(model["receiving"]["storage_id"]) if point["kind"] == "load" else str(model["work"]["input"]["storage_id"])


## Oferta dla maszyny przy punkcie: {"point_id", "kind", "title", "active", "options": [...], "machine_id", "storage"}.
## Każda opcja: {"material", "label", "detail", "enabled", "reason"}. Pusty słownik, gdy nic.
func offer_for(machine: Node2D) -> Dictionary:
	for point in _points:
		if not _serves(point, machine):
			continue
		var definition: Dictionary = point["definition"]
		var model: Dictionary = Machines.model(machine)
		var storage_id: String = _storage_id(point, model)
		var storage: Dictionary = Machines.state(machine)["storages"].get(storage_id, {})
		var storage_def: Dictionary = Storage.storage_definition(model, storage_id)
		var options: Array = []
		if point["kind"] == "load":
			var silo: Dictionary = _context.transfer.get_silo_state(str(definition["silo_id"]))
			for material_value in storage_def.get("accepted_material_ids", []):
				var material: String = str(material_value)
				var stock: float = float(silo["contents_l"].get(material, 0.0))
				var option := {"material": material, "label": material_name(material), "detail": "w silosie %.0f l" % stock, "enabled": true, "reason": ""}
				option.merge(FillRules.option_state(storage, storage_def, material, material_name(str(storage.get("material_id", "")))), true)
				if option["enabled"] and stock <= 0.0:
					option["enabled"] = false
					option["reason"] = "brak w silosie"
				options.append(option)
		else:
			for material in definition.get("sells_material_ids", []):
				if not storage_def.get("accepted_material_ids", []).has(material):
					continue
				var price: float = _price(str(material))
				var option := {"material": str(material), "label": material_name(str(material)),
					"detail": "%.2f %s/l" % [price, _currency()], "enabled": price >= 0.0, "reason": ""}
				var check: Dictionary = FillRules.option_state(storage, storage_def, str(material), material_name(str(storage.get("material_id", ""))))
				if not bool(check["enabled"]):
					option.merge(check, true)
				options.append(option)
		var request: Dictionary = point["request"]
		return {"point_id": str(definition["id"]), "kind": str(point["kind"]), "title": str(definition["name"]),
			"machine_id": Machines.id(machine), "active": not request.is_empty() and str(request["machine_id"]) == Machines.id(machine),
			"options": options, "storage": "%.0f / %.0f l" % [float(storage.get("amount_l", 0.0)), float(storage_def.get("capacity_l", 0.0))]}
	return {}


## Gracz wybrał materiał: punkt zaczyna napełniać maszynę. Zwraca komunikat.
func request_fill(point_id: String, machine_id: String, material: String) -> String:
	for point in _points:
		if str(point["definition"]["id"]) != point_id:
			continue
		var machine: Node2D = _machines().get(machine_id)
		if machine == null or not _serves(point, machine):
			return "Maszyna nie stoi w miejscu napełniania."
		for option in offer_for(machine).get("options", []):
			if str(option["material"]) == material:
				if not bool(option["enabled"]):
					return "Nie można: " + str(option["reason"]) + "."
				point["request"] = {"machine_id": machine_id, "material": material}
				return "%s: %s" % [point["definition"]["name"], material_name(material).to_lower()]
		return "Ten punkt nie ma takiego materiału."
	return "Nieznany punkt."


## Magazyn: maszyna przyjmuje jeden rodzaj (ziarno siewne albo nawóz) – zakup rusza od razu.
func start_purchase(offer: Dictionary) -> String:
	var options: Array = offer.get("options", [])
	if options.is_empty():
		return "Ta maszyna nie przyjmie niczego z magazynu."
	return request_fill(str(offer["point_id"]), str(offer["machine_id"]), str(options[0]["material"]))


## Napis przycisku zakupu, np. „Kup nawóz”.
func purchase_label(offer: Dictionary) -> String:
	var options: Array = offer.get("options", [])
	return FillRules.purchase_label(str(options[0]["material"]) if not options.is_empty() else "")


## Przerywa napełnianie danej maszyny.
func cancel_fill(machine_id: String) -> void:
	for point in _points:
		if str(point["request"].get("machine_id", "")) == machine_id:
			point["request"] = {}


func _fill(point: Dictionary, machine: Node2D, material: String, delta: float) -> Dictionary:
	var definition: Dictionary = point["definition"]
	var model: Dictionary = Machines.model(machine)
	var is_load: bool = point["kind"] == "load"
	var storage_id: String = _storage_id(point, model)
	var storage: Dictionary = Machines.state(machine)["storages"].get(storage_id, {})
	var storage_def: Dictionary = Storage.storage_definition(model, storage_id)
	var title: String = str(definition["name"])
	var room: float = Storage.space_for(storage, storage_def, material)
	if room <= 0.0:
		return {"moved": 0.0, "reason": "%s: pełne, koniec napełniania." % title}
	var moved: float = minf(float(definition["max_transfer_l_per_s"]) * delta, room)
	var price: float = 0.0
	if is_load:
		var contents: Dictionary = _context.transfer.get_silo_state(str(definition["silo_id"]))["contents_l"]
		moved = minf(moved, float(contents.get(material, 0.0)))
		if moved <= 0.0:
			return {"moved": 0.0, "reason": "%s: silos pusty." % title}
		_take_from_silo(contents, material, moved)
	else:
		price = _price(material)
		if price < 0.0:
			return {"moved": 0.0, "reason": "%s: brak tego towaru." % title}
		var economy: RefCounted = _context.economy
		moved = FillRules.purchase_amount(float(definition["max_transfer_l_per_s"]), delta, room, economy.get_money(), price)
		if moved <= 0.0 or not economy.spend(moved * price, "Zakup: " + material_name(material).to_lower()):
			return {"moved": 0.0, "reason": "%s: brak pieniędzy." % title}
	storage["material_id"] = material
	storage["amount_l"] = float(storage.get("amount_l", 0.0)) + moved
	Machines.change_cargo_mass(machine, moved * _context.density(material))
	var text: String = "%s: %.0f l/s" % [title, moved / delta]
	if price > 0.0:
		text += " (%.2f %s/l)" % [price, _currency()]
	return {"moved": moved, "status": text}


func _price(material: String) -> float:
	return float(_context.economy.prices.supply_buy_price(material)) if _context.economy != null else -1.0


func _currency() -> String:
	return _context.economy.prices.currency() if _context.economy != null else "zł"


## Nazwa materiału dla gracza (ziarna po gatunku).
func material_name(material: String) -> String:
	if material.begins_with("wheat"):
		return "Pszenica"
	if material.begins_with("barley"):
		return "Jęczmień"
	if material.begins_with("oats"):
		return "Owies"
	return _context.material_name(material)


func _take_from_silo(contents: Dictionary, material: String, amount: float) -> void:
	contents[material] = float(contents[material]) - amount
	if float(contents[material]) <= 0.000001:
		contents.erase(material)


## Stan punktów dla widoków: [{"kind", "definition", "flow_l_per_s", "target_id"}].
func get_points() -> Array[Dictionary]:
	return _points


## Komunikat dla maszyny w zasięgu punktu (pusty, gdy brak).
func get_status(instance_id: String) -> String:
	return str(_status.get(instance_id, ""))


func _fail(message: String) -> bool:
	last_error = message
	push_error(message)
	return false
