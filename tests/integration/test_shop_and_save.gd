extends "res://tests/framework/sim_harness.gd"
## Sklep (kupno, sprzedaż, plac), zapis gry → odczyt.

const SaveCodec = preload("res://scripts/data/save_codec.gd")


func test_buy_places_machine_on_lot_and_charges() -> void:
	if not await build():
		return
	var added: Array = []
	context.events.machine_added.connect(func(machine_node): added.append(machine_node))
	var money: float = context.economy.get_money()
	assert_has(actions.buy_machine("trailer_basic"), "Kupiono")
	assert_eq(context.economy.get_money(), money - 38000.0)
	var trailer: Node2D = machine("trailer_02")
	assert_true(trailer != null)
	assert_eq(added, [trailer], "widoki dowiadują się z EventBus")
	var lot: Dictionary = context.map_data()["shop"]["lot"]
	var area := Rect2(Vector2(lot["origin_m"][0], lot["origin_m"][1]), Vector2(lot["size_m"][0], lot["size_m"][1]))
	assert_true(area.has_point(Machines.pose_m(trailer, U).origin), "na placu sklepu")
	assert_has(actions.buy_machine("combine_basic"), "Za mało pieniędzy")
	assert_eq(actions.buy_machine("nope"), "Nieznana maszyna.")


func test_sell_rules() -> void:
	if not await build():
		return
	var money: float = context.economy.get_money()
	assert_has(actions.sell_machine("seeder_01"), "Sprzedano: Siewnik")
	assert_eq(context.economy.get_money(), money + 28800.0)
	assert_false(context.machines.has("seeder_01"))
	await frames(2)
	for id in ["tractor_02", "combine_01"]:
		assert_has(actions.sell_machine(id), "Sprzedano")
	assert_eq(query.sell_block_reason("truck_01"), "")
	assert_has(actions.sell_machine("tractor_01"), "Sprzedano")
	assert_eq(query.sell_block_reason("truck_01"), "To twój ostatni pojazd.")
	assert_eq(query.controlled_vehicle(), machine("truck_01"), "sterowanie przeszło na inny pojazd")


func test_save_and_load_roundtrip() -> void:
	if not await build():
		return
	var tractor: RigidBody2D = machine("tractor_02")
	var trailer: Node2D = machine("trailer_01")
	align(tractor, "rear_drawbar", trailer, "tow_eye")
	await frames(5)
	context.hitches.toggle_for(tractor)
	await drive(tractor, 15.0, 0.2, 240)
	await brake(tractor)
	context.field_work.fields[1].cultivate(5)
	context.economy.earn(123.0)
	context.routes.before_save()
	var saved: Dictionary = SaveCodec.new().capture(context.session, context.machines.by_id, context.field_work, U)
	var poses: Dictionary = {}
	for state in saved["machine_instances"]:
		poses[state["instance_id"]] = state["transform"]["position_m"]
	var money: float = context.economy.get_money()
	root.free()
	await frames(2)
	if not await build(saved):
		return
	assert_eq(context.economy.get_money(), money)
	assert_eq(context.save_data()["connections"].size(), 1, "zestaw odtworzony")
	assert_eq(context.hitches.get_attached_machine(machine("tractor_02")), machine("trailer_01"))
	assert_eq(context.field_work.fields[1].stage(5), 0)
	for id in poses:
		var now: Vector2 = Machines.pose_m(machine(id), U).origin
		assert_true(now.distance_to(Vector2(poses[id][0], poses[id][1])) < 0.2, id + " w zapisanym miejscu")
