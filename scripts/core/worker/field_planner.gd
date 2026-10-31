extends RefCounted
## Planista pracownika (czysta logika): obróbka prostokątnego pola „wężykiem”, krok po kroku –
## jak pomocnik w Farming Simulator, ale bez objazdów po poboczach.
##
## 1. PIERWSZY PAS – tam, gdzie zestaw stoi: kierunek pasów to oś pola (północ–południe albo
##    wschód–zachód) najbliższa kierunkowi pojazdu, a linia pasa przechodzi przez pojazd. Zestaw
##    wyrównuje się na tę oś (łagodnie, bez pętli) i jedzie prosto, pracując od razu – aż skończy
##    się to, co jest do zrobienia przed nim (granica pola, zrobiona część, niezakultywowana ziemia
##    dla siewnika, stojąca maszyna).
## 2. NASTĘPNY PAS – tuż obok: zaczyna się przy krawędzi poprzedniego (rozstaw = szerokość −
##    zakładka), po tej stronie, gdzie jest bliżej coś do zrobienia; potem zawsze w tę samą stronę,
##    a gdy tam nic nie zostało – po drugiej stronie pierwszego pasa. Zrobione pasy są przeskakiwane.
##    Gdy zostaje pasek węższy niż narzędzie, narzędzie jedzie jego środkiem.
##    Wzdłuż pasa praca trwa w ciągłym odcinku do zrobienia, którego początek jest najbliżej
##    miejsca zawrotu – granica działa jak koniec pola.
## 3. ZAWRÓT – kandydaci od najlepszego, każdy sprawdzany is_free (cały zestaw z narzędziem):
##    do przodu (krzywa Dubinsa), z cofaniem (podjazd jak najdalej, cofanie, jazda, cofnięcie na
##    początek pasa), pasy krótsze o 2–10 m. Gdy nic się nie mieści – zestaw staje.
## 4. Plan obejmuje najwyżej max_lanes pasów; state opisuje, skąd planować dalej (warstwa gry
##    dokłada kolejne pasy w trakcie jazdy). Niedokończonych kawałków pracownik nie objeżdża.
##
## Wynik: path – pozy punktu prowadzącego [Vector3, rodzaj, praca], samples() – próbki trasy,
## passes_info – pasy (rezerwacja między pracownikami), state – miejsce na dalszą część planu.

const Dubins = preload("res://scripts/core/worker/dubins.gd")

var settings: Dictionary = {}
var rig: RefCounted
## profile(a: Vector2, b: Vector2, width: float, bins: int) -> PackedFloat32Array
## (udział komórek wymagających pracy w kolejnych kawałkach od a do b).
var profile: Callable
var is_free: Callable
## Jak is_free, ale tylko stojące przeszkody (bez innych pracujących zestawów – one odjadą).
var is_free_static: Callable
var world_rect := Rect2()
## Narzucony kierunek pasów (świat); ZERO – oś pola najbliższa kierunkowi pojazdu.
var axis_hint := Vector2.ZERO
## Najwyżej tyle pasów w jednym planie (0 – bez limitu).
var max_lanes: int = 0
var last_error: String = ""
var warning: String = ""
## [[Vector3 poza punktu prowadzącego, rodzaj ("approach"|"lead"|"work"|"turn"|"reverse"), praca: bool]]
var path: Array = []
var tool_rots := PackedFloat32Array()
var stats := {}
## Pasy planu: [{"from": Vector2, "to": Vector2, "width": float, "end": indeks w path, "end_time": s}].
var passes_info: Array = []
var lane_axis := Vector2.ZERO
## Skąd planować dalej: {"axis", "lane_u", "sign", "side", "band", "open"} (open – mogą być dalsze pasy).
var state: Dictionary = {}

var radius: float = 6.0
var tight_radius: float = 3.0
var _origin := Vector2.ZERO
var _u_axis := Vector2.RIGHT
var _v_axis := Vector2.DOWN
var _size := Vector2.ZERO          # (U, V) w układzie pasów
var _tool_rot: float = 0.0
var _across := PackedFloat32Array()
var _bin_m: float = 0.5


func _number(key: String, fallback: float) -> float:
	return float(settings.get(key, fallback))


