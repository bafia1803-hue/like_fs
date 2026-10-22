extends Node2D
## Nagrywanie i odtwarzanie tras. Warstwa gry: bez rysowania (patrz record_path / preview_path).
const Rig = preload("res://scripts/route_rig.gd")
const Data = preload("res://scripts/route_data.gd")
const Collision = preload("res://scripts/route_collision.gd")
signal message(text: String)
signal changed
var settings: Dictionary = {}
var last_error: String = ""
var routes: Array = []
var tasks: Dictionary = {}
var held: Dictionary = {}
var recording: Dictionary = {}
var _hitches: Node
var _fields: Node
var _units: float
var _map_id: String
var _collision = Collision.new()
## Dane do rysowania przez widoki (metry, przerzedzone co line_spacing_m).
## System tras niczego nie rysuje; widoki czytają tylko nagrywaną ścieżkę.
var record_path := PackedVector2Array()
var record_revision: int = 0
## Przejazd oczekujący na start: gracz wybrał trasę, zestaw musi dojechać na miejsce startu
## i przygotować narzędzie. {"vehicle", "route"}; widoki pokazują wtedy „zestaw widmo”.
var armed: Dictionary = {}
## Dopuszczalna różnica kierunku na miejscu startu.
const ARM_HEADING_TOLERANCE_DEG: float = 30.0

func configure(session: Dictionary, hitches: Node, fields: Node, units: float) -> bool:
	process_physics_priority = -20
	z_index = 2
	_hitches = hitches
	_fields = fields
	_units = units
	_map_id = str(session["save_data"]["references"]["map"]["id"])
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string("res://files/routes.json")) != OK or not parser.data is Dictionary:
		last_error = "Brak lub niepoprawny files/routes.json."
		return false
	settings = parser.data
	settings["resume_ramp_seconds"] = maxf(0.0, float(settings.get("resume_ramp_seconds", 3.0)))
	settings["resume_clearance_m"] = maxf(0.0, float(settings.get("resume_clearance_m", 0.5)))
	settings["resume_clear_seconds"] = maxf(0.0, float(settings.get("resume_clear_seconds", 0.5)))
	settings["stop_ramp_seconds"] = maxf(0.0, float(settings.get("stop_ramp_seconds", 2.5)))
	for key in ["sample_seconds", "max_recording_seconds", "start_distance_m", "start_speed_m_s", "collision_step_m", "collision_step_degrees", "collision_margin_m", "max_collision_steps_per_tick", "line_spacing_m"]:
		if not settings.get(key) is float and not settings.get(key) is int:
			last_error = "Brak ustawienia tras: " + key
			return false
		if not is_finite(float(settings[key])) or float(settings[key]) <= 0.0:
			last_error = "Ustawienie tras musi być dodatnie: " + key
			return false
	if not session["save_data"].get("recorded_routes") is Array:
		session["save_data"]["recorded_routes"] = []
	routes = session["save_data"]["recorded_routes"]
	for route in routes:
		if not Data.valid(route):
			last_error = "Zapis zawiera uszkodzoną lub nieobsługiwaną trasę."
			return false
	return true


func _clear_record_path() -> void:
	record_path = PackedVector2Array()
	record_revision += 1


func _add_record_point(point_m: Vector2) -> void:
	if record_path.is_empty() or record_path[-1].distance_to(point_m) >= float(settings["line_spacing_m"]):
		record_path.append(point_m)
		record_revision += 1

func rig_for(vehicle: RigidBody2D) -> RefCounted:
	var rig = Rig.new()
	if not rig.configure(vehicle, _hitches, _units):
		last_error = rig.last_error
		return null
	return rig

func compatible(vehicle: RigidBody2D) -> Array:
	var result: Array = []
	var rig = rig_for(vehicle)
	if rig == null:
		return result
	var signature: Dictionary = rig.signature()
	for route in routes:
		# Pełna walidacja próbek przy uruchomieniu, nie podczas odświeżania UI.
		if Data.supported(route) and route.get("map_id") == _map_id and route.get("signature") == signature:
			result.append(route)
	return result

func begin_recording(vehicle: RigidBody2D, title: String) -> void:
	if not recording.is_empty() or tasks.has(vehicle):
		message.emit("Najpierw zakończ bieżące nagrywanie lub odtwarzanie tego pojazdu.")
		return
	release_hold(vehicle)
	var rig = rig_for(vehicle)
	if rig == null:
		message.emit(last_error)
		return
	if not rig.stopped(float(settings["start_speed_m_s"])):
		message.emit("Zatrzymaj cały zestaw przed rozpoczęciem nagrywania.")
		return
	var point: Array = rig.sample(0.0)
	recording = {"rig": rig, "name": title.strip_edges().left(80), "samples": [point],
		"time": 0.0, "next": float(settings["sample_seconds"]), "previous": point, "moving": false}
	vehicle.set_meta("route_recording", true)
	_clear_record_path()
	_add_record_point(vehicle.global_position / _units)
	message.emit("Nagrywanie rozpoczęte. Postoje też są nagrywane; zatrzymasz je przyciskiem w lewym dolnym rogu.")
	changed.emit()

