extends RefCounted
## Lekki pomiar czasu dla raportu wydajności (F4). Wyłączony nic nie mierzy (jedno sprawdzenie flagi).
##
## Użycie w gorącym kodzie:
##   var started: int = Profiler.start()
##   ...praca...
##   Profiler.stop(Profiler.FIELD_WORK, started)
## Klucz to "Grupa/Nazwa"; raport sumuje czasy z ostatniej sekundy i sortuje grupy i pozycje.

# Grupy i pozycje (stałe w jednym miejscu, żeby raport był spójny).
const PHYSICS_ENGINE: String = "Fizyka/Silnik Rapier: kolizje i ruch ciał"
const PHYSICS_TIRES: String = "Fizyka/Opony, napęd i hamulce (skrypty ciał)"
const MACHINES_STATE: String = "Logika gry/Maszyny: stan, składanie, kolizje profili"
const FIELD_WORK: String = "Logika gry/Praca na polu (siew, zbiór, nawożenie)"
const TRANSFER: String = "Logika gry/Przeładunek ziarna"
const SERVICES: String = "Logika gry/Usługi farmy (silos, magazyn)"
const ROUTES: String = "Logika gry/Trasy (nagrywanie, odtwarzanie, kolizje tras)"
const DRIVER: String = "Logika gry/Sterowanie gracza"
const FIELD_TEXTURE: String = "Grafika/Tekstury stanu pól (wysyłka do karty)"
const VIEW_MACHINES: String = "Widok/Maszyny 3D (animacje, ładunek, cząstki)"
const VIEW_MACHINES_PHYSICS: String = "Widok/Maszyny 3D: śledzenie pozy (krok fizyki)"
const VIEW_FIELDS: String = "Widok/Pola i zboże (poziomy szczegółów)"
const VIEW_FARM: String = "Widok/Farma, trasy, kamera, otoczenie"
const VIEW_2D: String = "Widok/Widok 2D"
const UI_HUD: String = "Interfejs/HUD, przyciski kontekstowe"
const UI_INFORMATOR: String = "Interfejs/Informator"
const RENDER_CPU: String = "Grafika/Renderowanie: przygotowanie klatki (CPU)"
const RENDER_GPU: String = "Karta graficzna/Rysowanie klatki na GPU (równolegle z CPU)"
## Etapy karty graficznej (znaczniki czasu renderera Godota): klucz GPU_PASS + nazwa etapu.
const GPU_PASS: String = "Karta graficzna/"
const GPU_OTHER: String = "Karta graficzna/Pozostałe etapy (niepodpisane)"
const WAIT_GPU: String = "Silnik/Procesor czeka, aż karta skończy poprzednią klatkę"
const WAIT_VSYNC: String = "Silnik/V-Sync / limit klatek (celowe czekanie)"
const WAIT_OTHER: String = "Silnik/Sterownik, okno, system"
const PHYSICS_OTHER: String = "Fizyka/Pozostałe skrypty fizyki"
const FRAME_OTHER: String = "Silnik/Pozostałe skrypty klatki"

static var enabled: bool = false
static var _usec: Dictionary = {}


static func start() -> int:
	return Time.get_ticks_usec() if enabled else 0


static func stop(key: String, started: int) -> void:
	if enabled and started > 0:
		_usec[key] = int(_usec.get(key, 0)) + Time.get_ticks_usec() - started


static func add(key: String, usec: int) -> void:
	if enabled and usec > 0:
		_usec[key] = int(_usec.get(key, 0)) + usec


## Zebrane czasy [µs] od ostatniego wywołania (i wyzerowanie).
static func take() -> Dictionary:
	var result: Dictionary = _usec
	_usec = {}
	return result


## Grupy posortowane malejąco: [{"name", "usec", "items": [{"name", "usec"}]}].
static func group(totals: Dictionary) -> Array:
	var groups: Dictionary = {}
	for key in totals:
		if str(key).begins_with("_"):
			continue
		var parts: PackedStringArray = str(key).split("/", true, 1)
		var group_name: String = parts[0]
		var item: String = parts[1] if parts.size() > 1 else parts[0]
		if not groups.has(group_name):
			groups[group_name] = {"name": group_name, "usec": 0, "items": []}
		groups[group_name]["usec"] += int(totals[key])
		groups[group_name]["items"].append({"name": item, "usec": int(totals[key])})
	var result: Array = groups.values()
	for entry in result:
		entry["items"].sort_custom(func(a, b): return int(a["usec"]) > int(b["usec"]))
	result.sort_custom(func(a, b): return int(a["usec"]) > int(b["usec"]))
	return result


