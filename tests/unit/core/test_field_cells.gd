extends "res://tests/framework/test_case.gd"

const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const Stage = FieldCells.Stage


func _cells(columns: int = 4, rows: int = 3):
	var cells = FieldCells.new()
	cells.setup(columns, rows)
	return cells


func test_new_field_is_plain() -> void:
	var cells = _cells()
	assert_eq(cells.size(), 12)
	assert_eq(cells.count_stage(Stage.PLAIN), 12)
	assert_eq(cells.crop_at(0), "")
	assert_eq(cells.fertilizer_level(0), 0)


func test_sow_only_on_plain() -> void:
	var cells = _cells()
	assert_true(cells.sow(1, "barley"))
	assert_eq(cells.stage(1), Stage.SOWN)
	assert_eq(cells.crop_at(1), "barley")
	assert_false(cells.sow(1, "wheat"), "drugi siew na zasianym")
	assert_eq(cells.crop_at(1), "barley")


func test_growth_cycle_and_harvest() -> void:
	var cells = _cells()
	cells.sow(0, "oats")
	for expected in [Stage.LIGHT, Stage.DARK, Stage.READY, Stage.READY]:
		cells.grow()
		assert_eq(cells.stage(0), expected)
	assert_true(cells.harvest(0))
	assert_eq(cells.stage(0), Stage.HARVESTED)
	assert_eq(cells.crop_at(0), "")
	assert_false(cells.harvest(0), "ściernisko nie daje drugiego zbioru")


func test_grow_returns_grown_indices() -> void:
	var cells = _cells()
	cells.sow(2, "wheat")
	cells.sow(5, "wheat")
	var grown: PackedInt32Array = cells.grow()
	assert_eq(Array(grown), [2, 5])
	assert_eq(cells.grow().size(), 2)


func test_cultivate_resets_any_stage() -> void:
	var cells = _cells()
	cells.sow(0, "wheat")
	assert_true(cells.cultivate(0))
	assert_eq(cells.stage(0), Stage.PLAIN)
	assert_false(cells.cultivate(0), "puste pole bez zmian")


func test_fertilizer_two_phases() -> void:
	var cells = _cells()
	assert_true(cells.fertilize(0), "przed siewem")
	assert_false(cells.fertilize(0), "ta sama faza drugi raz")
	assert_eq(cells.fertilizer_level(0), 1)
	cells.sow(0, "wheat")
	assert_true(cells.fertilize(0), "w trakcie wzrostu")
	assert_eq(cells.fertilizer_level(0), 2)
	cells.grow(); cells.grow(); cells.grow()
	assert_false(cells.fertilize(0), "dojrzałe zboże")
	cells.harvest(0)
	assert_eq(cells.fertilizer_level(0), 0, "zbiór zużywa nawóz")


func test_cultivation_keeps_fertilizer() -> void:
	var cells = _cells()
	cells.sow(0, "wheat")
	cells.fertilize(0)
	cells.cultivate(0)
	assert_eq(cells.fertilizer_level(0), 1)
	assert_true(cells.fertilize(0), "po kultywacji można nawieźć fazę przed siewem")
	assert_eq(cells.fertilizer_level(0), 2)


func test_fertilize_bit_by_stage() -> void:
	assert_eq(FieldCells.fertilize_bit(Stage.PLAIN), FieldCells.FERT_BEFORE)
	assert_eq(FieldCells.fertilize_bit(Stage.HARVESTED), FieldCells.FERT_BEFORE)
	assert_eq(FieldCells.fertilize_bit(Stage.SOWN), FieldCells.FERT_GROWING)
	assert_eq(FieldCells.fertilize_bit(Stage.DARK), FieldCells.FERT_GROWING)
	assert_eq(FieldCells.fertilize_bit(Stage.READY), 0)


func test_block_index_counts_visible_plants() -> void:
	var cells = _cells(64, 40)
	assert_eq(cells.block_columns, 2)
	assert_eq(cells.block_rows, 2)
	var revision: int = cells.blocks_revision
	cells.sow(0, "wheat")
	assert_eq(cells.plants_in_blocks(Vector2i(0, 0), Vector2i(1, 1)), 0, "zasiane jeszcze niewidoczne")
	cells.grow()
	assert_eq(cells.plants_in_blocks(Vector2i(0, 0), Vector2i(0, 0)), 1)
	assert_eq(cells.plants_in_blocks(Vector2i(1, 0), Vector2i(1, 1)), 0)
	assert_true(cells.blocks_revision > revision, "blok przestał być pusty")
	cells.cultivate(0)
	assert_eq(cells.plants_in_blocks(Vector2i(0, 0), Vector2i(1, 1)), 0)


func test_fill_strips() -> void:
	var cells = _cells(6, 2)
	cells.fill_strips(["wheat", "barley", "oats"], Stage.READY)
	assert_eq(cells.count_stage(Stage.READY), 12)
	assert_eq([cells.crop_at(0), cells.crop_at(2), cells.crop_at(5)], ["wheat", "barley", "oats"])


func test_export_restore_roundtrip() -> void:
	var cells = _cells(40, 30)
	cells.sow(3, "barley")
	cells.fertilize(3)
	cells.fertilize(7)
	cells.grow()
	cells.fill_strips([], Stage.READY)
	var saved: Dictionary = cells.export_state()
	assert_eq(saved["encoding"], "field_cells_v3")
	var copy = _cells(40, 30)
	assert_true(copy.restore_state(saved))
	assert_eq(copy.states, cells.states)
	assert_eq(copy.crop_codes, cells.crop_codes)
	assert_eq(copy.fertilized, cells.fertilized)
	assert_eq(copy.plants_in_blocks(Vector2i(0, 0), Vector2i(9, 9)), 1)


func test_restore_rejects_wrong_size_and_garbage() -> void:
	var cells = _cells(4, 3)
	var saved: Dictionary = cells.export_state()
	assert_false(_cells(5, 3).restore_state(saved), "inny rozmiar")
	saved["cells"] = "nie-base64"
	assert_false(cells.restore_state(saved), "uszkodzone dane")
	assert_false(cells.restore_state({"encoding": "?", "columns": 4, "rows": 3}), "nieznany format")


func test_restore_legacy_v2() -> void:
	var cells = _cells(2, 1)
	assert_true(cells.restore_state({"encoding": "field_cells_v2", "columns": 2, "rows": 1,
		"states": [Stage.DARK, Stage.PLAIN], "crops": ["oats", ""]}))
	assert_eq(cells.stage(0), Stage.DARK)
	assert_eq(cells.crop_at(0), "oats")
	assert_eq(cells.fertilizer_level(0), 0)


func test_packed_size_is_small() -> void:
	var cells = _cells(240, 320)
	cells.fill_strips(["wheat", "barley", "oats"], Stage.READY)
	assert_true(str(cells.export_state()["cells"]).length() < 2000, "76 800 komórek w kilku kB")
