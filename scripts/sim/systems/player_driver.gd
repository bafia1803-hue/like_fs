extends Node
## Klawisze W/S/A/D/Spacja → sterowanie pojazdem gracza. Na trasie (odtwarzanie) nie steruje;
## zestaw zatrzymany po trasie („held”) wraca do ręcznego sterowania pierwszym ruchem.

const Machines = preload("res://scripts/sim/machines/machines.gd")

var _vehicle: Node = null
var _routes: Node = null


func _ready() -> void:
	process_physics_priority = -10


## routes – RouteSystem (zwolnienie zestawu „held”); może być null w testach bez tras.
func setup(routes: Node) -> void:
	_routes = routes


func configure(vehicle: Node) -> void:
	assert(vehicle != null and vehicle.has_method("set_controls"), "Pojazd musi mieć set_controls().")
	if is_instance_valid(_vehicle) and _vehicle != vehicle and not Machines.on_route(_vehicle):
		# Poprzedni pojazd przestaje dostawać gaz i zaczyna hamować.
		_vehicle.call("set_controls", 0.0, 0.0, true)
	_vehicle = vehicle
	if not Machines.on_route(_vehicle):
		_vehicle.call("set_controls", 0.0, 0.0, false)


func _physics_process(_delta: float) -> void:
	if get_viewport().gui_get_focus_owner() is LineEdit:
		if is_instance_valid(_vehicle) and not Machines.on_route(_vehicle):
			_vehicle.call("set_controls", 0.0, 0.0, true)
		return
	if not is_instance_valid(_vehicle):
		return
	var mode: String = Machines.route_mode(_vehicle)
	if mode == "playing":
		return
	var forward_pressed: bool = Input.is_physical_key_pressed(KEY_W)
	var reverse_pressed: bool = Input.is_physical_key_pressed(KEY_S)
	var throttle: float = float(forward_pressed) - float(reverse_pressed)
	var steering: float = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
	var braking: bool = Input.is_physical_key_pressed(KEY_SPACE) or (forward_pressed and reverse_pressed)
	if mode == "held":
		if throttle == 0.0 and steering == 0.0 and not braking:
			return
		if _routes != null:
			_routes.release_hold(_vehicle)
	_vehicle.call("set_controls", throttle, steering, braking)