## Zamienia surowe sumy (z FrameProbe) na pozycje raportu:
##   – krok silnika fizyki bez sił opon (te liczą się w trakcie kroku),
##   – czas po skryptach klatki: przygotowanie obrazu (CPU, wg RenderingServer) i czekanie,
##   – czekanie dzielone na: procesor czeka na kartę (karta liczy dłużej niż procesor pracuje),
##     V-Sync / limit klatek (gdy włączone) albo sterownik i system,
##   – etapy karty (gdy renderer je podaje) + „pozostałe etapy” do pełnego czasu karty,
##   – „pozostałe skrypty” = zmierzony czas faz minus pozycje zmierzone osobno.
## Pełny czas karty trafia do "_gpu_total", pełny czas pracy procesora do "_cpu_total".
## frame_limited: włączony V-Sync albo limit FPS.
static func finish(totals: Dictionary, frame_limited: bool = false) -> Dictionary:
	var result: Dictionary = totals.duplicate()
	var physics_scripts: int = int(result.get("_physics_scripts", 0))
	var frame_scripts: int = int(result.get("_frame_scripts", 0))
	var after: int = int(result.get("_after_frame", 0))
	var render_cpu: int = mini(int(result.get("_render_cpu", 0)), after)
	var gpu_total: int = int(result.get(RENDER_GPU, 0))
	# Etapy karty są z klatek, w których renderer podał znaczniki czasu (nie zawsze z każdej) –
	# przeliczamy je na wszystkie klatki okresu.
	var frames: int = int(result.get("_frames", 0))
	var pass_frames: int = int(result.get("_gpu_pass_frames", 0))
	if frames > 0 and pass_frames > 0 and pass_frames != frames:
		for key in result.keys():
			if str(key).begins_with(GPU_PASS) and key != RENDER_GPU:
				result[key] = int(int(result[key]) * float(frames) / pass_frames)
	for key in ["_physics_scripts", "_frame_scripts", "_after_frame", "_render_cpu", "_frames", "_gpu_pass_frames"]:
		result.erase(key)
	var measured_physics: int = 0
	var measured_frame: int = 0
	var gpu_passes: int = 0
	for key in result:
		var group: String = str(key).get_slice("/", 0)
		if key == PHYSICS_ENGINE or key == PHYSICS_TIRES or key == RENDER_GPU:
			continue
		if str(key).begins_with(GPU_PASS):
			gpu_passes += int(result[key])
		elif group == "Logika gry" or key == VIEW_MACHINES_PHYSICS:
			measured_physics += int(result[key])
		else:
			measured_frame += int(result[key])
	# Siły opon liczą się w trakcie kroku silnika (_integrate_forces) – odejmujemy je od silnika.
	if result.has(PHYSICS_ENGINE):
		result[PHYSICS_ENGINE] = maxi(0, int(result[PHYSICS_ENGINE]) - int(result.get(PHYSICS_TIRES, 0)))
	result[RENDER_CPU] = render_cpu
	result[PHYSICS_OTHER] = maxi(0, physics_scripts - measured_physics)
	result[FRAME_OTHER] = maxi(0, frame_scripts - measured_frame)
	var cpu_total: int = 0
	for key in result:
		if not str(key).begins_with(GPU_PASS):
			cpu_total += int(result[key])
	# Czekanie po skryptach klatki.
	var wait: int = maxi(0, after - render_cpu)
	var wait_gpu: int = clampi(gpu_total - cpu_total, 0, wait)
	result[WAIT_GPU] = wait_gpu
	if frame_limited:
		result[WAIT_VSYNC] = wait - wait_gpu
	else:
		result[WAIT_OTHER] = wait - wait_gpu
	# Karta: etapy (jeśli są) zamiast jednej pozycji.
	if gpu_passes > 0:
		result.erase(RENDER_GPU)
		result[GPU_OTHER] = maxi(0, gpu_total - gpu_passes)
	result["_gpu_total"] = gpu_total
	result["_cpu_total"] = cpu_total
	for key in result.keys():
		if int(result[key]) <= 0 and not str(key).begins_with("_"):
			result.erase(key)
	return result
