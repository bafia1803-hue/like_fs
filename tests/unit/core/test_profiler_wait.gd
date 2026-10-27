extends "res://tests/framework/test_case.gd"

const Profiler = preload("res://scripts/core/util/profiler.gd")


func test_wait_split_gpu_and_vsync() -> void:
	# Procesor pracuje 4 ms, karta 10 ms, po skryptach 12 ms (2 ms renderowanie CPU).
	var totals := {"_frame_scripts": 2000, "_after_frame": 12000, "_render_cpu": 2000, Profiler.RENDER_GPU: 10000}
	var limited: Dictionary = Profiler.finish(totals, true)
	assert_eq(limited["_gpu_total"], 10000)
	assert_eq(limited["_cpu_total"], 4000)
	assert_eq(limited[Profiler.WAIT_GPU], 6000, "procesor czeka, aż karta skończy")
	assert_eq(limited[Profiler.WAIT_VSYNC], 4000)
	var free: Dictionary = Profiler.finish(totals, false)
	assert_eq(free[Profiler.WAIT_OTHER], 4000)


func test_gpu_passes_replace_total() -> void:
	var totals := {Profiler.RENDER_GPU: 10000, Profiler.GPU_PASS + "Render Shadows": 3000, Profiler.GPU_PASS + "Render Opaque": 5000}
	var result: Dictionary = Profiler.finish(totals)
	assert_false(result.has(Profiler.RENDER_GPU))
	assert_eq(result[Profiler.GPU_OTHER], 2000)
	assert_eq(result["_gpu_total"], 10000)
	var names: Array = []
	for group in Profiler.group(result):
		names.append(group["name"])
	assert_false(names.has("_gpu_total"), "klucze techniczne poza raportem")
