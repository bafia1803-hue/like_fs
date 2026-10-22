extends Node2D
const GridScript = preload("res://scripts/field_grid.gd")
signal work_message(vehicle: RigidBody2D, message: String)
var fields: Array = []
var settings: Dictionary = {}
var last_error: String = ""
var _machines: Dictionary
var _hitches: Node
var _units: float
var _materials: Dictionary = {}
var _previous: Dictionary = {}
var _message_times: Dictionary = {}
var _time: float = 0.0

func configure(session: Dictionary, machines: Dictionary, hitches: Node, units: float) -> bool:
	_machines = machines
	_hitches = hitches
	_units = units
	var parser := JSON.new()
	var path: String = "res://files/farming.json"
	if not FileAccess.file_exists(path) or parser.parse(FileAccess.get_file_as_string(path)) != OK:
		last_error = "Brak lub błędny JSON: " + path
		return false
	if not parser.data is Dictionary:
		last_error = "farming.json musi zawierać obiekt."
		return false
	settings = parser.data
	for key in ["minimum_work_speed_m_s", "yield_l_per_m2", "colors"]:
		if not settings.has(key):
			last_error = "Brak parametru farming.json: " + key
			return false
	for material in session["catalog_data"]["materials"]:
		_materials[str(material["id"])] = material
	var saved_fields: Dictionary = {}
	for entry in session["save_data"]["field_states"]:
		saved_fields[str(entry["field_id"])] = entry
	for definition in session["map_data"]["fields"]:
		var grid = GridScript.new()
		grid.name = str(definition["id"])
		grid.configure(definition, settings, units)
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
		fields.append(grid)
	return true

func _physics_process(delta: float) -> void:
	_time += delta
	var seen: Dictionary = {}
	for machine_value in _machines.values():
		if not machine_value is RigidBody2D:
			continue
		var vehicle: RigidBody2D = machine_value
		var tool: Node2D = _hitches.call("get_attached_machine", vehicle) as Node2D
		if vehicle.has_method("set_speed_cap_kmh"):
			vehicle.call("set_speed_cap_kmh", get_speed_cap_kmh(tool))
		if tool != null and tool.has_method("take_message"):
			var notice: String = str(tool.call("take_message"))
			if not notice.is_empty():
				work_message.emit(vehicle, notice)
		if tool == null or not tool.has_method("get_work_transform"):
			continue
		seen[tool.get_instance_id()] = true
		if not str(vehicle.get_meta("route_mode", "")).is_empty():
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
	if tool == null or not tool.has_meta("instance_state"):
		return false
	var work_state: Variant = tool.get_meta("instance_state").get("work_state")
	return work_state is Dictionary and bool(work_state.get("enabled", false)) and bool(work_state.get("lowered", false))

## Limit prędkości pojazdu wynikający z pracującego narzędzia (INF = brak limitu).
func get_speed_cap_kmh(tool: Node) -> float:
	if not is_working(tool):
		return INF
	var work: Variant = tool.get_meta("definition").get("work")
	if work is Dictionary and work.has("max_working_speed_kmh"):
		return float(work["max_working_speed_kmh"])
	return INF

