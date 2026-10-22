extends "res://tests/framework/test_case.gd"

const SessionLoader = preload("res://scripts/data/session_loader.gd")
const SaveCodec = preload("res://scripts/data/save_codec.gd")
const FieldCells = preload("res://scripts/core/field/field_cells.gd")


func _base() -> Dictionary:
	return SessionLoader.new().load_session("res://files/save.json")


func test_prepares_template() -> void:
	var base: Dictionary = _base()
	var codec = SaveCodec.new()
	var session: Dictionary = codec.prepare_session(base, base["save_data"])
	assert_empty(codec.last_error)
	var trailer: Dictionary = session["instances_by_id"]["trailer_01"]
	assert_eq(trailer["parking_brake_engaged"], true)
	assert_true(trailer["articulated_state"].has("front_carriage"))
	assert_eq(session["instances_by_id"]["seeder_01"]["work_state"], {"enabled": false, "lowered": false})


func test_rejects_unknown_controlled_vehicle() -> void:
	var base: Dictionary = _base()
	var game: Dictionary = base["save_data"].duplicate(true)
	game["player"]["controlled_machine_id"] = "trailer_01"
	var codec = SaveCodec.new()
	assert_true(codec.prepare_session(base, game).is_empty())
	assert_has(codec.last_error, "pojazdu gracza")


func test_rejects_overfull_storage() -> void:
	var base: Dictionary = _base()
	var game: Dictionary = base["save_data"].duplicate(true)
	for state in game["machine_instances"]:
		if state["instance_id"] == "trailer_01":
			for storage in state["storages"].values():
				storage["amount_l"] = 1.0e9
				storage["material_id"] = "wheat_grain"
	var codec = SaveCodec.new()
	assert_true(codec.prepare_session(base, game).is_empty())
	assert_has(codec.last_error, "pojemność")


func test_migrates_legacy_seed_material() -> void:
	var base: Dictionary = _base()
	var game: Dictionary = base["save_data"].duplicate(true)
	for state in game["machine_instances"]:
		if state["instance_id"] == "seeder_01":
			for storage in state["storages"].values():
				storage["material_id"] = "barley_seed"
				storage["amount_l"] = 10.0
	var session: Dictionary = SaveCodec.new().prepare_session(base, game)
	var seeder: Dictionary = session["instances_by_id"]["seeder_01"]
	assert_eq(seeder["seed_crop_id"], "barley")
	assert_eq(seeder["storages"].values()[0]["material_id"], "seed")


func test_field_of_new_size_starts_empty() -> void:
	var base: Dictionary = _base()
	var game: Dictionary = base["save_data"].duplicate(true)
	var cells = FieldCells.new()
	cells.setup(3, 3)
	game["field_states"][0]["growth_simulation"] = cells.export_state()
	var session: Dictionary = SaveCodec.new().prepare_session(base, game)
	assert_false(session.is_empty())
	assert_false(session["save_data"]["field_states"][0].has("growth_simulation"))


func test_rejects_corrupted_field() -> void:
	var base: Dictionary = _base()
	var game: Dictionary = base["save_data"].duplicate(true)
	var field: Dictionary = base["map_data"]["fields"][0]
	game["field_states"][0]["growth_simulation"] = {"encoding": "field_cells_v3",
		"columns": int(field["grid"]["columns"]), "rows": int(field["grid"]["rows"]), "cells": "AAAA"}
	var codec = SaveCodec.new()
	assert_true(codec.prepare_session(base, game).is_empty())
	assert_has(codec.last_error, "Uszkodzony zapis pola")
