extends "res://tests/framework/test_case.gd"

const LotPlanner = preload("res://scripts/core/shop/lot_planner.gd")
const Footprint = preload("res://scripts/core/shop/machine_footprint.gd")
const InstanceFactory = preload("res://scripts/core/shop/instance_factory.gd")
const AxleGroups = preload("res://scripts/core/machines/axle_groups.gd")
const TireModel = preload("res://scripts/core/machines/tire_model.gd")
const TimeFormat = preload("res://scripts/core/util/time_format.gd")
const Vec = preload("res://scripts/core/util/vec.gd")

const TRAILER := {"id": "trailer_basic", "category": "trailer", "physics_kind": "towed_turntable",
	"dimensions": {"width_m": 2.0, "length_m": 4.0},
	"axles": [{"distance_from_front_m": 1.0, "track_m": 1.8, "tire_width_m": 0.4, "tire_length_m": 1.0}],
	"hitch_ports": [], "storage_definitions": [{"id": "cargo"}]}


func test_lot_planner_rows_and_full_lot() -> void:
	var lot := Rect2(0, 0, 10, 4)
	var footprint := Rect2(-1, -1, 2, 2)
	var first: Variant = LotPlanner.find_spot(lot, footprint, [], 1.0)
	assert_eq(first, Vector2(1, 1))
	var second: Variant = LotPlanner.find_spot(lot, footprint, [Rect2(0, 0, 2, 2)], 1.0)
	assert_eq(second, Vector2(4, 1), "za zajętym miejscem + odstęp")
	assert_eq(LotPlanner.find_spot(lot, Rect2(-6, -1, 12, 2), [], 1.0), null, "za duża maszyna")


func test_footprint_includes_wheels_and_rotation() -> void:
	var local: Rect2 = Footprint.local_rect(TRAILER)
	assert_near(local.position.x, -1.1)
	assert_near(local.size.y, 4.0)
	var turned: Rect2 = Footprint.world_aabb(local, Vector2(10, 10), PI * 0.5)
	assert_near(turned.size.x, 4.0)
	assert_near(turned.get_center().y, 10.0)


func test_instance_factory() -> void:
	assert_eq(InstanceFactory.next_id("trailer", {"trailer_01": 1, "trailer_03": 1}), "trailer_02")
	var state: Dictionary = InstanceFactory.new_state(TRAILER, "trailer_02", Vector2(3, 4), PI)
	assert_eq(state["transform"]["position_m"], [3.0, 4.0])
	assert_near(state["transform"]["rotation_deg"], 180.0)
	assert_eq(state["storages"], {"cargo": {"material_id": null, "amount_l": 0.0}})
	assert_true(state["articulated_state"].has("front_carriage"), "przyczepa z wózkiem")
	assert_eq(state["work_state"], null)


func test_axle_groups_merge_tandem() -> void:
	var axles: Array = AxleGroups.physical([
		{"id": "front", "steerable": true, "distance_from_front_m": 1.0, "load_weight": 1.0},
		{"id": "r1", "tandem_group": "rear", "distance_from_front_m": 5.0, "track_m": 2.0, "load_weight": 1.0, "driven": true},
		{"id": "r2", "tandem_group": "rear", "distance_from_front_m": 6.4, "track_m": 2.0, "load_weight": 1.0, "carries_coupled_load": true}])
	assert_eq(axles.size(), 2)
	assert_eq(axles[1]["id"], "rear")
	assert_near(axles[1]["distance_from_front_m"], 5.7)
	assert_eq(axles[1]["load_weight"], 2.0)
	assert_true(axles[1]["driven"] and axles[1]["carries_coupled_load"])


func _body(velocity: Vector2) -> Dictionary:
	return {"linear_velocity": velocity, "angular_velocity": 0.0, "inverse_mass": 1.0 / 1000.0,
		"inverse_inertia": 0.0, "step": 1.0 / 60.0}


func test_tire_grip_limits_force() -> void:
	var force: Vector2 = TireModel.wheel_force(_body(Vector2.ZERO), Vector2.ZERO, 0.0, 250.0,
		100000.0, 0.0, 0.0, 0.8, 0.12, 4, 40.0)
	assert_near(force.length() / 40.0, 250.0 * 9.81 * 0.8, 0.01, "napęd ograniczony przyczepnością")
	assert_true(force.y < 0.0, "do przodu (−y)")


func test_tire_lateral_force_does_not_overshoot() -> void:
	# Koło przesuwa się bokiem 1 m/s: siła boczna co najwyżej zatrzymuje ruch w jednym kroku.
	var body: Dictionary = _body(Vector2(40.0, 0.0))
	body["inverse_mass"] = 1.0 / 10.0
	var force: Vector2 = TireModel.wheel_force(body, Vector2.ZERO, 0.0, 250.0, 0.0, 0.0, 0.0, 10.0, 0.0001, 1, 40.0)
	var delta_v_m: float = force.x / 40.0 * float(body["inverse_mass"]) * float(body["step"])
	assert_near(delta_v_m, -1.0, 0.0001)


func test_time_format_and_vectors() -> void:
	assert_eq(TimeFormat.play_time(0.0), "0:00")
	assert_eq(TimeFormat.play_time(3725.0), "1:02")
	assert_eq(TimeFormat.play_time(360000.0), "100:00")
	assert_eq(Vec.v2([1, 2.5]), Vector2(1, 2.5))
	assert_true(Vec.is_pair([1, 2]))
	assert_false(Vec.is_pair([1, "a"]))