func finish_recording(title_override: String = "") -> void:
	if recording.is_empty():
		return
	if not title_override.strip_edges().is_empty():
		recording["name"] = title_override.strip_edges().left(80)
	var rig = recording["rig"]
	var time: float = recording["time"]
	_append_sample(rig.sample(time))
	var samples: Array = recording["samples"]
	if samples.size() < 2 or time < 0.1:
		cancel_recording()
		message.emit("Nagranie było zbyt krótkie.")
		return
	var title: String = recording["name"]
	if title.is_empty():
		title = "Trasa " + Time.get_datetime_string_from_system().replace("T", " ")
	var route: Dictionary = {"version": Data.VERSION, "id": str(Time.get_unix_time_from_system()) + "_" + str(Time.get_ticks_usec()),
		"name": title, "map_id": _map_id, "signature": rig.signature(), "samples": samples,
		"sample_columns": ["time_s", "x_m", "y_m", "vehicle_rad", "tool_relative_rad", "drawbar_relative_rad", "visual_steering_normalized", "tool_working", "tool_unfolded"]}
	routes.append(route)
	rig.vehicle.remove_meta("route_recording")
	recording = {}
	_clear_record_path()
	message.emit("Ukończono: " + title + ". F9 utrwali trasy w slocie i zatrzyma wszystkie zadania.")
	changed.emit()

func cancel_recording() -> void:
	if not recording.is_empty():
		recording["rig"].vehicle.remove_meta("route_recording")
		recording = {}
	_clear_record_path()
	changed.emit()

func _append_sample(point: Array) -> void:
	var samples: Array = recording["samples"]
	if is_equal_approx(float(samples[-1][0]), float(point[0])):
		samples[-1] = point
	elif float(point[0]) > float(samples[-1][0]):
		samples.append(point)

func start(vehicle: RigidBody2D, route: Dictionary) -> void:
	if not armed.is_empty() and armed["vehicle"] == vehicle:
		armed = {}
	if tasks.has(vehicle) or bool(vehicle.get_meta("route_recording", false)):
		message.emit("Ten pojazd już wykonuje czynność.")
		return
	if not Data.valid(route):
		message.emit("Niepoprawny format nagranej trasy.")
		return
	var rig = rig_for(vehicle)
	if rig == null:
		message.emit(last_error)
		return
	if route["map_id"] != _map_id or route["signature"] != rig.signature():
		message.emit("Trasa wymaga tego samego modelu i konfiguracji pojazdu, narzędzia oraz zaczepów.")
		return
	var first: Array = route["samples"][0]
	if vehicle.global_position.distance_to(Vector2(first[1], first[2]) * _units) > float(settings["start_distance_m"]) * _units:
		message.emit("Podjedź do początku trasy – zielony punkt na mapce w oknie Trasy (maks. %.1f m)." % float(settings["start_distance_m"]))
		return
	if not rig.stopped(float(settings["start_speed_m_s"])):
		message.emit("Zatrzymaj zestaw przed odtwarzaniem.")
		return
	var volumes: Array = _collision.volumes(rig, [first], settings)
	if volumes.is_empty() or _collision.blocked(get_world_2d().direct_space_state, volumes, rig.excluded()):
		message.emit("Nie można ustawić zestawu: miejsce startu jest zajęte.")
		return
	release_hold(vehicle)
	rig.lock()
	rig.apply(first, true)
	vehicle.set_meta("route_mode", "playing")
	vehicle.set_meta("route_system", self)
	vehicle.set_meta("route_speed_m_s", 0.0)
	_fields.call("reset_route_sweep", rig.tool)
	tasks[vehicle] = {"rig": rig, "route": route, "time": 0.0, "index": 0, "paused": false, "clear_time": 0.0, "ramp_elapsed": float(settings["resume_ramp_seconds"])}
	message.emit("Uruchomiono: " + str(route["name"]) + ". TAB pozwala sterować innym pojazdem.")
	changed.emit()

