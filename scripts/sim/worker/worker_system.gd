extends Node2D
## Pracownik (warstwa gry, tylko logika 2D): gracz podjeżdża zestawem (pojazd + podpięte
## narzędzie) do pola i naciska H – pracownik obrabia pole wężykiem, sam zawraca i omija stojące
## maszyny. Drugie H odwołuje pracownika (zestaw płynnie hamuje).
##
## Podział pracy:
##   – core/worker/field_planner.gd planuje pasy, zawroty i dojazd (czysta logika),
##   – ten system dostarcza mu model zestawu (wymiary z katalogu i z podpiętych maszyn), profil
##     pracy pasów (które komórki pola wymagają pracy; pasy zarezerwowane przez innych pracowników
##     tej samej pracy liczą się jako zrobione) i test kolizji kandydatów (bryły całego zestawu
##     przeciągnięte po ścieżce, zapytania do fizyki – stojące maszyny, budynki),
##   – plan jedzie przez RouteSystem jak nagrana trasa (start_generated),
##   – kilku pracowników na jednym polu: każdy rezerwuje swoje pasy (do ich przejechania),
##     drogi pilnują korytarze (kto wcześniej zatrudniony, ten ma pierwszeństwo),
##   – po skończeniu planu pracownik planuje dalej (np. siewnik za kultywatorem: zakultywowana
##     część rośnie); gdy nic nie zostało, ale na polu pracuje zestaw, po którym może coś
##     przybyć (FEEDS), czeka; inaczej kończy. Plan, który niczego nie zmienił – koniec,
##   – nadzór: pełny zbiornik, pusty siewnik/rozsiewacz albo odmowa pracy zatrzymuje pracownika;
##     ponowne H planuje tylko to, co jeszcze wymaga pracy,
##   – zestaw stoi przed przeszkodą dłużej niż replan_after_s: nowy plan z miejsca, w którym stoi.
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
## Pracujące zestawy: pojazd → {"field", "operation", "axis", "preview", "claims", "waiting",
## "remaining", "paused_s", "replans"}.
var jobs: Dictionary = {}
## Rośnie przy każdej zmianie planów (widok 2D odświeża podgląd).
var revision: int = 0
var last_plan_ms: float = 0.0
var _context: RefCounted
var _units: float = 40.0
var _collision = Collision.new()
var _collision_settings: Dictionary = {}
var _supervise_timer: float = 0.0
var _wait_timer: float = 0.0
## Zestawy, których trasa jest właśnie podmieniana (zatrzymanie starej trasy nie kończy pracy).
var _switching: Dictionary = {}
## Najbliższa droga pracujących zestawów: pojazd → osłony (route_collision.gd).
var _corridors: Dictionary = {}
## Czy zestaw jest w trakcie manewru (zawrót, dojazd) – ma wtedy pierwszeństwo.
var _maneuvering: Dictionary = {}
## Osłona obecnej pozy pracujących zestawów (pierwszy odcinek korytarza).
var _bodies_now: Dictionary = {}
var _near: Dictionary = {}           # vehicle -> osłony najbliższych look_ahead_m (stojące przeszkody)
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
	if bool(jobs[vehicle].get("waiting", false)) or not _context.routes.tasks.has(vehicle):
		jobs.erase(vehicle)
		revision += 1
		return "Pracownik odwołany."
	_context.routes.request_stop(vehicle, "Pracownik odwołany.")
	return "Pracownik kończy – zestaw zwalnia i staje."


func hire(vehicle: RigidBody2D) -> String:
	if Machines.on_route(vehicle) and Machines.route_mode(vehicle) == "playing":
		return "Ten pojazd jedzie już trasą."
	var plan: Dictionary = _make_plan(vehicle, null, Vector2.ZERO)
	if plan.has("error"):
		# Na razie nic do zrobienia, ale na polu pracuje zestaw, po którym przybędzie pracy
		# (np. siewnik za kultywatorem) – pracownik czeka w miejscu.
		if bool(plan.get("no_work", false)) and _feeder_active(vehicle, plan["field"], str(plan["operation"])):
			var field: Node2D = plan["field"]
			jobs[vehicle] = {"field": field, "operation": plan["operation"], "axis": WorkerRig.forward(vehicle.global_rotation),
				"preview": [], "claims": [], "waiting": true, "announced_wait": true, "paused_s": 0.0, "replans": 0,
				"remaining": WorkerRules.remaining(str(plan["operation"]), field.cells.states, field.cells.fertilized)}
			revision += 1
			return "Pracownik czeka, aż na polu %s będzie co robić (H odwołuje)." % str(field.field_name)
		return str(plan["error"])
	return _launch(vehicle, plan, 0)


