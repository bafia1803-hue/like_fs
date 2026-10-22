extends "res://tests/framework/test_case.gd"

const SaveSlots = preload("res://scripts/data/save_slots.gd")
const DIRECTORY: String = "user://test_saves"

var slots


func before_each() -> void:
	slots = SaveSlots.new()
	slots.directory = DIRECTORY
	_clean()


func after_each() -> void:
	_clean()


func _clean() -> void:
	var dir := DirAccess.open(DIRECTORY)
	if dir == null:
		return
	for file in dir.get_files():
		dir.remove(file)
	DirAccess.remove_absolute(DIRECTORY)


func _game(money: float) -> Dictionary:
	return {"machine_instances": [{"instance_id": "a"}], "connections": [], "field_states": [],
		"player": {}, "references": {}, "economy": {"money": money}}


func test_write_and_read_slot() -> void:
	assert_true(slots.write_slot(2, _game(5.0), {"play_time_s": 3725.0}), slots.last_error)
	var document: Dictionary = slots.read_slot(2)
	assert_eq(document["game"]["economy"]["money"], 5.0)
	assert_eq(SaveSlots.play_time_s(document), 3725.0)
	var info: Dictionary = slots.slot_info(2)
	assert_true(info["loadable"])
	assert_eq(info["money"], 5.0)
	assert_false(slots.slot_info(1)["occupied"])


func test_backup_restores_after_corruption() -> void:
	slots.write_slot(1, _game(1.0))
	slots.write_slot(1, _game(2.0))
	var file := FileAccess.open(slots.slot_path(1), FileAccess.WRITE)
	file.store_string("{zepsute")
	file.close()
	var document: Dictionary = slots.read_slot(1)
	assert_eq(document["game"]["economy"]["money"], 1.0, "kopia .bak z poprzedniego zapisu")
	assert_has(slots.last_warning, "kopię")


func test_rejects_invalid_slot_and_game() -> void:
	assert_false(slots.write_slot(4, _game(1.0)))
	assert_false(slots.write_slot(1, {"machine_instances": []}))
	assert_true(slots.read_slot(3).is_empty())
