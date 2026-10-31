extends RefCounted
## Planista pracownika (czysta logika): obróbka prostokątnego pola „wężykiem”.
##
## 1. Pasy równoległe do tej krawędzi pola, która jest najbliżej kierunku jazdy pojazdu; rozstaw
##    = szerokość robocza − zakładka; ostatni pas dosunięty do krawędzi. Pasy, które nie wymagają
##    pracy (needs_work, np. już zebrane), są pomijane – dlatego ponowne zatrudnienie dokańcza pole.
## 2. Start od narożnika najbliższego pojazdowi; kolejne pasy w przeciwnych kierunkach.
## 3. Narzędzie opuszcza się, gdy przód obszaru roboczego dochodzi do krawędzi pola, a podnosi,
##    gdy jego tył ją minie (obszar roboczy narzędzia przyczepianego jest daleko za pojazdem).
##    Przed pasem prosty odcinek wjazdu – narzędzie przyczepiane zdąży się wyprostować.
## 4. Zawrót między pasami (i dojazd do pierwszego pasa) to krzywa Dubinsa (dubins.gd).
##    Kandydaci od najlepszego: zawrót POZA polem (promień R, większe promienie, wszystkie kształty
##    od najkrótszego), a gdy żaden się nie mieści – zawrót na UWROCIU: oba pasy kończą się
##    o h metrów wcześniej (h = 1, 2, 3 szerokości pasa) i zawrót odbywa się nad polem.
##    Każdy kandydat jest sprawdzany przez is_free (cały zestaw, także narzędzie) i granice świata.
## 5. Niedokończone uwrocia (końce skróconych pasów) są obrabiane na końcu – też wężykiem, pasami
##    w poprzek ich końców. Bez objazdu dookoła pola.
##
## Wejście: rig (worker_rig.gd), settings (workers.json), pole (origin, size, rotation – świat [m]),
## needs_work(środek: Vector2, rot: float, rozmiar: Vector2) -> bool,
## is_free(próbki trasy: Array) -> bool (kolizje sprawdza warstwa gry), world_rect.
## Wynik: path – pozy punktu prowadzącego [Vector3, rodzaj, praca], samples() – próbki trasy.

const Dubins = preload("res://scripts/core/worker/dubins.gd")

var settings: Dictionary = {}
var rig: RefCounted
var needs_work: Callable
var is_free: Callable
var world_rect := Rect2()
var last_error: String = ""
## Ostrzeżenie dla gracza (plan częściowy, pominięte uwrocie…).
var warning: String = ""
## [[Vector3 poza punktu prowadzącego, rodzaj ("approach"|"lead"|"work"|"turn"), praca: bool]]
var path: Array = []
## Obroty narzędzia (gra) dla każdej pozy path.
var tool_rots := PackedFloat32Array()
var stats := {"passes": 0, "skipped": 0, "outside_turns": 0, "headland_turns": 0, "cleanup_passes": 0}

var radius: float = 6.0
var _origin := Vector2.ZERO
var _u_axis := Vector2.RIGHT
var _v_axis := Vector2.DOWN
var _size := Vector2.ZERO          # (U, V) w układzie pasów
var _tool_rot: float = 0.0
## Skrócone końce pasów: klucz "low"/"high" → [[u_min, u_max, głębokość]].
var _headlands := {"low": [], "high": []}


func _number(key: String, fallback: float) -> float:
	return float(settings.get(key, fallback))


## Plan obróbki pola z pozy pojazdu (położenie, obrót) i obrotu narzędzia. false → last_error.
func plan(field_origin: Vector2, field_size: Vector2, field_rotation: float,
		vehicle_position: Vector2, vehicle_rot: float, tool_rot: float) -> bool:
	last_error = ""
	warning = ""
	path = []
	tool_rots = PackedFloat32Array()
	_headlands = {"low": [], "high": []}
	stats = {"passes": 0, "skipped": 0, "outside_turns": 0, "headland_turns": 0, "cleanup_passes": 0}
	if rig.work_width <= 0.1:
		last_error = "Narzędzie nie ma szerokości roboczej."
		return false
	radius = maxf(rig.minimum_radius() * _number("turn_radius_factor", 1.5), _number("min_turn_radius_m", 6.0))
	_setup_frame(field_origin, field_size, field_rotation, vehicle_rot)
	var start: Vector3 = rig.path_pose(vehicle_position, vehicle_rot)
	_tool_rot = tool_rot
	path.append([start, "approach", false])
	tool_rots.append(tool_rot)
	var local: Vector2 = _to_local(vehicle_position)
	var passes: Array = _main_passes(local)
	if passes.is_empty():
		last_error = "To pole nie wymaga tej pracy." if stats["skipped"] > 0 else "Pole jest za małe dla tego narzędzia."
		return false
	if not _run_passes(passes, "approach", true):
		return false
	_cleanup()
	return true


