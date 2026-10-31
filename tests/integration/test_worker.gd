extends "res://tests/framework/test_case.gd"
## Pracownik na mapie testowej (files/test/worker_save.json) i jego wyłączenie na mapie głównej.

const WorldScript = preload("res://scripts/app/world.gd")
const WorkerFeature = preload("res://scripts/sim/worker/worker_feature.gd")
const Machines = preload("res://scripts/sim/machines/machines.gd")


func _world(save_path: String) -> Node:
	var world = WorldScript.new()
	world.managed_by_menu = true
	if not save_path.is_empty():
		world.initial_save_path = save_path
	tree.root.add_child(world)
	await frames(3)
	return world


func test_worker_only_on_test_map() -> void:
	assert_false(WorkerFeature.test_save_path().is_empty(), "włączony w files/workers.json")
	var world = await _world("")
	assert_true(world.loaded)
	assert_eq(world.context.workers, null, "mapa główna – bez pracownika")
	world.input.run("worker")
	await frames(2)
	assert_eq(world.actions.toggle_worker(), "", "H nic nie robi")
	world.free()
	await frames(2)


func test_seeder_worker_sows_and_can_be_dismissed() -> void:
	var world = await _world(WorkerFeature.test_save_path())
	assert_true(world.loaded, "mapa testowa się wczytuje")
	var workers = world.context.workers
	assert_true(workers != null)
	var tractor: RigidBody2D = world.context.machines.get_machine("tractor_02")
	var start: Vector2 = tractor.global_position
	var text: String = workers.toggle(tractor)
	assert_has(text, "Pole wschodnie")
	assert_true(workers.jobs.has(tractor), text)
	assert_eq(Machines.route_mode(tractor), "playing")
	assert_true(workers.preview_lines().size() > 10, "plan do podglądu 2D")
	var field = world.context.field_work.fields[2]
	await frames(60 * 25)
	assert_true(tractor.global_position.distance_to(start) / world.context.units > 10.0, "zestaw jedzie")
	assert_true(field.cells.count_stage(1) > 0, "siewnik sieje")
	# Drugi pracownik na tym samym polu – odmowa.
	var other: RigidBody2D = world.context.machines.get_machine("tractor_01")
	var plan: Dictionary = workers._make_plan(other, field)
	assert_has(str(plan.get("error", "")), "pracuje już inny pracownik")
	workers.toggle(tractor)
	await frames(60 * 6)
	assert_false(workers.jobs.has(tractor), "odwołany pracownik kończy")
	assert_eq(Machines.route_mode(tractor), "held")
	world.free()
	await frames(2)
