extends "res://tests/framework/test_case.gd"

const Rules = preload("res://scripts/core/field/field_work_rules.gd")
const Stage = preload("res://scripts/core/field/field_cells.gd").Stage

const SEEDER := {"name": "Siewnik", "work": {"operation": "sow", "max_working_speed_kmh": 18.0,
	"sowable_crop_ids": ["wheat", "barley", "oats"]}}
const HEADER_WORK := {"operation": "harvest", "allowed_crop_ids": ["wheat", "barley"],
	"crop_to_material_id": {"wheat": "wheat_grain", "barley": "barley_grain"}}
const SETTINGS := {"yield_l_per_m2": {"wheat": 0.8, "barley": 0.7}, "fertilizer_yield_bonus": [0.0, 0.15, 0.35]}
const TANK := {"capacity_l": 100.0, "accepted_material_ids": ["wheat_grain", "barley_grain"]}


func test_is_working_needs_both_flags() -> void:
	assert_true(Rules.is_working({"work_state": {"enabled": true, "lowered": true}}))
	assert_false(Rules.is_working({"work_state": {"enabled": true, "lowered": false}}))
	assert_false(Rules.is_working({"work_state": null}))
	assert_false(Rules.is_working({}))


func test_speed_cap() -> void:
	assert_eq(Rules.speed_cap_kmh(SEEDER, true), 18.0)
	assert_eq(Rules.speed_cap_kmh(SEEDER, false), INF)
	assert_eq(Rules.speed_cap_kmh({"work": {"operation": "x"}}, true), INF)


func test_work_allowed_by_direction() -> void:
	assert_true(Rules.work_allowed("sow", -0.5, 0.05), "siewnik działa też na wstecznym")
	assert_false(Rules.work_allowed("cultivate", -0.5, 0.05))
	assert_true(Rules.work_allowed("cultivate", 0.5, 0.05))
	assert_false(Rules.work_allowed("harvest", 0.01, 0.05))


func test_toggle_messages() -> void:
	assert_eq(Rules.toggle_message(SEEDER, true), "Siewnik włączony (max 18 km/h)")
	assert_eq(Rules.toggle_message(SEEDER, false), "Siewnik wyłączony")
	assert_eq(Rules.toggle_message({"name": "Heder", "work": {"operation": "harvest"}}, true), "Heder opuszczony — koszenie")
	assert_eq(Rules.toggle_message({"name": "Rozsiewacz", "work": {"operation": "fertilize"}}, false), "Rozsiewacz: stop")


func test_seed_crop_cycle() -> void:
	var state := {}
	assert_eq(Rules.seed_crop(SEEDER, state), "wheat", "domyślnie pierwszy")
	state["seed_crop_id"] = Rules.next_seed_crop(SEEDER, state)
	assert_eq(state["seed_crop_id"], "barley")
	state["seed_crop_id"] = "oats"
	assert_eq(Rules.next_seed_crop(SEEDER, state), "wheat", "zawija")
	state["seed_crop_id"] = "rye"
	assert_eq(Rules.seed_crop(SEEDER, state), "wheat", "nieznany → pierwszy")
	assert_eq(Rules.seed_crop({"work": {"operation": "cultivate"}}, state), "")


func test_sow_check() -> void:
	var storage := {"amount_l": 1.0}
	assert_true(Rules.sow_check(Stage.PLAIN, storage, "wheat", 0.5)["ok"])
	assert_has(Rules.sow_check(Stage.READY, storage, "wheat", 0.5)["message"], "zbierz")
	assert_has(Rules.sow_check(Stage.HARVESTED, storage, "wheat", 0.5)["message"], "ściernisko")
	assert_empty(Rules.sow_check(Stage.LIGHT, storage, "wheat", 0.5)["message"])
	assert_has(Rules.sow_check(Stage.PLAIN, {"amount_l": 0.1}, "wheat", 0.5)["message"], "nie ma ziarna")


func test_harvest_yield_with_fertilizer() -> void:
	assert_near(Rules.harvest_yield(SETTINGS, "wheat", 0, 0.0625), 0.05)
	assert_near(Rules.harvest_yield(SETTINGS, "wheat", 2, 0.0625), 0.0675)
	assert_near(Rules.harvest_yield(SETTINGS, "wheat", 9, 1.0), 0.8 * 1.35, 0.0001, "poziom ponad tabelę = ostatni")


func test_harvest_check() -> void:
	var tank := {"amount_l": 0.0, "material_id": null}
	var ok: Dictionary = Rules.harvest_check(Stage.READY, "wheat", HEADER_WORK, tank, TANK, SETTINGS, 1, 1.0)
	assert_true(ok["ok"])
	assert_eq(ok["material"], "wheat_grain")
	assert_near(ok["amount"], 0.92)
	assert_has(Rules.harvest_check(Stage.READY, "oats", HEADER_WORK, tank, TANK, SETTINGS, 0, 1.0)["message"], "nie zbiera")
	var other := {"amount_l": 5.0, "material_id": "barley_grain"}
	assert_has(Rules.harvest_check(Stage.READY, "wheat", HEADER_WORK, other, TANK, SETTINGS, 0, 1.0)["message"], "Opróżnij")
	var full := {"amount_l": 99.9, "material_id": "wheat_grain"}
	assert_has(Rules.harvest_check(Stage.READY, "wheat", HEADER_WORK, full, TANK, SETTINGS, 0, 1.0)["message"], "pełny")
	assert_false(Rules.harvest_check(Stage.DARK, "wheat", HEADER_WORK, tank, TANK, SETTINGS, 0, 1.0)["ok"])


func test_store_and_consume() -> void:
	var tank := {"amount_l": 99.5, "material_id": null}
	Rules.store_harvest(tank, TANK, "wheat_grain", 1.0)
	assert_eq(tank["amount_l"], 100.0, "nie ponad pojemność")
	var supply := {"amount_l": 1.0, "material_id": "fertilizer"}
	Rules.consume(supply, 1.0, true)
	assert_eq(supply["material_id"], null, "pusty zbiornik nawozu")
	var seed := {"amount_l": 1.0, "material_id": "seed"}
	Rules.consume(seed, 2.0, false)
	assert_eq([seed["amount_l"], seed["material_id"]], [0.0, "seed"])
