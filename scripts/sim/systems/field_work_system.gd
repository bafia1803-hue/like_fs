extends Node2D
## Praca na polu (warstwa gry): pola (FieldGrid), włączanie pracy (B), limit prędkości od narzędzia,
## przeciąganie obszaru pracy narzędzia po komórkach. Zasady komórek: core/field/field_work_rules.gd.

const GridScript = preload("res://scripts/sim/systems/field_grid.gd")
const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const Rules = preload("res://scripts/core/field/field_work_rules.gd")
const Machines = preload("res://scripts/sim/machines/machines.gd")
const StorageRules = preload("res://scripts/core/storage/storage_rules.gd")
const Vec = preload("res://scripts/core/util/vec.gd")
const Profiler = preload("res://scripts/core/util/profiler.gd")

signal work_message(vehicle: RigidBody2D, message: String)

var fields: Array = []
var settings: Dictionary = {}
var last_error: String = ""
var _context: RefCounted
var _units: float
var _previous: Dictionary = {}
var _message_times: Dictionary = {}
var _time: float = 0.0
var _owned_ids: Array = []
## Zmiana masy ładunku maszyn w bieżącym kroku – stosowana raz na koniec (nie przy każdej komórce).
var _mass_delta: Dictionary = {}


func setup(context: RefCounted) -> bool:
	name = "FieldWork"
	_context = context
	_units = context.units
	settings = context.config.farming
	var session: Dictionary = context.session
	var saved_fields: Dictionary = {}
	for entry in session["save_data"]["field_states"]:
		saved_fields[str(entry["field_id"])] = entry
	# Własność pól: zapis gry, a bez zapisu – owned_at_start z mapy.
	var save_data: Dictionary = session["save_data"]
	if not save_data.get("owned_fields") is Array:
		var start: Array = []
		for definition in session["map_data"]["fields"]:
			if bool(definition.get("owned_at_start", true)):
				start.append(str(definition["id"]))
		save_data["owned_fields"] = start
	_owned_ids = save_data["owned_fields"]
	for definition in session["map_data"]["fields"]:
		var grid = GridScript.new()
		grid.name = str(definition["id"])
		grid.configure(definition, settings, _units)
		grid.owned = _owned_ids.has(grid.field_id)
		add_child(grid)
		var saved: Dictionary = saved_fields.get(grid.field_id, {})
		if saved.has("growth_simulation"):
			if not grid.restore_state(saved["growth_simulation"]):
				last_error = "Niezgodny zapis wzrostu pola: " + grid.field_id
				return false
		else:
			# Aktualny szablon ma jednorodne, puste pole. Nie ignorujemy innych zapisów.
			var legacy: Dictionary = saved.get("cell_state", {})
			var defaults: Dictionary = legacy.get("default", {})
			if not legacy.get("overrides", []).is_empty() or defaults.get("crop_id") != null:
				last_error = "Pole wymaga migracji starego zapisu upraw: " + grid.field_id
				return false
			# Szablon nowej gry: pasy zbóż na start (save.json → field_states[].initial_strips).
			if saved.get("initial_strips") is Dictionary:
				var strips: Dictionary = saved["initial_strips"]
				var stage_names := {"sown": FieldCells.Stage.SOWN, "light": FieldCells.Stage.LIGHT,
					"dark": FieldCells.Stage.DARK, "ready": FieldCells.Stage.READY}
				grid.fill_strips(strips.get("crop_ids", []), int(stage_names.get(str(strips.get("stage", "ready")), FieldCells.Stage.READY)))
		fields.append(grid)
	return true


func _physics_process(delta: float) -> void:
	var started: int = Profiler.start()
	_physics_process_measured(delta)
	Profiler.stop(Profiler.FIELD_WORK, started)


