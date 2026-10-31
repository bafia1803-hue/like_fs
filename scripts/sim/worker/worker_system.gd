extends Node2D
## Pracownik (warstwa gry, tylko logika 2D): gracz podjeżdża zestawem (pojazd + podpięte
## narzędzie) do pola i naciska H – pracownik obrabia pole wężykiem, sam zawraca i omija stojące
## maszyny. Drugie H odwołuje pracownika (zestaw płynnie hamuje).
##
## Podział pracy:
##   – core/worker/field_planner.gd planuje pasy, zawroty i dojazd (czysta logika),
##   – ten system dostarcza mu model zestawu (wymiary z katalogu i z podpiętych maszyn),
##     informację, które pasy wymagają pracy (komórki pola), i test kolizji kandydatów
##     (bryły całego zestawu przeciągnięte po ścieżce, zapytania do fizyki – stojące maszyny,
##     budynki),
##   – plan jedzie przez RouteSystem jak nagrana trasa (start_generated): ten sam ogranicznik
##     prędkości, praca narzędzia, pauza przy przeszkodzie, która pojawi się w trakcie jazdy,
##   – nadzór: pełny zbiornik kombajnu albo pusty siewnik/rozsiewacz zatrzymuje pracownika;
##     ponowne H planuje tylko pasy, które jeszcze wymagają pracy,
##   – zestaw stoi przed przeszkodą dłużej niż replan_after_s (np. dwa zestawy zablokowały się
##     na drodze między polami): pracownik planuje od nowa z miejsca, w którym stoi – przeszkoda
##     jest już w teście kolizji, więc nowy plan ją omija (najwyżej max_replans razy z rzędu).
## Włącznik całej funkcji: files/workers.json (sim/worker/worker_feature.gd).

signal message(text: String)

const Machines = preload("res://scripts/sim/machines/machines.gd")
const WorkerRig = preload("res://scripts/core/worker/worker_rig.gd")
const Planner = preload("res://scripts/core/worker/field_planner.gd")
const WorkerRules = preload("res://scripts/core/worker/worker_rules.gd")
const StorageRules = preload("res://scripts/core/storage/storage_rules.gd")
const FieldRules = preload("res://scripts/core/field/field_work_rules.gd")
const Collision = preload("res://scripts/sim/routes/route_collision.gd")
const Vec = preload("res://scripts/core/util/vec.gd")
const RouteData = preload("res://scripts/core/routes/route_data.gd")

var settings: Dictionary = {}
## Pracujące zestawy: pojazd → {"field", "operation", "preview", "passes"}.
var jobs: Dictionary = {}
## Rośnie przy każdej zmianie planów (widok 2D odświeża podgląd).
var revision: int = 0
var last_plan_ms: float = 0.0
var _context: RefCounted
var _units: float = 40.0
var _collision = Collision.new()
var _collision_settings: Dictionary = {}
var _supervise_timer: float = 0.0
## Zestawy w trakcie ponownego planowania (zatrzymanie starej trasy nie kończy pracy).
var _pending_replans: Dictionary = {}
## Najbliższa droga pracujących zestawów: pojazd → osłony (route_collision.gd).
var _corridors: Dictionary = {}
var _corridor_timer: float = 0.0


func setup(context: RefCounted, worker_settings: Dictionary) -> void:
	name = "Workers"
	_context = context
	_units = context.units
	settings = worker_settings
	_collision_settings = context.config.routes.duplicate()
	_collision_settings["collision_margin_m"] = float(settings.get("collision_margin_m", 0.3))
	_collision_settings["collision_step_m"] = float(settings.get("collision_step_m", 0.25))
	_collision_settings["collision_step_degrees"] = float(settings.get("collision_step_degrees", 2.0))
	_collision_settings["max_collision_steps_per_tick"] = 1000000
	context.routes.task_ended.connect(_on_task_ended)
	context.field_work.work_message.connect(_on_work_message)


## Klawisz H: zatrudnia albo odwołuje pracownika sterowanego pojazdu.
func toggle(vehicle: RigidBody2D) -> String:
	if not is_instance_valid(vehicle):
		return ""
	if jobs.has(vehicle):
		return dismiss(vehicle)
	return hire(vehicle)


