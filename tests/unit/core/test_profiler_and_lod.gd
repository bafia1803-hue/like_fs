extends "res://tests/framework/test_case.gd"

const Profiler = preload("res://scripts/core/util/profiler.gd")
const FocusLod = preload("res://scripts/views/view3d/focus_lod.gd")


func after_each() -> void:
	Profiler.enabled = false
	Profiler.take()


func test_disabled_profiler_measures_nothing() -> void:
	Profiler.enabled = false
	Profiler.stop(Profiler.FIELD_WORK, Profiler.start())
	Profiler.add(Profiler.TRANSFER, 500)
	assert_true(Profiler.take().is_empty())


func test_groups_sorted_by_time() -> void:
	var groups: Array = Profiler.group({"Fizyka/A": 100, "Widok/B": 50, "Fizyka/C": 300, "Widok/D": 400})
	assert_eq(groups[0]["name"], "Widok")
	assert_eq(groups[0]["usec"], 450)
	assert_eq(groups[1]["items"][0]["name"], "C", "w grupie od największego")


func test_finish_splits_engine_and_frame_gaps() -> void:
	var totals := {"_physics_scripts": 1000, "_frame_scripts": 800, "_after_frame": 5000, "_render_cpu": 3000,
		Profiler.PHYSICS_ENGINE: 2000, Profiler.PHYSICS_TIRES: 600, Profiler.FIELD_WORK: 700, Profiler.UI_HUD: 300}
	var result: Dictionary = Profiler.finish(totals)
	assert_eq(result[Profiler.PHYSICS_ENGINE], 1400, "opony odjęte od silnika")
	assert_eq(result[Profiler.RENDER_CPU], 3000)
	assert_eq(result[Profiler.WAIT_OTHER], 2000, "bez V-Sync: sterownik i system")
	assert_eq(result[Profiler.PHYSICS_OTHER], 300)
	assert_eq(result[Profiler.FRAME_OTHER], 500)
	assert_false(result.has("_after_frame"))


func test_focus_lod_rect_distances() -> void:
	var rect := Rect2(10, 0, 16, 16)
	var inside: Vector2 = FocusLod.rect_distance(Vector2(12, 2), rect)
	assert_eq(inside.x, 0.0)
	assert_near(inside.y, Vector2(14, 14).length())
	var far: Vector2 = FocusLod.rect_distance(Vector2(0, 8), rect)
	assert_eq(far.x, 10.0)
	assert_true(FocusLod.needs_detail(far, 22.0))
	assert_false(FocusLod.needs_detail(far, 0.0), "jakość niska: bez szczegółowych")
	assert_true(FocusLod.needs_simple(far, 22.0, 10.0, 85.0), "część kawałka w paśmie przejścia")
	assert_false(FocusLod.needs_simple(Vector2(1, 5), 22.0, 10.0, 85.0), "cały w kółku szczegółów")
	assert_false(FocusLod.needs_simple(Vector2(90, 100), 22.0, 10.0, 85.0), "za zasięgiem")
