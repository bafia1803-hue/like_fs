extends "res://tests/framework/test_case.gd"

const RouteCodec = preload("res://scripts/core/routes/route_codec.gd")
const RouteData = preload("res://scripts/core/routes/route_data.gd")


func _route(rows: int) -> Dictionary:
	var samples: Array = []
	for i in rows:
		var t: float = i / 60.0
		samples.append([t, 100.0 + sin(t) * 20.0, 200.0 - t * 3.3, t * 0.1, -0.2, 0.05, sin(t * 3.0), 1.0 if i > rows / 2 else 0.0, minf(1.0, t / 4.0)])
	samples[0][0] = 0.0
	return {"version": 4, "id": "r1", "name": "Pole", "map_id": "m", "signature": {"vehicle_model": "x"}, "samples": samples}


func test_roundtrip_keeps_route_within_precision() -> void:
	var route: Dictionary = _route(3000)
	var packed: Dictionary = RouteCodec.pack(route)
	assert_false(packed.has("samples"))
	assert_eq(packed["name"], "Pole")
	var restored: Dictionary = RouteCodec.unpack(packed)
	assert_true(RouteData.valid(restored), "odtworzona trasa poprawna")
	var worst: float = 0.0
	for i in route["samples"].size():
		for c in 9:
			worst = maxf(worst, absf(float(route["samples"][i][c]) - float(restored["samples"][i][c])))
	assert_true(worst <= 0.00006, "błąd zaokrąglenia %.7f" % worst)
	assert_eq(restored["samples"][2000][7], 1.0, "praca narzędzia dokładnie")


func test_packed_is_much_smaller_than_json() -> void:
	var route: Dictionary = _route(36000)      # 30 minut nagrania
	var json_size: int = JSON.stringify(route).length()
	var packed_size: int = JSON.stringify(RouteCodec.pack(route)).length()
	assert_true(packed_size * 4 < json_size, "%d B zamiast %d B" % [packed_size, json_size])


func test_unpacked_route_and_corruption() -> void:
	var route: Dictionary = _route(10)
	assert_eq(RouteCodec.unpack(route), route, "trasa bez kodowania bez zmian")
	var packed: Dictionary = RouteCodec.pack(route)
	packed["samples_packed"]["data"] = "AAAA"
	assert_true(RouteCodec.unpack(packed).is_empty())


func test_colliding_times_stay_unpacked() -> void:
	var route: Dictionary = _route(5)
	route["samples"][2][0] = route["samples"][1][0] + 0.00001
	assert_true(RouteCodec.pack(route).has("samples"), "bez stratnego zlania czasów")