func dismiss(vehicle: RigidBody2D) -> String:
	if not jobs.has(vehicle):
		return ""
	_context.routes.request_stop(vehicle, "Pracownik odwołany.")
	return "Pracownik kończy – zestaw zwalnia i staje."


func hire(vehicle: RigidBody2D) -> String:
	if Machines.on_route(vehicle) and Machines.route_mode(vehicle) == "playing":
		return "Ten pojazd jedzie już trasą."
	var plan: Dictionary = _make_plan(vehicle, null)
	if plan.has("error"):
		return str(plan["error"])
	return _launch(vehicle, plan, 0)


## Plan pracy zestawu: {"route", "field", "operation", "preview", "stats", "warning"} albo {"error"}.
## field – pole narzucone (ponowne planowanie w trakcie pracy), null – pole przed zestawem.
func _make_plan(vehicle: RigidBody2D, field: Node2D) -> Dictionary:
	var rig = _context.routes.rig_for(vehicle)
	if rig == null:
		return {"error": str(_context.routes.last_error)}
	var tool: Node2D = rig.tool
	var problem: String = WorkerRules.rig_problem(rig.kind, tool != null and Machines.has_work(tool))
	if not problem.is_empty():
		return {"error": problem}
	var work: Dictionary = Machines.model(tool)["work"]
	var operation: String = str(work["operation"])
	if field == null:
		# Pole przed zestawem: liczymy od punktu kilka metrów przed pojazdem (dwa pola po obu
		# stronach drogi – wybierane jest to, w którego stronę pojazd jest zwrócony).
		var ahead: Vector2 = vehicle.global_position / _units + WorkerRig.forward(vehicle.global_rotation) * float(settings.get("field_look_ahead_m", 8.0))
		field = _nearest_field(ahead)
		if field == null:
			return {"error": "Podjedź bliżej pola (do %.0f m od krawędzi)." % float(settings.get("max_field_distance_m", 40.0))}
	if not bool(field.owned):
		return {"error": "%s nie jest twoje – najpierw je kup." % str(field.field_name)}
	for other in jobs:
		if other != vehicle and jobs[other]["field"] == field:
			return {"error": "Na polu %s pracuje już inny pracownik." % str(field.field_name)}
	problem = _supply_problem(vehicle, tool, operation)
	if not problem.is_empty():
		return {"error": problem}
	var model = _rig_model(vehicle, rig)
	if model == null:
		return {"error": "Ten pojazd nie ma skrętnej osi – pracownik nim nie pojedzie."}
	_use_unfolded_shapes(rig, tool)
	var planner = Planner.new()
	planner.settings = settings
	planner.rig = model
	planner.world_rect = _context.world_rect_m
	planner.needs_work = func(center: Vector2, rot: float, size: Vector2) -> bool:
		return _strip_needs(field, operation, center, rot, size)
	planner.is_free = func(samples: Array) -> bool:
		return _free(rig, samples)
	var started: int = Time.get_ticks_usec()
	var tool_rot: float = rig.bodies[1].global_rotation if model.towed() else vehicle.global_rotation
	var ok: bool = planner.plan(field.global_position / _units, Vector2(field.columns, field.rows) * float(field.cell_m),
		field.global_rotation, vehicle.global_position / _units, vehicle.global_rotation, tool_rot)
	last_plan_ms = (Time.get_ticks_usec() - started) / 1000.0
	# Lambdy trzymają planistę i zestaw – zrywamy cykl referencji.
	planner.needs_work = Callable()
	planner.is_free = Callable()
	if not ok:
		return {"error": planner.last_error}
	var speed_cap: float = minf(float(settings.get("work_speed_kmh", 12.0)), FieldRules.speed_cap_kmh(Machines.model(tool), true))
	var fold_now: float = Machines.fold_progress(tool) if Machines.is_foldable(tool) else 1.0
	var fold_seconds: float = float(tool.call("get_fold_seconds")) if Machines.is_foldable(tool) and tool.has_method("get_fold_seconds") else 0.0
	var samples: Array = planner.samples(speed_cap / 3.6, fold_now, fold_seconds)
	var route: Dictionary = {"version": 4, "id": "worker_%s_%d" % [Machines.id(vehicle), Time.get_ticks_usec()],
		"name": "Pracownik: " + str(field.field_name), "map_id": "", "signature": {}, "samples": samples}
	return {"route": route, "field": field, "operation": operation, "preview": planner.preview(),
		"stats": planner.stats.duplicate(), "warning": planner.warning}


