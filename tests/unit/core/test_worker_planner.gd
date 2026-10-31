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
	"radius_factors": [1.0, 1.3, 1.7],
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


func test_combine_covers_field_in_snake() -> void:
	# Kombajn stoi na linii pierwszego pasa (przy krawędzi pola): jedzie prosto i dalej wężykiem.
	var planner = _planner(_combine())
	var ok: bool = planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(104.2, 130), 0.0, 0.0)
	assert_true(ok, planner.last_error)
	assert_eq(planner.stats["passes"], 8, "60 m: 7 pasów co 8,1 m + wąski pasek")
	assert_false(planner.stats["stopped_early"])
	var samples: Array = planner.samples(10.0 / 3.6)
	assert_true(_uncovered(planner, samples) < 10, "całe pole (%d m² zostało)" % _uncovered(planner, samples))
	for i in range(1, samples.size()):
		assert_true(float(samples[i][0]) > float(samples[i - 1][0]), "czas rośnie")
		var step: float = Vector2(samples[i][1], samples[i][2]).distance_to(Vector2(samples[i - 1][1], samples[i - 1][2]))
		assert_true(step < 1.2, "bez skoków pozy (%.2f m w próbce %d)" % [step, i])


func _first_work_distance(planner: RefCounted) -> float:
	var start: Vector3 = planner.path[0][0]
	for entry in planner.path:
		if bool(entry[2]):
			return Vector2(start.x, start.y).distance_to(Vector2(entry[0].x, entry[0].y))
	return INF


func test_starts_straight_where_vehicle_stands() -> void:
	# Krzywo o 6°, w środku szerokości pola, przed krawędzią: linia pasa przez pojazd, praca od razu
	# po wjeździe na pole – bez dojazdu do krawędzi pola z boku.
	var planner = _planner(_cultivator())
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(131, 124), deg_to_rad(6.0), deg_to_rad(6.0)), planner.last_error)
	var lane_x: float = planner.passes_info[0]["from"].x
	assert_near(lane_x, 131.0 + sin(deg_to_rad(6.0)) * 1.25, 0.6, "pierwszy pas przez pojazd")
	assert_true(_first_work_distance(planner) < 3.0, "pracuje od razu (%.1f m)" % _first_work_distance(planner))
	var second: Vector2 = planner.passes_info[1]["from"]
	assert_near(absf(second.x - lane_x), 7.7, 0.05, "następny pas tuż obok (szerokość − zakładka)")


func test_resume_in_the_middle_of_a_lane() -> void:
	# Zatrzymany w połowie pasa i wznowiony: jedzie dalej prosto od miejsca postoju.
	var planner = _planner(_combine())
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(120.4, 80), 0.0, 0.0), planner.last_error)
	assert_true(_first_work_distance(planner) < 1.5, "praca od miejsca postoju (%.1f m)" % _first_work_distance(planner))
	assert_near(planner.passes_info[0]["from"].x, 120.4, 0.05)
	assert_true(planner.passes_info[0]["to"].y < 45.0, "do końca pola przed sobą")


func test_narrow_last_strip_is_centered() -> void:
	var planner = _planner(_combine())
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(104.2, 130), 0.0, 0.0))
	# 7 pasów co 8,1 m od krawędzi kończy się na 156,7 m – zostaje pasek 3,3 m: narzędzie jego środkiem.
	assert_near(float(planner.passes_info[-1]["from"].x), 156.7 + (160.0 - 156.7) * 0.5, 0.3)


func test_partial_plan_continues_from_state() -> void:
	var planner = _planner(_combine())
	planner.max_lanes = 2
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(104.2, 130), 0.0, 0.0))
	assert_eq(planner.stats["passes"], 2)
	assert_true(planner.state["open"], "są dalsze pasy")
	var last: Array = planner.samples(3.0, 1.0, 0.0, false, true)[-1]
	var next = _planner(_combine())
	next.max_lanes = 2
	assert_true(next.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(last[1], last[2]), last[3], last[3], planner.state), next.last_error)
	assert_near(next.passes_info[0]["from"].x, 104.2 + 2 * 8.1, 0.05, "trzeci pas obok drugiego")


