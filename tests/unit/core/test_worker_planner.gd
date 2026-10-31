extends "res://tests/framework/test_case.gd"
## Pracownik: krzywe Dubinsa i planista „wężyka” (pokrycie pola, zawroty omijające przeszkody).

const Dubins = preload("res://scripts/core/worker/dubins.gd")
const WorkerRig = preload("res://scripts/core/worker/worker_rig.gd")
const Planner = preload("res://scripts/core/worker/field_planner.gd")
const Sample = preload("res://scripts/core/routes/route_sample.gd")

const FIELD_ORIGIN := Vector2(100, 40)
const FIELD_SIZE := Vector2(60, 80)
const SETTINGS := {"turn_radius_factor": 1.5, "min_turn_radius_m": 6.0, "lane_overlap_m": 0.3,
	"tool_margin_m": 0.5, "towed_lead_in_factor": 3.0, "mounted_lead_in_m": 2.0,
	"headland_depths_lanes": [1, 2, 3], "radius_factors": [1.0, 1.3, 1.7],
	"turn_sample_m": 0.3, "pass_sample_m": 1.0, "accel_m_s2": 0.8,
	"turn_speed_kmh": 7.0, "approach_speed_kmh": 10.0}


func _combine() -> RefCounted:
	var rig = WorkerRig.new()
	rig.pivot_y = -1.9
	rig.wheelbase = 4.1
	rig.max_steer = deg_to_rad(45.0)
	rig.tool_kind = "rigid_mounted"
	rig.work_center = Vector2(0, -3.6)
	rig.work_width = 8.4
	rig.work_length = 0.8
	return rig


func _cultivator() -> RefCounted:
	var rig = WorkerRig.new()
	rig.pivot_y = 1.25
	rig.wheelbase = 2.6
	rig.max_steer = deg_to_rad(45.0)
	rig.tool_kind = "towed_single_axle"
	rig.socket = Vector2(0, 2.45)
	rig.plug = Vector2(0, -2.4)
	rig.tool_axle = Vector2(0, 0.6)
	rig.work_center = Vector2.ZERO
	rig.work_width = 8.0
	rig.work_length = 1.4
	return rig


func _planner(rig: RefCounted) -> RefCounted:
	var planner = Planner.new()
	planner.settings = SETTINGS
	planner.rig = rig
	planner.world_rect = Rect2(0, 0, 240, 280)
	return planner


func test_dubins_paths_reach_goal() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 60:
		var start := Vector3(rng.randf_range(-20, 20), rng.randf_range(-20, 20), rng.randf_range(-PI, PI))
		var goal := Vector3(rng.randf_range(-20, 20), rng.randf_range(-20, 20), rng.randf_range(-PI, PI))
		var found: Array = Dubins.paths(start, goal, 5.0)
		assert_true(found.size() >= 1, "brak ścieżki %d" % i)
		var straight: float = Vector2(start.x, start.y).distance_to(Vector2(goal.x, goal.y))
		assert_true(float(found[0]["length"]) >= straight - 0.001)
		var end: Vector3 = Dubins.sample(start, found[0]["segments"], 5.0, 0.2)[-1]
		assert_near(end.x, goal.x, 0.05)
		assert_near(end.y, goal.y, 0.05)


func test_u_turn_wider_than_turn_circle_is_half_circle() -> void:
	# Pas o 12 m dalej przy R = 6: zawrót to pół okręgu (π·R).
	var found: Array = Dubins.paths(Vector3(0, 0, -PI / 2), Vector3(12, 0, PI / 2), 6.0)
	assert_near(float(found[0]["length"]), PI * 6.0, 0.01)


func test_rig_geometry() -> void:
	assert_near(_combine().work_offset(), 1.7, 0.001, "heder 1,7 m przed przednią osią")
	assert_near(_cultivator().work_offset(), -3.6, 0.001, "kultywator 3,6 m za tylną osią")
	assert_near(_cultivator().tool_length(), 3.0, 0.001)
	var rig = _cultivator()
	var pose: Vector3 = rig.vehicle_pose(Vector3(10, 20, -PI / 2))
	assert_near(pose.y, 20 - 1.25, 0.001, "środek ciągnika przed tylną osią")
	var back: Vector3 = rig.path_pose(Vector2(pose.x, pose.y), pose.z)
	assert_near(back.y, 20.0, 0.001)


