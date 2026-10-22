extends "res://tests/framework/test_case.gd"

const StorageRules = preload("res://scripts/core/storage/storage_rules.gd")
const UnloadRules = preload("res://scripts/core/transfer/unload_rules.gd")
const PipeMotion = preload("res://scripts/core/transfer/pipe_motion.gd")
const FillRules = preload("res://scripts/core/services/fill_rules.gd")

const BOX := {"id": "cargo", "capacity_l": 1000.0, "accepted_material_ids": ["wheat_grain", "barley_grain"]}


func test_space_does_not_mix_materials() -> void:
	assert_eq(StorageRules.space_for({"amount_l": 0.0}, BOX, "wheat_grain"), 1000.0)
	assert_eq(StorageRules.space_for({"amount_l": 300.0, "material_id": "wheat_grain"}, BOX, "wheat_grain"), 700.0)
	assert_eq(StorageRules.space_for({"amount_l": 300.0, "material_id": "wheat_grain"}, BOX, "barley_grain"), 0.0)
	assert_eq(StorageRules.space_for({"amount_l": 0.0}, BOX, "seed"), 0.0, "nieprzyjmowany materiał")


func test_transfer_moves_exact_amount() -> void:
	var source := {"amount_l": 400.0, "material_id": "wheat_grain"}
	var target := {"amount_l": 800.0, "material_id": "wheat_grain"}
	assert_eq(StorageRules.transfer(source, target, BOX, 1000.0), 200.0, "do pełna")
	assert_eq([source["amount_l"], target["amount_l"]], [200.0, 1000.0])
	assert_eq(StorageRules.transfer(source, target, BOX, 10.0), 0.0)


func test_transfer_empties_source_and_fills_silo() -> void:
	var silo_def := {"capacity_l": 500.0, "accepted_material_ids": ["wheat_grain", "barley_grain"]}
	var silo := {"contents_l": {"barley_grain": 100.0}}
	var source := {"amount_l": 50.0, "material_id": "wheat_grain"}
	assert_eq(StorageRules.transfer(source, silo, silo_def, INF, true), 50.0)
	assert_eq(source["material_id"], null)
	assert_eq(StorageRules.silo_total(silo), 150.0, "silos trzyma kilka gatunków")


func test_rectangle_corners() -> void:
	var points: PackedVector2Array = StorageRules.rectangle(Transform2D.IDENTITY,
		{"center_m": [1.0, 0.0], "width_m": 2.0, "length_m": 4.0}, 10.0)
	assert_eq(points[0], Vector2(0, -20))
	assert_eq(points[2], Vector2(20, 20))


func test_unload_delay_counts_down_per_zone() -> void:
	var state := {}
	assert_eq(UnloadRules.delay_step(state, "silo", 1.0, 0.6), 0.0)
	assert_near(UnloadRules.delay_step(state, "silo", 1.0, 0.6), 0.2)
	assert_near(UnloadRules.delay_step(state, "silo", 1.0, 0.5), 0.5)
	assert_eq(UnloadRules.delay_step(state, "buyer", 1.0, 0.5), 0.0, "nowe miejsce – odliczanie od nowa")
	UnloadRules.leave_zone(state)
	assert_eq(state["zone_id"], "")


func test_unload_limits_and_status() -> void:
	assert_eq(UnloadRules.limit_l("tipper", 100.0, 0.5), INF)
	assert_eq(UnloadRules.limit_l("conveyor", 100.0, 0.5), 50.0)
	assert_eq(UnloadRules.status("tipper", "sell", 300.0, 0.1), "Sprzedano 300 l")
	assert_eq(UnloadRules.status("conveyor", "silo", 100.0, 0.1), "Rozładunek: 1000 l/s")
	assert_has(UnloadRules.status("conveyor", "silo", 0.0, 0.1), "Silos pełny")


func test_pipe_opens_holds_and_closes() -> void:
	var motion = PipeMotion.new()
	motion.setup({"extend_seconds": 2.0, "retract_seconds": 1.0, "close_delay_seconds": 0.5}, {})
	assert_eq(motion.advance(true, 1.0), 0.0)
	assert_near(motion.extension, 0.5)
	assert_near(motion.advance(true, 1.5), 0.5, 0.0001, "pół sekundy już otwarta")
	assert_near(motion.advance(false, 0.3), 0.3, 0.0001, "zwłoka przed złożeniem")
	assert_near(motion.advance(false, 0.4), 0.2)
	assert_near(motion.extension, 0.8)
	var saved := {}
	motion.write(saved)
	assert_near(saved["extension"], 0.8)


func test_fill_option_and_purchase() -> void:
	var storage := {"amount_l": 10.0, "material_id": "barley_grain"}
	var blocked: Dictionary = FillRules.option_state(storage, BOX, "wheat_grain", "Jęczmień")
	assert_false(blocked["enabled"])
	assert_eq(blocked["reason"], "w środku jest jęczmień")
	assert_eq(FillRules.option_state({"amount_l": 1000.0, "material_id": "wheat_grain"}, BOX, "wheat_grain", "")["reason"], "pełne")
	assert_true(FillRules.option_state({"amount_l": 0.0}, BOX, "wheat_grain", "")["enabled"])
	assert_near(FillRules.purchase_amount(1000.0, 0.1, 500.0, 1000000.0, 2.0), 100.0)
	assert_near(FillRules.purchase_amount(1000.0, 0.1, 50.0, 1000000.0, 2.0), 50.0)
	assert_near(FillRules.purchase_amount(1000.0, 0.1, 500.0, 3.0, 2.0), 1.5, 0.0001, "brakuje pieniędzy")
	assert_eq(FillRules.purchase_label("fertilizer"), "Kup nawóz")
	assert_eq(FillRules.purchase_label("seed"), "Kup ziarno")