# ---------------------------------------------------------------------------
# Układ pasów
# ---------------------------------------------------------------------------

func _setup_frame(origin: Vector2, size: Vector2, rotation: float, vehicle_rot: float) -> void:
	var x_axis := Vector2.RIGHT.rotated(rotation)
	var y_axis := Vector2.DOWN.rotated(rotation)
	var forward: Vector2 = rig.forward(vehicle_rot)
	_origin = origin
	if absf(forward.dot(y_axis)) >= absf(forward.dot(x_axis)):
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


static func _rot_of(direction: Vector2) -> float:
	return atan2(direction.x, -direction.y)


## Środki pasów wzdłuż osi o długości span (pas o szerokości width, rozstaw step).
static func lane_centers(span: float, width: float, step: float) -> PackedFloat32Array:
	var result := PackedFloat32Array()
	if span <= width:
		result.append(span * 0.5)
		return result
	var count: int = ceili((span - width) / maxf(step, 0.1) - 0.0001) + 1
	for i in count:
		result.append(minf(width * 0.5 + i * step, span - width * 0.5))
	return result


func _main_passes(local: Vector2) -> Array:
	var width: float = rig.work_width
	var step: float = maxf(0.5, width - _number("lane_overlap_m", 0.3))
	var centers: PackedFloat32Array = lane_centers(_size.x, width, step)
	if local.x > _size.x * 0.5:
		centers.reverse()
	var sign: float = 1.0 if local.y <= _size.y * 0.5 else -1.0
	var passes: Array = []
	for u in centers:
		var center: Vector2 = _world(u, _size.y * 0.5)
		if needs_work.is_valid() and not bool(needs_work.call(center, _rot_of(_v_axis), Vector2(width, _size.y))):
			stats["skipped"] += 1
			continue
		passes.append({"from": _world(u, 0.0 if sign > 0.0 else _size.y), "to": _world(u, _size.y if sign > 0.0 else 0.0),
			"u": u, "entry": "low" if sign > 0.0 else "high", "exit": "high" if sign > 0.0 else "low"})
		sign = -sign
	return passes


# ---------------------------------------------------------------------------
# Pasy i zawroty
# ---------------------------------------------------------------------------

## Wjazd na pas (poza na początku odcinka wjazdu) przy skróceniu h od strony wjazdu.
func _entry_pose(pass_data: Dictionary, h: float) -> Vector3:
	var a: Vector2 = pass_data["from"]
	var b: Vector2 = pass_data["to"]
	var d: Vector2 = (b - a).normalized()
	var on: Vector2 = a + d * (h - rig.work_offset() - rig.work_length * 0.5 - _number("tool_margin_m", 0.5))
	var lead: float = _number("towed_lead_in_factor", 3.0) * rig.tool_length() if rig.towed() else _number("mounted_lead_in_m", 2.0)
	var entry: Vector2 = on - d * lead
	return Vector3(entry.x, entry.y, atan2(d.y, d.x))


## Punkt, w którym narzędzie się opuszcza (punkt prowadzący) przy skróceniu h.
func _work_on(pass_data: Dictionary, h: float) -> Vector2:
	var a: Vector2 = pass_data["from"]
	var d: Vector2 = (Vector2(pass_data["to"]) - a).normalized()
	return a + d * (h - rig.work_offset() - rig.work_length * 0.5 - _number("tool_margin_m", 0.5))


