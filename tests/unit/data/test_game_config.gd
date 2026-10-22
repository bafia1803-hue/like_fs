extends "res://tests/framework/test_case.gd"

const GameConfig = preload("res://scripts/data/game_config.gd")
const SessionLoader = preload("res://scripts/data/session_loader.gd")
const JsonFile = preload("res://scripts/data/json_file.gd")


func test_loads_project_files() -> void:
	var config = GameConfig.new()
	assert_true(config.load_from(), config.last_error)
	assert_true(config.farming.has("yield_l_per_m2"))
	assert_eq(config.routes["max_start_speed_kmh"], 6.0)
	assert_true(config.prices.machine_price("tractor_basic") > 0.0)


func test_missing_directory() -> void:
	var config = GameConfig.new()
	assert_false(config.load_from("res://does_not_exist"))
	assert_has(config.last_error, "Brak pliku konfiguracji")


func test_route_defaults_and_validation() -> void:
	var config = GameConfig.new()
	var routes := {"sample_seconds": 0.05, "max_recording_seconds": 10, "start_distance_m": 3, "collision_step_m": 0.1,
		"collision_step_degrees": 1, "collision_margin_m": 0.01, "max_collision_steps_per_tick": 64, "line_spacing_m": 0.1,
		"playback_accel_m_s2": 0.0}
	var normalized: Dictionary = config.normalize_routes(routes)
	assert_eq(normalized["playback_accel_m_s2"], 0.05, "dolna granica")
	assert_eq(normalized["start_blend_min_m"], 10.0, "domyślne")
	routes["line_spacing_m"] = -1
	assert_true(config.normalize_routes(routes).is_empty())
	assert_has(config.last_error, "line_spacing_m")


func test_farming_requires_keys() -> void:
	var config = GameConfig.new()
	assert_false(config.from_dictionaries({"colors": {}}, {}, {}))
	assert_has(config.last_error, "minimum_work_speed_m_s")


func test_session_loader_indexes_template() -> void:
	var loader = SessionLoader.new()
	var session: Dictionary = loader.load_session("res://files/save.json")
	assert_empty(loader.last_error)
	assert_true(session["models_by_id"].has("tractor_basic"))
	assert_true(session["instances_by_id"].has("tractor_01"))
	assert_eq(session["field_states_by_id"].size(), session["map_data"]["fields"].size())


func test_session_loader_reports_missing_file() -> void:
	var loader = SessionLoader.new()
	assert_true(loader.load_session("res://files/missing.json").is_empty())
	assert_has(loader.last_error, "Nie można otworzyć pliku")


func test_json_file_errors() -> void:
	var reader = JsonFile.new()
	assert_true(reader.read_object("res://nope.json").is_empty())
	assert_false(reader.last_error.is_empty())
	assert_false(reader.read_object("res://files/map.json").is_empty())
