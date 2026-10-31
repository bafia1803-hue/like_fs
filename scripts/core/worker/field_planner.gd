extends RefCounted
## Planista pracownika (czysta logika): obróbka prostokątnego pola „wężykiem”.
##
## 1. PASY Z KOMÓREK. profile(a, b, szerokość, kosze) mówi, jaka część komórek w każdym kawałku
##    pasa wymaga pracy (warstwa gry liczy to z pola i pomija pasy zajęte przez innych pracowników
##    tej samej pracy). Pasy kładzione są od boku pola bliższego pojazdowi: każdy zaczyna się tam,
##    gdzie jest coś do zrobienia, rozstaw = szerokość − zakładka. Gdy zostaje pasek węższy niż
##    narzędzie, narzędzie jedzie środkiem tego paska.
##    Wzdłuż pasa praca trwa w najdłuższym ciągłym odcinku, który wymaga pracy – granica
##    (np. niezakultywowana część pola dla siewnika) działa jak koniec pola i tam jest zawrót.
## 2. DOJAZD bez pętli: na linię najbliższego pasa, w kierunku zgodnym z pojazdem, łagodnym łukiem
##    (Hermite albo Dubins bez dodatkowego okrążenia). Pas zaczyna się tam, gdzie zestaw na niego
##    wjechał – kawałek za nim zostaje (pierwszy przejazd nie musi być idealny).
## 3. KOLEJNOŚĆ: od pasa startowego najpierw w stronę bliższego boku, potem reszta po drugiej stronie.
## 4. NARZĘDZIE opuszcza się, gdy przód obszaru roboczego dochodzi do początku odcinka pracy,
##    a podnosi, gdy tył minie jego koniec. Przyczepiane prostuje się na prostym wjeździe.
## 5. ZAWRÓT – kandydaci od najlepszego, każdy sprawdzany is_free (cały zestaw z narzędziem)
##    i granicami świata:
##      a) do przodu, krzywa Dubinsa (promień R, potem większe),
##      b) z cofaniem (gdy przed zestawem jest przeszkoda): podjazd jak najdalej, cofanie ze
##         skrętem, jazda, cofnięcie na początek pasa – albo w odwrotnej kolejności,
##      c) to samo, ale pasy kończą się wcześniej (zestaw dojeżdża tylko tak daleko, jak może).
##    Gdy nic się nie mieści – plan kończy się na tym pasie (zestaw staje). Niedokończonych
##    kawałków pracownik nie objeżdża i do nich nie wraca.
##
## Wynik: path – pozy punktu prowadzącego [Vector3, rodzaj, praca], samples() – próbki trasy,
## passes_info – pasy (do rezerwacji między pracownikami), lane_axis – kierunek pasów.

const Dubins = preload("res://scripts/core/worker/dubins.gd")

var settings: Dictionary = {}
var rig: RefCounted
## profile(a: Vector2, b: Vector2, width: float, bins: int) -> PackedFloat32Array
## (udział komórek wymagających pracy w kolejnych kawałkach od a do b).
var profile: Callable
var is_free: Callable
## Jak is_free, ale tylko stojące przeszkody (bez innych pracujących zestawów – one odjadą).
## Używane do pasów: pas kończy się przed maszyną, która stoi na nim na stałe.
var is_free_static: Callable
var world_rect := Rect2()
## Narzucony kierunek pasów (świat) – np. dalsza praca tego samego pracownika; ZERO – wg pojazdu.
var axis_hint := Vector2.ZERO
## Najwyżej tyle pasów w jednym planie (0 – wszystkie). Dalsze pasy pracownik planuje po
## skończeniu – inni pracownicy na tym polu mogą w tym czasie wziąć resztę.
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

var radius: float = 6.0
var tight_radius: float = 3.0
var _origin := Vector2.ZERO
var _u_axis := Vector2.RIGHT
var _v_axis := Vector2.DOWN
var _size := Vector2.ZERO          # (U, V) w układzie pasów
var _tool_rot: float = 0.0


