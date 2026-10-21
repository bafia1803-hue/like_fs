extends RefCounted
## Jedyna operacja przepływu: odejmij i dodaj dokładnie tę samą ilość.
## Nie tworzy ziarna, nie miesza gatunków w przyczepie, respektuje pojemności.

static func storage_definition(model: Dictionary, id: String) -> Dictionary:
	for definition in model.get("storage_definitions", []):
		if str(definition["id"]) == id:
			return definition
	return {}

static func silo_total(state: Dictionary) -> float:
	var total: float = 0.0
	for value in state.get("contents_l", {}).values():
		total += float(value)
	return total

static func space_for(storage: Dictionary, definition: Dictionary, material: String) -> float:
	if not definition.get("accepted_material_ids", []).has(material):
		return 0.0
	var amount: float = float(storage.get("amount_l", 0.0))
	if amount > 0.0 and str(storage.get("material_id")) != material:
		return 0.0
	return maxf(0.0, float(definition.get("capacity_l", 0.0)) - amount)

static func silo_space(state: Dictionary, definition: Dictionary, material: String) -> float:
	if not definition.get("accepted_material_ids", []).has(material):
		return 0.0
	return maxf(0.0, float(definition["capacity_l"]) - silo_total(state))

static func transfer(source: Dictionary, target: Dictionary,
		definition: Dictionary, limit_l: float, to_silo: bool = false) -> float:
	var material: String = str(source.get("material_id", ""))
	var available: float = maxf(0.0, float(source.get("amount_l", 0.0)))
	if available <= 0.0 or limit_l <= 0.0:
		return 0.0
	var room: float = silo_space(target, definition, material) if to_silo else space_for(target, definition, material)
	var moved: float = minf(available, minf(room, limit_l))
	if moved <= 0.0:
		return 0.0
	if to_silo:
		var contents: Dictionary = target["contents_l"]
		contents[material] = float(contents.get(material, 0.0)) + moved
	else:
		target["material_id"] = material
		target["amount_l"] = float(target.get("amount_l", 0.0)) + moved
	source["amount_l"] = available - moved
	if float(source["amount_l"]) <= 0.0:
		source["amount_l"] = 0.0
		source["material_id"] = null
	return moved

static func vector(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))

static func rectangle(pose: Transform2D, area: Dictionary, units: float) -> PackedVector2Array:
	var half := Vector2(float(area["width_m"]), float(area["length_m"])) * units * 0.5
	var local_pose := Transform2D(deg_to_rad(float(area.get("rotation_deg", 0.0))), vector(area["center_m"]) * units)
	var transform: Transform2D = pose * local_pose
	return PackedVector2Array([
		transform * Vector2(-half.x, -half.y), transform * Vector2(half.x, -half.y),
		transform * half, transform * Vector2(-half.x, half.y)
	])