func stop(vehicle: RigidBody2D, reason: String = "Przerwano ręcznie.") -> void:
	if not tasks.has(vehicle):
		return
	var task: Dictionary = tasks[vehicle]
	tasks.erase(vehicle)
	held[vehicle] = task["rig"]
	vehicle.set_meta("route_mode", "held")
	vehicle.set_meta("route_speed_m_s", 0.0)
	_fields.call("reset_route_sweep", task["rig"].tool)
	var state: Dictionary = vehicle.get_meta("instance_state")
	message.emit(str(state["instance_id"]) + ": " + reason + " W/S/A/D przywraca ręczne sterowanie.")
	changed.emit()

## „Odwołaj przejazd” w trakcie jazdy: zestaw jedzie dalej po trasie, płynnie zwalniając do zera
## (odwrotność ruszania po kolizji), i dopiero wtedy się zatrzymuje. Zestaw stojący w pauzie
## (przeszkoda) zatrzymuje się od razu.
func request_stop(vehicle: RigidBody2D, reason: String = "Przejazd odwołany.") -> void:
	if not tasks.has(vehicle):
		return
	var task: Dictionary = tasks[vehicle]
	if bool(task.get("paused", false)) or float(settings["stop_ramp_seconds"]) <= 0.0:
		stop(vehicle, reason)
		return
	if task.has("stop_elapsed"):
		return
	var duration: float = float(settings["resume_ramp_seconds"])
	task["stop_factor"] = clampf(float(task.get("ramp_elapsed", duration)) / maxf(duration, 0.000001), 0.0, 1.0) if duration > 0.0 else 1.0
	task["stop_elapsed"] = 0.0
	task["stop_reason"] = reason
	message.emit(str(vehicle.get_meta("instance_state")["instance_id"]) + ": zwalnianie i zatrzymanie.")
	changed.emit()


## Czy zestaw właśnie zwalnia po odwołaniu przejazdu.
func is_stopping(vehicle: RigidBody2D) -> bool:
	return tasks.has(vehicle) and tasks[vehicle].has("stop_elapsed")


## Droga trasy (w sekundach nagrania) przy zwalnianiu od prędkości factor do zera w czasie duration.
static func stop_integral(elapsed: float, duration: float, factor: float) -> float:
	var s: float = clampf(elapsed, 0.0, duration)
	return factor * (s - s * s / (2.0 * maxf(duration, 0.000001)))


func release_hold(vehicle: RigidBody2D) -> void:
	if not held.has(vehicle):
		return
	held[vehicle].unlock()
	held.erase(vehicle)
	vehicle.remove_meta("route_mode")
	vehicle.remove_meta("route_speed_m_s")
	vehicle.remove_meta("route_system")

func before_save() -> void:
	cancel_recording()
	for vehicle in tasks.keys():
		stop(vehicle, "Zapis gry przerwał odtwarzanie.")
	# Zablokowane na postoju ciała nie są częścią formatu zapisu.
	# Nowy świat tworzy je normalnie, z zerową prędkością.