func _physics_process_measured(delta: float) -> void:
	_time += delta
	var seen: Dictionary = {}
	for machine in _context.machines.by_id.values():
		if not machine is RigidBody2D:
			continue
		var vehicle: RigidBody2D = machine
		var tool: Node2D = _context.hitches.get_attached_machine(vehicle)
		if vehicle.has_method("set_speed_cap_kmh"):
			vehicle.call("set_speed_cap_kmh", get_speed_cap_kmh(tool))
		if tool != null and tool.has_method("take_message"):
			var notice: String = str(tool.call("take_message"))
			if not notice.is_empty():
				work_message.emit(vehicle, notice)
		if tool == null or not tool.has_method("get_work_transform"):
			continue
		seen[tool.get_instance_id()] = true
		if Machines.on_route(vehicle):
			continue
		var speed: float = vehicle.linear_velocity.dot(Vector2.UP.rotated(vehicle.global_rotation)) / _units
		_work_tool(vehicle, tool, speed)
	for key in _previous.keys():
		if not seen.has(key):
			_previous.erase(key)


# ---------------------------------------------------------------------------
# Włączanie pracy (klawisz B)
# ---------------------------------------------------------------------------

## Czy narzędzie pracuje (opuszczone i włączone).
static func is_working(tool: Node) -> bool:
	return Machines.is_working(tool)


## Limit prędkości pojazdu wynikający z pracującego narzędzia (INF = brak limitu).
func get_speed_cap_kmh(tool: Node) -> float:
	if tool == null:
		return INF
	return Rules.speed_cap_kmh(Machines.model(tool), is_working(tool))


## Przełącza pracę narzędzia podpiętego do pojazdu. Zwraca komunikat dla gracza.
func toggle_work(vehicle: RigidBody2D) -> String:
	var tool: Node2D = _context.hitches.get_attached_machine(vehicle)
	if tool == null or not Machines.has_work(tool):
		if str(Machines.model(vehicle).get("category", "")) == "combine":
			return "Podepnij heder (E), żeby rozpocząć żniwa."
		return "Brak podpiętej maszyny roboczej."
	if Machines.is_foldable(tool):
		_previous.erase(tool.get_instance_id())
		return str(tool.call("toggle_fold_work", vehicle))
	var state: Dictionary = Machines.state(tool)
	if not state.get("work_state") is Dictionary:
		state["work_state"] = {"enabled": false, "lowered": false}
	var work_state: Dictionary = state["work_state"]
	var active: bool = not is_working(tool)
	work_state["enabled"] = active
	work_state["lowered"] = active
	_previous.erase(tool.get_instance_id())
	return Rules.toggle_message(Machines.model(tool), active)


# ---------------------------------------------------------------------------
# Praca na trasie (RouteSystem przesuwa zestaw, praca po każdym odcinku nagrania)
# ---------------------------------------------------------------------------

func reset_route_sweep(tool: Node2D) -> void:
	if tool != null:
		_previous.erase(tool.get_instance_id())


func begin_route_segment(tool: Node2D) -> void:
	if tool == null or not tool.has_method("get_work_transform") or not Machines.has_work(tool):
		return
	_previous[tool.get_instance_id()] = _area_pose(tool)


func work_route_segment(vehicle: RigidBody2D, tool: Node2D, speed: float) -> void:
	if tool != null and tool.has_method("get_work_transform"):
		_work_tool(vehicle, tool, speed)


# ---------------------------------------------------------------------------
# Przeciąganie obszaru pracy
# ---------------------------------------------------------------------------

func _area_pose(tool: Node2D) -> Transform2D:
	var area: Dictionary = Machines.model(tool)["work"]["area"]
	var base: Transform2D = tool.call("get_work_transform")
	return base * Transform2D(deg_to_rad(float(area["rotation_deg"])), Vec.v2(area["center_m"]) * _units)


