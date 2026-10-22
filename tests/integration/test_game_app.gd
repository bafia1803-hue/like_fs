extends "res://tests/framework/test_case.gd"
## Aplikacja: menu → nowa gra w slocie → zapis → powrót do menu → wczytanie (zapis w katalogu testowym).

const GameAppScript = preload("res://scripts/app/game_app.gd")
const DIRECTORY: String = "user://test_saves_app"


func after_each() -> void:
	var dir := DirAccess.open(DIRECTORY)
	if dir != null:
		for file in dir.get_files():
			dir.remove(file)
		DirAccess.remove_absolute(DIRECTORY)


func test_new_game_save_menu_and_load() -> void:
	var app = GameAppScript.new()
	tree.root.add_child(app)
	app.manager.directory = DIRECTORY
	app.call("_request_start", 3, true)
	await frames(10)
	assert_true(is_instance_valid(app.get("_world")), "świat uruchomiony")
	var info: Dictionary = app.manager.slot_info(3)
	assert_true(info.get("loadable", false), "nowa gra od razu zapisana w slocie")
	app.request_action("menu")
	await frames(3)
	assert_false(is_instance_valid(app.get("_world")), "powrót do menu")
	assert_false(tree.paused)
	app.call("_request_start", 3, false)
	await frames(10)
	var world: Node = app.get("_world")
	assert_true(is_instance_valid(world) and world.loaded, "wczytano zapis")
	assert_eq(world.query.money(), 150000.0)
	app.request_action("menu")
	await frames(3)
	app.free()
	await frames(1)