## Zjazd z pasu (tył obszaru roboczego minął krawędź) przy skróceniu h od strony zjazdu.
func _exit_pose(pass_data: Dictionary, h: float) -> Vector3:
	var a: Vector2 = pass_data["from"]
	var b: Vector2 = pass_data["to"]
	var d: Vector2 = (b - a).normalized()
	var off: Vector2 = b - d * h + d * (rig.work_length * 0.5 - rig.work_offset() + _number("tool_margin_m", 0.5))
	return Vector3(off.x, off.y, atan2(d.y, d.x))


func _depths(allow_headland: bool) -> Array:
	var result: Array = [0.0]
	if allow_headland:
		var step: float = maxf(0.5, rig.work_width - _number("lane_overlap_m", 0.3))
		for lanes in settings.get("headland_depths_lanes", [1, 2, 3]):
			result.append(step * float(lanes))
	return result


## Wykonuje listę pasów: dojazd/zawroty z kandydatami. first_kind – rodzaj pierwszego łącznika.
func _run_passes(passes: Array, first_kind: String, allow_headland: bool) -> bool:
	# Dojazd do pierwszego pasa.
	var chosen: Dictionary = _connect(_last_pose(), passes[0], first_kind, allow_headland, _tool_rot)
	if chosen.is_empty():
		if path.size() <= 1:
			last_error = "Nie da się dojechać do pola bez kolizji – przestaw maszyny albo podjedź bliżej."
			return false
		warning = "Brak miejsca na dojazd do uwroci – część pola zostaje."
		return true
	var entry_h: float = float(chosen["h"])
	_record_headland(passes[0], "entry", entry_h)
	_append(chosen["poses"], first_kind, chosen["tools"])
	for k in passes.size():
		var pass_data: Dictionary = passes[k]
		var exit_h: float = 0.0
		var next: Dictionary = {}
		var exit_tool: float = _rot_of((Vector2(pass_data["to"]) - Vector2(pass_data["from"])).normalized())
		if k + 1 < passes.size():
			for h in _depths(allow_headland):
				next = _connect(_exit_pose(pass_data, h), passes[k + 1], "turn", false, exit_tool, h)
				if not next.is_empty():
					exit_h = h
					break
		else:
			# Ostatni pas: wyjazd za krawędź też musi być wolny (np. maszyna stoi tuż za polem),
			# a z miejsca zjazdu musi dać się dojechać do uwroci – inaczej pas kończy się wcześniej,
			# a resztę obrobi uwrocie.
			var fallback: float = -1.0
			for h in _depths(allow_headland):
				if not _run_out_free(pass_data, h, exit_tool):
					continue
				if fallback < 0.0:
					fallback = h
				var saved: Dictionary = _headlands.duplicate(true)
				_record_headland(pass_data, "exit", h)
				var reachable: bool = not _cleanup_choice(_exit_pose(pass_data, h), exit_tool, _headland_keys()).is_empty() \
					or _headland_keys().is_empty()
				_headlands = saved
				if reachable:
					exit_h = h
					fallback = -1.0
					break
			if fallback >= 0.0:
				exit_h = fallback
			_record_headland(pass_data, "exit", exit_h)
		_append_pass(pass_data, entry_h, exit_h)
		stats["passes"] += 1
		if k + 1 >= passes.size():
			break
		if next.is_empty():
			warning = "Brak miejsca na zawrót bez kolizji – pracownik obrobi %d z %d pasów." % [k + 1, passes.size()]
			return true
		if exit_h > 0.0:
			stats["headland_turns"] += 1
			_record_headland(pass_data, "exit", exit_h)
			_record_headland(passes[k + 1], "entry", exit_h)
		else:
			stats["outside_turns"] += 1
		_append(next["poses"], "turn", next["tools"])
		entry_h = exit_h
	return true


## Czy końcówka pasu (ostatnie metry pracy i wyjazd) przy skróceniu h jest wolna.
func _run_out_free(pass_data: Dictionary, h: float, tool_rot: float) -> bool:
	var exit: Vector3 = _exit_pose(pass_data, h)
	var back: float = rig.work_length + _number("tool_margin_m", 0.5) + 4.0
	var start: Vector3 = Dubins.advance(exit, "S", -back, 1.0)
	var poses: Array = _straight(start, back, _number("turn_sample_m", 0.3))
	return _candidate_free(poses, _follow(poses, tool_rot))


func _last_pose() -> Vector3:
	return path[-1][0]


