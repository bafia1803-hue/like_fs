extends Node2D
## Wolne zgodne zaczepy + odległość. Bez ograniczania prędkości i kąta.
## drawbar: przegub obrotowy; combine_header: mocowanie sztywne;
## three_point: TUZ ciągnika – narzędzie zawieszane sztywno (rozsiewacz), jak heder;
## fifth_wheel: siodło tira ↔ sworzeń naczepy (przegub obrotowy; port może mieć własną
## tolerancję "attach_distance_m" i "attach_angle_deg" – naczepa musi stać mniej więcej w linii).

var _machines: Dictionary = {}
var _save: Dictionary = {}
var _policy: Dictionary = {}
var _units: float = 40.0
var _links: Array[Dictionary] = []


func configure(machines: Dictionary, save_data: Dictionary,
		policy: Dictionary, units: float) -> void:
	_machines = machines
	_save = save_data
	_policy = policy
	_units = units


func toggle_for(parent: RigidBody2D) -> String:
	if bool(parent.get_meta("route_recording", false)) or str(parent.get_meta("route_mode", "")) == "playing":
		return "Zakończ nagrywanie/odtwarzanie przed zmianą zestawu."
	if str(parent.get_meta("route_mode", "")) == "held":
		parent.get_meta("route_system").release_hold(parent)
	for link in _links:
		if link["parent"] == parent:
			return _detach(link)

	var parent_model: Dictionary = parent.get_meta("definition")
	var best: Dictionary = {}
	var best_distance: float = INF
	for socket_value in parent_model["hitch_ports"]:
		var socket: Dictionary = socket_value
		if socket["role"] != "socket":
			continue
		for machine_value in _machines.values():
			var machine: Node2D = machine_value
			if machine == parent or _is_attached(machine):
				continue
			var model: Dictionary = machine.get_meta("definition")
			for plug_value in model["hitch_ports"]:
				var plug: Dictionary = plug_value
				if not _compatible(machine, socket, plug):
					continue
				var distance: float = _port_position(parent, socket).distance_to(
					_port_position(machine, plug)
				) / _units
				if distance < best_distance:
					best_distance = distance
					best = {"child": machine, "socket": socket, "plug": plug}
	if best.is_empty():
		return "Brak wolnego narzędzia pasującego do zaczepu tego pojazdu."
	var child: Node2D = best["child"]
	var socket: Dictionary = best["socket"]
	var plug: Dictionary = best["plug"]
	var allowed: float = _attach_distance(socket, plug)
	if best_distance > allowed:
		return "Zbliż zaczepy: %.2f m / wymagane %.2f m." % [best_distance, allowed]
	if socket.has("attach_angle_deg"):
		var difference: float = absf(rad_to_deg(angle_difference(parent.global_rotation, _port_body(child, plug).global_rotation)))
		if difference > float(socket["attach_angle_deg"]):
			return "Ustaw pojazd w linii z naczepą (różnica %.0f°, dozwolone %.0f°)." % [difference, float(socket["attach_angle_deg"])]
	var record: Dictionary = {
		"parent_instance_id": _instance_id(parent),
		"parent_port_id": socket["id"],
		"child_instance_id": _instance_id(child),
		"child_port_id": plug["id"]
	}
	_create_link(parent, child, socket, plug, record)
	var connections: Array = _save["connections"]
	connections.append(record)
	var model: Dictionary = child.get_meta("definition")
	return "Podpięto: %s. E odpina." % str(model["name"])


func restore_connections() -> bool:
	var connections: Array = _save["connections"]
	for record_value in connections:
		var record: Dictionary = record_value
		var parent: RigidBody2D = _machines.get(record.get("parent_instance_id")) as RigidBody2D
		var child: Node2D = _machines.get(record.get("child_instance_id")) as Node2D
		if parent == null or child == null or parent == child:
			return _restore_error("Niepoprawne maszyny zapisanej pary zaczepów.")
		var socket: Dictionary = _find_port(parent, str(record.get("parent_port_id", "")))
		var plug: Dictionary = _find_port(child, str(record.get("child_port_id", "")))
		if socket.is_empty() or plug.is_empty() or not _compatible(child, socket, plug):
			return _restore_error("Nieznane lub niezgodne porty zapisanej pary.")
		if _is_attached(child) or get_attached_machine(parent) != null:
			return _restore_error("Powtórzone użycie maszyny w połączeniach.")
		if _port_position(parent, socket).distance_to(_port_position(child, plug)) / _units > _attach_distance(socket, plug):
			return _restore_error("Zapisane maszyny są za daleko od siebie, aby odtworzyć zaczep.")
		_create_link(parent, child, socket, plug, record)
	return true


