extends Node2D
## Plan pracownika w widoku 2D: dojazd (fiolet), wjazdy (biały), praca (żółty), zawroty (błękit),
## cofanie (pomarańczowy).
## Czyta tylko preview_lines() i revision systemu pracownika.

const COLORS := {
	"approach": Color(1.0, 0.55, 1.0, 0.85),
	"lead": Color(1.0, 1.0, 1.0, 0.7),
	"work": Color(1.0, 0.92, 0.3, 0.55),
	"turn": Color(0.4, 0.9, 1.0, 0.85),
	"reverse": Color(1.0, 0.55, 0.1, 0.9),
}

var workers: Node2D
var units: float = 40.0
var _revision: int = -1
var _lines: Array = []


func configure(worker_system: Node2D, scale_units: float) -> void:
	name = "Workers2D"
	workers = worker_system
	units = scale_units
	z_index = 1


func _process(_delta: float) -> void:
	if not is_instance_valid(workers) or int(workers.get("revision")) == _revision:
		return
	_revision = int(workers.get("revision"))
	_lines = workers.call("preview_lines")
	queue_redraw()


func _draw() -> void:
	for line in _lines:
		var points: PackedVector2Array = line["points"]
		if points.size() < 2:
			continue
		var scaled := PackedVector2Array()
		for point in points:
			scaled.append(point * units)
		var color: Color = COLORS.get(str(line["kind"]), Color.WHITE)
		draw_polyline(scaled, color, (0.35 if line["kind"] == "work" else 0.18) * units, true)