func _physics_process(delta: float) -> void:
	_record_tick(delta)
	var plans: Dictionary = {}
	var blocked: Dictionary = {}
	var fatal: Dictionary = {}
	for vehicle in tasks:
		var task: Dictionary = tasks[vehicle]
		var route: Dictionary = task["route"]
		var ramp_duration: float = float(settings["resume_ramp_seconds"])
		var ramp_elapsed: float = float(task.get("ramp_elapsed", ramp_duration))
		var route_delta: float = ramp_integral(ramp_elapsed + delta, ramp_duration) - ramp_integral(ramp_elapsed, ramp_duration)
		if task.has("stop_elapsed"):
			var stop_duration: float = float(settings["stop_ramp_seconds"])
			var elapsed_stop: float = float(task["stop_elapsed"])
			route_delta = stop_integral(elapsed_stop + delta, stop_duration, float(task["stop_factor"])) - stop_integral(elapsed_stop, stop_duration, float(task["stop_factor"]))
			task["stop_elapsed"] = elapsed_stop + delta
		var finish: float = minf(float(task["time"]) + route_delta, float(route["samples"][-1][0]))
		var points: Array = Data.between(route, task["time"], finish, task["index"])
		task["rig"].refresh_shapes()
		var query_settings: Dictionary = settings.duplicate()
		if bool(task.get("paused", false)):
			query_settings["collision_margin_m"] = float(settings["collision_margin_m"]) + float(settings["resume_clearance_m"])
		var volumes: Array = _collision.volumes(task["rig"], points, query_settings)
		plans[vehicle] = {"finish": finish, "points": points, "volumes": volumes, "rate": route_delta / maxf(delta, 0.000001), "ramp_elapsed": minf(ramp_elapsed + delta, ramp_duration)}
		if volumes.is_empty():
			fatal[vehicle] = _collision.last_error
		elif _collision.blocked(get_world_2d().direct_space_state, volumes, task["rig"].excluded()):
			blocked[vehicle] = "Przeszkoda — pauza. Wznowienie po zwolnieniu miejsca."
	var vehicles: Array = plans.keys()
	for i in vehicles.size():
		for j in range(i + 1, vehicles.size()):
			if _collision.overlap(plans[vehicles[i]]["volumes"], plans[vehicles[j]]["volumes"]):
				blocked[vehicles[i]] = "Pauza: trasa innego zestawu blokuje przejazd."
				blocked[vehicles[j]] = "Pauza: trasa innego zestawu blokuje przejazd."
	for vehicle in fatal:
		stop(vehicle, fatal[vehicle])
	# Odwołane przejazdy: po wyhamowaniu (albo przy przeszkodzie) – zatrzymanie.
	for vehicle in tasks.keys():
		var stopping: Dictionary = tasks[vehicle]
		if stopping.has("stop_elapsed") and (float(stopping["stop_elapsed"]) >= float(settings["stop_ramp_seconds"]) or blocked.has(vehicle)):
			stop(vehicle, str(stopping.get("stop_reason", "Przejazd odwołany.")))
	for vehicle in tasks.keys():
		var pending: Dictionary = tasks[vehicle]
		if blocked.has(vehicle):
			pending["clear_time"] = 0.0
			if not bool(pending.get("paused", false)):
				pending["paused"] = true
				pending["ramp_elapsed"] = 0.0
				vehicle.set_meta("route_speed_m_s", 0.0)
				_fields.call("reset_route_sweep", pending["rig"].tool)
				message.emit(str(vehicle.get_meta("instance_state")["instance_id"]) + ": " + str(blocked[vehicle]))
				changed.emit()
			continue
		if bool(pending.get("paused", false)):
			pending["clear_time"] = float(pending.get("clear_time", 0.0)) + delta
			if float(pending["clear_time"]) < float(settings["resume_clear_seconds"]):
				continue
			pending["paused"] = false
			pending["clear_time"] = 0.0
			message.emit(str(vehicle.get_meta("instance_state")["instance_id"]) + ": wznowiono trasę.")
			changed.emit()
		var task: Dictionary = tasks[vehicle]
		var plan: Dictionary = plans[vehicle]
		task["ramp_elapsed"] = plan["ramp_elapsed"]
		var points: Array = plan["points"]
		# Praca narzędzia dostaje każdy przekroczony segment nagrania, także przy spadku FPS.
		for i in range(1, points.size()):
			var a: Array = points[i - 1]
			var b: Array = points[i]
			var movement := Vector2(b[1] - a[1], b[2] - a[2])
			var speed: float = movement.dot(Vector2.UP.rotated(lerp_angle(a[3], b[3], 0.5))) / maxf(0.000001, b[0] - a[0]) * float(plan["rate"])
			_fields.call("begin_route_segment", task["rig"].tool)
			task["rig"].apply(b)
			vehicle.set_meta("route_speed_m_s", speed)
			_fields.call("work_route_segment", vehicle, task["rig"].tool, speed)
		var cursor: Dictionary = Data.at(task["route"], plan["finish"], task["index"])
		task["index"] = cursor["index"]
		task["time"] = plan["finish"]
		if float(task["time"]) >= float(task["route"]["samples"][-1][0]):
			stop(vehicle, "Trasa zakończona.")

func _record_tick(delta: float) -> void:
	if recording.is_empty():
		return
	recording["time"] = float(recording["time"]) + delta
	var rig = recording["rig"]
	var point: Array = rig.sample(recording["time"])
	var moving: bool = rig.vehicle.linear_velocity.length() / _units > 0.01 or absf(rig.vehicle.angular_velocity) > 0.005
	# Zmiana ruchu albo pracy narzędzia (B): dwie próbki, żeby odtworzenie przełączyło się dokładnie tu.
	var previous_fold: float = float(recording["previous"][8])
	var fold_edge: bool = (previous_fold > 0.0 and previous_fold < 1.0) != (float(point[8]) > 0.0 and float(point[8]) < 1.0)
	if moving != bool(recording["moving"]) or float(point[7]) != float(recording["previous"][7]) or fold_edge:
		_append_sample(recording["previous"])
		_append_sample(point)
		recording["moving"] = moving
	if float(recording["time"]) + 0.0000001 >= float(recording["next"]):
		_append_sample(point)
		while float(recording["next"]) <= float(recording["time"]) + 0.0000001:
			recording["next"] = float(recording["next"]) + float(settings["sample_seconds"])
	recording["previous"] = point
	_add_record_point(rig.vehicle.global_position / _units)
	if float(recording["time"]) >= float(settings["max_recording_seconds"]):
		finish_recording()

