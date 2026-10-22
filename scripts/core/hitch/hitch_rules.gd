extends RefCounted
## Zasady zaczepów – czysta logika (bez węzłów i fizyki).
##   drawbar      – dyszel: przegub obrotowy (przyczepa, siewnik, kultywator),
##   fifth_wheel  – siodło tira ↔ sworzeń naczepy: przegub obrotowy; port może mieć własną
##                  tolerancję "attach_distance_m" i "attach_angle_deg",
##   combine_header, three_point – mocowanie sztywne (heder, narzędzie na TUZ).

const PIN_TYPES: Array[String] = ["drawbar", "fifth_wheel"]
const RIGID_TYPES: Array[String] = ["combine_header", "three_point"]


## Czy gniazdo pojazdu i zaczep narzędzia do siebie pasują (role i typ).
static func ports_match(socket: Dictionary, plug: Dictionary) -> bool:
	return socket.get("role") == "socket" and plug.get("role") == "plug" and socket.get("type") == plug.get("type")


## Rodzaj połączenia: "pin" (przegub), "rigid" (sztywne) albo "" (nieobsługiwane).
static func link_kind(port_type: String) -> String:
	if PIN_TYPES.has(port_type):
		return "pin"
	if RIGID_TYPES.has(port_type):
		return "rigid"
	return ""


## Metody, których wymaga dany rodzaj połączenia od narzędzia.
static func required_methods(port_type: String) -> Array[String]:
	match link_kind(port_type):
		"pin":
			return ["get_hitch_body", "snap_by", "set_attached"]
		"rigid":
			return ["attach_to_carrier", "get_hitch_position"]
	return []


## Dopuszczalna odległość zaczepów: zasada ogólna albo tolerancja portu (np. siodło).
static func attach_distance(policy: Dictionary, socket: Dictionary, plug: Dictionary) -> float:
	return maxf(float(policy["max_attach_distance_m"]),
		maxf(float(socket.get("attach_distance_m", 0.0)), float(plug.get("attach_distance_m", 0.0))))


## Komunikat, gdy odległość jest za duża (pusty = można podpiąć).
static func distance_problem(distance_m: float, allowed_m: float) -> String:
	if distance_m > allowed_m:
		return "Zbliż zaczepy: %.2f m / wymagane %.2f m." % [distance_m, allowed_m]
	return ""


## Komunikat, gdy port wymaga ustawienia w linii (attach_angle_deg), a kąt jest za duży.
static func angle_problem(socket: Dictionary, parent_rotation: float, child_rotation: float) -> String:
	if not socket.has("attach_angle_deg"):
		return ""
	var difference: float = absf(rad_to_deg(angle_difference(parent_rotation, child_rotation)))
	if difference > float(socket["attach_angle_deg"]):
		return "Ustaw pojazd w linii z naczepą (różnica %.0f°, dozwolone %.0f°)." % [difference, float(socket["attach_angle_deg"])]
	return ""


## Najbliższy kandydat z listy słowników z kluczem "distance" (pusty słownik, gdy lista pusta).
## Przy równych odległościach wygrywa wcześniejszy.
static func nearest(candidates: Array) -> Dictionary:
	var best: Dictionary = {}
	var best_distance: float = INF
	for candidate in candidates:
		if float(candidate["distance"]) < best_distance:
			best_distance = float(candidate["distance"])
			best = candidate
	return best