## Plan pracy zestawu: {"route", "field", "operation", "axis", "preview", "claims", "stats",
## "warning", "remaining"} albo {"error", "no_work": bool}.
## field/axis – narzucone (dalsza praca, nowa droga); null/ZERO – pole przed zestawem, kierunek pojazdu.
## previous/from_sample – dalsza część planu: state poprzedniego planu i ostatnia próbka trasy
## (planowanie od miejsca, w którym zestaw dopiero będzie).
func _make_plan(vehicle: RigidBody2D, field: Node2D, axis: Vector2, exclude: Array = [],
		previous: Dictionary = {}, from_sample: Array = []) -> Dictionary:
	var rig = _context.routes.rig_for(vehicle)
	if rig == null:
		return {"error": str(_context.routes.last_error)}
	var tool: Node2D = rig.tool
	var problem: String = WorkerRules.rig_problem(rig.kind, tool != null and Machines.has_work(tool))
	if not problem.is_empty():
		return {"error": problem}
	var operation: String = str(Machines.model(tool)["work"]["operation"])
	if field == null:
		# Pole przed zestawem: liczymy od punktu kilka metrów przed pojazdem (dwa pola po obu
		# stronach drogi – wybierane jest to, w którego stronę pojazd jest zwrócony).
		var ahead: Vector2 = vehicle.global_position / _units + WorkerRig.forward(vehicle.global_rotation) * float(settings.get("field_look_ahead_m", 8.0))
		field = _nearest_field(ahead)
		if field == null:
			return {"error": "Podjedź bliżej pola (do %.0f m od krawędzi)." % float(settings.get("max_field_distance_m", 40.0))}
	if not bool(field.owned):
		return {"error": "%s nie jest twoje – najpierw je kup." % str(field.field_name)}
	problem = _supply_problem(vehicle, tool, operation)
	if not problem.is_empty():
		return {"error": problem}
	var model = _rig_model(vehicle, rig)
	if model == null:
		return {"error": "Ten pojazd nie ma skrętnej osi – pracownik nim nie pojedzie."}
	_use_unfolded_shapes(rig, tool)
	var claims: Array = _claims_of_others(vehicle, field, operation)
	claims.append_array(exclude)
	var planner = Planner.new()
	planner.settings = settings
	planner.rig = model
	planner.world_rect = _context.world_rect_m
	planner.axis_hint = axis
	planner.max_lanes = int(settings.get("max_lanes_per_plan", 4))
	planner.profile = func(a: Vector2, b: Vector2, width: float, bins: int) -> PackedFloat32Array:
		return _profile(field, operation, a, b, width, bins, claims)
	planner.is_free = func(samples: Array) -> bool:
		return _free(rig, samples)
	planner.is_free_static = func(samples: Array) -> bool:
		return _free(rig, samples, null, false)
	var started: int = Time.get_ticks_usec()
	var position: Vector2 = vehicle.global_position / _units
	var rot: float = vehicle.global_rotation
	var tool_rot: float = rig.bodies[1].global_rotation if model.towed() else vehicle.global_rotation
	if not from_sample.is_empty():
		position = Vector2(float(from_sample[1]), float(from_sample[2]))
		rot = float(from_sample[3])
		tool_rot = rot + float(from_sample[4])
	var ok: bool = planner.plan(field.global_position / _units, Vector2(field.columns, field.rows) * float(field.cell_m),
		field.global_rotation, position, rot, tool_rot, previous)
	last_plan_ms = (Time.get_ticks_usec() - started) / 1000.0
	# Lambdy trzymają planistę i zestaw – zrywamy cykl referencji.
	planner.profile = Callable()
	planner.is_free = Callable()
	planner.is_free_static = Callable()
	if not ok:
		return {"error": planner.last_error, "no_work": bool(planner.stats.get("no_work", false)),
			"field": field, "operation": operation}
	var speed_cap: float = minf(float(settings.get("work_speed_kmh", 12.0)), FieldRules.speed_cap_kmh(Machines.model(tool), true))
	var fold_now: float = Machines.fold_progress(tool) if Machines.is_foldable(tool) else 1.0
	var fold_seconds: float = float(tool.call("get_fold_seconds")) if Machines.is_foldable(tool) and tool.has_method("get_fold_seconds") else 0.0
	var continuing: bool = not from_sample.is_empty()
	var samples: Array = planner.samples(speed_cap / 3.6, 1.0 if continuing else fold_now, fold_seconds,
		continuing, bool(planner.state.get("open", false)))
	var route: Dictionary = {"version": 4, "id": "worker_%s_%d" % [Machines.id(vehicle), Time.get_ticks_usec()],
		"name": "Pracownik: " + str(field.field_name), "map_id": "", "signature": {}, "samples": samples}
	if not RouteData.valid(route):
		# Brak przejazdu (np. tuż przed zestawem stoi inna maszyna) – jak brak wolnej drogi: ponowna próba
		# później. Inny problem (błąd geometrii) – opis w logu.
		if samples.size() >= 2:
			push_warning("Pracownik %s: niepoprawna trasa – %s" % [Machines.id(vehicle), _route_problem(samples)])
		return {"error": "Pracownik nie znalazł wolnej drogi – przestaw maszyny i naciśnij H.", "no_work": false,
			"field": field, "operation": operation}
	var own_claims: Array = []
	for info in planner.passes_info:
		own_claims.append({"polygon": _strip_polygon(info["from"], info["to"], float(info["width"])), "end_time": float(info["end_time"])})
	# Kolejne pasy planowane w trakcie przedostatniego pasa (pracownik patrzy niedaleko w przyszłość).
	var extend_at: float = float(planner.passes_info[-2]["end_time"]) if planner.passes_info.size() >= 2 else 0.0
	return {"route": route, "field": field, "operation": operation, "axis": planner.lane_axis, "preview": planner.preview(),
		"claims": own_claims, "stats": planner.stats.duplicate(), "warning": planner.warning,
		"state": planner.state.duplicate(), "extend_at": extend_at,
		"remaining": WorkerRules.remaining(operation, field.cells.states, field.cells.fertilized)}


