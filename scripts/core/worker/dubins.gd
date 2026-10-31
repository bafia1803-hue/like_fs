extends RefCounted
## Krzywe Dubinsa: najkrótsze ścieżki jazdy tylko do przodu dla pojazdu o minimalnym promieniu
## skrętu r, z pozy startowej do pozy docelowej (położenie i kierunek). Każda ścieżka to trzy
## odcinki: łuk / prosta / łuk (LSL, RSR, LSR, RSL) albo trzy łuki (RLR, LRL – „gruszka”).
## Pracownik używa ich do zawrotów na uwrociu i dojazdu do pierwszego pasa.
##
## Poza: Vector3(x, y, θ), kierunek jazdy = (cos θ, sin θ) w tym samym układzie co x, y.
## L zwiększa θ, R zmniejsza. Wynik każdego wzoru jest sprawdzany (koniec ścieżki = cel),
## więc do planisty trafiają tylko poprawne ścieżki.

const WORDS: Array[String] = ["LSL", "RSR", "LSR", "RSL", "RLR", "LRL"]


static func mod2pi(value: float) -> float:
	return fposmod(value, TAU)


## Wszystkie poprawne ścieżki od najkrótszej: [{"word", "length" (m), "segments": [[typ, długość m], …]}].
static func paths(start: Vector3, goal: Vector3, radius: float) -> Array:
	var result: Array = []
	var delta := Vector2(goal.x - start.x, goal.y - start.y)
	var d: float = delta.length() / radius
	var theta: float = mod2pi(atan2(delta.y, delta.x)) if delta.length() > 0.000001 else 0.0
	var a: float = mod2pi(start.z - theta)
	var b: float = mod2pi(goal.z - theta)
	for word in WORDS:
		var params: Vector3 = _word(word, a, b, d)
		if params.x < 0.0:
			continue
		var segments: Array = []
		for i in 3:
			segments.append([word[i], params[i] * radius])
		var end: Vector3 = sample(start, segments, radius, 1000000.0)[-1]
		if Vector2(end.x, end.y).distance_to(Vector2(goal.x, goal.y)) > 0.01 * maxf(radius, 1.0) \
				or absf(angle_difference(end.z, goal.z)) > 0.01:
			continue
		result.append({"word": word, "length": (params.x + params.y + params.z) * radius, "segments": segments})
	result.sort_custom(func(p, q): return float(p["length"]) < float(q["length"]))
	return result


## Długości odcinków (w jednostkach promienia) albo (-1, -1, -1), gdy ścieżki nie ma.
static func _word(word: String, a: float, b: float, d: float) -> Vector3:
	var sa: float = sin(a)
	var sb: float = sin(b)
	var ca: float = cos(a)
	var cb: float = cos(b)
	var c_ab: float = cos(a - b)
	match word:
		"LSL":
			var p2: float = 2.0 + d * d - 2.0 * c_ab + 2.0 * d * (sa - sb)
			if p2 < 0.0:
				return Vector3(-1, -1, -1)
			var tmp: float = atan2(cb - ca, d + sa - sb)
			return Vector3(mod2pi(-a + tmp), sqrt(p2), mod2pi(b - tmp))
		"RSR":
			var p2: float = 2.0 + d * d - 2.0 * c_ab + 2.0 * d * (sb - sa)
			if p2 < 0.0:
				return Vector3(-1, -1, -1)
			var tmp: float = atan2(ca - cb, d - sa + sb)
			return Vector3(mod2pi(a - tmp), sqrt(p2), mod2pi(-b + tmp))
		"LSR":
			var p2: float = -2.0 + d * d + 2.0 * c_ab + 2.0 * d * (sa + sb)
			if p2 < 0.0:
				return Vector3(-1, -1, -1)
			var p: float = sqrt(p2)
			var tmp: float = atan2(-ca - cb, d + sa + sb) - atan2(-2.0, p)
			return Vector3(mod2pi(-a + tmp), p, mod2pi(-mod2pi(b) + tmp))
		"RSL":
			var p2: float = -2.0 + d * d + 2.0 * c_ab - 2.0 * d * (sa + sb)
			if p2 < 0.0:
				return Vector3(-1, -1, -1)
			var p: float = sqrt(p2)
			var tmp: float = atan2(ca + cb, d - sa - sb) - atan2(2.0, p)
			return Vector3(mod2pi(a - tmp), p, mod2pi(b - tmp))
		"RLR":
			var tmp: float = (6.0 - d * d + 2.0 * c_ab + 2.0 * d * (sa - sb)) / 8.0
			if absf(tmp) > 1.0:
				return Vector3(-1, -1, -1)
			var p: float = mod2pi(TAU - acos(tmp))
			var t: float = mod2pi(a - atan2(ca - cb, d - sa + sb) + p / 2.0)
			return Vector3(t, p, mod2pi(a - b - t + p))
		"LRL":
			var tmp: float = (6.0 - d * d + 2.0 * c_ab + 2.0 * d * (sb - sa)) / 8.0
			if absf(tmp) > 1.0:
				return Vector3(-1, -1, -1)
			var p: float = mod2pi(TAU - acos(tmp))
			var t: float = mod2pi(-a - atan2(ca - cb, d + sa - sb) + p / 2.0)
			return Vector3(t, p, mod2pi(mod2pi(b) - a - t + p))
	return Vector3(-1, -1, -1)


## Pozy wzdłuż ścieżki co najwyżej co step metrów (pierwsza = start, ostatnia = koniec).
static func sample(start: Vector3, segments: Array, radius: float, step: float) -> Array:
	var result: Array = [start]
	var pose: Vector3 = start
	for segment in segments:
		var kind: String = str(segment[0])
		var length: float = float(segment[1])
		if length <= 0.000001:
			continue
		var count: int = maxi(1, ceili(length / step))
		var origin: Vector3 = pose
		for i in range(1, count + 1):
			pose = advance(origin, kind, length * i / count, radius)
			result.append(pose)
	return result


## Poza po przejechaniu distance metrów odcinkiem danego typu.
static func advance(pose: Vector3, kind: String, distance: float, radius: float) -> Vector3:
	match kind:
		"L":
			var turn: float = distance / radius
			return Vector3(pose.x + radius * (sin(pose.z + turn) - sin(pose.z)),
				pose.y - radius * (cos(pose.z + turn) - cos(pose.z)), pose.z + turn)
		"R":
			var turn: float = distance / radius
			return Vector3(pose.x - radius * (sin(pose.z - turn) - sin(pose.z)),
				pose.y + radius * (cos(pose.z - turn) - cos(pose.z)), pose.z - turn)
	return Vector3(pose.x + distance * cos(pose.z), pose.y + distance * sin(pose.z), pose.z)
