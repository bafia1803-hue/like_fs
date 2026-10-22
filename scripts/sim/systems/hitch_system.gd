extends Node2D
## Zaczepy (warstwa gry): wybór najbliższego pasującego narzędzia, przeguby i mocowania sztywne,
## odtworzenie połączeń z zapisu. Zasady (zgodność portów, odległości, kąt) są w HitchRules.
##   drawbar, fifth_wheel        – PinJoint2D między pojazdem a członem narzędzia,
##   combine_header, three_point – narzędzie staje się sztywną częścią nośnika (attach_to_carrier).

const HitchRules = preload("res://scripts/core/hitch/hitch_rules.gd")
const Machines = preload("res://scripts/sim/machines/machines.gd")

var _context: RefCounted
var _save: Dictionary = {}
var _policy: Dictionary = {}
var _units: float = 40.0
var _links: Array[Dictionary] = []


func setup(context: RefCounted) -> void:
	name = "HitchSystem"
	_context = context
	_save = context.save_data()
	_policy = context.catalog()["attachment_policy"]
	_units = context.units


func _machines() -> Dictionary:
	return _context.machines.by_id


## Klawisz E: odpina narzędzie pojazdu albo podpina najbliższe pasujące. Zwraca komunikat.
func toggle_for(parent: RigidBody2D) -> String:
	if Machines.is_recording(parent) or Machines.route_mode(parent) == "playing":
		return "Zakończ nagrywanie/odtwarzanie przed zmianą zestawu."
	if Machines.route_mode(parent) == "held" and _context.routes != null:
		_context.routes.release_hold(parent)
	for link in _links:
		if link["parent"] == parent:
			return _detach(link)
	var candidates: Array = []
	for socket in Machines.model(parent)["hitch_ports"]:
		if socket["role"] != "socket":
			continue
		for machine in _machines().values():
			if machine == parent or _is_attached(machine):
				continue
			for plug in Machines.model(machine)["hitch_ports"]:
				if not _compatible(machine, socket, plug):
					continue
				var distance: float = _port_position(parent, socket).distance_to(_port_position(machine, plug)) / _units
				candidates.append({"distance": distance, "child": machine, "socket": socket, "plug": plug})
	var best: Dictionary = HitchRules.nearest(candidates)
	if best.is_empty():
		return "Brak wolnego narzędzia pasującego do zaczepu tego pojazdu."
	var child: Node2D = best["child"]
	var socket: Dictionary = best["socket"]
	var plug: Dictionary = best["plug"]
	var problem: String = HitchRules.distance_problem(float(best["distance"]), HitchRules.attach_distance(_policy, socket, plug))
	if problem.is_empty():
		problem = HitchRules.angle_problem(socket, parent.global_rotation, _port_body(child, plug).global_rotation)
	if not problem.is_empty():
		return problem
	var record: Dictionary = {
		"parent_instance_id": Machines.id(parent),
		"parent_port_id": socket["id"],
		"child_instance_id": Machines.id(child),
		"child_port_id": plug["id"]
	}
	_create_link(parent, child, socket, plug, record)
	var connections: Array = _save["connections"]
	connections.append(record)
	return "Podpięto: %s. E odpina." % str(Machines.model(child)["name"])


func restore_connections() -> bool:
	var connections: Array = _save["connections"]
	for record_value in connections:
		var record: Dictionary = record_value
		var parent: RigidBody2D = _machines().get(record.get("parent_instance_id")) as RigidBody2D
		var child: Node2D = _machines().get(record.get("child_instance_id")) as Node2D
		if parent == null or child == null or parent == child:
			return _restore_error("Niepoprawne maszyny zapisanej pary zaczepów.")
		var socket: Dictionary = _find_port(parent, str(record.get("parent_port_id", "")))
		var plug: Dictionary = _find_port(child, str(record.get("child_port_id", "")))
		if socket.is_empty() or plug.is_empty() or not _compatible(child, socket, plug):
			return _restore_error("Nieznane lub niezgodne porty zapisanej pary.")
		if _is_attached(child) or get_attached_machine(parent) != null:
			return _restore_error("Powtórzone użycie maszyny w połączeniach.")
		if _port_position(parent, socket).distance_to(_port_position(child, plug)) / _units > HitchRules.attach_distance(_policy, socket, plug):
			return _restore_error("Zapisane maszyny są za daleko od siebie, aby odtworzyć zaczep.")
		_create_link(parent, child, socket, plug, record)
	return true


