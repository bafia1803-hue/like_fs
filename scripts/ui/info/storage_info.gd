extends "res://scripts/ui/info/info_provider.gd"
## Zawartość i pojemność zbiorników maszyny: zbiornik kombajnu, skrzynia przyczepy, nasiona w siewniku.

const COLORS := {
	"wheat_grain": Color("#f2c55c"), "barley_grain": Color("#e8d68f"), "oats_grain": Color("#f3e3ae"),
	"seed": Color("#8fc35a"), "fertilizer": Color("#f4f1e8"),
}


func rows(machine: Node, _role: String, query: RefCounted) -> Array:
	var result: Array = []
	var model: Dictionary = machine.get_meta("definition")
	var state: Dictionary = machine.get_meta("instance_state")
	var names: Dictionary = {}
	for material in query.catalog().get("materials", []):
		names[str(material["id"])] = str(material["name"])
	for definition in model.get("storage_definitions", []):
		var storage: Dictionary = state.get("storages", {}).get(str(definition["id"]), {})
		var amount: float = float(storage.get("amount_l", 0.0))
		var capacity: float = maxf(float(definition.get("capacity_l", 0.0)), 0.001)
		var material: String = str(storage.get("material_id", "")) if amount > 0.0 else ""
		var label: String = names.get(material, _default_label(model))
		result.append({"label": label, "value": "%.0f / %.0f l" % [amount, capacity],
			"ratio": clampf(amount / capacity, 0.0, 1.0), "color": COLORS.get(material, Color("#c9c0ae"))})
	return result


func _default_label(model: Dictionary) -> String:
	match str(model.get("category", "")):
		"combine":
			return "Zbiornik ziarna (pusty)"
		"trailer", "semitrailer":
			return "Skrzynia (pusta)"
		"seeder":
			return "Ziarno siewne (brak)"
		"spreader":
			return "Nawóz (brak)"
	return "Zbiornik (pusty)"