## Uruchamia plan (trasa w RouteSystem) i zapisuje pracę zestawu. Zwraca komunikat dla gracza.
func _launch(vehicle: RigidBody2D, plan: Dictionary, replans: int) -> String:
	var error: String = _context.routes.start_generated(vehicle, plan["route"])
	if not error.is_empty():
		return error
	var stats: Dictionary = plan["stats"]
	jobs[vehicle] = {"field": plan["field"], "operation": plan["operation"], "preview": plan["preview"],
		"passes": int(stats["passes"]), "paused_s": 0.0, "replans": replans}
	revision += 1
	var samples: Array = plan["route"]["samples"]
	var text: String = "Pracownik: %s – %d pasów, ok. %d min. H odwołuje." % [str(plan["field"].field_name),
		int(stats["passes"]), ceili(float(samples[-1][0]) / 60.0)]
	if int(stats["headland_turns"]) > 0:
		text += " Przy przeszkodach zawraca na uwrociu (obrobi je na końcu)."
	if not str(plan["warning"]).is_empty():
		text += " " + str(plan["warning"])
	return text


## Linie planów do podglądu w widoku 2D: [{"kind", "points"}] (metry).
func preview_lines() -> Array:
	var result: Array = []
	for vehicle in jobs:
		result.append_array(jobs[vehicle]["preview"])
	return result


func _on_task_ended(vehicle: RigidBody2D, reason: String, completed: bool) -> void:
	if not jobs.has(vehicle):
		return
	var job: Dictionary = jobs[vehicle]
	jobs.erase(vehicle)
	revision += 1
	if _pending_replans.has(vehicle):
		return
	if completed:
		message.emit("Pracownik skończył: %s." % str(job["field"].field_name))
	elif reason != "Pracownik odwołany.":
		message.emit("Pracownik przerwał pracę: " + reason)


## Praca na polu odmówiła (inne ziarno w zbiorniku, pusty siewnik, pole nie nasze…):
## pracownik zatrzymuje się z tym komunikatem zamiast jeździć na pusto.
func _on_work_message(vehicle: RigidBody2D, text: String) -> void:
	if jobs.has(vehicle) and not text.is_empty() and not _context.routes.is_stopping(vehicle):
		_context.routes.request_stop(vehicle, text + " Potem H wznawia pracę.")


# ---------------------------------------------------------------------------
# Nadzór: zbiorniki
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_supervise_timer += delta
	if jobs.is_empty():
		_corridors.clear()
		return
	_corridor_timer += delta
	if _corridor_timer >= float(settings.get("look_ahead_interval_s", 0.25)):
		_corridor_timer = 0.0
		for vehicle in _corridors.keys():
			if not jobs.has(vehicle):
				_corridors.erase(vehicle)
		for vehicle in jobs:
			_update_corridor(vehicle)
		_update_holds()
	if _supervise_timer < 0.5:
		return
	_supervise_timer = 0.0
	for vehicle in jobs.keys():
		if not is_instance_valid(vehicle) or _context.routes.is_stopping(vehicle):
			continue
		var rig = _context.routes.tasks.get(vehicle, {}).get("rig")
		if rig == null or rig.tool == null:
			continue
		var problem: String = _supply_problem(vehicle, rig.tool, str(jobs[vehicle]["operation"]))
		if not problem.is_empty():
			_context.routes.request_stop(vehicle, problem + " Potem H wznawia pracę.")
			continue
		var job: Dictionary = jobs[vehicle]
		var playback = _context.routes.tasks[vehicle]["playback"]
		if int(job["replans"]) > 0 and playback.distance_at(playback.time) > 40.0:
			job["replans"] = 0      # pojechał dalej – kolejne przeszkody liczą się od nowa
		job["paused_s"] = float(job["paused_s"]) + 0.5 if bool(_context.routes.tasks[vehicle].get("paused", false)) else 0.0
		if float(job["paused_s"]) >= float(settings.get("replan_after_s", 5.0)):
			job["paused_s"] = 0.0
			call_deferred("_replan", vehicle)