## Opis pierwszej niepoprawnej próbki (do logu).
func _route_problem(samples: Array) -> String:
	if samples.size() < 2:
		return "%d próbek" % samples.size()
	for i in samples.size():
		var sample: Array = samples[i]
		for value in sample:
			if not is_finite(float(value)):
				return "próbka %d nie jest liczbą: %s" % [i, str(sample)]
		if i > 0 and float(sample[0]) <= float(samples[i - 1][0]):
			return "czas próbki %d nie rośnie: %s po %s" % [i, str(sample), str(samples[i - 1])]
	return "inne (%s)" % str(samples[0])


## Uruchamia plan (trasa w RouteSystem) i zapisuje pracę zestawu. Zwraca komunikat dla gracza.
## carry – dane poprzedniej pracy tego zestawu (przejechane pasy, „karmiony”).
func _launch(vehicle: RigidBody2D, plan: Dictionary, replans: int, carry: Dictionary = {}) -> String:
	var error: String = _context.routes.start_generated(vehicle, plan["route"])
	if not error.is_empty():
		return error
	var stats: Dictionary = plan["stats"]
	var done: Array = carry.get("done", []).duplicate()
	jobs[vehicle] = {"field": plan["field"], "operation": plan["operation"], "axis": plan["axis"], "preview": plan["preview"],
		"claims": plan["claims"], "remaining": int(plan["remaining"]), "waiting": false, "paused_s": 0.0, "replans": replans,
		"stopped_early": bool(stats.get("stopped_early", false)), "truncated": bool(stats.get("truncated", false)),
		"done": done, "fed": bool(carry.get("fed", false)), "state": plan["state"], "extend_at": float(plan["extend_at"]),
		"worked": bool(carry.get("worked", false)), "route": plan["route"],
		"escapes": int(carry.get("escapes", 0))}
	revision += 1
	var text: String = "Pracownik: %s – pracuje. H odwołuje." % str(plan["field"].field_name)
	if not str(plan["warning"]).is_empty():
		text += " " + str(plan["warning"])
	return text


## Linie planów do podglądu w widoku 2D: [{"kind", "points"}] (metry).
func preview_lines() -> Array:
	var result: Array = []
	for vehicle in jobs:
		if not bool(jobs[vehicle].get("waiting", false)):
			result.append_array(jobs[vehicle]["preview"])
	return result


func _on_task_ended(vehicle: RigidBody2D, reason: String, completed: bool) -> void:
	if not jobs.has(vehicle) or _switching.has(vehicle):
		return
	var job: Dictionary = jobs[vehicle]
	if completed:
		# Dalsza praca na tym samym polu (np. siewnik za kultywatorem) – poza tym callbackiem.
		for claim in job["claims"]:
			job["done"].append(claim["polygon"])
		job["waiting"] = true
		job["preview"] = []
		job["claims"] = []
		revision += 1
		# Po zjechaniu z drogi innemu – dalsza praca dopiero przy kolejnej próbie (tamten przejedzie).
		if not bool(job.get("escaping", false)):
			call_deferred("_continue", vehicle)
		job["escaping"] = false
		return
	jobs.erase(vehicle)
	revision += 1
	if reason != "Pracownik odwołany.":
		message.emit("Pracownik przerwał pracę: " + reason)


## Po skończonym planie: nowy plan z tym samym kierunkiem pasów. Brak pracy → czekanie, jeśli na
## polu pracuje zestaw, po którym może jej przybyć (FEEDS), inaczej koniec.
func _continue(vehicle: RigidBody2D) -> void:
	if not jobs.has(vehicle) or not is_instance_valid(vehicle):
		return
	var job: Dictionary = jobs[vehicle]
	var field: Node2D = job["field"]
	var operation: String = str(job["operation"])
	var feeder: bool = _feeder_active(vehicle, field, operation)
	var fed: bool = bool(job.get("fed", false)) or feeder
	# Niedokończonych kawałków nie objeżdżamy: pasy przejechane wcześniej są wyłączone z planu.
	# Wyjątek: na polu pracuje (pracował) zestaw, po którym przybywa pracy – np. siewnik za
	# kultywatorem wraca na swoje pasy, bo zakultywowana część rośnie.
	var exclude: Array = [] if fed else job.get("done", [])
	var plan: Dictionary = _make_plan(vehicle, field, job["axis"], exclude)
	if not plan.has("error"):
		var now: int = WorkerRules.remaining(operation, field.cells.states, field.cells.fertilized)
		# Karmiony, ale poprzedni plan nic nie zmienił i nic już nie przybywa – koniec (bez krążenia).
		if fed and not feeder and not bool(job.get("truncated", false)) and now >= int(job["remaining"]):
			_finish(vehicle, "Pracownik skończył: %s." % str(field.field_name))
			return
		var carry: Dictionary = {"done": job.get("done", []), "fed": feeder, "worked": job.get("worked", false),
			"escapes": job.get("escapes", 0)}
		_switching[vehicle] = true
		jobs.erase(vehicle)
		var text: String = _launch(vehicle, plan, 0, carry)
		_switching.erase(vehicle)
		if not jobs.has(vehicle):
			message.emit("%s: %s" % [Machines.id(vehicle), text])
		return
	if bool(plan.get("no_work", false)):
		if feeder:
			job["fed"] = true
			if not bool(job.get("announced_wait", false)):
				job["announced_wait"] = true
				message.emit("%s: pracownik czeka na dalszą pracę na polu %s." % [Machines.id(vehicle), str(field.field_name)])
			return
		# Reszta pola jest w planach innych pracowników tej samej pracy – czekamy: jeśli któregoś pasa
		# nie zrobią (np. ich plan się zmienił), ten pracownik go weźmie.
		if _teammate_active(vehicle, field, operation):
			return
		_finish(vehicle, "Pracownik skończył: %s." % str(field.field_name))
		return
	# Nie da się dojechać, a obok czeka inny pracownik (też bez trasy) – ten, kto ma mniejsze
	# pierwszeństwo, cofa się po swoim śladzie (raz, do następnej pracy); inaczej czekaliby na siebie.
	for other in jobs.keys():
		if other != vehicle and bool(jobs[other].get("waiting", false)) and not _context.routes.tasks.has(other) \
				and not bool(jobs[other].get("escaped", false)) and _goes_first(vehicle, other) \
				and other.global_position.distance_to(vehicle.global_position) / _units < float(settings.get("escape_near_m", 30.0)):
			_escape(other)
			return
	# Nie da się dojechać (np. inny zestaw blokuje drogę) – kilka prób, potem koniec. Dopóki na
	# polu pracuje ktoś inny, próby się nie liczą (droga zwykle zaraz się zwolni).
	for other in jobs:
		if other != vehicle and jobs[other]["field"] == field and not bool(jobs[other].get("waiting", false)):
			return
	job["retries"] = int(job.get("retries", 0)) + 1
	if job["retries"] > int(settings.get("continue_retries", 5)):
		_finish(vehicle, "Pracownik skończył: %s (do reszty nie dojedzie)." % str(field.field_name))


