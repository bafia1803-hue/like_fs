extends RefCounted
## Konfiguracja zasad gry, wczytywana raz przy starcie świata:
##   farming.json – praca na polu i plony, routes.json – trasy, prices.json – cennik.
## Systemy dostają gotowe słowniki (nie czytają plików same), więc testy mogą podać własne
## ustawienia przez from_dictionaries().

const JsonFile = preload("res://scripts/data/json_file.gd")
const PriceList = preload("res://scripts/core/economy/price_list.gd")
const DEFAULT_DIRECTORY: String = "res://files"
const FARMING_REQUIRED: Array[String] = ["minimum_work_speed_m_s", "yield_l_per_m2", "colors"]
const ROUTE_REQUIRED: Array[String] = ["sample_seconds", "max_recording_seconds", "start_distance_m",
	"collision_step_m", "collision_step_degrees", "collision_margin_m", "max_collision_steps_per_tick", "line_spacing_m"]

var farming: Dictionary = {}
var routes: Dictionary = {}
var prices = PriceList.new()
var last_error: String = ""


func load_from(directory: String = DEFAULT_DIRECTORY) -> bool:
	var reader = JsonFile.new()
	var documents: Array = []
	for file_name in ["farming.json", "routes.json", "prices.json"]:
		var path: String = directory.path_join(file_name)
		if not FileAccess.file_exists(path):
			return _fail("Brak pliku konfiguracji: " + path)
		var data: Dictionary = reader.read_object(path)
		if data.is_empty():
			return _fail(reader.last_error)
		documents.append(data)
	return from_dictionaries(documents[0], documents[1], documents[2])


func from_dictionaries(farming_data: Dictionary, route_data: Dictionary, price_data: Dictionary) -> bool:
	last_error = ""
	for key in FARMING_REQUIRED:
		if not farming_data.has(key):
			return _fail("Brak parametru farming.json: " + key)
	farming = farming_data
	routes = normalize_routes(route_data)
	if routes.is_empty():
		return false
	if not prices.setup(price_data):
		return _fail(prices.last_error)
	return true


## Ustawienia tras z wartościami domyślnymi i ograniczeniami (pusty słownik = błąd w last_error).
func normalize_routes(data: Dictionary) -> Dictionary:
	var result: Dictionary = data.duplicate(true)
	# Start/koniec nagrywania i start trasy są dozwolone w ruchu do tej prędkości.
	result["max_start_speed_kmh"] = maxf(0.0, float(result.get("max_start_speed_kmh", 6.0)))
	result["playback_accel_m_s2"] = maxf(0.05, float(result.get("playback_accel_m_s2", 1.5)))
	result["playback_decel_m_s2"] = maxf(0.05, float(result.get("playback_decel_m_s2", 2.0)))
	result["start_blend_min_m"] = maxf(0.5, float(result.get("start_blend_min_m", 10.0)))
	result["resume_clearance_m"] = maxf(0.0, float(result.get("resume_clearance_m", 0.5)))
	result["resume_clear_seconds"] = maxf(0.0, float(result.get("resume_clear_seconds", 0.5)))
	for key in ROUTE_REQUIRED:
		if not result.get(key) is float and not result.get(key) is int:
			_fail("Brak ustawienia tras: " + key)
			return {}
		if not is_finite(float(result[key])) or float(result[key]) <= 0.0:
			_fail("Ustawienie tras musi być dodatnie: " + key)
			return {}
	return result


func _fail(message: String) -> bool:
	last_error = message
	return false
