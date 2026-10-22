extends Node2D
## Rura rozładunkowa kombajnu (warstwa gry): ruch (core/transfer/pipe_motion.gd), punkt wylotu,
## obszar wykrywania odbiornika. Nie rysuje i nie ma kolizji; widoki 2D/3D czytają extension,
## flow_l_per_s i geometrię (pivot_local, tip_local).

const StorageRules = preload("res://scripts/core/storage/storage_rules.gd")
const PipeMotion = preload("res://scripts/core/transfer/pipe_motion.gd")
const Vec = preload("res://scripts/core/util/vec.gd")

var config: Dictionary = {}
var state: Dictionary = {}
var units: float = 40.0
var motion = PipeMotion.new()
var flow_l_per_s: float = 0.0
var extension: float:
	get:
		return motion.extension


func configure(data: Dictionary, saved_state: Dictionary, world_units: float) -> void:
	config = data
	state = saved_state
	units = world_units
	motion.setup(config, state)


## Zwraca liczbę sekund tego kroku, przez które rura była całkowicie otwarta.
func advance(want_open: bool, delta: float) -> float:
	var open_seconds: float = motion.advance(want_open, delta)
	motion.write(state)
	return open_seconds


func _mirror(point: Vector2) -> Vector2:
	return Vector2(-point.x, point.y) if str(config["side"]) == "right" else point


func pivot_local() -> Vector2:
	return _mirror(Vec.v2(config["pivot_in_body_m"])) * units


func tip_local() -> Vector2:
	var angle: float = lerpf(float(config["folded_angle_deg"]), float(config["deployed_angle_deg"]), motion.extension)
	var direction := Vector2.from_angle(deg_to_rad(angle))
	return pivot_local() + _mirror(direction) * float(config["length_m"]) * units


func outlet_world() -> Vector2:
	return to_global(tip_local())


func detection_polygon() -> PackedVector2Array:
	var polygon: PackedVector2Array = StorageRules.rectangle(Transform2D.IDENTITY, config["detection_area"], units)
	for index in polygon.size():
		polygon[index] = to_global(_mirror(polygon[index]))
	return polygon


func set_flow(value: float) -> void:
	flow_l_per_s = value
