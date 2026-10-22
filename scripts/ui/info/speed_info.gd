extends "res://scripts/ui/info/info_provider.gd"
## Prędkość sterowanego pojazdu (także podczas odtwarzania trasy).

const Machines = preload("res://scripts/sim/machines/machines.gd")


func rows(machine: Node, role: String, _query: RefCounted) -> Array:
	if role != "vehicle" or not machine.has_method("get_speed_kmh"):
		return []
	var label: String = "Prędkość (trasa)" if Machines.on_route(machine) else "Prędkość"
	return [{"label": label, "value": "%.1f km/h" % absf(Machines.display_speed_kmh(machine))}]