## Przełącza pracę narzędzia podpiętego do pojazdu. Zwraca komunikat dla gracza.
func toggle_work(vehicle: RigidBody2D) -> String:
	var tool: Node2D = _hitches.call("get_attached_machine", vehicle) as Node2D
	var vehicle_model: Dictionary = vehicle.get_meta("definition")
	if tool == null or not tool.get_meta("definition").get("work") is Dictionary:
		if str(vehicle_model.get("category", "")) == "combine":
			return "Podepnij heder (E), żeby rozpocząć żniwa."
		return "Brak podpiętej maszyny roboczej."
	if tool.has_method("is_foldable") and bool(tool.call("is_foldable")):
		_previous.erase(tool.get_instance_id())
		return str(tool.call("toggle_fold_work", vehicle))
	var state: Dictionary = tool.get_meta("instance_state")
	if not state.get("work_state") is Dictionary:
		state["work_state"] = {"enabled": false, "lowered": false}
	var work_state: Dictionary = state["work_state"]
	var active: bool = not is_working(tool)
	work_state["enabled"] = active
	work_state["lowered"] = active
	_previous.erase(tool.get_instance_id())
	var model: Dictionary = tool.get_meta("definition")
	var limit: String = ""
	if active and model["work"].has("max_working_speed_kmh"):
		limit = " (max %d km/h)" % roundi(float(model["work"]["max_working_speed_kmh"]))
	match str(model["work"]["operation"]):
		"harvest":
			return ("Heder opuszczony — koszenie" + limit) if active else "Heder podniesiony"
		"cultivate":
			return ("Kultywator opuszczony" + limit) if active else "Kultywator podniesiony"
		"sow":
			return ("Siewnik włączony" + limit) if active else "Siewnik wyłączony"
	return (str(model["name"]) + ": praca" + limit) if active else (str(model["name"]) + ": stop")

func reset_route_sweep(tool: Node2D) -> void:
	if tool != null:
		_previous.erase(tool.get_instance_id())

func begin_route_segment(tool: Node2D) -> void:
	if tool == null or not tool.has_method("get_work_transform"):
		return
	var model: Dictionary = tool.get_meta("definition")
	if not model.get("work") is Dictionary:
		return
	var area: Dictionary = model["work"]["area"]
	var base: Transform2D = tool.call("get_work_transform")
	_previous[tool.get_instance_id()] = base * Transform2D(deg_to_rad(float(area["rotation_deg"])), _vec(area["center_m"]) * _units)

func work_route_segment(vehicle: RigidBody2D, tool: Node2D, speed: float) -> void:
	if tool != null and tool.has_method("get_work_transform"):
		_work_tool(vehicle, tool, speed)

func _work_tool(vehicle: RigidBody2D, tool: Node2D, speed: float) -> void:
	var definition: Dictionary = tool.get_meta("definition")
	if not definition.get("work") is Dictionary:
		return
	var work: Dictionary = definition["work"]
	if not is_working(tool):
		_previous.erase(tool.get_instance_id())
		return
	var operation: String = str(work["operation"])
	var minimum: float = maxf(0.001, float(settings["minimum_work_speed_m_s"]))
	var allowed: bool = absf(speed) >= minimum if operation == "sow" else speed >= minimum
	var key: int = tool.get_instance_id()
	var area: Dictionary = work["area"]
	var base: Transform2D = tool.call("get_work_transform")
	var offset := Transform2D(deg_to_rad(float(area["rotation_deg"])), _vec(area["center_m"]) * _units)
	var current: Transform2D = base * offset
	if not allowed:
		_previous.erase(key)
		return
	var size := Vector2(float(area["width_m"]), float(area["length_m"]))
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
	for step in range(1, steps + 1):
		var pose: Transform2D = previous.interpolate_with(current, float(step) / steps)
		for field in fields:
			for index in field.cells_in_rectangle(pose, size):
				_work_cell(field, int(index), vehicle, tool, work)
	_previous[key] = current


