extends RefCounted
## Odtwarzanie jednej trasy – czysta logika (bez fizyki, węzłów i UI).
##
## 1) OGRANICZNIK PRĘDKOŚCI (jeden mechanizm na wszystkie przypadki)
##    speed_limit [m/s] mówi, jak szybko wolno teraz jechać po trasie. W każdym kroku trasa
##    przesuwa się o mniejszą z dróg: nagraną (czas płynie normalnie) albo speed_limit · dt
##    (czas trasy zwalnia). Postoje z nagrania (droga 0) zawsze trwają tyle, co w nagraniu.
##      – start: speed_limit = prędkość zestawu w chwili startu (0 na postoju), potem rośnie
##        ze stałym przyspieszeniem accel,
##      – wznowienie po przeszkodzie: halt() zeruje speed_limit, dalej jak przy starcie,
##      – odwołanie przejazdu: begin_stop() – speed_limit maleje z opóźnieniem decel do 0,
##      – koniec trasy: speed_limit ≤ √(2 · decel · droga_do_końca), więc nagranie zakończone
##        w ruchu wyhamowuje dokładnie na końcu.
##
## 2) PŁYNNE WEJŚCIE NA TRASĘ (start w ruchu lub obok punktu startu)
##    Zestaw startuje z rzeczywistej pozy. Różnica względem początku trasy (przesunięcie
##    boczne, wzdłużne, kąt pojazdu i przegubów) zanika wraz z PRZEJECHANĄ drogą trasy
##    (blend_length), nie z czasem. Przesunięcie boczne to krzywa Hermite'a: na starcie
##    styczna do rzeczywistego kierunku jazdy, na końcu styczna do trasy – zestaw skręca
##    w stronę linii nagrania, a kierunek nadwozia zawsze odpowiada kierunkowi ruchu
##    (bez jazdy „bokiem”). Na postoju (droga 0) zestaw stoi w swojej rzeczywistej pozie.
##    Praca narzędzia (B) i składanie pochodzą wprost z próbek – zdarzenia z początku trasy
##    nie są pomijane, bo każdy przekroczony odcinek nagrania jest stosowany po kolei.

const Data = preload("res://scripts/core/routes/route_data.gd")
const MAX_SPEED_M_S: float = 40.0
const END_EPSILON_M: float = 0.02

var route: Dictionary
var samples: Array
var time: float = 0.0
var index: int = 0
var speed_limit: float = 0.0
var stopping: bool = false
## Rzeczywista prędkość po trasie w ostatnim kroku [m/s] (od niej zaczyna się hamowanie).
var current_speed: float = 0.0
var accel: float = 1.5
var decel: float = 2.0
var _cum := PackedFloat64Array()     # droga pojazdu do próbki i [m]
var _sign := PackedFloat32Array()    # kierunek jazdy w próbce i: +1 przód, −1 tył
var _blend: Dictionary = {}


func setup(route_data: Dictionary, settings: Dictionary) -> void:
	route = route_data
	samples = route["samples"]
	accel = maxf(0.05, float(settings.get("playback_accel_m_s2", 1.5)))
	decel = maxf(0.05, float(settings.get("playback_decel_m_s2", 2.0)))
	_cum.resize(samples.size())
	_sign.resize(samples.size())
	_cum[0] = 0.0
	var last_sign: float = 0.0
	for i in range(1, samples.size()):
		var a: Array = samples[i - 1]
		var b: Array = samples[i]
		var step := Vector2(float(b[1]) - float(a[1]), float(b[2]) - float(a[2]))
		_cum[i] = _cum[i - 1] + step.length()
		if step.length() > 0.001:
			_sign[i - 1] = 1.0 if step.dot(Vector2.UP.rotated(float(a[3]))) >= 0.0 else -1.0
			last_sign = _sign[i - 1]
		else:
			_sign[i - 1] = last_sign
	# Postoje przed pierwszym ruchem: kierunek pierwszego ruchu (domyślnie do przodu).
	var first_sign: float = 1.0
	for i in samples.size() - 1:
		if _sign[i] != 0.0:
			first_sign = _sign[i]
			break
	for i in samples.size():
		if _sign[i] == 0.0:
			_sign[i] = first_sign if i == 0 or _sign[i - 1] == 0.0 else _sign[i - 1]


func duration() -> float:
	return float(samples[-1][0])


func total_distance() -> float:
	return _cum[-1]


func finished() -> bool:
	return time >= duration()


## Kierunek jazdy na początku trasy (+1 przód, −1 tył).
func start_sign() -> float:
	return _sign[0]


## Droga pojazdu po trasie w chwili t [m].
func distance_at(at_time: float, hint: int = -1) -> float:
	var cursor: Dictionary = Data.at(route, clampf(at_time, 0.0, duration()), index if hint < 0 else hint)
	var i: int = int(cursor["index"])
	var t0: float = float(samples[i][0])
	var t1: float = float(samples[i + 1][0])
	var weight: float = clampf((at_time - t0) / maxf(t1 - t0, 0.000001), 0.0, 1.0)
	return lerpf(_cum[i], _cum[i + 1], weight)


## Najwcześniejsza chwila z przedziału [from_time, to_time], w której droga osiąga s.
func time_at_distance(s: float, from_time: float, to_time: float) -> float:
	if distance_at(to_time) <= s + 0.000001:
		return to_time
	var i: int = int(Data.at(route, from_time, index)["index"])
	while i < samples.size() - 2 and _cum[i + 1] < s:
		i += 1
	var t0: float = float(samples[i][0])
	var t1: float = float(samples[i + 1][0])
	var span: float = _cum[i + 1] - _cum[i]
	var weight: float = clampf((s - _cum[i]) / span, 0.0, 1.0) if span > 0.000001 else 0.0
	return clampf(lerpf(t0, t1, weight), from_time, to_time)