func _number(key: String, fallback: float) -> float:
	return float(settings.get(key, fallback))


func plan(field_origin: Vector2, field_size: Vector2, field_rotation: float,
		vehicle_position: Vector2, vehicle_rot: float, tool_rot: float) -> bool:
	last_error = ""
	warning = ""
	path = []
	passes_info = []
	tool_rots = PackedFloat32Array()
	stats = {"lanes": 0, "passes": 0, "forward_turns": 0, "reverse_turns": 0, "shortened_turns": 0, "stopped_early": false, "truncated": false}
	if rig.work_width <= 0.1:
		last_error = "Narzędzie nie ma szerokości roboczej."
		return false
	radius = maxf(rig.minimum_radius() * _number("turn_radius_factor", 1.5), _number("min_turn_radius_m", 6.0))
	tight_radius = rig.minimum_radius() * _number("tight_radius_factor", 1.15)
	_setup_frame(field_origin, field_size, field_rotation, vehicle_rot)
	lane_axis = _v_axis
	var start: Vector3 = rig.path_pose(vehicle_position, vehicle_rot)
	_tool_rot = tool_rot
	path.append([start, "approach", false])
	tool_rots.append(tool_rot)
	var local: Vector2 = _to_local(Vector2(start.x, start.y))
	var lanes: Array = _lanes(local.x)
	stats["lanes"] = lanes.size()
	if lanes.is_empty():
		last_error = "Na tym polu nie ma teraz pracy dla tego narzędzia."
		return false
	var first: Dictionary = _approach(lanes, local)
	if first.is_empty():
		last_error = "Nie da się dojechać do żadnego pasa bez kolizji – przestaw maszyny albo podjedź bliżej."
		return false
	var passes: Array = []
	var sign: float = float(first["sign"])
	for index in _order(lanes.size(), int(first["index"])):
		if max_lanes > 0 and passes.size() >= max_lanes:
			stats["truncated"] = true
			break
		passes.append(_pass(lanes[index], sign))
		sign = -sign
	_run(passes, float(first["on_s"]))
	return true


# ---------------------------------------------------------------------------
# Układ pasów
# ---------------------------------------------------------------------------

func _setup_frame(origin: Vector2, size: Vector2, rotation: float, vehicle_rot: float) -> void:
	var x_axis := Vector2.RIGHT.rotated(rotation)
	var y_axis := Vector2.DOWN.rotated(rotation)
	var direction: Vector2 = axis_hint if axis_hint != Vector2.ZERO else rig.forward(vehicle_rot)
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


## Najdłuższy ciąg koszy z udziałem ≥ threshold (przerwy krótsze niż gap_bins są łączone):
## Vector2i(pierwszy, ostatni) albo (-1, -1).
static func longest_run(values: PackedFloat32Array, threshold: float, gap_bins: int) -> Vector2i:
	var best := Vector2i(-1, -1)
	var start: int = -1
	var last: int = -1
	for i in values.size():
		if values[i] >= threshold:
			if start < 0 or i - last - 1 > gap_bins:
				start = i
			last = i
			if best.x < 0 or last - start > best.y - best.x:
				best = Vector2i(start, last)
	return best