func _create_link(parent: RigidBody2D, child: Node2D, socket: Dictionary, plug: Dictionary, record: Dictionary) -> void:
	var joint: PinJoint2D = null
	if HitchRules.link_kind(str(socket["type"])) == "rigid":
		child.call("attach_to_carrier", parent, socket, plug)
	else:
		var shift: Vector2 = _port_position(parent, socket) - _port_position(child, plug)
		child.call("snap_by", shift)
		var child_body: RigidBody2D = _port_body(child, plug)
		joint = PinJoint2D.new()
		joint.name = "Hitch_" + str(record["child_instance_id"])
		joint.position = to_local(_port_position(parent, socket))
		joint.softness = 0.0
		# Wyjątek dla wózka przyczepy zachowuje dotychczasowe zachowanie.
		# Korpus narzędzia jednoosiowego nadal może uderzyć w ciągnik.
		joint.disable_collision = (
			bool(_policy["disable_collision_between_connected_members"])
			and Machines.kind(child) == "towed_turntable"
		)
		add_child(joint)
		joint.node_a = joint.get_path_to(parent)
		joint.node_b = joint.get_path_to(child_body)
		joint.angular_limit_enabled = false
		child.call("set_attached", true)
		if child.has_method("set_carrier"):
			child.call("set_carrier", parent)
		child_body.sleeping = false
	parent.sleeping = false
	_links.append({"parent": parent, "child": child, "joint": joint, "socket": socket, "plug": plug, "record": record})


func _detach(link: Dictionary) -> String:
	var child: Node2D = link["child"]
	if link["joint"] == null:
		child.call("detach_from_carrier")
	else:
		var joint: PinJoint2D = link["joint"]
		joint.node_a = NodePath("")
		joint.node_b = NodePath("")
		joint.queue_free()
		child.call("set_attached", false)
	var connections: Array = _save["connections"]
	connections.erase(link["record"])
	_links.erase(link)
	return "Odpięto: %s." % str(Machines.model(child)["name"])


## Odpina wszystkie połączenia maszyny (jako pojazdu i jako narzędzia), np. przed sprzedażą.
func detach_all(machine: Node) -> void:
	for link in _links.duplicate():
		if link["parent"] == machine or link["child"] == machine:
			_detach(link)


func get_attached_machine(parent: Node) -> Node2D:
	for link in _links:
		if link["parent"] == parent:
			return link["child"] as Node2D
	return null


## Pojazd, do którego podpięta jest maszyna (null, gdy wolna).
func get_carrier(child: Node) -> RigidBody2D:
	for link in _links:
		if link["child"] == child:
			return link["parent"] as RigidBody2D
	return null


func get_diagnostics(parent: RigidBody2D) -> String:
	for link in _links:
		if link["parent"] == parent:
			var error_m: float = _port_position(parent, link["socket"]).distance_to(_port_position(link["child"], link["plug"])) / _units
			var kind: String = "sztywne" if link["joint"] == null else "obrotowe"
			return "Mocowanie: %s | rozbieżność zaczepów: %.3f m" % [kind, error_m]
	return "Zaczep aktywnego pojazdu: wolny."


## Połączenie pojazdu dla tras: {"parent", "child", "joint", "socket", "plug", "record"} albo {}.
func get_route_link(parent: RigidBody2D) -> Dictionary:
	for link in _links:
		if link["parent"] == parent:
			return link
	return {}


func _compatible(child: Node2D, socket: Dictionary, plug: Dictionary) -> bool:
	if not HitchRules.ports_match(socket, plug):
		return false
	var required: Array[String] = HitchRules.required_methods(str(socket["type"]))
	if required.is_empty():
		return false
	for method in required:
		if not child.has_method(method):
			return false
	return true


func _is_attached(machine: Node) -> bool:
	for link in _links:
		if link["child"] == machine:
			return true
	return false


func _find_port(machine: Node, port_id: String) -> Dictionary:
	for port in Machines.model(machine)["hitch_ports"]:
		if port["id"] == port_id:
			return port
	return {}


func _port_body(machine: Node, port: Dictionary) -> Node2D:
	if machine.has_method("get_hitch_body"):
		return machine.call("get_hitch_body", port) as RigidBody2D
	return Machines.pose_body(machine)


## Położenie portu w świecie (piksele).
func port_position(machine: Node, port: Dictionary) -> Vector2:
	return _port_position(machine, port)


func _port_position(machine: Node, port: Dictionary) -> Vector2:
	if machine.has_method("get_hitch_position"):
		return machine.call("get_hitch_position", port)
	var body: Node2D = _port_body(machine, port)
	var position_m: Array = port["position_m"]
	return body.to_global(Vector2(float(position_m[0]), float(position_m[1])) * _units)


func _restore_error(message: String) -> bool:
	push_error(message)
	return false
