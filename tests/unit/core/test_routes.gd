extends "res://tests/framework/test_case.gd"

const RouteData = preload("res://scripts/core/routes/route_data.gd")
const RouteSample = preload("res://scripts/core/routes/route_sample.gd")
const Playback = preload("res://scripts/core/routes/route_playback.gd")
const Recorder = preload("res://scripts/core/routes/route_recorder.gd")
const Signature = preload("res://scripts/core/routes/route_signature.gd")

const SETTINGS := {"playback_accel_m_s2": 1.5, "playback_decel_m_s2": 2.0}


## Prosta trasa: jazda na północ (−y) ze stałą prędkością speed przez seconds sekund.
func _straight(speed: float, seconds: float, step: float = 0.5) -> Dictionary:
	var samples: Array = []
	var t: float = 0.0
	while t <= seconds + 0.0001:
		samples.append([t, 0.0, -speed * t, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0])
		t += step
	return {"version": 4, "id": "r", "name": "test", "map_id": "m", "signature": {}, "samples": samples}


func test_valid_route_and_rejections() -> void:
	var route: Dictionary = _straight(2.0, 4.0)
	assert_true(RouteData.valid(route))
	var broken: Dictionary = route.duplicate(true)
	broken["samples"][1][0] = 0.0
	assert_false(RouteData.valid(broken), "czas musi rosnąć")
	var bad_work: Dictionary = route.duplicate(true)
	bad_work["samples"][1][7] = 0.5
	assert_false(RouteData.valid(bad_work), "praca narzędzia tylko 0/1")
	var old: Dictionary = route.duplicate(true)
	old["version"] = 1
	assert_false(RouteData.valid(old), "wersja 1 ma 6 kolumn")


func test_at_and_between() -> void:
	var route: Dictionary = _straight(2.0, 4.0)
	var cursor: Dictionary = RouteData.at(route, 1.25, 0)
	assert_eq(cursor["index"], 2)
	assert_near(cursor["point"][2], -2.5)
	var points: Array = RouteData.between(route, 0.25, 1.75, 0)
	assert_eq(points.size(), 5, "początek, 3 próbki, koniec")
	assert_near(points[-1][0], 1.75)


func test_interpolation_keeps_work_flag_until_end() -> void:
	var a: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0]
	var b: Array = [1.0, 2.0, 0.0, PI, 0.0, 0.0, 1.0, 1.0, 1.0]
	var mid: Array = RouteSample.interpolate(a, b, 0.5)
	assert_near(mid[1], 1.0)
	assert_near(mid[6], 0.0)
	assert_eq(mid[7], 0.0, "praca z początku odcinka")
	assert_near(mid[8], 0.5)
	assert_eq(RouteSample.interpolate(a, b, 1.0)[7], 1.0)
	assert_near(absf(mid[3]), PI * 0.5, 0.0001, "kąt po krótszym łuku")


func test_playback_starts_from_standstill_with_ramp() -> void:
	var playback = Playback.new()
	playback.setup(_straight(5.0, 20.0), SETTINGS)
	var step: Dictionary = playback.plan(1.0)
	assert_near(step["speed_limit"], 1.5, 0.0001, "przyspieszenie 1,5 m/s²")
	assert_near(step["speed"], 1.5, 0.001)
	playback.commit(step)
	assert_near(playback.distance_at(playback.time), 1.5, 0.001)


func test_playback_brakes_to_route_end() -> void:
	var playback = Playback.new()
	playback.setup(_straight(5.0, 4.0), SETTINGS)
	var top: float = 0.0
	for i in 2000:
		if playback.finished():
			break
		var step: Dictionary = playback.plan(0.02)
		top = maxf(top, float(step["speed"]))
		playback.commit(step)
	assert_true(playback.finished(), "trasa dojechana")
	assert_near(playback.distance_at(playback.time), 20.0, 0.05)
	assert_true(top <= 5.0 + 0.001, "nie szybciej niż nagranie")
	assert_true(playback.current_speed < 1.0, "na końcu prawie stoi")


