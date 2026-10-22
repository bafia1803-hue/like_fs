extends RefCounted
## Osie fizyki a osie wyglądu.
##
## Osie z tym samym kluczem "tandem_group" (np. tandem tira lub naczepy: dwie nieskrętne osie
## tuż obok siebie) fizyka traktuje jak JEDNĄ oś w środku grupy – dwie sztywne osie „szorują”
## w ciasnym zakręcie i źle się nimi steruje. Widoki (2D, 3D) nadal pokazują wszystkie koła.
## Oś zastępcza: średnia pozycja i rozstaw, suma obciążeń (load_weight), napęd i przenoszenie
## nacisku siodła, jeśli ma je którakolwiek oś grupy. Osie skrętne nie są łączone.


static func physical(axles: Array) -> Array:
	var result: Array = []
	var groups: Dictionary = {}       # nazwa -> indeks w result
	var counts: Dictionary = {}
	for value in axles:
		var axle: Dictionary = value
		var group: String = str(axle.get("tandem_group", ""))
		if group.is_empty() or bool(axle.get("steerable", false)):
			result.append(axle)
			continue
		if not groups.has(group):
			var merged: Dictionary = axle.duplicate(true)
			merged["id"] = group
			groups[group] = result.size()
			counts[group] = 1
			result.append(merged)
			continue
		var merged: Dictionary = result[groups[group]]
		var n: int = int(counts[group])
		for key in ["distance_from_front_m", "track_m", "lateral_grip", "tire_length_m", "tire_width_m"]:
			if axle.has(key):
				merged[key] = (float(merged.get(key, 0.0)) * n + float(axle[key])) / (n + 1)
		merged["load_weight"] = float(merged.get("load_weight", 1.0)) + float(axle.get("load_weight", 1.0))
		merged["driven"] = bool(merged.get("driven", false)) or bool(axle.get("driven", false))
		merged["carries_coupled_load"] = bool(merged.get("carries_coupled_load", false)) or bool(axle.get("carries_coupled_load", false))
		counts[group] = n + 1
	return result
