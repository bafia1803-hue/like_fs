extends "res://tests/framework/test_case.gd"

const GraphicsSettings = preload("res://scripts/app/graphics_settings.gd")
const JsonFile = preload("res://scripts/data/json_file.gd")
const KEYS: Array[String] = ["max_render_height_px", "msaa", "fxaa", "shadow_splits", "shadow_distance_m",
	"shadow_atlas_px", "ssao", "glow", "crop_detail_m", "crop_fade_m", "crop_thin_from_m", "crop_visible_m", "grass_fade_m", "grass_visible_m", "tree_shadows"]


func test_presets_are_complete() -> void:
	var data: Dictionary = JsonFile.new().read_object("res://files/graphics.json")
	assert_true(data["presets"].has(data["default"]))
	for name in data["order"]:
		var preset: Dictionary = data["presets"][name]
		for key in KEYS:
			assert_true(preset.has(key), "%s: brak %s" % [name, key])
		assert_true(float(preset["crop_visible_m"]) >= float(preset["crop_detail_m"]), name)


func test_render_scale_caps_resolution() -> void:
	assert_eq(GraphicsSettings.render_scale(1080.0, 1080.0), 1.0)
	assert_eq(GraphicsSettings.render_scale(720.0, 1080.0), 1.0, "nie powiększa ponad okno")
	assert_near(GraphicsSettings.render_scale(1600.0, 1080.0), 0.675)
	assert_eq(GraphicsSettings.render_scale(2160.0, 720.0), 0.5, "dolna granica")


func test_integrated_gpu_starts_lower() -> void:
	var data: Dictionary = JsonFile.new().read_object("res://files/graphics.json")
	assert_eq(GraphicsSettings.default_quality(data, RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU), data["integrated_default"])
	assert_eq(GraphicsSettings.default_quality(data, RenderingDevice.DEVICE_TYPE_DISCRETE_GPU), data["default"])
	assert_true(data["presets"].has(data["integrated_default"]))


func test_expensive_effects_are_off() -> void:
	# SSAO (~27 ms) i MSAA (~3 ms scalania) na słabszej karcie – zmierzone raportem F4.
	var data: Dictionary = JsonFile.new().read_object("res://files/graphics.json")
	for name in data["order"]:
		assert_false(bool(data["presets"][name]["ssao"]), name)
		assert_eq(int(data["presets"][name]["msaa"]), 0, name)
