extends "res://tests/framework/test_case.gd"

const HitchRules = preload("res://scripts/core/hitch/hitch_rules.gd")

const POLICY := {"max_attach_distance_m": 0.4}
const DRAWBAR_SOCKET := {"id": "rear", "role": "socket", "type": "drawbar"}
const DRAWBAR_PLUG := {"id": "eye", "role": "plug", "type": "drawbar"}
const SADDLE := {"id": "saddle", "role": "socket", "type": "fifth_wheel", "attach_distance_m": 3.0, "attach_angle_deg": 30.0}
const KINGPIN := {"id": "kingpin", "role": "plug", "type": "fifth_wheel"}


func test_ports_match() -> void:
	assert_true(HitchRules.ports_match(DRAWBAR_SOCKET, DRAWBAR_PLUG))
	assert_false(HitchRules.ports_match(DRAWBAR_SOCKET, KINGPIN), "inny typ")
	assert_false(HitchRules.ports_match(DRAWBAR_PLUG, DRAWBAR_SOCKET), "odwrócone role")


func test_link_kinds() -> void:
	assert_eq(HitchRules.link_kind("drawbar"), "pin")
	assert_eq(HitchRules.link_kind("fifth_wheel"), "pin")
	assert_eq(HitchRules.link_kind("three_point"), "rigid")
	assert_eq(HitchRules.link_kind("combine_header"), "rigid")
	assert_eq(HitchRules.link_kind("rope"), "")
	assert_true(HitchRules.required_methods("three_point").has("attach_to_carrier"))
	assert_true(HitchRules.required_methods("rope").is_empty())


func test_attach_distance_uses_port_tolerance() -> void:
	assert_eq(HitchRules.attach_distance(POLICY, DRAWBAR_SOCKET, DRAWBAR_PLUG), 0.4)
	assert_eq(HitchRules.attach_distance(POLICY, SADDLE, KINGPIN), 3.0)
	assert_empty(HitchRules.distance_problem(0.3, 0.4))
	assert_has(HitchRules.distance_problem(0.5, 0.4), "Zbliż zaczepy: 0.50 m")


func test_angle_problem_only_for_ports_with_limit() -> void:
	assert_empty(HitchRules.angle_problem(DRAWBAR_SOCKET, 0.0, PI * 0.5))
	assert_empty(HitchRules.angle_problem(SADDLE, 0.0, deg_to_rad(29.0)))
	assert_has(HitchRules.angle_problem(SADDLE, 0.0, deg_to_rad(-40.0)), "różnica 40°")


func test_nearest_prefers_first_on_tie() -> void:
	var best: Dictionary = HitchRules.nearest([{"distance": 2.0, "id": "a"}, {"distance": 1.0, "id": "b"}, {"distance": 1.0, "id": "c"}])
	assert_eq(best["id"], "b")
	assert_true(HitchRules.nearest([]).is_empty())
