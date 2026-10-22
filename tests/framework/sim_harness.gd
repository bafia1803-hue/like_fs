extends "res://tests/framework/test_case.gd"
## Testy integracyjne symulacji: buduje samą warstwę gry (SimulationBuilder) bez widoków i HUD,
## na prawdziwej fizyce Rapier2D, z danymi z res://files. Pomocnicze ustawianie i jazda maszyn.

const SimulationBuilder = preload("res://scripts/sim/simulation_builder.gd")
const WorldQuery = preload("res://scripts/sim/world_query.gd")
const GameActions = preload("res://scripts/sim/game_actions.gd")
const Levels = preload("res://scripts/sim/machines/collision_levels.gd")
const Machines = preload("res://scripts/sim/machines/machines.gd")
const U: float = 40.0

var context: RefCounted
var query: RefCounted
var actions: RefCounted
var root: Node2D
var notices: PackedStringArray = []


## Nowa symulacja (pusty saved_game = nowa gra z szablonu). Gracz nie steruje klawiaturą.
func build(saved_game: Dictionary = {}) -> bool:
	root = Node2D.new()
	root.name = "Simulation"
	tree.root.add_child(root)
	var builder = SimulationBuilder.new()
	context = builder.build(root, saved_game)
	if context == null:
		fail("Symulacja się nie zbudowała: " + builder.last_error)
		return false
	query = WorldQuery.new(context)
	actions = GameActions.new(context)
	context.player.driver.set_physics_process(false)
	context.events.notice.connect(func(text: String): notices.append(text))
	await frames(3)
	return true


func after_each() -> void:
	if is_instance_valid(root):
		root.free()
	context = null
	query = null
	actions = null
	await frames(2)


func machine(id: String) -> Node2D:
	return context.machines.get_machine(id)


## Przełącza sterowanie gracza (TAB) na wskazany pojazd.
func control(vehicle: RigidBody2D) -> void:
	for i in context.machines.vehicles.size():
		if context.player.controlled == vehicle:
			return
		context.player.switch_vehicle(1)
	fail("Nie można przełączyć na pojazd " + Machines.id(vehicle))


func place(body: Node2D, pos_m: Vector2, rot_deg: float) -> void:
	body.global_position = pos_m * U
	body.global_rotation = deg_to_rad(rot_deg)
	if body is RigidBody2D:
		PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, body.global_transform)
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		Levels.sync(body)


## Przyczepa z wózkiem skrętnym: nadwozie i wózek razem (bez szarpnięcia obrotnicy).
func place_trailer(trailer: Node2D, pos_m: Vector2, rot_deg: float) -> void:
	var pivot: Array = Machines.model(trailer)["front_carriage"]["pivot_in_body_m"]
	place(trailer.body, pos_m, rot_deg)
	place(trailer.carriage, pos_m + Vector2(pivot[0], pivot[1]).rotated(deg_to_rad(rot_deg)), rot_deg)


func port(machine_node: Node, port_id: String) -> Dictionary:
	for item in Machines.model(machine_node)["hitch_ports"]:
		if item["id"] == port_id:
			return item
	return {}


## Ustawia pojazd tak, by jego gniazdo socket_id trafiło w zaczep plug_id narzędzia.
func align(vehicle: RigidBody2D, socket_id: String, tool: Node2D, plug_id: String) -> void:
	var plug: Dictionary = port(tool, plug_id)
	var socket: Dictionary = port(vehicle, socket_id)
	var rotation: float = tool.get_hitch_body(plug).global_rotation if tool.has_method("get_hitch_body") else Machines.pose_body(tool).global_rotation
	var target: Vector2 = context.hitches.port_position(tool, plug) / U
	var local := Vector2(float(socket["position_m"][0]), float(socket["position_m"][1]))
	place(vehicle, target - local.rotated(rotation), rad_to_deg(rotation))


## Jazda z prostym regulatorem prędkości przez podaną liczbę klatek fizyki.
func drive(vehicle: RigidBody2D, kmh: float, steer: float, frame_count: int) -> void:
	for i in frame_count:
		vehicle.set_controls(clampf((kmh - vehicle.get_speed_kmh()) * 0.8, -1.0, 1.0), steer, false)
		await tree.physics_frame


func brake(vehicle: RigidBody2D) -> void:
	var count: int = 0
	while absf(vehicle.get_speed_kmh()) > 0.05 and count < 600:
		vehicle.set_controls(0, 0, true)
		await tree.physics_frame
		count += 1
	vehicle.set_controls(0, 0, true)


func pos_m(node: Node2D) -> Vector2:
	return node.global_position / U
