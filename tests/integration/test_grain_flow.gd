extends "res://tests/framework/sim_harness.gd"
## Przepływ ziarna i materiałów: rura kombajnu, wywrotka nad kratą i skupem, załadunek z silosu,
## magazyn przy wiacie (zakup za pieniądze).


func _cargo(machine_node: Node2D) -> Dictionary:
	return Machines.state(machine_node)["storages"].values()[0]


func test_combine_pipe_fills_trailer_alongside() -> void:
	if not await build():
		return
	var combine: RigidBody2D = machine("combine_01")
	var trailer: Node2D = machine("trailer_01")
	place(combine, Vector2(180.0, 120.0), 90)
	var tank: Dictionary = Machines.state(combine)["storages"]["grain"]
	tank["material_id"] = "wheat_grain"
	tank["amount_l"] = 136.0
	var right := Vector2.RIGHT.rotated(combine.global_rotation)
	place_trailer(trailer, pos_m(combine) - right * 6.5, 90)
	await frames(60 * 14)
	assert_near(tank["amount_l"], 0.0, 0.001, "zbiornik kombajnu pusty")
	assert_near(_cargo(trailer)["amount_l"], 136.0, 0.001)
	var pipe: Node2D = combine.get_node("UnloadingPipe")
	assert_eq(pipe.flow_l_per_s, 0.0, "po opróżnieniu bez przepływu")


func test_tipper_dumps_into_silo_and_sells_at_buyer() -> void:
	if not await build():
		return
	var trailer: Node2D = machine("trailer_01")
	var silo: Dictionary = context.transfer.get_silo_state("silo_01")
	var before: float = float(silo["contents_l"].get("wheat_grain", 0.0))
	var cargo: Dictionary = _cargo(trailer)
	cargo["material_id"] = "wheat_grain"
	cargo["amount_l"] = 4000.0
	place_trailer(trailer, Vector2(36.0, 198.0 - 1.8), 0)
	await frames(60 * 6)
	assert_eq(silo["contents_l"]["wheat_grain"], before + 4000.0)
	assert_eq(cargo["amount_l"], 0.0)
	var money: float = context.economy.get_money()
	cargo["material_id"] = "barley_grain"
	cargo["amount_l"] = 2000.0
	place_trailer(trailer, Vector2(206.0, 246.0 - 1.8), 0)
	await frames(60 * 6)
	assert_near(context.economy.get_money() - money, 1200.0, 0.01, "2000 l × 0,60 zł")
	assert_eq(context.transfer.get_sell_points()[0]["sold_l"], 2000.0)


func test_conveyor_semitrailer_unloads_gradually() -> void:
	if not await build():
		return
	var semitrailer: Node2D = machine("semitrailer_02")
	var cargo: Dictionary = _cargo(semitrailer)
	cargo["material_id"] = "wheat_grain"
	cargo["amount_l"] = 30000.0
	context.transfer.get_silo_state("silo_01")["contents_l"].clear()
	place(semitrailer.body, Vector2(36.0, 198.0 - 6.4), 0)
	await frames(60 * 10)
	var left: float = float(cargo["amount_l"])
	assert_true(left > 0.0 and left < 30000.0, "taśmociąg rozładowuje stopniowo (zostało %.0f l)" % left)
	assert_true(float(Machines.state(semitrailer)["unloading_state"]["flow_l_per_s"]) > 0.0)


func test_silo_load_point_fills_trailer() -> void:
	if not await build():
		return
	var trailer: Node2D = machine("trailer_01")
	var silo: Dictionary = context.transfer.get_silo_state("silo_01")
	silo["contents_l"] = {"wheat_grain": 5000.0}
	place_trailer(trailer, Vector2(36.0, 216.0), 0)
	await frames(10)
	var offer: Dictionary = context.services.offer_for(trailer)
	assert_eq(offer.get("kind"), "load")
	assert_false(offer["options"][1]["enabled"], "jęczmienia brak w silosie")
	assert_has(actions.request_fill(offer["point_id"], "trailer_01", "wheat_grain"), "pszenica")
	await frames(60 * 8)
	assert_eq(_cargo(trailer)["amount_l"], 5000.0)
	assert_true(silo["contents_l"].is_empty())


func test_supply_point_sells_fertilizer_for_money() -> void:
	if not await build():
		return
	context.economy.earn(100000.0)
	assert_has(actions.buy_machine("spreader_basic"), "Kupiono")
	var spreader: Node2D = machine("spreader_01")
	var tractor: RigidBody2D = machine("tractor_02")
	await frames(5)
	align(tractor, "rear_three_point", spreader, "three_point")
	await frames(5)
	assert_has(context.hitches.toggle_for(tractor), "Podpięto: Rozsiewacz")
	place(tractor, Vector2(72.0, 202.5 - 3.0), 0)
	await frames(20)
	control(tractor)
	var offer: Dictionary = query.service_offer()
	assert_eq(query.purchase_label(offer), "Kup nawóz")
	var money: float = context.economy.get_money()
	actions.start_purchase(offer)
	await frames(60 * 6)
	var tank: Dictionary = Machines.state(spreader)["storages"]["fertilizer"]
	assert_eq(tank["amount_l"], 900.0)
	assert_near(money - context.economy.get_money(), 1080.0, 0.01, "900 l × 1,20 zł")
	assert_near(tractor.mass, 6350.0, 1.0, "nawóz na ciągniku")
	assert_eq(actions.cancel_fill("spreader_01"), "Przerwano napełnianie.")