## Plan kroku (bez zmiany stanu): {"finish", "speed_limit", "rate", "stopped"}.
func plan(delta: float) -> Dictionary:
	var v: float = speed_limit
	v = maxf(0.0, v - decel * delta) if stopping else minf(v + accel * delta, MAX_SPEED_M_S)
	var s_now: float = distance_at(time)
	var remaining: float = maxf(0.0, total_distance() - s_now)
	v = minf(v, sqrt(2.0 * decel * remaining))
	var allowed: float = v * delta
	if remaining <= END_EPSILON_M and not stopping:
		allowed = remaining + END_EPSILON_M
	var finish: float = time_at_distance(s_now + allowed, time, minf(time + delta, duration()))
	return {"finish": finish, "speed_limit": v, "rate": (finish - time) / maxf(delta, 0.000001),
		"speed": (distance_at(finish) - s_now) / maxf(delta, 0.000001), "stopped": stopping and v <= 0.0}


func commit(step: Dictionary) -> void:
	speed_limit = float(step["speed_limit"])
	current_speed = float(step["speed"])
	index = int(Data.at(route, float(step["finish"]), index)["index"])
	time = float(step["finish"])


## Przeszkoda: zestaw stoi, po wznowieniu rusza od zera.
func halt() -> void:
	speed_limit = 0.0
	current_speed = 0.0


## Odwołanie: hamowanie od rzeczywistej prędkości (ogranicznik mógł urosnąć ponad nagranie).
func begin_stop() -> void:
	stopping = true
	speed_limit = current_speed


# ---------------------------------------------------------------------------
# Płynne wejście na trasę
# ---------------------------------------------------------------------------

## actual: próbka z rzeczywistej pozy zestawu (RouteRig.sample). min_length: minimalna droga
## wejścia [m]. Długość rośnie z wielkością przesunięcia, by zakręt był łagodny.
func setup_blend(actual: Array, min_length: float) -> void:
	_blend = {}
	var first: Array = samples[0]
	var dp := Vector2(float(actual[1]) - float(first[1]), float(actual[2]) - float(first[2]))
	var dtheta: float = clampf(angle_difference(float(first[3]), float(actual[3])), deg_to_rad(-60.0), deg_to_rad(60.0))
	var tool: float = angle_difference(float(first[4]), float(actual[4]))
	var drawbar: float = angle_difference(float(first[5]), float(actual[5]))
	if dp.length() < 0.01 and absf(dtheta) < 0.002 and absf(tool) < 0.002 and absf(drawbar) < 0.002:
		return
	var travel: Vector2 = Vector2.UP.rotated(float(first[3])) * _sign[0]
	var normal: Vector2 = travel.rotated(PI * 0.5)
	var lateral: float = dp.dot(normal)
	var longitudinal: float = dp.dot(travel)
	var length: float = maxf(min_length, maxf(5.0 * absf(lateral), 6.0 * absf(longitudinal)))
	_blend = {"travel": travel, "normal": normal, "lateral": lateral, "longitudinal": longitudinal,
		"slope": tan(dtheta), "tool": tool, "drawbar": drawbar, "length": length}


func blending() -> bool:
	return not _blend.is_empty() and distance_at(time) < float(_blend["length"])


## Próbka trasy przesunięta o zanikającą różnicę pozy (bez zmian po przejechaniu blend_length).
func blended(point: Array) -> Array:
	if _blend.is_empty():
		return point
	var length: float = float(_blend["length"])
	var s: float = distance_at(float(point[0]))
	if s >= length:
		return point
	var u: float = s / length
	# Hermite: y(0) = boczne, y'(0) = tg(kąt), y(1) = y'(1) = 0.
	var lateral: float = float(_blend["lateral"])
	var slope: float = float(_blend["slope"])
	var h00: float = 2.0 * u * u * u - 3.0 * u * u + 1.0
	var h10: float = u * u * u - 2.0 * u * u + u
	var y: float = lateral * h00 + slope * length * h10
	var dy: float = lateral * (6.0 * u * u - 6.0 * u) / length + slope * (3.0 * u * u - 4.0 * u + 1.0)
	var fade: float = 1.0 - smoothstep(0.0, 1.0, u)
	var x: float = float(_blend["longitudinal"]) * fade
	var dx: float = -float(_blend["longitudinal"]) * 6.0 * u * (1.0 - u) / length
	var travel: Vector2 = _blend["travel"]
	var normal: Vector2 = _blend["normal"]
	var result: Array = point.duplicate()
	var position := Vector2(float(point[1]), float(point[2])) + normal * y + travel * x
	result[1] = position.x
	result[2] = position.y
	# Kierunek nadwozia = kierunek ruchu po przesuniętej ścieżce.
	var cursor: int = int(Data.at(route, float(point[0]), index)["index"])
	var route_travel: Vector2 = Vector2.UP.rotated(float(point[3])) * _sign[cursor]
	var path_travel: Vector2 = route_travel + normal * dy + travel * dx
	result[3] = float(point[3]) + angle_difference(route_travel.angle(), path_travel.angle())
	result[4] = float(point[4]) + float(_blend["tool"]) * fade
	result[5] = float(point[5]) + float(_blend["drawbar"]) * fade
	return result