## Plan z pozy pojazdu. previous – state poprzedniego planu (dalsze pasy z miejsca jego końca).
func plan(field_origin: Vector2, field_size: Vector2, field_rotation: float,
		vehicle_position: Vector2, vehicle_rot: float, tool_rot: float, previous: Dictionary = {}) -> bool:
	last_error = ""
	warning = ""
	path = []
	passes_info = []
	tool_rots = PackedFloat32Array()
	state = {}
	stats = {"passes": 0, "forward_turns": 0, "reverse_turns": 0, "shortened_turns": 0, "stopped_early": false,
		"truncated": false, "no_work": false}
	if rig.work_width <= 0.1:
		last_error = "Narzędzie nie ma szerokości roboczej."
		return false
	radius = maxf(rig.minimum_radius() * _number("turn_radius_factor", 1.5), _number("min_turn_radius_m", 6.0))
	tight_radius = rig.minimum_radius() * _number("tight_radius_factor", 1.15)
	_setup_frame(field_origin, field_size, field_rotation, vehicle_rot, previous.get("axis", axis_hint))
	lane_axis = _v_axis
	var start: Vector3 = rig.path_pose(vehicle_position, vehicle_rot)
	_tool_rot = tool_rot
	path.append([start, "approach", false])
	tool_rots.append(tool_rot)
	_bin_m = maxf(0.1, _number("profile_bin_m", 0.5))
	_across = _profile(_world(0.0, _size.y * 0.5), _world(_size.x, _size.y * 0.5), _size.y, maxi(1, ceili(_size.x / _bin_m)))
	var lane_u: float
	var sign: float
	var side: float = 0.0
	var band: Vector2
	var pending: Dictionary = {}       # pas czekający na decyzję o końcu (zawrót albo koniec planu)
	if previous.is_empty():
		var local: Vector2 = _to_local(Vector2(start.x, start.y))
		sign = 1.0 if Vector2(cos(start.z), sin(start.z)).dot(_v_axis) >= 0.0 else -1.0
		lane_u = clampf(local.x, 0.0, _size.x)
		band = Vector2(lane_u, lane_u)
		pending = _first_pass(lane_u, sign, start)
	else:
		lane_u = float(previous["lane_u"])
		sign = float(previous["sign"])
		side = float(previous["side"])
		band = previous["band"]
	var limit_reached: bool = false
	var entry_h: float = float(previous.get("entry_h", 0.0))
	while true:
		var planned: int = int(stats["passes"]) + (0 if pending.is_empty() else 1)
		limit_reached = max_lanes > 0 and planned >= max_lanes
		# Następny pas liczony także na granicy planu – od niego zależy, gdzie skończyć obecny
		# (zawrót musi się zmieścić); sam zawrót dołoży już następna część planu.
		var next: Dictionary = _next_pass(lane_u, sign, side, band, pending)
		if pending.is_empty():
			if next.is_empty() or limit_reached:
				break
			var turn: Dictionary = {}
			var used_h: float = entry_h
			for h in [entry_h, 0.0, 2.0, 4.0, 7.0, 10.0]:
				turn = _turn(_last_pose(), next["pass"], float(h), _tool_rot)
				if not turn.is_empty():
					used_h = float(h)
					break
			if turn.is_empty():
				warning = "Brak miejsca na dojazd do pasa – pracownik staje."
				stats["stopped_early"] = true
				break
			var kinds: Array = turn["kinds"] if not previous.is_empty() else turn["kinds"].map(func(kind): return "approach" if kind == "turn" else kind)
			_append_kinds(turn["poses"], kinds, turn["tools"])
			pending = {"pass": next["pass"], "on": _on_s(used_h)}
			lane_u = float(next["u"])
			sign = float(next["sign"])
			side = float(next["side"])
			band = Vector2(minf(band.x, lane_u), maxf(band.y, lane_u))
			continue
		var exit: Dictionary = _close_pass(pending, next)
		stats["passes"] += 1
		if limit_reached:
			entry_h = float(exit["h"])
			pending = {}
			if not next.is_empty() and exit["turn"].is_empty():
				warning = "Brak miejsca na zawrót – pracownik zatrzymał się po %d pasach." % stats["passes"]
				stats["stopped_early"] = true
			elif next.is_empty():
				limit_reached = false
			break
		if next.is_empty() or exit["turn"].is_empty():
			if not next.is_empty():
				warning = "Brak miejsca na zawrót – pracownik zatrzymał się po %d pasach." % stats["passes"]
				stats["stopped_early"] = true
			pending = {}
			break
		var turn: Dictionary = exit["turn"]
		stats[str(turn["type"])] += 1
		if float(exit["h"]) > 0.0:
			stats["shortened_turns"] += 1
		_append_kinds(turn["poses"], turn["kinds"], turn["tools"])
		pending = {"pass": next["pass"], "on": _on_s(float(exit["h"]))}
		lane_u = float(next["u"])
		sign = float(next["sign"])
		side = float(next["side"])
		band = Vector2(minf(band.x, lane_u), maxf(band.y, lane_u))
	stats["truncated"] = limit_reached
	state = {"axis": _v_axis, "lane_u": lane_u, "sign": sign, "side": side, "band": band, "entry_h": entry_h,
		"open": limit_reached and not bool(stats["stopped_early"])}
	if int(stats["passes"]) == 0:
		stats["no_work"] = not bool(stats["stopped_early"])
		last_error = warning if not warning.is_empty() else "Na tym polu nie ma teraz pracy dla tego narzędzia."
		return false
	return true


# ---------------------------------------------------------------------------
# Układ pasów
# ---------------------------------------------------------------------------

func _setup_frame(origin: Vector2, size: Vector2, rotation: float, vehicle_rot: float, axis: Vector2) -> void:
	var x_axis := Vector2.RIGHT.rotated(rotation)
	var y_axis := Vector2.DOWN.rotated(rotation)
	var direction: Vector2 = axis if axis != Vector2.ZERO else rig.forward(vehicle_rot)
	_origin = origin
	if absf(direction.dot(y_axis)) >= absf(direction.dot(x_axis)):
		_u_axis = x_axis
		_v_axis = y_axis
		_size = size
	else:
		_u_axis = y_axis
		_v_axis = x_axis
		_size = Vector2(size.y, size.x)