## Najlepszy bezkolizyjny łącznik z pozy start do wjazdu na pas (z wjazdem skróconym o h).
## fixed_h ≥ 0 – tylko to skrócenie; allow_headland – próbuj też skróceń (dojazd).
## Wynik: {"poses", "tools", "h"} albo {}.
func _connect(start: Vector3, pass_data: Dictionary, _kind: String, allow_headland: bool, tool_rot: float, fixed_h: float = -1.0) -> Dictionary:
	var depths: Array = [fixed_h] if fixed_h >= 0.0 else _depths(allow_headland)
	for h in depths:
		var goal: Vector3 = _entry_pose(pass_data, h)
		var on: Vector2 = _work_on(pass_data, h)
		# Zestaw stoi prawie w linii pasa (np. gracz podjechał do krawędzi pola): łagodne „S”
		# zamiast pętli, jeśli mieści się w skręcie kół. Przyczepiane narzędzie musi się jeszcze
		# wyprostować, więc celem jest początek odcinka wjazdu; zawieszane może celować dalej.
		var smooth_goals: Array = [goal]
		if not rig.towed():
			smooth_goals.append(Vector3(on.x, on.y, goal.z))
		for smooth_goal in smooth_goals:
			var curve: Array = _smooth(start, smooth_goal, _number("turn_sample_m", 0.3))
			if curve.is_empty():
				continue
			var lead_from: Vector3 = curve[-1]
			var lead_length: float = Vector2(lead_from.x, lead_from.y).distance_to(on)
			var checked: Array = curve.duplicate()
			for pose in _straight(lead_from, lead_length, _number("turn_sample_m", 0.3)).slice(1):
				checked.append(pose)
			var curve_tools: PackedFloat32Array = _follow(checked, tool_rot)
			if _candidate_free(checked, curve_tools):
				return {"poses": curve.slice(1), "tools": curve_tools.slice(1, curve.size()), "h": h}
		for factor in settings.get("radius_factors", [1.0, 1.3, 1.7]):
			var r: float = radius * float(factor)
			for candidate in Dubins.paths(start, goal, r):
				var poses: Array = Dubins.sample(start, candidate["segments"], r, _number("turn_sample_m", 0.3))
				# Odcinek wjazdu do miejsca opuszczenia narzędzia też musi być wolny.
				var lead: float = Vector2(goal.x, goal.y).distance_to(on)
				for pose in _straight(goal, lead, _number("turn_sample_m", 0.3)).slice(1):
					poses.append(pose)
				var tools: PackedFloat32Array = _follow(poses, tool_rot)
				if _candidate_free(poses, tools):
					# Odcinek wjazdu dopisuje _append_pass – tu tylko sam łącznik.
					var count: int = Dubins.sample(start, candidate["segments"], r, _number("turn_sample_m", 0.3)).size()
					return {"poses": poses.slice(1, count), "tools": tools.slice(1, count), "h": h}
	return {}


## Obroty narzędzia wzdłuż póz (traktrysa od tool_rot).
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


func _candidate_free(poses: Array, tools: PackedFloat32Array) -> bool:
	var inner: Rect2 = world_rect.grow(-1.0)
	for pose in poses:
		var vehicle: Vector3 = rig.vehicle_pose(pose)
		if world_rect.size != Vector2.ZERO and not inner.has_point(Vector2(vehicle.x, vehicle.y)):
			return false
	if not is_free.is_valid():
		return true
	var samples: Array = []
	for i in poses.size():
		samples.append(_sample(float(i), poses[i], tools[i], false, 0.0))
	return bool(is_free.call(samples))


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


static func _straight(start: Vector3, length: float, step: float) -> Array:
	var result: Array = [start]
	var count: int = maxi(1, ceili(length / maxf(step, 0.01)))
	for i in range(1, count + 1):
		result.append(Dubins.advance(start, "S", length * i / count, 1.0))
	return result


func _append(poses: Array, kind: String, tools: PackedFloat32Array) -> void:
	for i in poses.size():
		path.append([poses[i], kind, false])
		tool_rots.append(tools[i])
	if not tools.is_empty():
		_tool_rot = tools[-1]


