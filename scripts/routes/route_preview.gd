extends RefCounted
## Podgląd nagranej trasy – czysta logika, bez węzłów, fizyki i UI.
##
## Z trasy (format route_data.gd) i katalogu modeli liczy:
##   - czas trwania i punkty przebiegu (metry),
##   - stan w dowolnej chwili t: pozy członów zestawu (pojazd, narzędzie, wózek przyczepy),
##     praca narzędzia (B) i rozłożenie.
## Nie korzysta z istniejących maszyn w świecie – geometria zaczepów pochodzi z katalogu
## (sygnatura trasy: vehicle_model, tool_model, socket, plug). Dzięki temu podgląd działa
## dla każdej trasy, także gdy danego zestawu nie ma teraz na mapie.
##
## Tu w przyszłości: przycinanie tras, łączenie i kolejność (operacje na próbkach).

const Data = preload("res://scripts/route_data.gd")

var route: Dictionary = {}
var vehicle_model: Dictionary = {}
var tool_model: Dictionary = {}
var last_error: String = ""
var _socket := Vector2.ZERO          # zaczep pojazdu (m, lokalnie)
var _plug := Vector2.ZERO            # zaczep narzędzia (m, lokalnie względem jego członu)
var _tool_kind: String = ""
var _path := PackedVector2Array()
var _path_times := PackedFloat32Array()   # czas nagrania każdego punktu _path


func setup(route_data: Dictionary, models_by_id: Dictionary) -> bool:
	route = route_data
	if not Data.valid(route_data):
		last_error = "Uszkodzona trasa."
		return false
	var signature: Dictionary = route["signature"]
	vehicle_model = models_by_id.get(str(signature.get("vehicle_model", "")), {})
	tool_model = models_by_id.get(str(signature.get("tool_model", "")), {})
	if vehicle_model.is_empty():
		last_error = "Nieznany pojazd trasy."
		return false
	_tool_kind = str(tool_model.get("physics_kind", "")) if not tool_model.is_empty() else ""
	_socket = _port(vehicle_model, str(signature.get("socket", "")))
	_plug = _port(tool_model, str(signature.get("plug", ""))) if not tool_model.is_empty() else Vector2.ZERO
	_path = PackedVector2Array()
	_path_times = PackedFloat32Array()
	for sample in route["samples"]:
		var point := Vector2(float(sample[1]), float(sample[2]))
		if _path.is_empty() or _path[-1].distance_to(point) >= 0.25:
			_path.append(point)
			_path_times.append(float(sample[0]))
	return true


func title() -> String:
	return str(route.get("name", "Trasa"))


## Np. "Ciągnik testowy + Kultywator testowy".
func rig_name() -> String:
	var text: String = str(vehicle_model.get("name", "?"))
	if not tool_model.is_empty():
		text += " + " + str(tool_model.get("name", "?"))
	return text


func duration() -> float:
	return float(route["samples"][-1][0])


## Przebieg pojazdu (metry, przerzedzony co 0,25 m).
func path_points() -> PackedVector2Array:
	return _path


## Czasy punktów przebiegu (ta sama długość co path_points).
func path_times() -> PackedFloat32Array:
	return _path_times


## Przebieg przejechany do chwili t: punkty o czasie ≤ t i dokładna pozycja pojazdu w chwili t.
func path_until(time: float) -> PackedVector2Array:
	var count: int = _path_times.bsearch(time, true)   # liczba punktów z czasem < t (+ równe)
	while count < _path_times.size() and _path_times[count] <= time:
		count += 1
	var result: PackedVector2Array = _path.slice(0, count)
	var sample: Array = sample_at(time)
	result.append(Vector2(float(sample[1]), float(sample[2])))
	return result


func sample_at(time: float) -> Array:
	return Data.at(route, clampf(time, 0.0, duration()))["point"]


## Człony zestawu w chwili t: [{"role", "model", "transforms": {"body": Transform2D, "front_carriage": ...}}].
## Transformacje w metrach (układ mapy: x w prawo, y w dół, obrót jak w grze).
func parts_at(time: float) -> Array:
	var sample: Array = sample_at(time)
	var vehicle := Transform2D(float(sample[3]), Vector2(float(sample[1]), float(sample[2])))
	var result: Array = [{"role": "vehicle", "model": vehicle_model, "transforms": {"body": vehicle}}]
	if tool_model.is_empty():
		return result
	var anchor: Vector2 = vehicle * _socket
	match _tool_kind:
		"towed_single_axle":
			var angle: float = float(sample[3]) + float(sample[4])
			result.append({"role": "tool", "model": tool_model,
				"transforms": {"body": Transform2D(angle, anchor - _plug.rotated(angle))}})
		"towed_turntable":
			var body_angle: float = float(sample[3]) + float(sample[4])
			var carriage_angle: float = body_angle + float(sample[5])
			var pivot: Vector2 = anchor - _plug.rotated(carriage_angle)
			var pivot_local: Vector2 = _vec(tool_model["front_carriage"]["pivot_in_body_m"])
			result.append({"role": "tool", "model": tool_model, "transforms": {
				"body": Transform2D(body_angle, pivot - pivot_local.rotated(body_angle)),
				"front_carriage": Transform2D(carriage_angle, pivot)}})
		"rigid_mounted":
			result.append({"role": "tool", "model": tool_model,
				"transforms": {"body": vehicle * Transform2D(0.0, _socket - _plug)}})
	return result


## Czy narzędzie pracuje (B) w chwili t (trasy v3+).
func working_at(time: float) -> bool:
	var sample: Array = sample_at(time)
	return sample.size() >= 8 and float(sample[7]) > 0.5


## Rozłożenie narzędzia 0..1 w chwili t (trasy v4+; starsze: 1).
func unfolded_at(time: float) -> float:
	var sample: Array = sample_at(time)
	return float(sample[8]) if sample.size() >= 9 else 1.0


## Prędkość pojazdu w chwili t (km/h) z sąsiednich próbek.
func speed_kmh_at(time: float) -> float:
	var a: Array = sample_at(time - 0.25)
	var b: Array = sample_at(time + 0.25)
	var span: float = float(b[0]) - float(a[0])
	if span <= 0.0:
		return 0.0
	return Vector2(float(b[1]) - float(a[1]), float(b[2]) - float(a[2])).length() / span * 3.6


## Obszar zajmowany przez cały przebieg (metry), z zapasem na zestaw.
func bounds() -> Rect2:
	if _path.is_empty():
		return Rect2()
	var rect := Rect2(_path[0], Vector2.ZERO)
	for point in _path:
		rect = rect.expand(point)
	var reach: float = float(vehicle_model.get("dimensions", {}).get("length_m", 4.0))
	if not tool_model.is_empty():
		reach += float(tool_model.get("dimensions", {}).get("length_m", 3.0)) + maxf(float(tool_model.get("dimensions", {}).get("width_m", 3.0)) * 0.5, 2.0)
	return rect.grow(reach)


func _port(model: Dictionary, port_id: String) -> Vector2:
	for port in model.get("hitch_ports", []):
		if str(port["id"]) == port_id:
			return _vec(port["position_m"])
	return Vector2.ZERO


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