func _world(u: float, v: float) -> Vector2:
	return _origin + _u_axis * u + _v_axis * v


func _to_local(point: Vector2) -> Vector2:
	var relative: Vector2 = point - _origin
	return Vector2(relative.dot(_u_axis), relative.dot(_v_axis))


func _profile(a: Vector2, b: Vector2, width: float, bins: int) -> PackedFloat32Array:
	if profile.is_valid():
		return profile.call(a, b, width, bins)
	var full := PackedFloat32Array()
	full.resize(bins)
	full.fill(1.0)
	return full


## Ciągi koszy z udziałem ≥ threshold (przerwy krótsze niż gap_bins łączone): [Vector2i(od, do)].
static func runs(values: PackedFloat32Array, threshold: float, gap_bins: int) -> Array:
	var result: Array = []
	var start: int = -1
	var last: int = -1
	for i in values.size():
		if values[i] >= threshold:
			if start >= 0 and i - last - 1 > gap_bins:
				result.append(Vector2i(start, last))
				start = -1
			if start < 0:
				start = i
			last = i
	if start >= 0:
		result.append(Vector2i(start, last))
	return result


## Odcinki do zrobienia wzdłuż linii pasa u: [Vector2(v_od, v_do)] (v rosnąco).
func _lane_runs(u: float) -> Array:
	var bins: int = maxi(1, ceili(_size.y / _bin_m))
	var along: PackedFloat32Array = _profile(_world(u, 0.0), _world(u, _size.y), rig.work_width, bins)
	var result: Array = []
	for run in runs(along, _number("along_min_fraction", 0.05), int(_number("gap_m", 2.0) / _bin_m)):
		var v0: float = run.x * _size.y / bins
		var v1: float = minf(_size.y, (run.y + 1) * _size.y / bins)
		if v1 - v0 >= _number("min_pass_m", 3.0):
			result.append(Vector2(v0, v1))
	return result


## Pas na linii u w kierunku sign od v_from do v_to.
func _make_pass(u: float, sign: float, run: Vector2) -> Dictionary:
	var a: float = run.x if sign > 0.0 else run.y
	var b: float = run.y if sign > 0.0 else run.x
	return {"from": _world(u, a), "to": _world(u, b), "u": u}


## Pierwszy pas: linia przez pojazd, prosto przed siebie – odcinek do zrobienia, w którym zestaw
## jest albo który ma przed sobą. {"pass", "on"} albo {} (przed pojazdem nic nie ma).
func _first_pass(u: float, sign: float, start: Vector3) -> Dictionary:
	var here: float = _to_local(Vector2(start.x, start.y)).y
	var tool_point: float = _to_local(rig.work_point(rig.vehicle_pose(start), _tool_rot)).y
	var best: Vector2 = Vector2(INF, INF)
	for run in _lane_runs(u):
		var far_end: float = run.y if sign > 0.0 else run.x
		# Odcinek przed zestawem (albo pod narzędziem): jego dalszy koniec jest przed narzędziem.
		if (far_end - tool_point) * sign > 0.5:
			var near: float = run.x if sign > 0.0 else run.y
			if best.x == INF or (near - here) * sign < ((best.x if sign > 0.0 else best.y) - here) * sign:
				best = run
	if best.x == INF:
		return {}
	var pass_data: Dictionary = _make_pass(u, sign, best)
	_align(pass_data, start)
	return {"pass": pass_data, "on": -INF}


## Wyrównanie na linię pasa (zestaw stoi lekko krzywo): łagodny łuk na linię kilka metrów przed
## pojazdem. Przy małym odchyleniu narzędzie pracuje od razu.
func _align(pass_data: Dictionary, start: Vector3) -> void:
	var d: Vector2 = _direction(pass_data)
	var error: float = absf(angle_difference(start.z, atan2(d.y, d.x)))
	if error < deg_to_rad(1.0):
		return
	var s_here: float = (Vector2(start.x, start.y) - Vector2(pass_data["from"])).dot(d)
	var working: bool = error < deg_to_rad(_number("work_while_aligning_deg", 12.0))
	var step: float = _number("turn_sample_m", 0.3)
	for extra in settings.get("align_distances_m", [3.0, 5.0, 8.0, 12.0, 18.0, 26.0]):
		var goal: Vector3 = _pose_at(pass_data, s_here + float(extra))
		for candidate in _merge_paths(start, goal, step):
			var tools: PackedFloat32Array = _follow(candidate, _tool_rot)
			if _candidate_free(candidate, tools):
				for i in range(1, candidate.size()):
					path.append([candidate[i], "work" if working else "lead", working])
					tool_rots.append(tools[i])
				_tool_rot = tools[-1]
				return