func _finish(vehicle: RigidBody2D, text: String) -> void:
	jobs.erase(vehicle)
	revision += 1
	message.emit(text)


## Czy na polu pracuje zestaw, po którym ta praca może mieć więcej do zrobienia.
func _feeder_active(vehicle: RigidBody2D, field: Node2D, operation: String) -> bool:
	var feeders: Array = WorkerRules.FEEDS.get(operation, [])
	for other in jobs:
		if other != vehicle and jobs[other]["field"] == field and feeders.has(str(jobs[other]["operation"])) \
				and not bool(jobs[other].get("waiting", false)):
			return true
	return false


## Inny pracownik tej samej pracy jedzie po tym polu (ma niewykonane pasy).
func _teammate_active(vehicle: RigidBody2D, field: Node2D, operation: String) -> bool:
	for other in jobs:
		if other != vehicle and jobs[other]["field"] == field and str(jobs[other]["operation"]) == operation \
				and not bool(jobs[other].get("waiting", false)) and not (jobs[other]["claims"] as Array).is_empty():
			return true
	return false


## Praca na polu odmówiła (inne ziarno w zbiorniku, pusty siewnik, pole nie nasze…):
## pracownik zatrzymuje się z tym komunikatem zamiast jeździć na pusto.
func _on_work_message(vehicle: RigidBody2D, text: String) -> void:
	if jobs.has(vehicle) and WorkerRules.blocking(text) and _context.routes.tasks.has(vehicle) \
			and not _context.routes.is_stopping(vehicle):
		_context.routes.request_stop(vehicle, text + " Potem H wznawia pracę.")


# ---------------------------------------------------------------------------
# Rezerwacje pasów (kilku pracowników tej samej pracy na jednym polu)
# ---------------------------------------------------------------------------

static func _strip_polygon(from: Vector2, to: Vector2, width: float) -> PackedVector2Array:
	var direction: Vector2 = (to - from).normalized()
	var side := Vector2(-direction.y, direction.x) * width * 0.5
	return PackedVector2Array([from - side, to - side, to + side, from + side])


## Pasy (jeszcze nieprzejechane) innych pracowników tej samej pracy na tym polu.
func _claims_of_others(vehicle: RigidBody2D, field: Node2D, operation: String) -> Array:
	var result: Array = []
	for other in jobs:
		if other == vehicle or jobs[other]["field"] != field or str(jobs[other]["operation"]) != operation:
			continue
		for claim in jobs[other]["claims"]:
			result.append(claim["polygon"])
	return result


## Profil pasa od a do b (szerokość width): udział komórek wymagających pracy w każdym z bins
## kawałków; kawałki, których środek leży w pasie zarezerwowanym przez innego pracownika – 0.
func _profile(field: Node2D, operation: String, a: Vector2, b: Vector2, width: float, bins: int, claims: Array) -> PackedFloat32Array:
	var length: float = a.distance_to(b)
	var direction: Vector2 = (b - a) / maxf(length, 0.001)
	var pose := Transform2D(atan2(direction.x, -direction.y), (a + b) * 0.5 * _units)
	var cells: PackedInt32Array = field.cells_in_rectangle(pose, Vector2(width, length))
	# Położenie komórki wzdłuż pasa liniowo z kolumny i wiersza.
	var cell: float = float(field.cell_m)
	var origin: Vector2 = field.global_position / _units
	var x_axis := Vector2.RIGHT.rotated(field.global_rotation)
	var y_axis := Vector2.DOWN.rotated(field.global_rotation)
	var start: float = (origin + (x_axis + y_axis) * cell * 0.5 - a).dot(direction) / length
	var per_column: float = cell * x_axis.dot(direction) / length
	var per_row: float = cell * y_axis.dot(direction) / length
	var columns: int = int(field.columns)
	var positions := PackedFloat32Array()
	positions.resize(cells.size())
	for i in cells.size():
		var index: int = cells[i]
		positions[i] = start + (index % columns) * per_column + (index / columns) * per_row
	var result: PackedFloat32Array = WorkerRules.strip_profile(operation, cells, positions, field.cells.states, field.cells.fertilized, bins)
	if not claims.is_empty():
		for bin in bins:
			var point: Vector2 = a + direction * length * (bin + 0.5) / bins
			for polygon in claims:
				if Geometry2D.is_point_in_polygon(point, polygon):
					result[bin] = 0.0
					break
	return result