## Pasy: [{"u", "v0", "v1"}] rosnąco po u. Kładzione od boku bliższego pojazdowi (u0).
func _lanes(u0: float) -> Array:
	var width: float = rig.work_width
	var bin: float = maxf(0.1, _number("profile_bin_m", 0.5))
	var count: int = maxi(1, ceili(_size.x / bin))
	var across: PackedFloat32Array = _profile(_world(0.0, _size.y * 0.5), _world(_size.x, _size.y * 0.5), _size.y, count)
	var threshold: float = _number("lane_min_fraction", 0.01)
	var gap: int = int(_number("gap_m", 2.0) / bin)
	var step: float = maxf(0.5, width - _number("lane_overlap_m", 0.3))
	var descending: bool = u0 > _size.x * 0.5
	var centers: Array = []
	var position: float = 0.0          # odległość od boku startowego [m]
	while position < _size.x - 0.05:
		# Pierwszy kosz, w którym jest coś do zrobienia.
		var i: int = int(position / bin)
		while i < count and across[_bin(i, count, descending)] < threshold:
			i += 1
		if i >= count:
			break
		var begin: float = maxf(position, i * bin)
		# Ciągły zakres pracy od begin (krótkie przerwy łączone).
		var j: int = i
		var last: int = i
		while j < count and j - last - 1 <= gap:
			if across[_bin(j, count, descending)] >= threshold:
				last = j
			j += 1
		var available: float = minf(_size.x, (last + 1) * bin) - begin
		# Węższy pasek niż narzędzie: narzędzie środkiem paska.
		var used: float = minf(width, maxf(available, 0.1))
		var center: float = begin + used * 0.5
		centers.append(_size.x - center if descending else center)
		position = begin + (step if available >= width else used)
	centers.sort()
	var lanes: Array = []
	var along_bins: int = maxi(1, ceili(_size.y / bin))
	for u in centers:
		var along: PackedFloat32Array = _profile(_world(u, 0.0), _world(u, _size.y), width, along_bins)
		var run: Vector2i = longest_run(along, _number("along_min_fraction", 0.05), gap)
		if run.x < 0:
			continue
		var v0: float = run.x * _size.y / along_bins
		var v1: float = (run.y + 1) * _size.y / along_bins
		if v1 - v0 < _number("min_pass_m", 3.0):
			continue
		lanes.append({"u": float(u), "v0": v0, "v1": minf(v1, _size.y)})
	return lanes


static func _bin(i: int, count: int, descending: bool) -> int:
	return count - 1 - i if descending else i


## Kolejność pasów: startowy, potem w stronę bliższego boku, potem pozostałe po drugiej stronie.
static func order_from(count: int, start: int) -> Array:
	var result: Array = [start]
	var below: Array = range(start - 1, -1, -1)
	var above: Array = range(start + 1, count)
	if below.size() <= above.size():
		result.append_array(below)
		result.append_array(above)
	else:
		result.append_array(above)
		result.append_array(below)
	return result


func _order(count: int, start: int) -> Array:
	return order_from(count, start)


## Pas w kierunku sign (+1 rosnące v, −1 malejące): {"from", "to", "u"}.
func _pass(lane: Dictionary, sign: float) -> Dictionary:
	var u: float = float(lane["u"])
	var a: Vector2 = _world(u, float(lane["v0"]) if sign > 0.0 else float(lane["v1"]))
	var b: Vector2 = _world(u, float(lane["v1"]) if sign > 0.0 else float(lane["v0"]))
	return {"from": a, "to": b, "u": u}


# ---------------------------------------------------------------------------
# Geometria pasa (s – droga wzdłuż pasa od „from”)
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Dojazd do pierwszego pasa
# ---------------------------------------------------------------------------