## Następny pas obok: {"pass", "u", "sign", "side"} albo {}.
func _next_pass(lane_u: float, sign: float, side: float, band: Vector2, pending: Dictionary) -> Dictionary:
	# Miejsce zawrotu (v) – koniec obecnego pasa albo miejsce, gdzie zestaw stoi.
	var here_v: float
	if not pending.is_empty():
		here_v = _to_local(pending["pass"]["to"]).y
	else:
		here_v = _to_local(Vector2(_last_pose().x, _last_pose().y)).y
	var sides: Array = []
	if side != 0.0:
		sides = [side, -side]
	else:
		# Pierwszy wybór: strona, po której najbliżej jest coś do zrobienia.
		var plus: float = _next_lane(band, 1.0)
		var minus: float = _next_lane(band, -1.0)
		if is_nan(plus) and is_nan(minus):
			sides = []
		elif is_nan(minus) or (not is_nan(plus) and absf(plus - lane_u) <= absf(minus - lane_u)):
			sides = [1.0, -1.0]
		else:
			sides = [-1.0, 1.0]
	for candidate_side in sides:
		var u: float = _next_lane(band, candidate_side)
		if is_nan(u):
			continue
		# Kierunek: odcinek, którego początek jest najbliżej miejsca zawrotu.
		var best: Dictionary = {}
		var best_distance: float = INF
		for run in _lane_runs(u):
			for direction in [1.0, -1.0]:
				var near: float = run.x if direction > 0.0 else run.y
				var distance: float = absf(near - here_v)
				if distance < best_distance:
					best_distance = distance
					best = {"pass": _make_pass(u, direction, run), "u": u, "sign": direction, "side": candidate_side}
		if not best.is_empty():
			return best
	return {}


## Środek następnego pasa za zakresem zrobionych pasów band w stronę side (NAN – nic tam nie ma).
## Zaczyna się przy krawędzi poprzedniego pasa (zakładka), przeskakuje zrobione kawałki;
## pasek węższy niż narzędzie – narzędzie jego środkiem.
func _next_lane(band: Vector2, side: float) -> float:
	var width: float = rig.work_width
	var overlap: float = _number("lane_overlap_m", 0.3)
	var edge: float = (band.y if side > 0.0 else band.x) + side * (width * 0.5 - overlap)
	var threshold: float = _number("lane_min_fraction", 0.01)
	var gap: int = int(_number("gap_m", 2.0) / _bin_m)
	var count: int = _across.size()
	var i: int = int(floor(edge / _bin_m)) if side > 0.0 else int(ceil(edge / _bin_m)) - 1
	while i >= 0 and i < count and _across[i] < threshold:
		i += int(side)
	if i < 0 or i >= count:
		return NAN
	var begin: float = maxf(edge, i * _bin_m) if side > 0.0 else minf(edge, (i + 1) * _bin_m)
	var last: int = i
	var j: int = i
	while j >= 0 and j < count and absi(j - last) - 1 <= gap:
		if _across[j] >= threshold:
			last = j
		j += int(side)
	var end: float = minf(_size.x, (last + 1) * _bin_m) if side > 0.0 else maxf(0.0, last * _bin_m)
	var available: float = absf(end - begin)
	if available < _number("min_strip_m", 0.3):
		return NAN
	return begin + side * minf(width, available) * 0.5


## Kończy pas (dopisuje go) z wyborem miejsca zjazdu i zawrotu na pas next:
## {"h": skrócenie, "turn": zawrót albo {}}.
func _close_pass(pending: Dictionary, next: Dictionary) -> Dictionary:
	var pass_data: Dictionary = pending["pass"]
	var on: float = float(pending["on"])
	var exit_tool: float = _rot_of(_direction(pass_data))
	var s_here: float = (Vector2(_last_pose().x, _last_pose().y) - Vector2(pass_data["from"])).dot(_direction(pass_data))
	var start_s: float = maxf(on, s_here)
	var exit_h: float = -1.0
	var turn: Dictionary = {}
	var farthest: float = -1.0
	# Maszyna stojąca na pasie: pas kończy się przed nią (dalej zostaje – jak koniec pola).
	var blocked_h: float = _pass_block(pass_data, start_s, exit_tool)
	for backoff in settings.get("exit_backoffs_m", [0.0, 2.0, 4.0, 7.0, 10.0]):
		var h: float = float(backoff) + blocked_h
		if _off_s(pass_data, h) <= start_s + 1.0:
			break
		if not _run_out_free(pass_data, h, exit_tool):
			continue
		if farthest < 0.0:
			farthest = h
		if next.is_empty():
			break
		turn = _turn(_pose_at(pass_data, _off_s(pass_data, h)), next["pass"], h, exit_tool)
		if not turn.is_empty():
			exit_h = h
			break
	if exit_h < 0.0:
		exit_h = maxf(farthest, blocked_h) if farthest >= 0.0 else blocked_h
	_append_pass(pass_data, on, exit_h)
	return {"h": exit_h, "turn": turn}


static func _direction(pass_data: Dictionary) -> Vector2:
	return (Vector2(pass_data["to"]) - Vector2(pass_data["from"])).normalized()


static func _length(pass_data: Dictionary) -> float:
	return Vector2(pass_data["from"]).distance_to(pass_data["to"])


func _point(pass_data: Dictionary, s: float) -> Vector2:
	return Vector2(pass_data["from"]) + _direction(pass_data) * s


func _pose_at(pass_data: Dictionary, s: float) -> Vector3:
	var point: Vector2 = _point(pass_data, s)
	var d: Vector2 = _direction(pass_data)
	return Vector3(point.x, point.y, atan2(d.y, d.x))