## Pas: wjazd (narzędzie podniesione), praca od _work_on do zjazdu.
func _append_pass(pass_data: Dictionary, entry_h: float, exit_h: float) -> void:
	var entry: Vector3 = _entry_pose(pass_data, entry_h)
	var on: Vector2 = _work_on(pass_data, entry_h)
	var exit: Vector3 = _exit_pose(pass_data, exit_h)
	# Łącznik mógł skończyć się już na linii pasu, dalej niż początek wjazdu (łagodne „S”).
	var last: Vector3 = _last_pose()
	var direction := Vector2(cos(entry.z), sin(entry.z))
	var offset: Vector2 = Vector2(last.x, last.y) - Vector2(entry.x, entry.y)
	if absf(offset.cross(direction)) < 0.05 and offset.dot(direction) > 0.01:
		entry = Vector3(last.x, last.y, entry.z)
	var lead_length: float = Vector2(entry.x, entry.y).distance_to(on)
	var work_length: float = on.distance_to(Vector2(exit.x, exit.y))
	var lead: Array = _straight(entry, lead_length, _number("turn_sample_m", 0.3))
	var work: Array = _straight(Dubins.advance(entry, "S", lead_length, 1.0), work_length, _number("pass_sample_m", 1.0))
	var poses: Array = []
	var kinds: Array = []
	# Wjazd zaczyna się tam, gdzie skończył się łącznik (ta sama poza) – bez duplikatu.
	for pose in lead.slice(1 if Vector2(entry.x, entry.y).distance_to(Vector2(_last_pose().x, _last_pose().y)) < 0.01 else 0):
		poses.append(pose)
		kinds.append(["lead", false])
	for pose in work.slice(1):
		poses.append(pose)
		kinds.append(["work", true])
	var tools: PackedFloat32Array = _follow([_last_pose()] + poses, _tool_rot).slice(1)
	for i in poses.size():
		path.append([poses[i], kinds[i][0], kinds[i][1]])
		tool_rots.append(tools[i])
	_tool_rot = tools[-1] if not tools.is_empty() else _tool_rot


func _record_headland(pass_data: Dictionary, side: String, h: float) -> void:
	if h <= 0.0:
		return
	var key: String = str(pass_data[side])
	var u: float = float(pass_data["u"])
	_headlands[key].append([u - rig.work_width * 0.5, u + rig.work_width * 0.5, h])


# ---------------------------------------------------------------------------
# Uwrocia skróconych pasów
# ---------------------------------------------------------------------------

func _cleanup() -> void:
	var pending: Array = _headland_keys()
	while not pending.is_empty():
		var choice: Dictionary = _cleanup_choice(_last_pose(), _tool_rot, pending)
		if choice.is_empty():
			for key in pending:
				if not _headland_passes(key, _headland_span(key), true, false).is_empty():
					warning = "Brak miejsca na dojazd do uwrocia – jego część zostaje."
					return
			return
		pending.erase(choice["key"])
		var before: int = stats["passes"]
		if not _run_passes(choice["passes"], "turn", false):
			return
		stats["cleanup_passes"] += stats["passes"] - before
		if not warning.is_empty():
			return


func _headland_keys() -> Array:
	var keys: Array = []
	for key in ["low", "high"]:
		if not _headlands[key].is_empty():
			keys.append(key)
	return keys


## Pierwsze uwrocie (bliższy koniec pola najpierw) i wariant jego pasów, do którego da się
## dojechać z pozy from bez kolizji: {"key", "passes"} albo {} (także gdy nic nie wymaga pracy).
func _cleanup_choice(from: Vector3, tool_rot: float, keys: Array) -> Dictionary:
	var here: Vector2 = _to_local(Vector2(from.x, from.y))
	var ordered: Array = keys.duplicate()
	ordered.sort_custom(func(a, b): return absf(here.y - (0.0 if a == "low" else _size.y)) < absf(here.y - (0.0 if b == "low" else _size.y)))
	for key in ordered:
		var span: Vector3 = _headland_span(key)
		var near_first: bool = absf(here.x - span.x) <= absf(here.x - span.y)
		# Warianty: od bliższego/dalszego boku, od krawędzi pola albo od środka.
		for variant in [[near_first, false], [near_first, true], [not near_first, false], [not near_first, true]]:
			var passes: Array = _headland_passes(key, span, bool(variant[0]), bool(variant[1]))
			if passes.is_empty():
				break
			if not _connect(from, passes[0], "turn", false, tool_rot, 0.0).is_empty():
				return {"key": key, "passes": passes}
	return {}


