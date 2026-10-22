extends "res://tests/framework/test_case.gd"
## Pełny świat (symulacja + widoki 2D/3D + HUD + wejście) w trybie headless.

const WorldScript = preload("res://scripts/app/world.gd")


func test_world_assembles_and_runs_actions() -> void:
	var world = WorldScript.new()
	world.managed_by_menu = true
	var ready: Array = [false]
	world.world_ready.connect(func(): ready[0] = true)
	tree.root.add_child(world)
	await frames(3)
	assert_true(ready[0] and world.loaded, "world_ready")
	assert_eq(world.views.views().size(), 2)
	var mode: String = world.views.mode
	world.input.run("toggle_view")
	assert_true(world.views.mode != mode, "przełączenie widoku")
	world.input.run("toggle_view")
	world.input.run("debug")
	world.input.run("switch_vehicle")
	await frames(2)
	assert_eq(world.query.controlled_vehicle(), world.context.machines.get_machine("combine_01"), "następny pojazd z zapisu")
	assert_has(world.hud.toast.last_message, "Sterujesz")
	world.actions.buy_machine("trailer_basic")
	await frames(2)
	var saved: Dictionary = world.capture_save()
	assert_eq(saved["document_type"], "save_game")
	assert_eq(saved["machine_instances"].size(), 11)
	assert_eq(saved["player"]["controlled_machine_id"], "combine_01")
	world.free()
	await frames(2)


func test_world_reports_broken_save() -> void:
	var world = WorldScript.new()
	world.saved_game = {"references": {}}
	var failed: Array = [""]
	world.world_failed.connect(func(message: String): failed[0] = message)
	tree.root.add_child(world)
	await frames(1)
	assert_false(world.loaded)
	assert_false(failed[0].is_empty(), "world_failed z opisem")
	world.free()
	await frames(1)