func _work_cell(field: Node2D, index: int, vehicle: RigidBody2D, tool: Node2D, work: Dictionary) -> void:
	var stage: int = int(field.get("states")[index])
	var square_m: float = float(field.get("cell_m")) ** 2
	var state: Dictionary = tool.get_meta("instance_state")
	match str(work["operation"]):
		"cultivate":
			field.call("cultivate", index)
		"sow":
			if stage == GridScript.Stage.READY:
				_message(vehicle, "Najpierw zbierz albo skultywuj dojrzałe zboże.")
				return
			if stage == GridScript.Stage.HARVESTED:
				_message(vehicle, "Przed siewem skultywuj ściernisko.")
				return
			if stage != GridScript.Stage.PLAIN:
				return
			var storage: Dictionary = state["storages"][str(work["input"]["storage_id"])]
			var material: String = str(storage.get("material_id", ""))
			var crop: String = str(work["seed_material_to_crop_id"].get(material, ""))
			var cost: float = float(work["seed_consumption_l_per_m2"]) * square_m
			if crop.is_empty() or float(storage["amount_l"]) + 0.000001 < cost:
				_message(vehicle, "Siewnik nie ma odpowiednich nasion.")
				return
			if field.call("sow", index, crop):
				storage["amount_l"] = maxf(0.0, float(storage["amount_l"]) - cost)
				tool.call("change_cargo_mass", -cost * _density(material))
		"harvest":
			if stage != GridScript.Stage.READY:
				return
			var crop: String = str(field.get("crops")[index])
			if not work["allowed_crop_ids"].has(crop):
				_message(vehicle, "Ten heder nie zbiera tej rośliny.")
				return
			var material: String = str(work["crop_to_material_id"].get(crop, ""))
			var vehicle_state: Dictionary = vehicle.get_meta("instance_state")
			var storage_id: String = str(work["output"]["storage_id"])
			var storage: Dictionary = vehicle_state["storages"].get(storage_id, {})
			var vehicle_model: Dictionary = vehicle.get_meta("definition")
			var storage_def: Dictionary = {}
			for item in vehicle_model.get("storage_definitions", []):
				if str(item["id"]) == storage_id:
					storage_def = item
			if storage.is_empty() or storage_def.is_empty():
				_message(vehicle, "Pojazd nie ma zbiornika na ziarno.")
				return
			if not storage_def["accepted_material_ids"].has(material):
				return
			if float(storage["amount_l"]) > 0.000001 and str(storage["material_id"]) != material:
				_message(vehicle, "Opróżnij zbiornik przed zmianą rodzaju ziarna.")
				return
			var amount: float = float(settings["yield_l_per_m2"].get(crop, 0.0)) * square_m
			if amount <= 0.0:
				_message(vehicle, "Brak przelicznika plonu dla: " + crop)
				return
			if float(storage["amount_l"]) + amount > float(storage_def["capacity_l"]) + 0.000001:
				_message(vehicle, "Zbiornik kombajnu pełny — zbiór wstrzymany.")
				return
			storage["amount_l"] = minf(float(storage_def["capacity_l"]), float(storage["amount_l"]) + amount)
			storage["material_id"] = material
			vehicle.mass += amount * _density(material)
			vehicle.inertia = 0.0
			field.call("harvest", index)

func _density(material: String) -> float:
	return float(_materials.get(material, {}).get("bulk_density_kg_per_l", 0.0))

func _message(vehicle: RigidBody2D, text: String) -> void:
	var key: String = str(vehicle.get_instance_id()) + text
	if _time - float(_message_times.get(key, -100.0)) >= 2.0:
		_message_times[key] = _time
		work_message.emit(vehicle, text)

func get_diagnostics(vehicle: RigidBody2D) -> String:
	var parts := PackedStringArray()
	var state: Dictionary = vehicle.get_meta("instance_state")
	for id in state["storages"]:
		var storage: Dictionary = state["storages"][id]
		parts.append("%s: %.1f l" % [id, float(storage["amount_l"])])
	var tool: Node2D = _hitches.call("get_attached_machine", vehicle) as Node2D
	if tool != null:
		var tool_state: Dictionary = tool.get_meta("instance_state")
		for id in tool_state["storages"]:
			parts.append("%s: %.1f l" % [id, float(tool_state["storages"][id]["amount_l"])])
	return " | ".join(parts)

## Przycisk „Sen”: wszystkie zasiane rośliny przechodzą do kolejnej fazy wzrostu.
func sleep() -> int:
	var grown: int = 0
	for field in fields:
		grown += int(field.sleep())
	return grown

## Wywołaj przed przyszłym JSON.stringify(save_data); teraz brak automatycznego zapisu na dysk.
func write_to_save(save_data: Dictionary) -> void:
	for field in fields:
		for saved in save_data["field_states"]:
			if str(saved["field_id"]) == field.field_id:
				saved["growth_simulation"] = field.export_state()

func _vec(values: Array) -> Vector2:
	return Vector2(float(values[0]), float(values[1]))