## {"index", "sign", "on_s"} albo {}. Dopisuje pozy dojazdu do path.
func _approach(lanes: Array, local: Vector2) -> Dictionary:
	var start: Vector3 = path[0][0]
	var heading := Vector2(cos(start.z), sin(start.z))
	var indices: Array = range(lanes.size())
	indices.sort_custom(func(a, b): return absf(float(lanes[a]["u"]) - local.x) < absf(float(lanes[b]["u"]) - local.x))
	var step: float = _number("turn_sample_m", 0.3)
	for index in indices.slice(0, int(_number("approach_lanes", 4))):
		var signs: Array = [1.0, -1.0]
		if (_v_axis * -1.0).dot(heading) > _v_axis.dot(heading):
			signs = [-1.0, 1.0]
		for sign in signs:
			var pass_data: Dictionary = _pass(lanes[index], sign)
			var d: Vector2 = _direction(pass_data)
			var s_vehicle: float = (Vector2(start.x, start.y) - Vector2(pass_data["from"])).dot(d)
			var s_entry: float = _on_s(0.0) - _lead()
			for extra in settings.get("merge_distances_m", [4.0, 8.0, 12.0, 18.0, 26.0, 36.0, 50.0]):
				var s_goal: float = maxf(s_vehicle + float(extra), s_entry - 30.0)
				if s_goal > _off_s(pass_data, 0.0) - 3.0:
					break
				var goal: Vector3 = _pose_at(pass_data, s_goal)
				var on: float = maxf(_on_s(0.0), s_goal + (_lead() if rig.towed() else 0.5))
				for candidate in _merge_paths(start, goal, step):
					var checked: Array = candidate.duplicate()
					checked.append_array(_straight(goal, on - s_goal, step).slice(1))
					var tools: PackedFloat32Array = _follow(checked, _tool_rot)
					if _candidate_free(checked, tools):
						_append(candidate.slice(1), "approach", tools.slice(1, candidate.size()))
						return {"index": index, "sign": sign, "on_s": on}
	# Łagodnie się nie da (np. zestaw stoi tyłem do pasów po skończonym pasie): zwykły zawrót
	# (do przodu albo z cofaniem) na początek najbliższego pasa.
	for index in indices.slice(0, int(_number("approach_lanes", 4))):
		for sign in [1.0, -1.0]:
			var pass_data: Dictionary = _pass(lanes[index], sign)
			var turn: Dictionary = _turn(start, pass_data, 0.0, _tool_rot)
			if not turn.is_empty():
				var kinds: Array = turn["kinds"].map(func(kind): return "approach" if kind == "turn" else kind)
				_append_kinds(turn["poses"], kinds, turn["tools"])
				return {"index": index, "sign": sign, "on_s": _on_s(0.0)}
	return {}


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
# Pasy i zawroty
# ---------------------------------------------------------------------------

## Wykonuje pasy po kolei. first_on – miejsce opuszczenia narzędzia na pierwszym pasie
## (zestaw stoi już na jego linii po dojeździe).
func _run(passes: Array, first_on: float) -> void:
	var on: float = first_on
	for k in passes.size():
		var pass_data: Dictionary = passes[k]
		var exit_tool: float = _rot_of(_direction(pass_data))
		var exit_h: float = -1.0
		var turn: Dictionary = {}
		var farthest: float = -1.0
		# Maszyna stojąca na pasie: pas kończy się przed nią (dalej zostaje – jak koniec pola).
		var blocked_h: float = _pass_block(pass_data, on, exit_tool)
		for backoff in settings.get("exit_backoffs_m", [0.0, 2.0, 4.0, 7.0, 10.0]):
			var h: float = float(backoff) + blocked_h
			if _off_s(pass_data, float(h)) <= on + 1.0:
				break
			if not _run_out_free(pass_data, float(h), exit_tool):
				continue
			if farthest < 0.0:
				farthest = float(h)
			if k + 1 >= passes.size():
				break
			turn = _turn(_pose_at(pass_data, _off_s(pass_data, float(h))), passes[k + 1], float(h), exit_tool)
			if not turn.is_empty():
				exit_h = float(h)
				break
		if farthest < 0.0:
			# Nawet koniec pasa jest zajęty – zestaw jedzie tylko do pierwszej przeszkody.
			warning = "Przeszkoda na pasie – pracownik staje."
			stats["stopped_early"] = true
			return
		if exit_h < 0.0:
			exit_h = farthest
		_append_pass(pass_data, on, exit_h)
		stats["passes"] += 1
		if k + 1 >= passes.size():
			return
		if turn.is_empty():
			warning = "Brak miejsca na zawrót – pracownik zatrzymał się po %d z %d pasów." % [k + 1, passes.size()]
			stats["stopped_early"] = true
			return
		stats[str(turn["type"])] += 1
		if exit_h > 0.0:
			stats["shortened_turns"] += 1
		_append_kinds(turn["poses"], turn["kinds"], turn["tools"])
		on = _on_s(exit_h)


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
func samples(work_speed_m_s: float, fold_now: float = 1.0, fold_seconds: float = 0.0) -> Array:
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
	speeds[0] = 0.0
	speeds[count - 1] = 0.0
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
