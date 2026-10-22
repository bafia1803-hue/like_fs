extends Node
## Gracz: sterowany pojazd (TAB przełącza), sterowanie klawiszami (PlayerDriver)
## i komunikaty dotyczące zestawu gracza (EventBus.machine_message → notice).

const Machines = preload("res://scripts/sim/machines/machines.gd")
const DriverScript = preload("res://scripts/sim/systems/player_driver.gd")

var controlled: RigidBody2D
var driver: Node
var _context: RefCounted


## Zwraca false, gdy zapis nie wskazuje pojazdu z napędem.
func setup(context: RefCounted) -> bool:
	name = "PlayerControl"
	_context = context
	var player: Dictionary = context.save_data()["player"]
	controlled = context.machines.get_machine(str(player["controlled_machine_id"])) as RigidBody2D
	if controlled == null:
		return false
	driver = DriverScript.new()
	driver.name = "PlayerDriver"
	driver.configure(controlled)
	add_child(driver)
	context.events.machine_message.connect(_on_machine_message)
	return true


## Po utworzeniu systemu tras (zwalnianie zestawu „held” przez kierowcę).
func connect_routes(routes: Node) -> void:
	driver.setup(routes)


## Następny (+1) albo poprzedni (−1) pojazd. Zwraca komunikat dla gracza (pusty = bez zmian).
func switch_vehicle(direction: int = 1) -> String:
	if _context.routes != null and not _context.routes.recording.is_empty():
		return "Zakończ nagrywanie przed przełączeniem pojazdu."
	var vehicles: Array[RigidBody2D] = _context.machines.vehicles
	if vehicles.size() < 2:
		return ""
	var current: int = vehicles.find(controlled)
	controlled = vehicles[posmod(current + direction, vehicles.size())]
	driver.configure(controlled)
	var player: Dictionary = _context.save_data()["player"]
	player["controlled_machine_id"] = Machines.id(controlled)
	player["camera"]["target_instance_id"] = Machines.id(controlled)
	_context.events.controlled_changed.emit(controlled)
	return "Sterujesz: " + str(Machines.model(controlled)["name"])


## Maszyny gracza: sterowany pojazd i jego narzędzie/przyczepa.
func player_machines() -> Array:
	var result: Array = []
	if is_instance_valid(controlled):
		result.append(controlled)
		var tool: Node2D = _context.hitches.get_attached_machine(controlled)
		if tool != null:
			result.append(tool)
	return result


## Podpięty siewnik sterowanego zestawu (albo null).
func controlled_seeder() -> Node2D:
	for machine in player_machines():
		var work: Variant = Machines.model(machine).get("work")
		if work is Dictionary and str(work.get("operation", "")) == "sow" and machine != controlled:
			return machine
	return null


## Komunikat pracy na polu dotyczący pojazdu (tylko sterowanego).
func on_vehicle_message(vehicle: RigidBody2D, text: String) -> void:
	if vehicle == controlled:
		_context.events.notice.emit(text)


func _on_machine_message(machine_id: String, text: String) -> void:
	for machine in player_machines():
		if Machines.id(machine) == machine_id:
			_context.events.notice.emit(text)
			return
