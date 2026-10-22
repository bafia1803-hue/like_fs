extends "res://scripts/ui/info/info_provider.gd"
## Bieżące komunikaty przeładunku: rura kombajnu, wywrotka, załadunek z silosu, stacja nasion.

const HIDDEN_PREFIXES := ["Przyczepa: poza miejscem", "Rura: pusty", "Przyczepa: pusta", "Rura: 0%"]


func rows(machine: Node, _role: String, world: Node) -> Array:
	var result: Array = []
	for text in world.call("get_machine_statuses", machine):
		var hidden: bool = false
		for prefix in HIDDEN_PREFIXES:
			if str(text).begins_with(prefix):
				hidden = true
		if not hidden:
			result.append({"label": str(text)})
	return result