## Pokrycie: każdy punkt siatki 1 m wewnątrz pola leży w obszarze roboczym jakiegoś odcinka pracy.
func _uncovered(planner: RefCounted, samples: Array) -> int:
	var segments: Array = []
	for i in range(samples.size() - 1):
		if float(samples[i][Sample.TOOL_WORKING]) < 0.5:
			continue
		var points: Array = []
		for sample in [samples[i], samples[i + 1]]:
			var vehicle := Vector3(sample[1], sample[2], sample[3])
			var tool_rot: float = vehicle.z + float(sample[4])
			points.append([planner.rig.work_point(vehicle, tool_rot), tool_rot])
		segments.append(points)
	var missing: int = 0
	var half: float = planner.rig.work_width * 0.5
	for x in range(1, int(FIELD_SIZE.x)):
		for y in range(1, int(FIELD_SIZE.y)):
			var p: Vector2 = FIELD_ORIGIN + Vector2(x, y)
			var covered: bool = false
			for segment in segments:
				var a: Vector2 = segment[0][0]
				var b: Vector2 = segment[1][0]
				var axis: Vector2 = WorkerRig.forward(float(segment[0][1]))
				var side := Vector2(-axis.y, axis.x)
				var along: float = (p - a).dot((b - a).normalized()) if a.distance_to(b) > 0.001 else 0.0
				if along >= -0.7 and along <= a.distance_to(b) + 0.7 and absf((p - a).dot(side)) <= half:
					covered = true
					break
			if not covered:
				missing += 1
	return missing


func test_combine_covers_whole_field_in_snake() -> void:
	var planner = _planner(_combine())
	var ok: bool = planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(105, 130), 0.0, 0.0)
	assert_true(ok, planner.last_error)
	assert_eq(planner.stats["passes"], 8, "60 m / (8,4 − 0,3) m = 8 pasów")
	assert_eq(planner.stats["headland_turns"], 0)
	var samples: Array = planner.samples(10.0 / 3.6)
	assert_eq(_uncovered(planner, samples), 0)
	for i in range(1, samples.size()):
		assert_true(float(samples[i][0]) > float(samples[i - 1][0]), "czas rośnie")
		var step: float = Vector2(samples[i][1], samples[i][2]).distance_to(Vector2(samples[i - 1][1], samples[i - 1][2]))
		assert_true(step < 1.2, "bez skoków pozy (%.2f m w próbce %d)" % [step, i])
	assert_true(planner.path[1][1] == "approach" and planner.path.size() > 10)
	var first_turn: float = 0.0
	for entry in planner.path:
		if entry[1] != "approach":
			break
		first_turn = maxf(first_turn, absf(angle_difference(-PI / 2, entry[0].z)))
	assert_true(first_turn < deg_to_rad(30.0), "kombajn w linii pasa: dojazd łagodnym S, bez pętli")


func test_towed_tool_is_straight_while_working() -> void:
	var planner = _planner(_cultivator())
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(155, 128), 0.0, 0.0), planner.last_error)
	var samples: Array = planner.samples(12.0 / 3.6)
	var worst: float = 0.0
	for sample in samples:
		if float(sample[Sample.TOOL_WORKING]) > 0.5:
			worst = maxf(worst, absf(float(sample[4])))
	assert_true(rad_to_deg(worst) < 3.0, "narzędzie wyprostowane podczas pracy (%.1f°)" % rad_to_deg(worst))
	assert_eq(_uncovered(planner, samples), 0)


func test_turns_avoid_parked_machine() -> void:
	# Maszyna stoi 8 m nad górną krawędzią pola, w połowie szerokości.
	var obstacle := Rect2(122, 26, 12, 8)
	var planner = _planner(_cultivator())
	planner.is_free = func(samples: Array) -> bool:
		for sample in samples:
			var vehicle := Vector3(sample[1], sample[2], sample[3])
			var tool_rot: float = vehicle.z + float(sample[4])
			for point in [Vector2(vehicle.x, vehicle.y), planner.rig.work_point(vehicle, tool_rot)]:
				if obstacle.grow(2.0).has_point(point):
					return false
		return true
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(155, 128), 0.0, 0.0), planner.last_error)
	assert_true(planner.stats["headland_turns"] > 0, "zawroty przy maszynie przeniesione na uwrocie")
	assert_true(planner.stats["cleanup_passes"] > 0, "uwrocie obrobione na końcu")
	var samples: Array = planner.samples(12.0 / 3.6)
	assert_true(bool(planner.is_free.call(samples)), "żadna poza nie wjeżdża w maszynę")
	assert_eq(_uncovered(planner, samples), 0, "całe pole obrobione mimo przeszkody")
	planner.is_free = Callable()     # lambda trzyma planistę – zrywamy cykl referencji


func test_skips_lanes_that_need_no_work() -> void:
	var planner = _planner(_combine())
	# Lewa połowa pola już zebrana.
	planner.needs_work = func(center: Vector2, _rot: float, _size: Vector2) -> bool: return center.x > 130.0
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(105, 130), 0.0, 0.0))
	assert_eq(planner.stats["passes"], 4)
	assert_eq(planner.stats["skipped"], 4)
	planner.needs_work = func(_c: Vector2, _r: float, _s: Vector2) -> bool: return false
	assert_false(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(105, 130), 0.0, 0.0))
	assert_eq(planner.last_error, "To pole nie wymaga tej pracy.")