# ---------------------------------------------------------------------------
# Nadzór
# ---------------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if jobs.is_empty():
		_corridors.clear()
		return
	_corridor_timer += delta
	if _corridor_timer >= float(settings.get("look_ahead_interval_s", 0.25)):
		_corridor_timer = 0.0
		for vehicle in _corridors.keys():
			if not jobs.has(vehicle) or not _context.routes.tasks.has(vehicle):
				_corridors.erase(vehicle)
				_bodies_now.erase(vehicle)
				_near.erase(vehicle)
		for vehicle in jobs:
			if _context.routes.tasks.has(vehicle):
				_update_corridor(vehicle)
		_update_holds()
	_wait_timer += delta
	if _wait_timer >= float(settings.get("wait_retry_s", 3.0)):
		_wait_timer = 0.0
		for vehicle in jobs.keys():
			if bool(jobs[vehicle].get("waiting", false)) and not _context.routes.tasks.has(vehicle):
				call_deferred("_continue", vehicle)
	_supervise_timer += delta
	if _supervise_timer < 0.5:
		return
	_supervise_timer = 0.0
	for vehicle in jobs.keys():
		if not is_instance_valid(vehicle) or not _context.routes.tasks.has(vehicle) or _context.routes.is_stopping(vehicle):
			continue
		var task: Dictionary = _context.routes.tasks[vehicle]
		var rig = task["rig"]
		var job: Dictionary = jobs[vehicle]
		var problem: String = _supply_problem(vehicle, rig.tool, str(job["operation"]))
		if not problem.is_empty():
			_context.routes.request_stop(vehicle, problem + " Potem H wznawia pracę.")
			continue
		var playback = task["playback"]
		if _feeder_active(vehicle, job["field"], str(job["operation"])):
			job["fed"] = true
		# Przejechane pasy zwalniają rezerwację i trafiają do zrobionych (bez powrotów na nie).
		for claim in job["claims"]:
			if float(claim["end_time"]) <= playback.time:
				job["done"].append(claim["polygon"])
		job["claims"] = job["claims"].filter(func(claim): return float(claim["end_time"]) > playback.time)
		if int(job["replans"]) > 0 and playback.distance_at(playback.time) > 40.0 and not bool(task.get("paused", false)):
			job["replans"] = 0      # nowa trasa ruszyła i przejechała 40 m – przeszkody liczą się od nowa
		if int(job.get("escapes", 0)) > 0 and playback.distance_at(playback.time) > 40.0 and not bool(task.get("paused", false)):
			job["escapes"] = 0
		if bool(job["state"].get("open", false)) and playback.time >= float(job["extend_at"]):
			_extend(vehicle)
		job["paused_s"] = float(job["paused_s"]) + 0.5 if bool(task.get("paused", false)) else 0.0
		# Bez postępu (zestaw kręci się w kółko w miejscu albo czeka bez końca) – zatrzymanie zamiast zakleszczenia.
		var here: Vector2 = vehicle.global_position / _units
		if not job.has("stuck_pos") or here.distance_to(job["stuck_pos"]) > float(settings.get("escape_m", 8.0)) + 2.0:
			job["stuck_pos"] = here
			job["stuck_s"] = 0.0
		elif bool(task.get("paused", false)):
			job["stuck_s"] = float(job.get("stuck_s", 0.0)) + 0.5
			if float(job["stuck_s"]) >= float(settings.get("max_wait_s", 90.0)):
				_context.routes.stop(vehicle, "Pracownik utknął (inna maszyna na drodze) – przestaw maszyny i naciśnij H.")
				continue
		# Ustępowanie drogi innemu pracownikowi to zwykłe czekanie (on zaraz przejedzie);
		# nowej drogi szukamy dopiero po dłuższym czasie. Przeszkoda (stojąca maszyna) – szybciej.
		var yielding: bool = _waits_for_worker(task) or _near_worker(vehicle)
		var limit: float = float(settings.get("yield_timeout_s", 30.0)) if yielding else float(settings.get("replan_after_s", 5.0))
		if bool(job.get("escape", false)) and bool(task.get("paused", false)):
			job["escape"] = false
			call_deferred("_escape", vehicle)
			continue
		job["escape"] = false
		if float(job["paused_s"]) >= limit:
			job["paused_s"] = 0.0
			call_deferred("_replan", vehicle)


