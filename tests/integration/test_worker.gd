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


func after_each() -> void:
	Engine.time_scale = 1.0


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


func test_two_cultivators_share_field() -> void:
	var world = await _world(WorkerFeature.test_save_path())
	assert_true(world.loaded, "mapa testowa się wczytuje")
	var workers = world.context.workers
	var first: RigidBody2D = world.context.machines.get_machine("tractor_01")
	var second: RigidBody2D = world.context.machines.get_machine("tractor_03")
	assert_has(workers.toggle(first), "Pole północne")
	assert_has(workers.toggle(second), "Pole północne")
	assert_true(workers.jobs.has(first) and workers.jobs.has(second), "dwóch pracowników na jednym polu")
	assert_eq(Machines.route_mode(second), "playing")
	# Pasy się nie powtarzają: środek każdego pasa drugiego pracownika poza pasami pierwszego.
	for claim in workers.jobs[second]["claims"]:
		var polygon: PackedVector2Array = claim["polygon"]
		var center: Vector2 = (polygon[0] + polygon[2]) * 0.5
		for other in workers.jobs[first]["claims"]:
			assert_false(Geometry2D.is_point_in_polygon(center, other["polygon"]), "ten sam pas u dwóch pracowników")
	assert_true(workers.preview_lines().size() > 10, "plan do podglądu 2D")
	var start: Vector2 = second.global_position
	await frames(60 * 15)
	assert_true(second.global_position.distance_to(start) / world.context.units > 5.0, "drugi zestaw jedzie")
	workers.toggle(first)
	workers.toggle(second)
	await frames(60 * 6)
	assert_false(workers.jobs.has(first) or workers.jobs.has(second), "odwołani pracownicy kończą")
	assert_eq(Machines.route_mode(first), "held")
	world.free()
	await frames(2)


func test_seeder_waits_for_cultivator_and_follows() -> void:
	var world = await _world(WorkerFeature.test_save_path())
	var workers = world.context.workers
	var cultivator: RigidBody2D = world.context.machines.get_machine("tractor_01")
	var seeder: RigidBody2D = world.context.machines.get_machine("tractor_02")
	assert_has(workers.toggle(seeder), "nie ma teraz pracy", "samo ściernisko – bez kultywatora siewnik nie ma pracy")
	workers.toggle(cultivator)
	assert_has(workers.toggle(seeder), "czeka", "kultywator pracuje – siewnik czeka")
	assert_true(bool(workers.jobs[seeder]["waiting"]))
	Engine.time_scale = 4.0
	var field = world.context.field_work.fields[0]
	var started: bool = false
	for i in 60 * 50:
		await tree.physics_frame
		if Machines.route_mode(seeder) == "playing":
			started = true
			break
	assert_true(started, "siewnik rusza, gdy jest zakultywowana ziemia")
	assert_true((workers.jobs[seeder]["axis"] as Vector2).abs().x > 0.9, "siewnik jedzie wschód–zachód")
	for i in 60 * 20:
		await tree.physics_frame
	assert_true(field.cells.count_stage(1) > 0, "siewnik sieje za kultywatorem")
	Engine.time_scale = 1.0
	world.free()
	await frames(2)