## Nowy plan z miejsca, w którym zestaw stoi przed przeszkodą (zablokowany zawrót albo dojazd).
## Planowany, zanim stara trasa się zatrzyma: gdy nowej drogi nie ma, zestaw dalej czeka
## i próbuje ponownie (najwyżej max_replans razy z rzędu).
func _replan(vehicle: RigidBody2D) -> void:
	if not jobs.has(vehicle) or not _context.routes.tasks.has(vehicle):
		return
	var job: Dictionary = jobs[vehicle]
	var count: int = int(job.get("replans", 0)) + 1
	var plan: Dictionary = _make_plan(vehicle, job["field"])
	if plan.has("error"):
		if count >= int(settings.get("max_replans", 3)):
			_context.routes.stop(vehicle, "Pracownik nie znalazł wolnej drogi – przestaw maszyny i naciśnij H.")
		else:
			job["replans"] = count
		return
	_pending_replans[vehicle] = true
	_context.routes.stop(vehicle, "Pracownik szuka innej drogi.", true)
	var text: String = _launch(vehicle, plan, count)
	_pending_replans.erase(vehicle)
	if not jobs.has(vehicle):
		message.emit("%s: pracownik nie ruszył – %s" % [Machines.id(vehicle), text])
	else:
		message.emit("%s: przeszkoda – pracownik wybrał inną drogę." % Machines.id(vehicle))


## Brak materiału albo miejsca w zbiorniku (pusty = można pracować).
func _supply_problem(vehicle: RigidBody2D, tool: Node2D, operation: String) -> String:
	var work: Dictionary = Machines.model(tool)["work"]
	match operation:
		"sow", "fertilize":
			var storage_id: String = str(work.get("input", {}).get("storage_id", ""))
			var storage: Dictionary = Machines.state(tool).get("storages", {}).get(storage_id, {})
			if float(storage.get("amount_l", 0.0)) < float(settings.get("min_supply_l", 1.0)):
				return "Pusty zbiornik narzędzia – uzupełnij go na stacji."
		"harvest":
			var storage_id: String = str(work.get("output", {}).get("storage_id", ""))
			var storage: Dictionary = Machines.state(vehicle).get("storages", {}).get(storage_id, {})
			var definition: Dictionary = StorageRules.storage_definition(Machines.model(vehicle), storage_id)
			var capacity: float = float(definition.get("capacity_l", 0.0))
			if capacity > 0.0 and float(storage.get("amount_l", 0.0)) >= capacity * float(settings.get("full_tank_ratio", 0.97)):
				return "Zbiornik ziarna pełny – rozładuj go."
	return ""


# ---------------------------------------------------------------------------
# Pole, model zestawu, kolizje
# ---------------------------------------------------------------------------

func _nearest_field(point: Vector2) -> Node2D:
	var best: Node2D = null
	var best_distance: float = float(settings.get("max_field_distance_m", 40.0))
	for field in _context.field_work.fields:
		var local: Vector2 = field.global_transform.affine_inverse() * (point * _units) / _units
		var size := Vector2(field.columns, field.rows) * float(field.cell_m)
		var nearest := Vector2(clampf(local.x, 0.0, size.x), clampf(local.y, 0.0, size.y))
		var distance: float = local.distance_to(nearest)
		if distance <= best_distance:
			best_distance = distance
			best = field
	return best


func _strip_needs(field: Node2D, operation: String, center: Vector2, rot: float, size: Vector2) -> bool:
	var cells: PackedInt32Array = field.cells_in_rectangle(Transform2D(rot, center * _units), size)
	return WorkerRules.strip_needs(operation, cells, field.cells.states, field.cells.fertilized)