# ---------------------------------------------------------------------------
# Przejazd oczekujący na start (zestaw widmo)
# ---------------------------------------------------------------------------

## Wyznacza trasę do przejechania przez pojazd. Nie startuje – patrz armed_status / start_armed.
func arm(vehicle: RigidBody2D, route: Dictionary) -> void:
	armed = {"vehicle": vehicle, "route": route}
	changed.emit()


func disarm() -> void:
	if not armed.is_empty():
		armed = {}
		changed.emit()


## Stan oczekującego przejazdu: {"valid", "at_start", "stopped", "tool_ok", "tool_needed": "activate"|"deactivate"|""}.
func armed_status() -> Dictionary:
	if armed.is_empty():
		return {"valid": false}
	var vehicle: RigidBody2D = armed["vehicle"]
	var route: Dictionary = armed["route"]
	if not is_instance_valid(vehicle):
		return {"valid": false}
	# Zestaw chwilowo inny (np. odpięte narzędzie): przejazd czeka, ale nie da się go uruchomić.
	if not compatible(vehicle).has(route):
		return {"valid": true, "matches": false, "at_start": false, "stopped": false, "tool_ok": false, "tool_needed": ""}
	var first: Array = route["samples"][0]
	var distance: float = vehicle.global_position.distance_to(Vector2(first[1], first[2]) * _units) / _units
	var heading_ok: bool = absf(rad_to_deg(angle_difference(vehicle.global_rotation, float(first[3])))) <= ARM_HEADING_TOLERANCE_DEG
	var rig = rig_for(vehicle)
	var needed: String = ""
	if rig != null and first.size() >= 8 and rig.tool != null:
		var want: bool = float(first[7]) > 0.5
		if want != rig.tool_working():
			needed = "activate" if want else "deactivate"
	return {"valid": true, "matches": true, "at_start": distance <= float(settings["start_distance_m"]) and heading_ok,
		"stopped": rig != null and rig.stopped(float(settings["start_speed_m_s"])),
		"tool_ok": needed.is_empty(), "tool_needed": needed, "distance_m": distance}


## Próba startu oczekującego przejazdu. Zwraca komunikat (pusty = wystartował).
func start_armed() -> String:
	var status: Dictionary = armed_status()
	if not bool(status.get("valid", false)):
		disarm()
		return "Przejazd odwołany – brak pojazdu."
	if not bool(status.get("matches", false)):
		return "Podepnij to samo narzędzie, co w nagraniu."
	if not bool(status["at_start"]):
		return "Podjedź na miejsce startu"
	if not bool(status["tool_ok"]):
		return "Aktywuj narzędzie (B)" if status["tool_needed"] == "activate" else "Dezaktywuj narzędzie (B)"
	if not bool(status["stopped"]):
		return "Zatrzymaj zestaw"
	var vehicle: RigidBody2D = armed["vehicle"]
	var route: Dictionary = armed["route"]
	start(vehicle, route)
	if tasks.has(vehicle):
		disarm()
		return ""
	return "Nie udało się uruchomić trasy."


func rename_route(id: String, title: String) -> void:
	title = title.strip_edges().left(80)
	if title.is_empty():
		message.emit("Podaj niepustą nazwę trasy.")
		return
	for route in routes:
		if str(route["id"]) == id:
			route["name"] = title
			message.emit("Zmieniono nazwę. Zapisz grę, aby utrwalić zmianę.")
			changed.emit()
			return

func delete_route(id: String) -> void:
	for task in tasks.values():
		if str(task["route"]["id"]) == id:
			message.emit("Najpierw przerwij wszystkie odtwarzania tej trasy, również te na pauzie.")
			return
	for index in routes.size():
		if str(routes[index]["id"]) == id:
			routes.remove_at(index)
			if str(armed.get("route", {}).get("id", "")) == id:
				disarm()
			message.emit("Usunięto trasę. Zapisz grę, aby utrwalić zmianę.")
			changed.emit()
			return

## Całka tempa 0..1. Wynik niezależny od liczby kroków fizyki.
## Czas rampy biegnie tylko podczas rzeczywiście wykonywanego ruchu trasy.
static func ramp_integral(elapsed: float, duration: float) -> float:
	elapsed = maxf(0.0, elapsed)
	if duration <= 0.0:
		return elapsed
	var accelerating: float = minf(elapsed, duration)
	return accelerating * accelerating / (2.0 * duration) + maxf(0.0, elapsed - duration)
