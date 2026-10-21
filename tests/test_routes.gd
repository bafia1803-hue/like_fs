extends SceneTree
const World = preload("res://scripts/world.gd")
const Data = preload("res://scripts/route_data.gd")
const Rig = preload("res://scripts/route_rig.gd")
const Collision = preload("res://scripts/route_collision.gd")
var checks: int = 0
var failures: int = 0
var messages: Array[String] = []

func _initialize() -> void:
	call_deferred("run")

func check(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error("FAIL: " + label)

func sync_body(body: RigidBody2D, position: Vector2) -> void:
	body.global_position = position
	PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, body.global_transform)
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0

func freeze_tree(node: Node) -> void:
	if node is RigidBody2D:
		node.freeze = true
	for child in node.get_children():
		freeze_tree(child)

func route_for(system: Node, vehicle: RigidBody2D, samples: Array) -> Dictionary:
	return {"version": 1, "id": str(Time.get_ticks_usec()), "name": "Test", "map_id": system._map_id,
		"signature": system.rig_for(vehicle).signature(), "samples": samples}

func run() -> void:
	var world = World.new()
	root.add_child(world)
	await process_frame
	if not world._world_loaded:
		push_error("Świat testowy nie został uruchomiony.")
		quit(1)
		return
	freeze_tree(world)
	world._driver.set_physics_process(false)
	world._field_work.set_physics_process(false)
	var system = world._routes
	system.set_physics_process(false)
	system.message.connect(func(text: String): messages.append(text))
	var vehicle: RigidBody2D = world.machines_by_id["tractor_01"]
	var combine: RigidBody2D = world.machines_by_id["combine_01"]
	sync_body(vehicle, Vector2(35,55) * 40)
	system.begin_recording(vehicle, "Z postojem")
	check(not system.recording.is_empty(), "Nagrywanie od postoju")
	for i in range(12):
		vehicle.linear_velocity = Vector2(40,0)
		sync_body(vehicle, Vector2(35.0 + (i+1) / 60.0,55) * 40)
		vehicle.linear_velocity = Vector2(40,0)
		system._physics_process(1.0 / 60.0)
	vehicle.linear_velocity = Vector2.ZERO
	for i in range(30):
		system._physics_process(1.0 / 60.0)
	system.finish_recording()
	var recorded: Dictionary = system.routes[-1]
	check(Data.valid(recorded), "Format nagrania")
	check(is_equal_approx(float(recorded["samples"][-1][0]), 0.7), "Nagranie zachowuje czas postoju")
	check(recorded["samples"].size() >= 12 and recorded["samples"].size() < 30, "Próbki około 20 Hz plus granice postoju")
	var serialized: Variant = JSON.parse_string(JSON.stringify(recorded))
	check(Data.valid(serialized), "Trasa po JSON roundtrip")
	check(system.compatible(vehicle).size() == 1 and system.compatible(combine).is_empty(), "Filtrowanie modelu")
	var route: Dictionary = route_for(system, vehicle, [[0.0,35.0,55.0,0.0,0.0,0.0],[1.0,35.0,54.0,0.0,0.0,0.0],[2.0,35.0,54.0,0.0,0.0,0.0],[3.0,35.0,53.0,0.0,0.0,0.0]])
	sync_body(vehicle, Vector2(35,55)*40)
	system.start(vehicle, route)
	check(system.tasks.has(vehicle), "Start odtwarzania")
	system._physics_process(0.025)
	check(vehicle.position.distance_to(Vector2(35,54.975)*40) < 0.001, "Pozycja pośrednia przy 40 Hz, bez skoku do próbki")
	for i in range(39):
		system._physics_process(0.025)
	var pause_position: Vector2 = vehicle.position
	system._physics_process(0.5)
	check(vehicle.position.distance_to(pause_position) < 0.001, "Postój odtwarzany")
	system.stop(vehicle)
	check(not system.tasks.has(vehicle) and vehicle.freeze and vehicle.linear_velocity == Vector2.ZERO, "Ręczne przerwanie i blokada postoju")
	system.release_hold(vehicle)
	check(not vehicle.has_meta("route_mode"), "Powrót do sterowania ręcznego")
	# Kolizja z cienką przeszkodą po drodze, a nie tylko w pozycji końcowej.
	sync_body(vehicle, Vector2(10,10)*40)
	var wall := StaticBody2D.new()
	var collider := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = Vector2(0.01,10)*40
	collider.shape = shape
	wall.add_child(collider)
	wall.position = Vector2(12,10)*40
	root.add_child(wall)
	await physics_frame
	await process_frame
	var fast: Dictionary = route_for(system, vehicle, [[0.0,10.0,10.0,0.0,0.0,0.0],[0.1,14.0,10.0,0.0,0.0,0.0]])
	system.start(vehicle, fast)
	check(system.tasks.has(vehicle), "Wolny start przed ścianą")
	system._physics_process(0.1)
	check(system.tasks.has(vehicle) and system.tasks[vehicle]["paused"] and vehicle.position.is_equal_approx(Vector2(10,10)*40), "Cienka ściana pauzuje cały ruch")
	var paused_time: float = system.tasks[vehicle]["time"]
	system._physics_process(0.1)
	check(system.tasks[vehicle]["time"] == paused_time and vehicle.linear_velocity == Vector2.ZERO, "Zegar trasy i prędkość zatrzymane na pauzie")
	# Bezpieczny odstęp od granicy całego następnego ruchu, nie tylko od środka pojazdu.
	wall.position = Vector2(15.3,10)*40
	PhysicsServer2D.body_set_state(wall.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, wall.global_transform)
	await physics_frame
	await process_frame
	system._physics_process(0.1)
	check(system.tasks[vehicle]["paused"] and system.tasks[vehicle]["clear_time"] == 0.0, "Zbyt mały odstęp nie wznawia trasy")
	wall.position = Vector2(17,10)*40
	PhysicsServer2D.body_set_state(wall.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, wall.global_transform)
	await physics_frame
	await process_frame
	system.settings["resume_clear_seconds"] = 0.2
	system._physics_process(0.1)
	check(system.tasks[vehicle]["paused"] and system.tasks[vehicle]["time"] == paused_time, "Oczekiwanie przez czas bezpieczeństwa")
	system._physics_process(0.1)
	check(not system.tasks.has(vehicle) and vehicle.position.is_equal_approx(Vector2(14,10)*40), "Automatyczne wznowienie i zakończenie bez przeskoku zegara")
	system.release_hold(vehicle)
	wall.free()
	# Ustawienie na starcie nie może teleportować w przeszkodę.
	var obstacle := StaticBody2D.new()
	var blocker := CollisionShape2D.new()
	blocker.shape = shape
	obstacle.add_child(blocker)
	obstacle.position = Vector2(10,10)*40
	root.add_child(obstacle)
	await physics_frame
	await process_frame
	system.start(vehicle, fast)
	check(not system.tasks.has(vehicle), "Zajęte miejsce startu odrzucane")
	obstacle.free()
	# Dwa zadania działają niezależnie, zapis zatrzymuje oba i odrzuca nagrywanie.
	sync_body(vehicle, Vector2(35,55)*40)
	sync_body(combine, Vector2(60,55)*40)
	var combine_route: Dictionary = route_for(system, combine, [[0.0,60.0,55.0,0.0,0.0,0.0],[1.0,60.0,54.0,0.0,0.0,0.0]])
	system.start(vehicle, route)
	system.start(combine, combine_route)
	check(system.tasks.size() == 2, "Dwa aktywne zadania")
	system._physics_process(0.05)
	check(vehicle.position.y < 55*40 and combine.position.y < 55*40, "Oba zestawy wykonują ruch")
	var snapshot: Dictionary = world.capture_save()
	check(system.tasks.is_empty() and not snapshot.has("active_routes"), "Zapis przerywa zadania")
	check(snapshot["recorded_routes"].size() == 1, "Zapis zawiera tylko ukończone trasy")
	system.begin_recording(vehicle, "Niedokończona")
	system._physics_process(0.1)
	snapshot = world.capture_save()
	check(system.recording.is_empty() and snapshot["recorded_routes"].size() == 1, "Zapis odrzuca bieżące nagranie")
	# Zderzenie dwóch planów w tym samym kroku zatrzymuje obie maszyny.
	system.release_hold(combine)
	sync_body(vehicle, Vector2(10,20)*40)
	sync_body(combine, Vector2(15,15)*40)
	system.settings["max_collision_steps_per_tick"] = 256
	var cross_a: Dictionary = route_for(system, vehicle, [[0.0,10.0,20.0,0.0,0.0,0.0],[1.0,20.0,20.0,0.0,0.0,0.0]])
	var cross_b: Dictionary = route_for(system, combine, [[0.0,15.0,15.0,0.0,0.0,0.0],[1.0,15.0,25.0,0.0,0.0,0.0]])
	system.start(vehicle, cross_a)
	system.start(combine, cross_b)
	check(system.tasks.size() == 2, "Start przecinających się tras")
	system._physics_process(1.0)
	check(system.tasks.size() == 2 and system.tasks[vehicle]["paused"] and system.tasks[combine]["paused"], "Kolizja planów pauzuje obie maszyny")
	var paused_snapshot: Dictionary = world.capture_save()
	check(system.tasks.is_empty() and not paused_snapshot.has("active_routes"), "Zapis przerywa również zadania na pauzie")
	# UI i edycja ukończonych tras.
	var panel: Node = null
	for child in world.get_node("Interface").get_children():
		if child.get_script() == preload("res://scripts/route_panel.gd"):
			panel = child
	check(panel != null and not panel.visible and system._selected.is_empty(), "Panel i podgląd domyślnie ukryte")
	panel.set_panel_open(true)
	check(panel.visible and system._selected.is_empty(), "Otwarcie panelu nie pokazuje trasy")
	panel._preview.button_pressed = true
	check(not system._selected.is_empty(), "Podgląd na wyraźne żądanie")
	panel._name.grab_focus()
	await process_frame
	check(root.gui_get_focus_owner() == panel._name, "Pole nazwy przyjmuje fokus")
	var click := InputEventMouseButton.new()
	click.pressed = true
	click.button_index = MOUSE_BUTTON_LEFT
	click.position = Vector2(900,300)
	panel._input(click)
	check(root.gui_get_focus_owner() != panel._name, "Kliknięcie poza polem oddaje sterowanie")
	panel._name.grab_focus()
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	panel._input(escape)
	check(root.gui_get_focus_owner() != panel._name, "Escape kończy edycję")
	panel.set_panel_open(false)
	check(not panel.visible and system._selected.is_empty() and not panel._preview.button_pressed, "Zamknięcie panelu ukrywa podgląd")
	var recorded_id: String = recorded["id"]
	system.rename_route(recorded_id, "  Nowa nazwa  ")
	check(recorded["name"] == "Nowa nazwa" and world.session["save_data"]["recorded_routes"][0]["name"] == "Nowa nazwa", "Zmiana nazwy jest częścią danych zapisu")
	system.rename_route(recorded_id, "   ")
	check(recorded["name"] == "Nowa nazwa", "Pusta nazwa odrzucana")
	# Dokładne więzy zaczepów przy skręconej przyczepie.
	system.release_hold(vehicle)
	system.release_hold(combine)
	var trailer: Node2D = world.machines_by_id["trailer_01"]
	var hitches = world._hitches
	var socket: Dictionary = vehicle.get_meta("definition")["hitch_ports"][0]
	var plug: Dictionary = trailer.get_meta("definition")["hitch_ports"][0]
	hitches._create_link(vehicle, trailer, socket, plug, {"parent_instance_id":"tractor_01","child_instance_id":"trailer_01","parent_port_id":socket["id"],"child_port_id":plug["id"]})
	var rig = system.rig_for(vehicle)
	var point: Array = [0.0,35.0,55.0,0.5,-0.2,0.3]
	rig.lock()
	rig.apply(point)
	check(hitches._port_position(vehicle,socket).distance_to(hitches._port_position(trailer,plug)) < 0.001, "Zaczepy pozostają połączone")
	var pivot: Array = trailer.definition["front_carriage"]["pivot_in_body_m"]
	check(trailer.body.to_global(Vector2(pivot[0],pivot[1])*40).distance_to(trailer.carriage.global_position) < 0.001, "Obrotnica pozostaje połączona")
	check(system.compatible(vehicle).is_empty(), "Inne narzędzie filtruje listę tras")
	rig.unlock()
	vehicle.freeze = false
	trailer.body.freeze = false
	trailer.carriage.freeze = false
	await physics_frame
	await physics_frame
	await process_frame
	check(hitches._port_position(vehicle,socket).distance_to(hitches._port_position(trailer,plug)) < 1.0, "Po powrocie do fizyki zaczepy nie rozrywają zestawu")
	vehicle.freeze = true
	trailer.body.freeze = true
	trailer.carriage.freeze = true
	hitches.toggle_for(vehicle)
	# Ten sam model, inny egzemplarz: sygnatura nie zawiera instance_id.
	var old_id: String = vehicle.get_meta("instance_state")["instance_id"]
	vehicle.get_meta("instance_state")["instance_id"] = "tractor_copy"
	check(system.compatible(vehicle).size() == 1, "Trasa pasuje do innego egzemplarza tego samego modelu")
	vehicle.get_meta("instance_state")["instance_id"] = old_id
	var seeder: Node2D = world.machines_by_id["seeder_01"]
	plug = seeder.get_meta("definition")["hitch_ports"][0]
	sync_body(vehicle, Vector2(105,80)*40)
	hitches._create_link(vehicle,seeder,socket,plug,{"parent_instance_id":"tractor_01","child_instance_id":"seeder_01","parent_port_id":socket["id"],"child_port_id":plug["id"]})
	var seed_route: Dictionary = route_for(system,vehicle,[[0.0,105.0,80.0,0.0,0.0,0.0],[0.1,105.0,77.0,0.0,0.0,0.0]])
	var initial_seed: float = seeder.instance_state["storages"]["seed"]["amount_l"]
	system.start(vehicle, seed_route)
	check(system.tasks.has(vehicle), "Odtwarzanie z siewnikiem")
	var initial_work_y: float = seeder.body.position.y / 40.0 + 0.7
	system._physics_process(0.1)
	var grid = world._field_work.fields[0]
	var continuous: bool = true
	var column: int = int((105.0-90.0)/0.5)
	for row in range(ceili((initial_work_y-3.0-40.0)/0.5), floori((initial_work_y-40.0)/0.5)):
		if grid.states[row*grid.columns+column] != 1:
			continuous = false
	check(continuous, "Siewnik nie pomija komórek pomiędzy odległymi próbkami")
	check(float(seeder.instance_state["storages"]["seed"]["amount_l"]) < initial_seed, "Rzeczywiste zużycie nasion podczas odtwarzania")
	system.release_hold(vehicle)
	# Cofanie siewnikiem nadal wykonuje pracę.
	var reverse_route: Dictionary = route_for(system,vehicle,[[0.0,105.0,77.0,0.0,0.0,0.0],[0.1,105.0,83.0,0.0,0.0,0.0]])
	var before_reverse: float = seeder.instance_state["storages"]["seed"]["amount_l"]
	system.start(vehicle,reverse_route)
	system._physics_process(0.1)
	check(float(seeder.instance_state["storages"]["seed"]["amount_l"]) < before_reverse, "Siew podczas cofania")
	# Zwolnienie blokady przywraca faktyczny tryb dynamiczny.
	system.release_hold(vehicle)
	vehicle.freeze = false
	var dynamic_rig = system.rig_for(vehicle)
	dynamic_rig.lock()
	dynamic_rig.apply(dynamic_rig.sample(0.0))
	dynamic_rig.unlock()
	check(not vehicle.freeze and vehicle.linear_velocity == Vector2.ZERO, "Powrót do dynamicznego ciała z zerową prędkością")
	system.delete_route(recorded_id)
	check(system.routes.is_empty() and world.session["save_data"]["recorded_routes"].is_empty(), "Usuwanie aktualizuje dane slotu")
	world.free()
	print("ROUTES: %d checks, %d failures" % [checks,failures])
	quit(1 if failures else 0)
