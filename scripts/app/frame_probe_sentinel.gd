extends Node
## Wartownik FrameProbe: pierwszy albo ostatni węzeł w kolejności _process / _physics_process.

var probe: Node
var first: bool = true


func _process(_delta: float) -> void:
	if first:
		probe.frame_begin()
	else:
		probe.frame_end()


func _physics_process(_delta: float) -> void:
	if first:
		probe.physics_begin()
	else:
		probe.physics_end()