func test_begin_stop_decelerates_from_current_speed() -> void:
	var playback = Playback.new()
	playback.setup(_straight(5.0, 30.0), SETTINGS)
	for i in 250:
		playback.commit(playback.plan(0.02))
	assert_near(playback.current_speed, 5.0, 0.01)
	playback.begin_stop()
	var frames_to_stop: int = 0
	while frames_to_stop < 1000:
		var step: Dictionary = playback.plan(0.02)
		playback.commit(step)
		frames_to_stop += 1
		if step["stopped"]:
			break
	assert_near(frames_to_stop * 0.02, 2.5, 0.05, "5 m/s przy 2 m/s²")


func test_halt_resets_speed() -> void:
	var playback = Playback.new()
	playback.setup(_straight(5.0, 30.0), SETTINGS)
	for i in 100:
		playback.commit(playback.plan(0.02))
	playback.halt()
	assert_near(playback.plan(0.1)["speed_limit"], 0.15, 0.0001)


func test_blend_converges_to_route() -> void:
	var playback = Playback.new()
	var route: Dictionary = _straight(5.0, 20.0)
	playback.setup(route, SETTINGS)
	var actual: Array = route["samples"][0].duplicate()
	actual[1] = 1.5
	actual[3] = deg_to_rad(15.0)
	playback.setup_blend(actual, 10.0)
	var start: Array = playback.blended(route["samples"][0])
	assert_near(start[1], 1.5, 0.0001, "start w rzeczywistej pozie")
	assert_near(start[3], deg_to_rad(15.0), 0.0001)
	var later: Array = playback.blended(RouteData.at(route, 3.0, 0)["point"])
	assert_near(later[1], 0.0, 0.0001, "po 15 m (> długości wejścia) na trasie")
	assert_true(playback.blending(), "na starcie trwa wejście na trasę")


func test_recorder_adds_edge_samples() -> void:
	var recorder = Recorder.new()
	var point: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
	recorder.start(point, 0.5)
	for i in 5:
		var t: float = recorder.advance(0.1)
		var sample: Array = [t, 0.0, -t, 0.0, 0.0, 0.0, 0.0, 1.0 if i >= 2 else 0.0, 1.0]
		recorder.record(sample, true)
	var times: Array = []
	for sample in recorder.samples:
		times.append(snappedf(sample[0], 0.001))
	assert_eq(times, [0.0, 0.1, 0.2, 0.3, 0.5], "start ruchu i włączenie pracy dają po dwie próbki")
	assert_true(recorder.finish([0.55, 0.0, -0.55, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0]))


func test_recorder_too_short() -> void:
	var recorder = Recorder.new()
	recorder.start([0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0], 0.05)
	recorder.advance(0.05)
	assert_false(recorder.finish([0.05, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]))


func test_signature_ignores_unused_ports() -> void:
	var tractor := {"id": "tractor", "hitch_ports": [{"id": "rear", "type": "drawbar"}]}
	var with_tpl: Dictionary = tractor.duplicate(true)
	with_tpl["hitch_ports"].append({"id": "tuz", "type": "three_point"})
	var tool := {"id": "cultivator", "hitch_ports": [{"id": "eye", "type": "drawbar"}]}
	var socket: Dictionary = tractor["hitch_ports"][0]
	var plug: Dictionary = tool["hitch_ports"][0]
	var signature: Dictionary = Signature.build(tractor, tool, socket, plug)
	assert_eq(signature, Signature.build(with_tpl, tool, socket, plug), "nowy zaczep nie unieważnia trasy")
	assert_true(Signature.matches(signature, with_tpl, tool, socket, plug))
	var other_tool: Dictionary = tool.duplicate(true)
	other_tool["mass"] = 1
	assert_false(Signature.matches(signature, tractor, other_tool, socket, plug), "inna konfiguracja narzędzia")


func test_signature_accepts_legacy_full_hash() -> void:
	var tractor := {"id": "tractor", "hitch_ports": [{"id": "rear", "type": "drawbar"}, {"id": "aux", "type": "drawbar"}]}
	var legacy := {"vehicle_model": "tractor", "tool_model": "", "vehicle_config": JSON.stringify(tractor, "", true).sha256_text(),
		"tool_config": JSON.stringify({}, "", true).sha256_text(), "socket": "", "plug": ""}
	var with_tpl: Dictionary = tractor.duplicate(true)
	with_tpl["hitch_ports"].append({"id": "tuz", "type": "three_point"})
	assert_true(Signature.matches(legacy, with_tpl, {}, {}, {}), "trasa sprzed TUZ")