func test_work_ends_where_cells_end() -> void:
	# Tylko górna połowa pola wymaga pracy (np. siewnik za kultywatorem): pasy kończą się w połowie
	# pola i tam jest zawrót.
	var planner = _planner(_combine())
	planner.profile = func(a: Vector2, b: Vector2, _width: float, bins: int) -> PackedFloat32Array:
		var result := PackedFloat32Array()
		for i in bins:
			var point: Vector2 = a.lerp(b, (i + 0.5) / bins)
			result.append(1.0 if point.y <= 80.0 else 0.0)
		return result
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(105, 30), PI, PI), planner.last_error)
	var lowest: float = 0.0
	for entry in planner.path:
		if bool(entry[2]):
			lowest = maxf(lowest, entry[0].y)
	assert_true(lowest < 86.0 and lowest > 76.0, "praca kończy się przy granicy (%.1f)" % lowest)
	planner.profile = Callable()


func test_reverse_maneuver_when_turn_is_blocked() -> void:
	# Ściana 6 m za krawędzią pola (cała szerokość): do przodu zawrotu nie ma, jest z cofaniem.
	var planner = _planner(_combine())
	planner.is_free = func(samples: Array) -> bool:
		for sample in samples:
			var vehicle := Vector3(sample[1], sample[2], sample[3])
			for point in [Vector2(vehicle.x, vehicle.y), planner.rig.work_point(vehicle, vehicle.z)]:
				if point.y < 40.0 - 6.0:
					return false
		return true
	assert_true(planner.plan(FIELD_ORIGIN, FIELD_SIZE, 0.0, Vector2(104.2, 130), 0.0, 0.0), planner.last_error)
	assert_true(int(planner.stats["reverse_turns"]) + int(planner.stats["shortened_turns"]) > 0, str(planner.stats))
	var reversing: int = 0
	for entry in planner.path:
		if entry[1] == "reverse":
			reversing += 1
	assert_true(reversing > 0, "zestaw cofa")
	var samples: Array = planner.samples(10.0 / 3.6)
	assert_true(bool(planner.is_free.call(samples)), "żadna poza nie wjeżdża w ścianę")
	planner.is_free = Callable()


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
	var samples: Array = planner.samples(12.0 / 3.6)
	assert_true(bool(planner.is_free.call(samples)), "żadna poza nie wjeżdża w maszynę")
	assert_true(int(planner.stats["passes"]) >= 6, str(planner.stats))
	planner.is_free = Callable()     # lambda trzyma planistę – zrywamy cykl referencji


func test_towed_tool_follows_in_reverse() -> void:
	var rig = _cultivator()
	var vehicle := Vector3(0, 0, 0)
	var tool: float = 0.0
	# Cofanie prosto: narzędzie zostaje w linii.
	for i in 20:
		var next := Vector3(0, vehicle.y + 0.2, 0)
		tool = rig.follow_tool(tool, vehicle, next)
		vehicle = next
	assert_near(tool, 0.0, 0.001)
	# Cofanie ze skrętem: kąt narzędzia rośnie szybciej niż obrót ciągnika (składanie zestawu).
	var start_tool: float = tool
	for i in 20:
		var next := Vector3(vehicle.x + 0.05, vehicle.y + 0.2, vehicle.z + 0.02)
		tool = rig.follow_tool(tool, vehicle, next)
		vehicle = next
	assert_true(absf(angle_difference(vehicle.z, tool)) > 0.25, "kąt narzędzia rośnie przy cofaniu (%.2f)" % angle_difference(vehicle.z, tool))
	assert_true(start_tool == 0.0)


func test_runs_merge_short_gaps() -> void:
	assert_eq(Planner.runs(PackedFloat32Array([0, 1, 1, 0, 1, 1, 1, 0]), 0.5, 0), [Vector2i(1, 2), Vector2i(4, 6)])
	assert_eq(Planner.runs(PackedFloat32Array([0, 1, 1, 0, 1, 1, 1, 0]), 0.5, 1), [Vector2i(1, 6)])
