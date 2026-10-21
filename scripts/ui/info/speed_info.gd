extends "res://scripts/ui/info/info_provider.gd"
## Prędkość sterowanego pojazdu (także podczas odtwarzania trasy).


func rows(machine: Node, role: String, _world: Node) -> Array:
	if role != "vehicle" or not machine.has_method("get_speed_kmh"):
		return []
	var speed: float = float(machine.call("get_speed_kmh"))
	if not str(machine.get_meta("route_mode", "")).is_empty():
		speed = float(machine.get_meta("route_speed_m_s", 0.0)) * 3.6
		return [{"label": "Prędkość (trasa)", "value": "%.1f km/h" % absf(speed)}]
	return [{"label": "Prędkość", "value": "%.1f km/h" % absf(speed)}]
