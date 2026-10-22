extends "res://tests/framework/sim_harness.gd"
## Praca na polu na prawdziwej fizyce: kultywacja, siew, nawożenie, zbiór, cudze pole, sen.

const Stage = preload("res://scripts/core/field/field_cells.gd").Stage


func _field(index: int) -> Node2D:
	return query.field_grids()[index]


func _attach(vehicle: RigidBody2D, socket: String, tool: Node2D, plug: String) -> void:
	align(vehicle, socket, tool, plug)
	await frames(5)
	assert_has(context.hitches.toggle_for(vehicle), "Podpięto")


func test_cultivator_unfolds_and_cultivates() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var cultivator: Node2D = machine("cultivator_01")
	place(cultivator.body, Vector2(96.0, 160.0), 90)
	await frames(3)
	await _attach(tractor, "rear_drawbar", cultivator, "tow_eye")
	assert_empty(context.field_work.toggle_work(tractor), "rozkładanie – komunikat przyjdzie później")
	await frames(60 * 5)
	assert_eq(Machines.fold_progress(cultivator), 1.0)
	assert_true(Machines.is_working(cultivator))
	assert_eq(context.field_work.get_speed_cap_kmh(cultivator), 18.0)
	await drive(tractor, 12.0, 0.0, 600)
	await brake(tractor)
	assert_eq(_field(1).cells.count_stage(Stage.PLAIN), 3680)
	assert_has(context.field_work.toggle_work(tractor), "podnoszenie i składanie")


func test_header_harvests_into_tank() -> void:
	if not await build():
		return
	var combine: RigidBody2D = machine("combine_01")
	var header: Node2D = machine("header_01")
	place(Machines.pose_body(header), Vector2(96.0, 200.0), 90)
	await frames(3)
	await _attach(combine, "front_header", header, "rear_mount")
	assert_has(context.field_work.toggle_work(combine), "Heder opuszczony")
	await drive(combine, 8.0, 0.0, 720)
	await brake(combine)
	var tank: Dictionary = Machines.state(combine)["storages"]["grain"]
	assert_eq(tank["material_id"], "wheat_grain")
	assert_near(tank["amount_l"], 136.0, 0.01)
	assert_eq(_field(1).cells.count_stage(Stage.HARVESTED), 2720)


func test_seeder_sows_selected_crop() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var seeder: Node2D = machine("seeder_01")
	var grid: Node2D = _field(1)
	for index in grid.cells.size():
		grid.cultivate(index)
	var tank: Dictionary = Machines.state(seeder)["storages"].values()[0]
	tank["material_id"] = "seed"
	tank["amount_l"] = 100.0
	place(seeder.body, Vector2(110.0, 160.0), 90)
	await frames(3)
	await _attach(tractor, "rear_drawbar", seeder, "tow_eye")
	control(tractor)
	assert_eq(actions.cycle_seed_crop(), "barley")
	actions.toggle_work()
	await drive(tractor, 10.0, 0.0, 300)
	await brake(tractor)
	var sown: int = grid.cells.count_stage(Stage.SOWN)
	assert_true(sown > 1000, "zasiano %d komórek" % sown)
	assert_true(float(tank["amount_l"]) < 100.0, "zużyto ziarno")
	var barley: int = 0
	for index in grid.cells.size():
		if grid.cells.stage(index) == Stage.SOWN and grid.cells.crop_at(index) == "barley":
			barley += 1
	assert_eq(barley, sown, "wszystko jęczmieniem")
	assert_eq(actions.grow_crops(), sown, "sen: wszystko urosło")
	assert_eq(grid.cells.count_stage(Stage.LIGHT), sown)


func test_foreign_field_is_not_worked_until_bought() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var cultivator: Node2D = machine("cultivator_01")
	place(cultivator.body, Vector2(96.0, 60.0), 90)
	await frames(3)
	await _attach(tractor, "rear_drawbar", cultivator, "tow_eye")
	control(tractor)
	context.field_work.toggle_work(tractor)
	await frames(60 * 5)
	_field(0).fill_strips(["wheat"], Stage.READY)
	await drive(tractor, 12.0, 0.0, 240)
	await brake(tractor)
	assert_eq(_field(0).cells.count_stage(Stage.PLAIN), 0, "cudze pole nietknięte")
	assert_true(notices.size() > 0 and notices[-1].contains("nie jest twoje"), str(notices))
	var offer: Dictionary = query.field_offer()
	assert_eq(offer["id"], "field_01")
	context.economy.earn(100000.0)
	assert_has(actions.buy_field("field_01"), "Kupiono pole")
	assert_true(_field(0).owned)
	assert_true(context.save_data()["owned_fields"].has("field_01"))
	await drive(tractor, 12.0, 0.0, 240)
	assert_true(_field(0).cells.count_stage(Stage.PLAIN) > 0, "teraz kultywuje")