## Dokłada do jadącej trasy kolejne pasy, planowane od jej końca (zestaw jedzie dalej bez postoju).
## Gdy nic nie zostało – trasa skończy się sama, a _continue zdecyduje (czekanie albo koniec).
func _extend(vehicle: RigidBody2D) -> void:
	var job: Dictionary = jobs[vehicle]
	var task: Dictionary = _context.routes.tasks[vehicle]
	var route_samples: Array = task["route"]["samples"]
	var last: Array = route_samples[-1]
	var exclude: Array = [] if bool(job.get("fed", false)) else job.get("done", [])
	# Własne pasy jeszcze nieprzejechane też są zajęte.
	exclude = exclude.duplicate()
	for claim in job["claims"]:
		exclude.append(claim["polygon"])
	var plan: Dictionary = _make_plan(vehicle, job["field"], job["axis"], exclude, job["state"], last)
	if plan.has("error"):
		if bool(plan.get("no_work", false)):
			job["state"]["open"] = false
		return
	var more: Array = plan["route"]["samples"]
	var offset: float = float(last[0]) - float(more[0][0])
	if not _context.routes.extend_generated(vehicle, more):
		return
	for claim in plan["claims"]:
		claim["end_time"] = float(claim["end_time"]) + offset
		job["claims"].append(claim)
	job["preview"].append_array(plan["preview"])
	job["state"] = plan["state"]
	job["extend_at"] = float(plan["extend_at"]) + offset if float(plan["extend_at"]) > 0.0 else float(last[0])
	revision += 1


## Czy na najbliższej drodze zestawu stoi albo jedzie inny pracownik (wtedy się czeka, nie omija).
func _near_worker(vehicle: RigidBody2D) -> bool:
	var corridor: Array = _corridors.get(vehicle, [])
	for other in _bodies_now:
		if other != vehicle and jobs.has(other) and _collision.overlap(corridor, _bodies_now[other]):
			return true
	return false


## Zjazd z drogi pracownikowi z pierwszeństwem: cofnięcie po własnym śladzie o escape_m
## (tamtędy zestaw właśnie przejechał, więc zwykle jest wolno). Potem dalsza praca jak po skończonym planie.
func _escape(vehicle: RigidBody2D) -> void:
	if not jobs.has(vehicle):
		return
	var job: Dictionary = jobs[vehicle]
	var task: Dictionary = _context.routes.tasks.get(vehicle, {})
	# Ślad: przejechana część trasy, ostatnia próbka = obecna poza.
	var trail: Array = []
	var rig: RefCounted = null
	if not task.is_empty():
		var playback = task["playback"]
		var route_samples: Array = task["route"]["samples"]
		trail = route_samples.slice(maxi(0, int(playback.index) - 600), int(playback.index) + 1)
		trail.append(RouteData.at(task["route"], playback.time, playback.index)["point"])
		rig = task["rig"]
	elif job.has("route"):
		var route_samples: Array = job["route"]["samples"]
		trail = route_samples.slice(maxi(0, route_samples.size() - 600))
		rig = _context.routes.rig_for(vehicle)
	if bool(job.get("escaping", false)):
		return
	if trail.size() < 2 or rig == null or int(job.get("escapes", 0)) >= int(settings.get("max_escapes", 3)):
		return
	var back: Array = [trail[-1]]
	var travelled: float = 0.0
	var index: int = trail.size() - 2
	var limit: float = float(settings.get("escape_m", 8.0))
	while index >= 0 and travelled < limit:
		var sample: Array = trail[index]
		travelled += Vector2(sample[1], sample[2]).distance_to(Vector2(back[-1][1], back[-1][2]))
		back.append(sample)
		index -= 1
	if travelled < 2.0:
		return
	var speed: float = float(settings.get("reverse_speed_kmh", 4.0)) / 3.6
	var samples: Array = []
	var time: float = 0.0
	for i in back.size():
		var sample: Array = (back[i] as Array).duplicate()
		if i > 0:
			time += maxf(0.01, Vector2(sample[1], sample[2]).distance_to(Vector2(back[i - 1][1], back[i - 1][2])) / speed)
		sample[0] = time
		sample[7] = 0.0
		samples.append(sample)
	if not _free(rig, samples, null, true, true):
		return
	var route: Dictionary = {"version": 4, "id": "worker_escape_%d" % Time.get_ticks_usec(), "name": "Pracownik: zjazd z drogi",
		"map_id": "", "signature": {}, "samples": samples}
	_switching[vehicle] = true
	_context.routes.stop(vehicle, "Pracownik zjeżdża z drogi.", true)
	var error: String = _context.routes.start_generated(vehicle, route)
	_switching.erase(vehicle)
	if not error.is_empty():
		return
	job["escaping"] = true
	job["escaped"] = true
	job["escapes"] = int(job.get("escapes", 0)) + 1
	# Ślad na następny raz: dalej wstecz od miejsca, do którego zestaw się cofnął.
	job["route"] = {"samples": trail.slice(0, index + 2)}
	job["state"] = {"open": false}
	job["claims"] = []
	job["preview"] = []
	revision += 1
	message.emit("%s: pracownik zjeżdża z drogi." % Machines.id(vehicle))


