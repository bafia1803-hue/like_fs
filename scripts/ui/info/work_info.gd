extends "res://scripts/ui/info/info_provider.gd"
## Stan pracy narzędzia (klawisz B): opuszczone/włączone albo podniesione.

const Machines = preload("res://scripts/sim/machines/machines.gd")


func rows(machine: Node, role: String, _query: RefCounted) -> Array:
	if role != "implement":
		return []
	var work: Variant = machine.get_meta("definition").get("work")
	if not work is Dictionary:
		return []
	var active: bool = Machines.is_working(machine)
	var text: String
	match str(work.get("operation", "")):
		"harvest", "cultivate":
			text = "opuszczony" if active else "podniesiony"
		_:
			text = "włączony" if active else "wyłączony"
	var limit: String = ""
	if active and work.has("max_working_speed_kmh"):
		limit = ", max %d km/h" % roundi(float(work["max_working_speed_kmh"]))
	return [{"label": "Praca (B)", "value": text + limit}]

