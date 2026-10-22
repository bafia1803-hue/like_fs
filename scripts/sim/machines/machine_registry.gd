extends RefCounted
## Maszyny obecne w grze: id → węzeł, lista pojazdów z napędem (kolejność przełączania TAB).
## Każda zmiana idzie przez add/remove, które ogłaszają ją w EventBus (widoki, przeładunek).

const Machines = preload("res://scripts/sim/machines/machines.gd")

var by_id: Dictionary = {}
var vehicles: Array[RigidBody2D] = []
var root: Node2D
var _events: RefCounted


func setup(machines_root: Node2D, events: RefCounted) -> void:
	root = machines_root
	_events = events


func add(machine: Node2D) -> void:
	by_id[Machines.id(machine)] = machine
	if Machines.kind(machine) == "powered_vehicle" and machine is RigidBody2D:
		vehicles.append(machine as RigidBody2D)
	if machine.get_parent() == null:
		root.add_child(machine)
	if _events != null:
		_events.machine_added.emit(machine)


func remove(machine: Node2D) -> void:
	if _events != null:
		_events.machine_removed.emit(machine)
	if machine is RigidBody2D:
		vehicles.erase(machine as RigidBody2D)
	by_id.erase(Machines.id(machine))
	machine.queue_free()


func get_machine(id: String) -> Node2D:
	return by_id.get(id) as Node2D


func has(id: String) -> bool:
	return by_id.has(id)


func sorted_ids() -> Array:
	var ids: Array = by_id.keys()
	ids.sort()
	return ids


func all() -> Array:
	return by_id.values()