## Nowy plan z miejsca, w którym zestaw stoi przed przeszkodą (zablokowany zawrót albo dojazd).
## Planowany, zanim stara trasa się zatrzyma: gdy nowej drogi nie ma, zestaw dalej czeka
## i próbuje ponownie (najwyżej max_replans razy z rzędu).
func _replan(vehicle: RigidBody2D) -> void:
	if not jobs.has(vehicle) or not _context.routes.tasks.has(vehicle):
		return
	var job: Dictionary = jobs[vehicle]
	# Przeszkodą jest inny pracownik – on się ruszy, więc ta próba się nie liczy.
	var by_worker: bool = _near_worker(vehicle) or _waits_for_worker(_context.routes.tasks[vehicle])
	var count: int = int(job.get("replans", 0)) + (0 if by_worker else 1)
	# Własne rezerwacje nie blokują nowego planu.
	var own_claims: Array = job["claims"]
	job["claims"] = []
	var plan: Dictionary = _make_plan(vehicle, job["field"], job["axis"])
	if plan.has("error"):
		job["claims"] = own_claims
		# Drogę blokuje inny pracownik – on się ruszy; czekamy bez liczenia prób.
		if by_worker:
			return
		if count >= int(settings.get("max_replans", 3)):
			_context.routes.stop(vehicle, "Pracownik nie znalazł wolnej drogi – przestaw maszyny i naciśnij H.")
		else:
			job["replans"] = count
		return
	if count > int(settings.get("max_replans", 3)):
		_context.routes.stop(vehicle, "Pracownik nie znalazł wolnej drogi – przestaw maszyny i naciśnij H.")
		return
	_switching[vehicle] = true
	_context.routes.stop(vehicle, "Pracownik szuka innej drogi.", true)
	jobs.erase(vehicle)
	var text: String = _launch(vehicle, plan, count, {"done": job.get("done", []), "fed": job.get("fed", false),
		"worked": job.get("worked", false), "escapes": job.get("escapes", 0)})
	_switching.erase(vehicle)
	if not jobs.has(vehicle):
		message.emit("%s: pracownik nie ruszył – %s" % [Machines.id(vehicle), text])
	else:
		message.emit("%s: przeszkoda – pracownik wybrał inną drogę." % Machines.id(vehicle))


## Zestaw stoi, bo czeka na innego pracownika (ustępuje mu albo czeka, aż tamten zjedzie z drogi).
func _waits_for_worker(task: Dictionary) -> bool:
	for key in ["hold", "pause_reason"]:
		var text: String = str(task.get(key, ""))
		if text.begins_with("Pracownik ustępuje") or text.begins_with("Pracownik czeka, aż"):
			return true
	return false


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
## bodies_only: inni pracownicy liczą się tam, gdzie stoją teraz (bez ich dalszej drogi).
func _free(rig: RefCounted, samples: Array, ignore: RigidBody2D = null, with_workers: bool = true, bodies_only: bool = false) -> bool:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var others: Array = []
	var excluded: Array[RID] = rig.excluded()
	if bodies_only:
		for vehicle in _bodies_now:
			if vehicle != rig.vehicle:
				others.append_array(_bodies_now[vehicle])
	elif with_workers:
		# Inni pracownicy: najbliższy kawałek ich drogi (dalsze rezerwacje rozstrzyga czekanie, nie objazd).
		for vehicle in _near:
			if vehicle != ignore and vehicle != rig.vehicle:
				others.append_array(_near[vehicle])
	else:
		# Jadące zestawy pominięte – liczą się tylko maszyny, które stoją (także pracownik, który czeka).
		for vehicle in jobs:
			if vehicle != rig.vehicle and _context.routes.tasks.has(vehicle) \
					and not bool(_context.routes.tasks[vehicle].get("paused", false)):
				excluded.append_array(_context.routes.tasks[vehicle]["rig"].excluded())
	var windows: Array = _windows(samples)
	var order: Array = []
	for phase in 4:
		for k in range(phase, windows.size(), 4):
			order.append(k)
	for k in order:
		var window: Vector2i = windows[k]
		var volumes: Array = _collision.volumes(rig, samples.slice(window.x, window.y + 1), _collision_settings)
		if volumes.is_empty() or _collision.blocked(space, volumes, excluded):
			return false
		if not others.is_empty() and _collision.overlap(volumes, others):
			return false
	return true


## Podział próbek na odcinki ok. collision_window_m / 10° (osłona całego zawrotu byłaby zbyt gruba):
## [Vector2i(od, do)] – indeksy próbek.
func _windows(samples: Array) -> Array:
	var result: Array = []
	var window_m: float = float(settings.get("collision_window_m", 1.0))
	var straight_m: float = float(settings.get("straight_window_m", 25.0))
	var i: int = 0
	while i < samples.size() - 1:
		var j: int = i + 1
		var travelled: float = 0.0
		var turned: float = 0.0
		while j < samples.size() - 1:
			travelled += Vector2(samples[j][1], samples[j][2]).distance_to(Vector2(samples[j - 1][1], samples[j - 1][2]))
			turned += absf(angle_difference(float(samples[j - 1][3]), float(samples[j][3]))) \
				+ absf(angle_difference(float(samples[j - 1][4]), float(samples[j][4])))
			# Na prostej (zestaw i narzędzie bez skrętu) jedna osłona na dłuższy odcinek – otoczka jest dokładna.
			var straight: bool = turned < deg_to_rad(0.5)
			if travelled >= (straight_m if straight else window_m) or turned >= deg_to_rad(10.0):
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