## Punkt prowadzący w chwili opuszczenia narzędzia (przód obszaru roboczego na początku pasa).
func _on_s(h: float) -> float:
	return h - rig.work_offset() - rig.work_length * 0.5 - _number("tool_margin_m", 0.5)


## Punkt prowadzący w chwili podniesienia narzędzia (tył obszaru roboczego za końcem pasa).
func _off_s(pass_data: Dictionary, h: float) -> float:
	return _length(pass_data) - h + rig.work_length * 0.5 - rig.work_offset() + _number("tool_margin_m", 0.5)


func _lead() -> float:
	return _number("towed_lead_in_factor", 3.0) * rig.tool_length() if rig.towed() else _number("mounted_lead_in_m", 2.0)


## Łagodne ścieżki z pozy start na linię pasa (bez pętli): Hermite, potem Dubins bez okrążenia.
func _merge_paths(start: Vector3, goal: Vector3, step: float) -> Array:
	var result: Array = []
	var smooth: Array = _smooth(start, goal, step)
	if not smooth.is_empty():
		result.append(smooth)
	var allowed: float = absf(angle_difference(start.z, goal.z)) + _number("loop_slack_rad", 0.6)
	for r in [radius, tight_radius]:
		for candidate in Dubins.paths(start, goal, r):
			if _turning(candidate) <= allowed:
				result.append(Dubins.sample(start, candidate["segments"], r, step))
				break
	return result


static func _turning(candidate: Dictionary) -> float:
	var total: float = 0.0
	for segment in candidate["segments"]:
		if str(segment[0]) != "S":
			total += float(segment[1])
	return total


## Łagodna krzywa (Hermite) ze startu do celu; pusta, gdy wymaga ostrzejszego skrętu niż
## pozwalają koła (minimalny promień · 1,1) albo cel nie leży przed pojazdem.
func _smooth(start: Vector3, goal: Vector3, step: float) -> Array:
	var a := Vector2(start.x, start.y)
	var b := Vector2(goal.x, goal.y)
	var distance: float = a.distance_to(b)
	var ta := Vector2(cos(start.z), sin(start.z))
	var tb := Vector2(cos(goal.z), sin(goal.z))
	if distance < 0.5 or (b - a).dot(ta) <= 0.0 or ta.dot(tb) < cos(deg_to_rad(60.0)):
		return []
	var limit: float = 1.0 / (rig.minimum_radius() * 1.1)
	var count: int = maxi(4, ceili(distance / maxf(step, 0.05)))
	var result: Array = [start]
	var previous_heading: float = start.z
	var previous_point: Vector2 = a
	for i in range(1, count + 1):
		var t: float = float(i) / count
		var h00: float = 2.0 * t * t * t - 3.0 * t * t + 1.0
		var h10: float = t * t * t - 2.0 * t * t + t
		var h01: float = -2.0 * t * t * t + 3.0 * t * t
		var h11: float = t * t * t - t * t
		var point: Vector2 = a * h00 + ta * distance * h10 + b * h01 + tb * distance * h11
		var d00: float = 6.0 * t * t - 6.0 * t
		var d10: float = 3.0 * t * t - 4.0 * t + 1.0
		var d01: float = -6.0 * t * t + 6.0 * t
		var d11: float = 3.0 * t * t - 2.0 * t
		var tangent: Vector2 = a * d00 + ta * distance * d10 + b * d01 + tb * distance * d11
		var heading: float = atan2(tangent.y, tangent.x)
		var ds: float = point.distance_to(previous_point)
		if ds > 0.0001 and absf(angle_difference(previous_heading, heading)) / ds > limit:
			return []
		result.append(Vector3(point.x, point.y, heading))
		previous_heading = heading
		previous_point = point
	result[-1] = goal
	return result


# ---------------------------------------------------------------------------
# Zawroty
# ---------------------------------------------------------------------------

## Skrócenie końca pasa [m], gdy na pasie stoi maszyna: sprawdzany odcinkami po 5 m od miejsca
## opuszczenia narzędzia; 0 – pas wolny do końca.
func _pass_block(pass_data: Dictionary, on: float, tool_rot: float) -> float:
	var off: float = _off_s(pass_data, 0.0)
	var chunk: float = 5.0
	var s: float = maxf(on, 0.0)
	while s < off - 0.01:
		var length: float = minf(chunk, off - s)
		var poses: Array = _straight(_pose_at(pass_data, s), length, _number("pass_sample_m", 1.0))
		if not _candidate_free(poses, _follow(poses, tool_rot), true):
			return maxf(0.0, off - s + _number("tool_margin_m", 0.5))
		s += length
	return 0.0


## Zawrót z pozy exit na pas next (wjazd skrócony o h). {"poses", "kinds", "tools", "type"} albo {}.
func _turn(exit: Vector3, next: Dictionary, h: float, tool_rot: float) -> Dictionary:
	var step: float = _number("turn_sample_m", 0.3)
	var goal: Vector3 = _pose_at(next, _on_s(h) - _lead())
	var lead: Array = _straight(goal, _lead(), step).slice(1)
	# a) do przodu
	for factor in settings.get("radius_factors", [1.0, 1.3, 1.7]):
		var r: float = radius * float(factor)
		for candidate in Dubins.paths(exit, goal, r):
			var poses: Array = Dubins.sample(exit, candidate["segments"], r, step)
			var result: Dictionary = _try(poses, [], lead, tool_rot, "forward_turns")
			if not result.is_empty():
				return result
	# b) z cofaniem
	if not bool(settings.get("allow_reverse", true)):
		return {}
	for maneuver in _reverse_maneuvers(exit, goal, step):
		var result: Dictionary = _try(maneuver[0], maneuver[1], lead, tool_rot, "reverse_turns")
		if not result.is_empty():
			return result
	return {}