func _work_tool(vehicle: RigidBody2D, tool: Node2D, speed: float) -> void:
	if not Machines.has_work(tool):
		return
	var work: Dictionary = Machines.model(tool)["work"]
	var key: int = tool.get_instance_id()
	if not is_working(tool):
		_previous.erase(key)
		return
	var current: Transform2D = _area_pose(tool)
	if not Rules.work_allowed(str(work["operation"]), speed, float(settings["minimum_work_speed_m_s"])):
		_previous.erase(key)
		return
	var operation: String = str(work["operation"])
	var area: Dictionary = work["area"]
	var size := Vector2(float(area["width_m"]), float(area["length_m"]))
	var polygon := PackedVector2Array()
	for point in area.get("polygon_m", []):
		polygon.append(Vec.v2(point))
	var previous: Transform2D = _previous.get(key, current)
	var distance: float = previous.origin.distance_to(current.origin) / _units
	var turn: float = absf(angle_difference(previous.get_rotation(), current.get_rotation()))
	var sweep_distance: float = distance + turn * size.length() * 0.5
	var spacing: float = minf(size.x, size.y) * 0.25
	for field in fields:
		spacing = minf(spacing, field.cell_m * 0.25)
	var steps: int = maxi(1, ceili(sweep_distance / maxf(spacing, 0.01)))
	# W normalnej jeździe jest to 1 próbka. Teleport nie wykonuje pracy po drodze.
	if distance > 10.0:
		previous = current
		steps = 1
	# Każda komórka raz na krok fizyki, choć kolejne pozy obszaru pracy częściowo się pokrywają.
	var done: Array[Dictionary] = []
	for field in fields:
		done.append({})
	for step in range(1, steps + 1):
		var pose: Transform2D = previous.interpolate_with(current, float(step) / steps)
		for field_index in fields.size():
			var field: Node2D = fields[field_index]
			# Obszar pracy: prostokąt albo wielokąt (np. trójkąt rozrzutu rozsiewacza, area.polygon_m).
			var cells: PackedInt32Array = field.cells_in_polygon(pose, polygon) if not polygon.is_empty() else field.cells_in_rectangle(pose, size)
			if not field.owned:
				if not cells.is_empty():
					_message(vehicle, "%s nie jest twoje — możesz je kupić (przycisk na dole ekranu)." % field.field_name)
				continue
			var seen: Dictionary = done[field_index]
			# Migawka stanu (każda komórka i tak jest odwiedzana raz na krok): szybkie pominięcie
			# komórek, których operacja nie zmieni – zwykle prawie cały obszar z poprzedniej klatki.
			var states: PackedByteArray = field.cells.states
			var fertilized: PackedByteArray = field.cells.fertilized
			for index in cells:
				if steps > 1:
					if seen.has(index):
						continue
					seen[index] = true
				if Rules.cell_needs_work(operation, states[index], fertilized[index]):
					_work_cell(field, int(index), vehicle, tool, work)
	_previous[key] = current
	_apply_mass_changes()


func _apply_mass_changes() -> void:
	for machine in _mass_delta:
		if is_instance_valid(machine):
			Machines.change_cargo_mass(machine, float(_mass_delta[machine]))
	_mass_delta.clear()


func _add_mass(machine: Node, delta_kg: float) -> void:
	_mass_delta[machine] = float(_mass_delta.get(machine, 0.0)) + delta_kg