## Model kinematyczny z katalogu (osie, zaczepy) i z podpiętych maszyn (położenie obszaru roboczego).
func _rig_model(vehicle: RigidBody2D, rig: RefCounted) -> RefCounted:
	var model: Dictionary = Machines.model(vehicle)
	var length: float = float(model["dimensions"]["length_m"])
	var fixed: Array = []
	var steer_y: float = 0.0
	var max_steer: float = 0.0
	for axle in model["axles"]:
		var y: float = -length * 0.5 + float(axle["distance_from_front_m"])
		if bool(axle.get("steerable", false)) and float(axle.get("max_steering_deg", 0.0)) > 0.0:
			if float(axle["max_steering_deg"]) > max_steer:
				max_steer = float(axle["max_steering_deg"])
				steer_y = y
		else:
			fixed.append(y)
	if fixed.is_empty() or max_steer <= 0.0:
		return null
	var result = WorkerRig.new()
	var pivot: float = 0.0
	for y in fixed:
		pivot += float(y)
	result.pivot_y = pivot / fixed.size()
	result.wheelbase = maxf(0.5, absf(steer_y - result.pivot_y))
	result.max_steer = deg_to_rad(max_steer)
	var tool: Node2D = rig.tool
	var tool_model: Dictionary = Machines.model(tool)
	var area: Dictionary = tool_model["work"]["area"]
	result.tool_kind = rig.kind
	result.work_width = float(area["width_m"])
	result.work_length = float(area["length_m"])
	var area_local := Transform2D(deg_to_rad(float(area.get("rotation_deg", 0.0))), Vec.v2(area["center_m"]) * _units)
	if rig.kind == "towed_single_axle":
		result.socket = Vec.v2(rig.link["socket"]["position_m"])
		result.plug = Vec.v2(rig.link["plug"]["position_m"])
		var tool_length: float = float(tool_model["dimensions"]["length_m"])
		result.tool_axle = Vector2(0.0, -tool_length * 0.5 + float(tool_model["axles"][0]["distance_from_front_m"]))
		# Obszar roboczy w układzie korpusu narzędzia (get_work_transform = korpus).
		var body: Node2D = rig.bodies[1]
		var in_body: Transform2D = body.global_transform.affine_inverse() * tool.call("get_work_transform") * area_local
		result.work_center = in_body.origin / _units
	else:
		var in_vehicle: Transform2D = vehicle.global_transform.affine_inverse() * tool.call("get_work_transform") * area_local
		result.work_center = in_vehicle.origin / _units
	return result


## Kolizje planowane dla rozłożonego narzędzia (złożone rozłoży się na początku pracy).
func _use_unfolded_shapes(rig: RefCounted, tool: Node2D) -> void:
	if not Machines.is_foldable(tool) or Machines.fold_progress(tool) >= 1.0 or rig.bodies.size() < 2:
		return
	var tool_model: Dictionary = Machines.model(tool)
	var profile: String = str(tool_model.get("folding", {}).get("unfolded_profile", "unfolded"))
	var rects: Array = tool_model["physics"].get("collision_profiles", {}).get(profile, [])
	if rects.is_empty():
		return
	var mask: int = rig.bodies[1].collision_mask
	rig.shapes = rig.shapes.filter(func(shape): return int(shape["body"]) != 1)
	for rect in rects:
		var local := Transform2D(deg_to_rad(float(rect.get("rotation_deg", 0.0))), Vec.v2(rect["center_m"]) * _units)
		var half: Vector2 = Vector2(float(rect["width_m"]), float(rect["length_m"])) * _units * 0.5
		var corners := PackedVector2Array()
		for p in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
			corners.append(local * p)
		rig.shapes.append({"body": 1, "corners": corners, "mask": mask})