func _create_link(parent: RigidBody2D, child: Node2D,
		socket: Dictionary, plug: Dictionary, record: Dictionary) -> void:
	var joint: PinJoint2D = null
	if child.has_method("attach_to_carrier"):
		child.call("attach_to_carrier", parent, socket, plug)
	else:
		var shift: Vector2 = _port_position(parent, socket) - _port_position(child, plug)
		child.call("snap_by", shift)
		var child_body: RigidBody2D = _port_body(child, plug)
		joint = PinJoint2D.new()
		joint.name = "Hitch_" + str(record["child_instance_id"])
		joint.position = to_local(_port_position(parent, socket))
		joint.softness = 0.0
		var child_model: Dictionary = child.get_meta("definition")
		# Wyjątek dla wózka przyczepy zachowuje dotychczasowe zachowanie.
		# Korpus narzędzia jednoosiowego nadal może uderzyć w ciągnik.
		joint.disable_collision = (
			bool(_policy["disable_collision_between_connected_members"])
			and str(child_model["physics_kind"]) == "towed_turntable"
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
	_links.append({
		"parent": parent, "child": child, "joint": joint,
		"socket": socket, "plug": plug, "record": record
	})


func _detach(link: Dictionary) -> String:
	var child: Node2D = link["child"]
	if child.has_method("detach_from_carrier"):
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
	var model: Dictionary = child.get_meta("definition")
	return "Odpięto: %s." % str(model["name"])


## Odpina wszystkie połączenia maszyny (jako pojazdu i jako narzędzia), np. przed sprzedażą.
func detach_all(machine: Node) -> void:
	for link in _links.duplicate():
		if link["parent"] == machine or link["child"] == machine:
			_detach(link)


func get_attached_machine(parent: RigidBody2D) -> Node2D:
	for link in _links:
		if link["parent"] == parent:
			return link["child"] as Node2D
	return null


func get_diagnostics(parent: RigidBody2D) -> String:
	for link in _links:
		if link["parent"] == parent:
			var error_m: float = _port_position(parent, link["socket"]).distance_to(
				_port_position(link["child"], link["plug"])
			) / _units
			var kind: String = "sztywne" if link["joint"] == null else "obrotowe"
			return "Mocowanie: %s | rozbieżność zaczepów: %.3f m" % [kind, error_m]
	return "Zaczep aktywnego pojazdu: wolny."


func _compatible(child: Node2D, socket: Dictionary, plug: Dictionary) -> bool:
	if socket["role"] != "socket" or plug["role"] != "plug" or socket["type"] != plug["type"]:
		return false
	if socket["type"] == "drawbar" or socket["type"] == "fifth_wheel":
		return child.has_method("get_hitch_body") and child.has_method("snap_by") and child.has_method("set_attached")
	if socket["type"] == "combine_header" or socket["type"] == "three_point":
		return child.has_method("attach_to_carrier") and child.has_method("get_hitch_position")
	return false


## Dopuszczalna odległość zaczepów: zasada ogólna albo tolerancja portu (np. siodło).
func _attach_distance(socket: Dictionary, plug: Dictionary) -> float:
	return maxf(float(_policy["max_attach_distance_m"]), maxf(float(socket.get("attach_distance_m", 0.0)), float(plug.get("attach_distance_m", 0.0))))


func _is_attached(machine: Node) -> bool:
	for link in _links:
		if link["child"] == machine:
			return true
	return false


func _instance_id(machine: Node) -> String:
	var state: Dictionary = machine.get_meta("instance_state")
	return str(state["instance_id"])


func _find_port(machine: Node, port_id: String) -> Dictionary:
	var model: Dictionary = machine.get_meta("definition")
	for port_value in model["hitch_ports"]:
		var port: Dictionary = port_value
		if port["id"] == port_id:
			return port
	return {}


func _port_body(machine: Node, port: Dictionary) -> RigidBody2D:
	if machine.has_method("get_hitch_body"):
		return machine.call("get_hitch_body", port) as RigidBody2D
	return machine as RigidBody2D


func _port_position(machine: Node, port: Dictionary) -> Vector2:
	if machine.has_method("get_hitch_position"):
		return machine.call("get_hitch_position", port)
	var body: RigidBody2D = _port_body(machine, port)
	var position_m: Array = port["position_m"]
	return body.to_global(Vector2(float(position_m[0]), float(position_m[1])) * _units)


func _restore_error(message: String) -> bool:
	push_error(message)
	return false


func get_route_link(parent: RigidBody2D) -> Dictionary:
	for link in _links:
		if link["parent"] == parent:
			return link
	return {}
