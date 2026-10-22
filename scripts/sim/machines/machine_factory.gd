extends RefCounted
## Tworzy węzły maszyn ze stanu (wczytanie gry, zakup w sklepie).
## Rejestr physics_kind → skrypt: nowy rodzaj fizyki to register_kind(...) w jednym miejscu
## (SimulationBuilder). Nieznany rodzaj staje się nieruchomą maszyną (parked_machine.gd).

const Machines = preload("res://scripts/sim/machines/machines.gd")
const ParkedScript = preload("res://scripts/sim/machines/parked_machine.gd")

const DEFAULT_KINDS := {
	"powered_vehicle": preload("res://scripts/sim/machines/vehicle.gd"),
	"towed_turntable": preload("res://scripts/sim/machines/trailer.gd"),
	"towed_single_axle": preload("res://scripts/sim/machines/single_axle_implement.gd"),
	"towed_semitrailer": preload("res://scripts/sim/machines/semitrailer.gd"),
	"rigid_mounted": preload("res://scripts/sim/machines/mounted_implement.gd"),
}

var last_error: String = ""
var _kinds: Dictionary = {}
var _models: Dictionary = {}
var _materials: Array = []
var _units: float = 40.0


func setup(models_by_id: Dictionary, materials: Array, units: float) -> void:
	_models = models_by_id
	_materials = materials
	_units = units
	for kind in DEFAULT_KINDS:
		register_kind(kind, DEFAULT_KINDS[kind])


func register_kind(physics_kind: String, script: Script) -> void:
	_kinds[physics_kind] = script


func kinds() -> Array:
	return _kinds.keys()


func model(model_id: String) -> Dictionary:
	return _models.get(model_id, {})


## Nowy węzeł maszyny (jeszcze poza drzewem sceny). Zwraca null, gdy model jest nieznany.
func create(saved_state: Dictionary) -> Node2D:
	last_error = ""
	var model_data: Dictionary = _models.get(str(saved_state.get("model_id", "")), {})
	if model_data.is_empty():
		last_error = "Nieznany model maszyny: " + str(saved_state.get("model_id", ""))
		return null
	var kind: String = str(model_data["physics_kind"])
	if kind == "towed_turntable":
		var front: Dictionary = saved_state["articulated_state"]["front_carriage"]
		front["relative_angular_velocity_deg_per_s"] = 0.0
	var script: Script = _kinds.get(kind, ParkedScript)
	var machine: Node2D = script.new()
	machine.call("configure", model_data, saved_state, _materials, _units)
	machine.set_meta("definition", model_data)
	machine.set_meta("instance_state", saved_state)
	var missing: PackedStringArray = Machines.missing_methods(machine)
	if not missing.is_empty():
		last_error = "Maszyna %s nie spełnia protokołu: %s" % [kind, ", ".join(missing)]
		machine.free()
		return null
	return machine
