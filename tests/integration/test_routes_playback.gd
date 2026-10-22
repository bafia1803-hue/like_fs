extends "res://tests/framework/sim_harness.gd"
## Trasy na fizyce: nagranie z pracą kultywatora (B) i odtworzenie, odwołanie przejazdu.


func _record(tractor: RigidBody2D, cultivator: Node2D) -> Dictionary:
	place(cultivator.body, Vector2(180, 130), 0)
	place(tractor, Vector2(180, 125.15), 0)
	await frames(5)
	assert_has(context.hitches.toggle_for(tractor), "Podpięto")
	control(tractor)
	actions.begin_recording()
	assert_false(context.routes.recording.is_empty(), "nagrywanie trwa")
	for t in 60 * 12:
		tractor.set_controls(clampf((8.0 - tractor.get_speed_kmh()) * 0.8, -1, 1), 0.4 if t > 60 * 4 and t < 60 * 8 else 0.0, false)
		if t == 60:
			actions.toggle_work()
		await tree.physics_frame
	await brake(tractor)
	actions.finish_recording("test")
	return context.routes.routes[-1]


func test_record_and_replay_with_tool_work() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var cultivator: Node2D = machine("cultivator_01")
	var route: Dictionary = await _record(tractor, cultivator)
	assert_eq(route["samples"].size(), 255)
	assert_near(route["samples"][-1][0], 12.38, 0.01)
	assert_eq(query.compatible_routes(tractor), [route])
	actions.toggle_work()
	await frames(60 * 5)
	assert_eq(Machines.fold_progress(cultivator), 0.0, "złożony przed odtworzeniem")
	var first: Array = route["samples"][0]
	place(cultivator.body, Vector2(first[1], first[2]) - Vector2.UP.rotated(first[3]) * 4.85, rad_to_deg(first[3]))
	place(tractor, Vector2(first[1], first[2]), rad_to_deg(first[3]))
	await frames(5)
	assert_eq(actions.request_route_start(route), "Uruchomiono trasę.")
	assert_eq(Machines.route_mode(tractor), "playing")
	var frame_count: int = 0
	while context.routes.tasks.has(tractor) and frame_count < 60 * 40:
		await tree.physics_frame
		frame_count += 1
	var last: Array = route["samples"][-1]
	assert_near(frame_count / 60.0, 13.03, 0.05)
	assert_near(pos_m(tractor).distance_to(Vector2(last[1], last[2])), 0.0, 0.01, "dojechał do końca")
	assert_eq(Machines.fold_progress(cultivator), 1.0, "kultywator rozłożony jak w nagraniu")
	assert_eq(Machines.route_mode(tractor), "held")
	context.routes.release_hold(tractor)
	assert_false(Machines.on_route(tractor))


func test_cancel_route_slows_down_and_stops() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var cultivator: Node2D = machine("cultivator_01")
	var route: Dictionary = await _record(tractor, cultivator)
	actions.toggle_work()
	await frames(60 * 5)
	var first: Array = route["samples"][0]
	place(cultivator.body, Vector2(first[1], first[2]) - Vector2.UP.rotated(first[3]) * 4.85, rad_to_deg(first[3]))
	place(tractor, Vector2(first[1], first[2]), rad_to_deg(first[3]))
	await frames(5)
	actions.request_route_start(route)
	await frames(60 * 5)
	assert_true(Machines.route_speed_m_s(tractor) > 1.0, "jedzie")
	actions.cancel_route()
	assert_true(context.routes.is_stopping(tractor))
	var frame_count: int = 0
	while context.routes.tasks.has(tractor) and frame_count < 600:
		await tree.physics_frame
		frame_count += 1
	assert_true(frame_count > 30 and frame_count < 200, "płynne hamowanie (%d klatek)" % frame_count)
	assert_eq(Machines.route_mode(tractor), "held")


func test_route_start_requires_start_position() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var cultivator: Node2D = machine("cultivator_01")
	var route: Dictionary = await _record(tractor, cultivator)
	assert_eq(actions.request_route_start(route), "Podjedź na miejsce startu")
	assert_false(context.routes.armed.is_empty(), "zestaw widmo czeka")
	assert_eq(actions.cancel_route(), "Przejazd odwołany.")
	assert_true(context.routes.armed.is_empty())