func _work_cell(field: Node2D, index: int, vehicle: RigidBody2D, tool: Node2D, work: Dictionary) -> void:
	var stage: int = field.stage(index)
	var square_m: float = float(field.cell_m) ** 2
	var state: Dictionary = Machines.state(tool)
	var result: Dictionary = {}
	match str(work["operation"]):
		"cultivate":
			field.cultivate(index)
		"sow":
			var storage: Dictionary = state["storages"][str(work["input"]["storage_id"])]
			# Ziarno siewne jest jedno; gatunek to ustawienie siewnika (przycisk w prawym dolnym rogu).
			var material: String = str(storage.get("material_id", ""))
			var crop: String = Rules.seed_crop(Machines.model(tool), state)
			var cost: float = float(work["seed_consumption_l_per_m2"]) * square_m
			result = Rules.sow_check(stage, storage, crop, cost)
			if bool(result["ok"]) and field.sow(index, crop):
				Rules.consume(storage, cost, false)
				_add_mass(tool, -cost * _context.density(material))
		"fertilize":
			# Puste pole/ściernisko albo rosnące zboże (nie dojrzałe) – każda faza raz (field_cells.gd).
			var supply: Dictionary = state["storages"][str(work["input"]["storage_id"])]
			var dose: float = float(work["fertilizer_l_per_m2"]) * square_m
			result = Rules.fertilize_check(supply, dose)
			if bool(result["ok"]) and field.fertilize(index):
				var density: float = _context.density(str(supply.get("material_id", "")))
				Rules.consume(supply, dose, true)
				_add_mass(tool, -dose * density)
		"harvest":
			if stage != FieldCells.Stage.READY:
				return
			var storage_id: String = str(work["output"]["storage_id"])
			var storage: Dictionary = Machines.state(vehicle)["storages"].get(storage_id, {})
			var storage_def: Dictionary = StorageRules.storage_definition(Machines.model(vehicle), storage_id)
			result = Rules.harvest_check(stage, field.crop_at(index), work, storage, storage_def, settings,
				field.fertilizer_level(index), square_m)
			if bool(result["ok"]):
				var material: String = str(result["material"])
				var amount: float = float(result["amount"])
				Rules.store_harvest(storage, storage_def, material, amount)
				_add_mass(vehicle, amount * _context.density(material))
				field.harvest(index)
	if not result.is_empty() and not str(result["message"]).is_empty():
		_message(vehicle, str(result["message"]))


func _message(vehicle: RigidBody2D, text: String) -> void:
	var key: String = str(vehicle.get_instance_id()) + text
	if _time - float(_message_times.get(key, -100.0)) >= 2.0:
		_message_times[key] = _time
		work_message.emit(vehicle, text)


func get_diagnostics(vehicle: RigidBody2D) -> String:
	var parts := PackedStringArray()
	var state: Dictionary = Machines.state(vehicle)
	for id in state["storages"]:
		parts.append("%s: %.1f l" % [id, float(state["storages"][id]["amount_l"])])
	var tool: Node2D = _context.hitches.get_attached_machine(vehicle)
	if tool != null:
		var tool_state: Dictionary = Machines.state(tool)
		for id in tool_state["storages"]:
			parts.append("%s: %.1f l" % [id, float(tool_state["storages"][id]["amount_l"])])
	return " | ".join(parts)


## Pole, nad którym stoi punkt (piksele 2D), albo null.
func field_at(global_point: Vector2) -> Node2D:
	for field in fields:
		if field.contains_point(global_point):
			return field
	return null


## Oznacza pole jako własność gracza (zakup). Płatność obsługuje ShopService.
func set_owned(field_id: String) -> void:
	for field in fields:
		if field.field_id == field_id:
			field.owned = true
	if not _owned_ids.has(field_id):
		_owned_ids.append(field_id)


## Sen: wszystkie zasiane rośliny przechodzą do kolejnej fazy wzrostu. Zwraca liczbę komórek.
func grow_crops() -> int:
	var grown: int = 0
	for field in fields:
		grown += int(field.sleep())
	return grown


## Stan pól do zapisu gry (field_cells_v3).
func write_to_save(save_data: Dictionary) -> void:
	for field in fields:
		for saved in save_data["field_states"]:
			if str(saved["field_id"]) == field.field_id:
				saved["growth_simulation"] = field.export_state()


## Gatunek, który sieje siewnik.
static func seed_crop_of(tool: Node) -> String:
	return Rules.seed_crop(Machines.model(tool), Machines.state(tool))


## Przełącza gatunek siewnika na następny z listy. Zwraca nowy.
static func cycle_seed_crop(tool: Node) -> String:
	var next: String = Rules.next_seed_crop(Machines.model(tool), Machines.state(tool))
	if not next.is_empty():
		Machines.state(tool)["seed_crop_id"] = next
	return next