## Zakres skróconych końców pasów: (u_min, u_max, głębokość).
func _headland_span(key: String) -> Vector3:
	var u_min: float = INF
	var u_max: float = -INF
	var depth: float = 0.0
	for span in _headlands[key]:
		u_min = minf(u_min, float(span[0]))
		u_max = maxf(u_max, float(span[1]))
		depth = maxf(depth, float(span[2]))
	return Vector3(maxf(0.0, u_min), minf(_size.x, u_max), depth)


## Pasy uwrocia (w poprzek końców pasów głównych), tylko te, które wymagają pracy.
func _headland_passes(key: String, span: Vector3, forward: bool, from_inside: bool) -> Array:
	var width: float = rig.work_width
	var step: float = maxf(0.5, width - _number("lane_overlap_m", 0.3))
	var offsets: PackedFloat32Array = lane_centers(span.z, width, step)
	if from_inside:
		offsets.reverse()
	var passes: Array = []
	for offset in offsets:
		var v: float = offset if key == "low" else _size.y - offset
		var a: Vector2 = _world(span.x if forward else span.y, v)
		var b: Vector2 = _world(span.y if forward else span.x, v)
		var center: Vector2 = (a + b) * 0.5
		if needs_work.is_valid() and not bool(needs_work.call(center, _rot_of((b - a).normalized()), Vector2(width, a.distance_to(b)))):
			continue
		passes.append({"from": a, "to": b, "u": v, "entry": "", "exit": ""})
		forward = not forward
	return passes


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
	return _number("turn_speed_kmh", 7.0) / 3.6


## Próbki trasy z planu: prędkości z ograniczeniem przyspieszenia, rozkładanie narzędzia
## na postoju na początku (fold_now < 1, trwa fold_seconds · (1 − fold_now)).
func samples(work_speed_m_s: float, fold_now: float = 1.0, fold_seconds: float = 0.0) -> Array:
	var count: int = path.size()
	var distances := PackedFloat32Array()
	distances.resize(count)
	var speeds := PackedFloat32Array()
	speeds.resize(count)
	for i in count:
		speeds[i] = _target_speed(str(path[i][1]), work_speed_m_s)
		if i > 0:
			var a: Vector3 = path[i - 1][0]
			var b: Vector3 = path[i][0]
			distances[i] = Vector2(a.x, a.y).distance_to(Vector2(b.x, b.y))
	# Ograniczenie przyspieszenia i hamowania (postój na początku i na końcu).
	var accel: float = maxf(0.1, _number("accel_m_s2", 0.8))
	speeds[0] = 0.0
	speeds[count - 1] = 0.0
	for i in range(1, count):
		speeds[i] = minf(speeds[i], sqrt(speeds[i - 1] * speeds[i - 1] + 2.0 * accel * distances[i]))
	for i in range(count - 2, -1, -1):
		speeds[i] = minf(speeds[i], sqrt(speeds[i + 1] * speeds[i + 1] + 2.0 * accel * distances[i + 1]))
	var result: Array = []
	var time: float = 0.0
	var fold: float = clampf(fold_now, 0.0, 1.0)
	result.append(_sample(0.0, path[0][0], tool_rots[0], false, 0.0, fold))
	if fold < 1.0:
		time = maxf(0.1, fold_seconds * (1.0 - fold))
		result.append(_sample(time, path[0][0], tool_rots[0], false, 0.0, 1.0))
	for i in range(1, count):
		var average: float = maxf(0.05, (speeds[i - 1] + speeds[i]) * 0.5)
		time += maxf(0.001, distances[i] / average)
		var a: Vector3 = path[i - 1][0]
		var b: Vector3 = path[i][0]
		var curvature: float = angle_difference(a.z, b.z) / maxf(distances[i], 0.001)
		# Praca narzędzia obowiązuje od próbki na początku odcinka (route_sample.gd), więc próbka
		# pracuje, gdy następna poza jest pozą pracy (pierwsza: miejsce opuszczenia narzędzia).
		var working: bool = i + 1 < count and bool(path[i + 1][2])
		result.append(_sample(time, b, tool_rots[i], working, rig.steering_for(curvature)))
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