## Sprawdza kandydata (pozy od pozy startowej, rodzaje odcinków – puste = do przodu) razem
## z wjazdem lead. Wynik bez pozy startowej i bez wjazdu.
func _try(poses: Array, kinds: Array, lead: Array, tool_rot: float, type: String) -> Dictionary:
	var checked: Array = poses.duplicate()
	checked.append_array(lead)
	var tools: PackedFloat32Array = _follow(checked, tool_rot)
	if not _candidate_free(checked, tools):
		return {}
	var count: int = poses.size()
	var result_kinds: Array = []
	for i in range(1, count):
		result_kinds.append(kinds[i] if i < kinds.size() else "turn")
	return {"poses": poses.slice(1), "kinds": result_kinds, "tools": tools.slice(1, count), "type": type}


## Manewry z cofaniem (od najkrótszego): [pozy od exit, rodzaje].
##   – podjazd (0 albo kilka m), łuk do przodu, łuk wstecz z przeciwnym skrętem, jazda do wjazdu,
##   – łuk wstecz, łuk do przodu, cofnięcie po krzywej na początek pasa.
## Ostatni odcinek bez dodatkowych okrążeń. Promień – najciaśniejszy (tight_radius).
func _reverse_maneuvers(exit: Vector3, goal: Vector3, step: float) -> Array:
	var r: float = tight_radius
	var candidates: Array = []
	var angles: Array = settings.get("reverse_angles_deg", [45.0, 70.0, 95.0, 120.0, 145.0])
	for extra in settings.get("reverse_pull_forward_m", [0.0, 4.0]):
		var pulled: Array = _straight(exit, float(extra), step)
		var origin: Vector3 = pulled[-1]
		for first in ["L", "R"]:
			var second: String = "R" if first == "L" else "L"
			for a1 in angles:
				for a2 in angles:
					# Do przodu – wstecz – do przodu.
					var poses: Array = pulled.duplicate()
					var kinds: Array = []
					for i in poses.size():
						kinds.append("turn")
					var arc1: Array = _arc(origin, first, r * deg_to_rad(float(a1)), r, false, step)
					var arc2: Array = _arc(arc1[-1], second, r * deg_to_rad(float(a2)), r, true, step)
					var tail: Array = _loop_free(arc2[-1], goal, step, false)
					if not tail.is_empty():
						candidates.append(_joined(poses, kinds, [[arc1, "turn"], [arc2, "reverse"], [tail, "turn"]]))
					# Wstecz – do przodu – cofnięcie na początek pasa.
					var back1: Array = _arc(origin, first, r * deg_to_rad(float(a1)), r, true, step)
					var forward2: Array = _arc(back1[-1], second, r * deg_to_rad(float(a2)), r, false, step)
					var back_tail: Array = _loop_free(forward2[-1], goal, step, true)
					if not back_tail.is_empty():
						candidates.append(_joined(poses, kinds, [[back1, "reverse"], [forward2, "turn"], [back_tail, "reverse"]]))
	candidates.sort_custom(func(p, q): return _path_length(p[0]) < _path_length(q[0]))
	return candidates


static func _joined(poses: Array, kinds: Array, parts: Array) -> Array:
	var all_poses: Array = poses.duplicate()
	var all_kinds: Array = kinds.duplicate()
	for part in parts:
		for pose in (part[0] as Array).slice(1):
			all_poses.append(pose)
			all_kinds.append(part[1])
	return [all_poses, all_kinds]


static func _path_length(poses: Array) -> float:
	var total: float = 0.0
	for i in range(1, poses.size()):
		total += Vector2(poses[i].x, poses[i].y).distance_to(Vector2(poses[i - 1].x, poses[i - 1].y))
	return total


## Łuk o długości length (wstecz: zestaw cofa się po okręgu skrętu kind).
static func _arc(start: Vector3, kind: String, length: float, r: float, reverse: bool, step: float) -> Array:
	var result: Array = [start]
	var count: int = maxi(1, ceili(length / maxf(step, 0.05)))
	for i in range(1, count + 1):
		result.append(Dubins.advance(start, kind, (-length if reverse else length) * i / count, r))
	return result


## Ścieżka bez dodatkowego okrążenia z from do goal (do przodu albo wstecz); [] gdy brak.
func _loop_free(from: Vector3, goal: Vector3, step: float, reverse: bool) -> Array:
	var a: Vector3 = Vector3(from.x, from.y, from.z + PI) if reverse else from
	var b: Vector3 = Vector3(goal.x, goal.y, goal.z + PI) if reverse else goal
	# Esowate dojście dozwolone, pełne okrążenie – nie.
	var allowed: float = absf(angle_difference(a.z, b.z)) + _number("maneuver_slack_rad", 2.0)
	for r in [tight_radius, radius]:
		for candidate in Dubins.paths(a, b, r):
			if _turning(candidate) > allowed:
				continue
			var poses: Array = Dubins.sample(a, candidate["segments"], r, step)
			if reverse:
				for i in poses.size():
					poses[i] = Vector3(poses[i].x, poses[i].y, poses[i].z - PI)
			return poses
	return []


