extends "res://tests/framework/sim_harness.gd"
## Protokół maszyn, jazda i zaczepy wszystkich rodzajów.

const InstanceFactory = preload("res://scripts/core/shop/instance_factory.gd")


func test_every_catalog_model_satisfies_protocol() -> void:
	if not await build():
		return
	for model_id in context.models():
		var model: Dictionary = context.models()[model_id]
		var state: Dictionary = InstanceFactory.new_state(model, "probe_" + model_id, Vector2(0, 300), 0.0)
		var machine: Node2D = context.factory.create(state)
		if not assert_true(machine != null, model_id + ": " + context.factory.last_error):
			continue
		assert_true(Machines.missing_methods(machine).is_empty(), model_id)
		machine.free()
	for machine in context.machines.all():
		assert_true(Machines.pose_body(machine) != null, Machines.id(machine))


func test_tractor_accelerates_and_turns() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_01")
	await drive(tractor, 30.0, 0.3, 300)
	assert_near(tractor.get_speed_kmh(), 29.76, 0.05)
	assert_near(pos_m(tractor).x, 59.75, 0.05)
	assert_near(pos_m(tractor).y, 233.13, 0.05)


func test_trailer_drawbar_hitch_and_detach() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var trailer: Node2D = machine("trailer_01")
	align(tractor, "rear_drawbar", trailer, "tow_eye")
	await frames(5)
	control(tractor)
	assert_has(actions.toggle_attachment(), "Podpięto: Przyczepa")
	assert_eq(context.save_data()["connections"].size(), 1, "połączenie w zapisie")
	await drive(tractor, 20.0, 0.25, 360)
	assert_near(tractor.get_speed_kmh(), 19.80, 0.05)
	assert_near(pos_m(trailer.body).x, 50.43, 0.05)
	assert_true(trailer.attached)
	await brake(tractor)
	assert_has(actions.toggle_attachment(), "Odpięto")
	assert_eq(context.save_data()["connections"].size(), 0)
	assert_false(trailer.attached)


func test_hitch_rejects_far_tool() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_01")
	place(tractor, Vector2(36, 230), 0)
	await frames(3)
	assert_has(actions.toggle_attachment(), "Zbliż zaczepy")


func test_truck_fifth_wheel_needs_alignment() -> void:
	if not await build():
		return
	var truck: RigidBody2D = machine("truck_01")
	var semitrailer: Node2D = machine("semitrailer_02")
	place(semitrailer.body, Vector2(56.5, 37.3), 180)
	await frames(3)
	align(truck, "saddle", semitrailer, "kingpin")
	# Obrót o 45° wokół siodła: odległość zaczepów bez zmian, kąt za duży.
	var saddle: Vector2 = context.hitches.port_position(truck, port(truck, "saddle")) / U
	var rotation: float = truck.global_rotation + deg_to_rad(45.0)
	place(truck, saddle - Vector2(0.0, 2.05).rotated(rotation), rad_to_deg(rotation))
	assert_has(context.hitches.toggle_for(truck), "Ustaw pojazd w linii")
	align(truck, "saddle", semitrailer, "kingpin")
	await frames(20)
	assert_has(context.hitches.toggle_for(truck), "Podpięto: Naczepa")
	assert_near(truck.get("_coupled_load_kg"), 3502.0, 2.0, "nacisk na siodło")
	await drive(truck, 40.0, 0.0, 600)
	assert_near(truck.get_speed_kmh(), 39.89, 0.1)
	assert_true(pos_m(truck).distance_to(pos_m(semitrailer.body)) < 9.0, "naczepa jedzie za tirem")


func test_mounted_header_and_three_point() -> void:
	if not await build():
		return
	var combine: RigidBody2D = machine("combine_01")
	var header: Node2D = machine("header_01")
	var mass_before: float = combine.mass
	align(combine, "front_header", header, "rear_mount")
	await frames(5)
	assert_has(context.hitches.toggle_for(combine), "Podpięto: Heder")
	assert_true(Machines.is_attached(header))
	assert_true(combine.mass > mass_before, "masa hedera na kombajnie")
	assert_eq(Machines.motion_body(header), combine)
	assert_has(context.hitches.toggle_for(combine), "Odpięto")
	assert_near(combine.mass, mass_before, 0.01)
	await frames(2)
	assert_false(Machines.is_attached(header))
	assert_true(Machines.pose_body(header) != header, "odłożony heder ma bryłę na ziemi")

