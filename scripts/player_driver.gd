extends Node

var _vehicle: Node = null


func _ready() -> void:
	process_physics_priority = -10


func configure(vehicle: Node) -> void:
	assert(vehicle != null and vehicle.has_method("set_controls"),
		"Pojazd musi mieć set_controls().")
	if is_instance_valid(_vehicle) and _vehicle != vehicle and str(_vehicle.get_meta("route_mode", "")).is_empty():
		# Poprzedni pojazd przestaje dostawać gaz i zaczyna hamować.
		_vehicle.call("set_controls", 0.0, 0.0, true)
	_vehicle = vehicle
	if str(_vehicle.get_meta("route_mode", "")).is_empty():
		_vehicle.call("set_controls", 0.0, 0.0, false)


func _physics_process(_delta: float) -> void:
	if get_viewport().gui_get_focus_owner() is LineEdit:
		if is_instance_valid(_vehicle) and str(_vehicle.get_meta("route_mode", "")).is_empty():
			_vehicle.call("set_controls", 0.0, 0.0, true)
		return
	if not is_instance_valid(_vehicle):
		return
	if str(_vehicle.get_meta("route_mode", "")) == "playing":
		return
	var forward_pressed: bool = Input.is_physical_key_pressed(KEY_W)
	var reverse_pressed: bool = Input.is_physical_key_pressed(KEY_S)
	var throttle: float = float(forward_pressed) - float(reverse_pressed)
	var steering: float = (
		float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
	)
	var braking: bool = Input.is_physical_key_pressed(KEY_SPACE) or (forward_pressed and reverse_pressed)
	if str(_vehicle.get_meta("route_mode", "")) == "held":
		if throttle == 0.0 and steering == 0.0 and not braking:
			return
		_vehicle.get_meta("route_system").release_hold(_vehicle)
	_vehicle.call("set_controls", throttle, steering, braking)