## Czy zestaw przejedzie po próbkach bez kolizji ze stojącymi maszynami, budynkami
## i z drogą, którą za chwilę przejadą inni pracownicy (ignore – pojazd, którego drogi nie liczymy).
## Odcinki sprawdzane najpierw co czwarty (kolizja zwykle jest w środku zawrotu – kandydat
## odpada szybciej), potem pozostałe.
func _free(rig: RefCounted, samples: Array, ignore: RigidBody2D = null) -> bool:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var others: Array = []
	for vehicle in _corridors:
		if vehicle != ignore and vehicle != rig.vehicle:
			others.append_array(_corridors[vehicle])
	var windows: Array = _windows(samples)
	var order: Array = []
	for phase in 4:
		for k in range(phase, windows.size(), 4):
			order.append(k)
	for k in order:
		var window: Vector2i = windows[k]
		var volumes: Array = _collision.volumes(rig, samples.slice(window.x, window.y + 1), _collision_settings)
		if volumes.is_empty() or _collision.blocked(space, volumes, rig.excluded()):
			return false
		if not others.is_empty() and _collision.overlap(volumes, others):
			return false
	return true


## Podział próbek na odcinki ok. collision_window_m / 10° (osłona całego zawrotu byłaby zbyt gruba):
## [Vector2i(od, do)] – indeksy próbek.
func _windows(samples: Array) -> Array:
	var result: Array = []
	var window_m: float = float(settings.get("collision_window_m", 1.0))
	var i: int = 0
	while i < samples.size() - 1:
		var j: int = i + 1
		var travelled: float = 0.0
		var turned: float = 0.0
		while j < samples.size() - 1:
			travelled += Vector2(samples[j][1], samples[j][2]).distance_to(Vector2(samples[j - 1][1], samples[j - 1][2]))
			turned += absf(angle_difference(float(samples[j - 1][3]), float(samples[j][3])))
			if travelled >= window_m or turned >= deg_to_rad(10.0):
				break
			j += 1
		result.append(Vector2i(i, j))
		i = j
	return result


## Osłony ruchu zestawu odcinkami (lista wyników RouteCollision.volumes; pusty = błąd).
func _volumes_along(rig: RefCounted, samples: Array) -> Array:
	var result: Array = []
	for window in _windows(samples):
		result.append(_collision.volumes(rig, samples.slice(window.x, window.y + 1), _collision_settings))
	return result


# ---------------------------------------------------------------------------
# Droga przed zestawem (korytarze) i ustępowanie pierwszeństwa
# ---------------------------------------------------------------------------

## Korytarz: osłony najbliższych look_ahead_m drogi zestawu (od obecnej chwili trasy).
func _update_corridor(vehicle: RigidBody2D) -> void:
	var task: Dictionary = _context.routes.tasks.get(vehicle, {})
	if task.is_empty():
		_corridors.erase(vehicle)
		return
	var playback = task["playback"]
	var ahead: float = float(settings.get("look_ahead_m", 10.0))
	var s_now: float = playback.distance_at(playback.time)
	var finish: float = playback.time_at_distance(s_now + ahead, playback.time, playback.duration())
	var samples: Array = RouteData.between(task["route"], playback.time, maxf(finish, playback.time + 0.001), playback.index)
	var corridor: Array = []
	for volumes in _volumes_along(task["rig"], samples):
		corridor.append_array(volumes)
	_corridors[vehicle] = corridor


## Zestaw czeka (zanim podjedzie pod przeszkodę), gdy na jego najbliższej drodze stoi maszyna
## albo przejedzie tamtędy pracownik o wyższym pierwszeństwie (wcześniej zatrudniony).
## Zatrzymanie z wyprzedzeniem zostawia miejsce na nowy plan (replan_after_s).
func _update_holds() -> void:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var earlier: Array = []
	for vehicle in jobs:
		if not _corridors.has(vehicle) or not _context.routes.tasks.has(vehicle):
			continue
		var corridor: Array = _corridors[vehicle]
		var rig = _context.routes.tasks[vehicle]["rig"]
		var reason: String = ""
		if _collision.blocked(space, corridor, rig.excluded()):
			reason = "Pracownik czeka – na drodze stoi maszyna."
		else:
			for other in earlier:
				if _collision.overlap(corridor, _corridors[other]):
					reason = "Pracownik ustępuje drogi: " + Machines.id(other) + "."
					break
		_context.routes.set_hold(vehicle, reason)
		earlier.append(vehicle)