## Korytarz: osłony drogi zestawu od obecnej chwili trasy. Na pasie – look_ahead_m; w trakcie
## manewru (zawrót, dojazd – narzędzie podniesione) – cały manewr aż do początku następnej pracy
## (najwyżej max_reservation_m): zestaw rezerwuje cały zawrót, zanim w niego wjedzie inny.
func _update_corridor(vehicle: RigidBody2D) -> void:
	var task: Dictionary = _context.routes.tasks.get(vehicle, {})
	if task.is_empty():
		_corridors.erase(vehicle)
		return
	var playback = task["playback"]
	var samples_all: Array = task["route"]["samples"]
	var ahead: float = float(settings.get("look_ahead_m", 10.0))
	var s_now: float = playback.distance_at(playback.time)
	var index: int = mini(playback.index + 1, samples_all.size() - 1)
	var maneuvering: bool = float(samples_all[playback.index][7]) < 0.5
	# Rezerwacja do końca pasu: na pasie – reszta pasa, w trakcie manewru – manewr i cały następny pas
	# (nikt nie wjedzie naprzeciw na pas obok, póki ten zestaw go nie skończy).
	if maneuvering:
		while index < samples_all.size() - 1 and float(samples_all[index][7]) < 0.5:
			index += 1
	while index < samples_all.size() - 1 and float(samples_all[index][7]) >= 0.5:
		index += 1
	var to_end: float = playback.distance_at(float(samples_all[index][0])) - s_now
	ahead = clampf(to_end + 2.0, ahead, float(settings.get("max_reservation_m", 300.0)))
	var finish: float = playback.time_at_distance(s_now + ahead, playback.time, playback.duration())
	var samples: Array = RouteData.between(task["route"], playback.time, maxf(finish, playback.time + 0.001), playback.index)
	var corridor: Array = []
	var near: Array = []
	var near_m: float = float(settings.get("look_ahead_m", 20.0))
	var travelled: float = 0.0
	for window in _windows(samples):
		var volumes: Array = _collision.volumes(task["rig"], samples.slice(window.x, window.y + 1), _collision_settings)
		corridor.append_array(volumes)
		if travelled <= near_m:
			near.append_array(volumes)
		for k in range(window.x + 1, window.y + 1):
			travelled += Vector2(samples[k][1], samples[k][2]).distance_to(Vector2(samples[k - 1][1], samples[k - 1][2]))
	_corridors[vehicle] = corridor
	_near[vehicle] = near
	_bodies_now[vehicle] = _collision.volumes(task["rig"], [samples[0]], _collision_settings) if not samples.is_empty() else []
	_maneuvering[vehicle] = maneuvering
	if not maneuvering and jobs.has(vehicle):
		jobs[vehicle]["worked"] = true
		jobs[vehicle]["escaped"] = false


## Kto jedzie pierwszy, gdy drogi dwóch zestawów się nakładają: zestaw, który już pracował, przed
## dopiero wjeżdżającym na pole; potem ten na pasie (jedzie do końca pasa) przed zawracającym,
## a gdy obaj tak samo – wcześniej zatrudniony.
func _goes_first(first: RigidBody2D, second: RigidBody2D) -> bool:
	var worked_a: bool = bool(jobs.get(first, {}).get("worked", false))
	var worked_b: bool = bool(jobs.get(second, {}).get("worked", false))
	if worked_a != worked_b:
		return worked_a
	var a: bool = bool(_maneuvering.get(first, false))
	var b: bool = bool(_maneuvering.get(second, false))
	if a != b:
		return b
	return jobs.keys().find(first) < jobs.keys().find(second)


## Zestaw czeka (zanim podjedzie pod przeszkodę), gdy na jego drodze stoi maszyna albo przejedzie
## tamtędy pracownik, który ma pierwszeństwo. Zatrzymanie z wyprzedzeniem zostawia miejsce
## na nowy plan (replan_after_s).
func _update_holds() -> void:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	for vehicle in _corridors:
		if not jobs.has(vehicle) or not _context.routes.tasks.has(vehicle):
			continue
		var corridor: Array = _corridors[vehicle]
		var reason: String = ""
		for other in _corridors:
			if other == vehicle or not jobs.has(other):
				continue
			var first: bool = _goes_first(vehicle, other)
			var body_in_way: bool = _collision.overlap(corridor, _bodies_now.get(other, []))
			# Drugi pracownik ustępuje: czeka, gdy pierwszy stoi mu na drodze albo przejedzie tamtędy.
			if not first and (body_in_way or _collision.overlap(corridor, _corridors[other])):
				reason = "Pracownik ustępuje drogi: " + Machines.id(other) + "."
				break
			# Pierwszy ma przed sobą drugiego (już tam stoi): czeka, a drugi zjeżdża mu z drogi –
			# cofa się po własnym śladzie (inaczej staliby w nieskończoność).
			if first and body_in_way:
				reason = "Pracownik czeka, aż %s zjedzie z drogi." % Machines.id(other)
				jobs[other]["escape"] = true
				break
		# Stojąca maszyna – zestaw podjeżdża jak najbliżej (sprawdzane tylko look_ahead_m przed nim).
		if reason.is_empty() and _collision.blocked(space, _near.get(vehicle, []), _context.routes.tasks[vehicle]["rig"].excluded()):
			reason = "Pracownik czeka – na drodze stoi maszyna."
		_context.routes.set_hold(vehicle, reason)