static func _rot_of(direction: Vector2) -> float:
	return atan2(direction.x, -direction.y)


## Obroty narzędzia wzdłuż póz (od tool_rot; także przy cofaniu).
func _follow(poses: Array, tool_rot: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	var previous: Vector3 = rig.vehicle_pose(poses[0])
	var current_tool: float = tool_rot
	for pose in poses:
		var vehicle: Vector3 = rig.vehicle_pose(pose)
		current_tool = rig.follow_tool(current_tool, previous, vehicle)
		result.append(current_tool)
		previous = vehicle
	return result


## Kandydat w granicach świata, bez złożenia narzędzia (kąt) i bez kolizji (is_free).
func _candidate_free(poses: Array, tools: PackedFloat32Array, static_only: bool = false) -> bool:
	var inner: Rect2 = world_rect.grow(-1.0)
	var jackknife: float = deg_to_rad(_number("max_tool_angle_deg", 75.0))
	for i in poses.size():
		var vehicle: Vector3 = rig.vehicle_pose(poses[i])
		if world_rect.size != Vector2.ZERO and not inner.has_point(Vector2(vehicle.x, vehicle.y)):
			return false
		if rig.towed() and absf(angle_difference(vehicle.z, tools[i])) > jackknife:
			return false
	var check: Callable = is_free_static if static_only and is_free_static.is_valid() else is_free
	if not check.is_valid():
		return true
	var samples: Array = []
	for i in poses.size():
		samples.append(_sample(float(i), poses[i], tools[i], false, 0.0))
	return bool(check.call(samples))


## Czy końcówka pasa (ostatnie metry pracy i zjazd) przy skróceniu h jest wolna.
func _run_out_free(pass_data: Dictionary, h: float, tool_rot: float) -> bool:
	var exit: Vector3 = _pose_at(pass_data, _off_s(pass_data, h))
	var back: float = rig.work_length + _number("tool_margin_m", 0.5) + 4.0
	var poses: Array = _straight(Dubins.advance(exit, "S", -back, 1.0), back, _number("turn_sample_m", 0.3))
	return _candidate_free(poses, _follow(poses, tool_rot))


static func _straight(start: Vector3, length: float, step: float) -> Array:
	var result: Array = [start]
	if length <= 0.0001:
		return result
	var count: int = maxi(1, ceili(length / maxf(step, 0.01)))
	for i in range(1, count + 1):
		result.append(Dubins.advance(start, "S", length * i / count, 1.0))
	return result


func _last_pose() -> Vector3:
	return path[-1][0]


func _append(poses: Array, kind: String, tools: PackedFloat32Array) -> void:
	for i in poses.size():
		path.append([poses[i], kind, false])
		tool_rots.append(tools[i])
	if not tools.is_empty():
		_tool_rot = tools[-1]


func _append_kinds(poses: Array, kinds: Array, tools: PackedFloat32Array) -> void:
	for i in poses.size():
		path.append([poses[i], kinds[i], false])
		tool_rots.append(tools[i])
	if not tools.is_empty():
		_tool_rot = tools[-1]


## Pas od obecnej pozy (na linii pasa): wjazd do on, praca do zjazdu (skrócenie exit_h).
func _append_pass(pass_data: Dictionary, on: float, exit_h: float) -> void:
	var here: Vector3 = _last_pose()
	var d: Vector2 = _direction(pass_data)
	var s_here: float = (Vector2(here.x, here.y) - Vector2(pass_data["from"])).dot(d)
	var start: Vector3 = _pose_at(pass_data, s_here)
	var off: float = _off_s(pass_data, exit_h)
	on = clampf(on, s_here, off)
	var poses: Array = []
	var kinds: Array = []
	for pose in _straight(start, on - s_here, _number("turn_sample_m", 0.3)).slice(1):
		poses.append(pose)
		kinds.append(["lead", false])
	for pose in _straight(_pose_at(pass_data, on), off - on, _number("pass_sample_m", 1.0)).slice(1):
		poses.append(pose)
		kinds.append(["work", true])
	var tools: PackedFloat32Array = _follow([here] + poses, _tool_rot).slice(1)
	for i in poses.size():
		path.append([poses[i], kinds[i][0], kinds[i][1]])
		tool_rots.append(tools[i])
	if not tools.is_empty():
		_tool_rot = tools[-1]
	passes_info.append({"from": _point(pass_data, maxf(0.0, on + rig.work_offset())), "to": _point(pass_data, minf(_length(pass_data), off + rig.work_offset())),
		"width": rig.work_width, "end": path.size() - 1, "end_time": 0.0})


# ---------------------------------------------------------------------------
# Próbki trasy
# ---------------------------------------------------------------------------

## Próbka w formacie tras (route_sample.gd): [czas, x, y, obrót, kąt narzędzia, 0, skręt, praca, rozłożenie].
func _sample(time: float, pose: Vector3, tool_rot: float, working: bool, steering: float, fold: float = 1.0) -> Array:
	var vehicle: Vector3 = rig.vehicle_pose(pose)
	var tool_angle: float = angle_difference(vehicle.z, tool_rot) if rig.towed() else 0.0
	return [time, vehicle.x, vehicle.y, vehicle.z, tool_angle, 0.0, steering, 1.0 if working else 0.0, fold]


## Prędkość docelowa [m/s] dla rodzaju odcinka.
func _target_speed(kind: String, work_speed_m_s: float) -> float:
	match kind:
		"work":
			return work_speed_m_s
		"lead":
			return minf(work_speed_m_s, _number("turn_speed_kmh", 7.0) / 3.6)
		"approach":
			return _number("approach_speed_kmh", 10.0) / 3.6
		"reverse":
			return _number("reverse_speed_kmh", 4.0) / 3.6
	return _number("turn_speed_kmh", 7.0) / 3.6


## Kierunek ruchu z pozy a do b: +1 do przodu, −1 wstecz.
static func _motion_sign(a: Vector3, b: Vector3) -> float:
	var move := Vector2(b.x - a.x, b.y - a.y)
	return -1.0 if move.dot(Vector2(cos(a.z), sin(a.z))) < 0.0 else 1.0


## Próbki trasy z planu: prędkości z ograniczeniem przyspieszenia (postój przy zmianie kierunku),
## rozkładanie narzędzia na postoju na początku (fold_now < 1, trwa fold_seconds · (1 − fold_now)).
## start_moving / end_moving – plan jest kontynuacją jadącej trasy / będzie miał ciąg dalszy:
## na początku i na końcu prędkość zawrotu zamiast postoju.
func samples(work_speed_m_s: float, fold_now: float = 1.0, fold_seconds: float = 0.0,
		start_moving: bool = false, end_moving: bool = false) -> Array:
	var count: int = path.size()
	var distances := PackedFloat32Array()
	distances.resize(count)
	var speeds := PackedFloat32Array()
	speeds.resize(count)
	var signs := PackedFloat32Array()
	signs.resize(count)
	for i in count:
		speeds[i] = _target_speed(str(path[i][1]), work_speed_m_s)
		if i > 0:
			var a: Vector3 = path[i - 1][0]
			var b: Vector3 = path[i][0]
			distances[i] = Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y))
			signs[i] = _motion_sign(a, b)
	signs[0] = signs[1] if count > 1 else 1.0
	var accel: float = maxf(0.1, _number("accel_m_s2", 0.8))
	var turn_speed: float = _number("turn_speed_kmh", 7.0) / 3.6
	speeds[0] = minf(speeds[0], turn_speed) if start_moving else 0.0
	speeds[count - 1] = minf(speeds[count - 1], turn_speed) if end_moving else 0.0
	for i in range(1, count - 1):
		if signs[i] != signs[i + 1]:
			speeds[i] = 0.0          # zmiana kierunku jazdy – postój
	for i in range(1, count):
		speeds[i] = minf(speeds[i], sqrt(speeds[i - 1] * speeds[i - 1] + 2.0 * accel * distances[i]))
	for i in range(count - 2, -1, -1):
		speeds[i] = minf(speeds[i], sqrt(speeds[i + 1] * speeds[i + 1] + 2.0 * accel * distances[i + 1]))
	var result: Array = []
	var times := PackedFloat32Array()
	times.resize(count)
	var time: float = 0.0
	var fold: float = clampf(fold_now, 0.0, 1.0)
	result.append(_sample(0.0, path[0][0], tool_rots[0], false, 0.0, fold))
	if fold < 1.0:
		time = maxf(0.1, fold_seconds * (1.0 - fold))
		result.append(_sample(time, path[0][0], tool_rots[0], false, 0.0, 1.0))
	times[0] = time
	for i in range(1, count):
		var average: float = maxf(0.05, (speeds[i - 1] + speeds[i]) * 0.5)
		time += maxf(0.001, distances[i] / average)
		times[i] = time
		var a: Vector3 = path[i - 1][0]
		var b: Vector3 = path[i][0]
		var curvature: float = angle_difference(a.z, b.z) / maxf(distances[i], 0.001) * signs[i]
		# Praca obowiązuje od próbki na początku odcinka (route_sample.gd).
		var working: bool = i + 1 < count and bool(path[i + 1][2])
		result.append(_sample(time, b, tool_rots[i], working, rig.steering_for(curvature)))
	for info in passes_info:
		info["end_time"] = times[int(info["end"])]
	return result


## Linie planu do podglądu: [{"kind", "points": PackedVector2Array}] (środek pojazdu, metry).
func preview() -> Array:
	var result: Array = []
	var current: Dictionary = {}
	for entry in path:
		var kind: String = "work" if bool(entry[2]) else str(entry[1])
		var vehicle: Vector3 = rig.vehicle_pose(entry[0])
		var point := Vector2(vehicle.x, vehicle.y)
		if current.is_empty() or current["kind"] != kind:
			var points := PackedVector2Array()
			if not current.is_empty():
				points.append(current["points"][-1])
			current = {"kind": kind, "points": points}
			result.append(current)
		current["points"].append(point)
	return result
