extends Node
## Pomiar przerw między skryptami w klatce – to, czego nie da się zmierzyć w samych skryptach:
##   – krok silnika fizyki (Rapier: kolizje, całkowanie) następuje po wszystkich _physics_process
##     danego kroku; mierzymy czas od końca skryptów fizyki do początku następnej części klatki,
##   – renderowanie i oczekiwanie (V-Sync, karta) następuje po wszystkich _process; mierzymy czas
##     od końca skryptów klatki do początku następnej klatki i dzielimy go wg czasu renderowania
##     zmierzonego przez RenderingServer (CPU i GPU).
## Dwa węzły-wartownicy: pierwszy (najniższy priorytet) i ostatni (najwyższy) w każdej fazie.
##
## Etapy karty graficznej (cienie, nieprzezroczyste, niebo, SSAO, poświata…) podaje renderer
## Godota przez znaczniki czasu RenderingDevice – tylko w Forward+/Mobile i tylko gdy działa
## profiler wizualny (gra uruchomiona z edytora). Wtedy włączamy go na czas raportu.

const Profiler = preload("res://scripts/core/util/profiler.gd")
const _SentinelScript = preload("res://scripts/app/frame_probe_sentinel.gd")

var frames: int = 0
var physics_steps: int = 0
var _first: Node
var _last: Node
var _physics_end: int = 0
var _frame_end: int = 0
var _physics_start: int = 0
var _frame_start: int = 0
## Czas skryptów fizyki/klatki zmierzony osobno (żeby policzyć „pozostałe”).
var physics_scripts_usec: int = 0
var frame_scripts_usec: int = 0
## Czy renderer podaje etapy karty graficznej.
var gpu_passes_available: bool = false
var _last_timestamp_frame: int = -1


func _ready() -> void:
	name = "FrameProbe"
	process_mode = Node.PROCESS_MODE_ALWAYS
	_first = _sentinel(-1000000, true)
	_last = _sentinel(1000000, false)


func _sentinel(priority: int, first: bool) -> Node:
	var node = _SentinelScript.new()
	node.name = "First" if first else "Last"
	node.process_mode = Node.PROCESS_MODE_ALWAYS
	node.process_priority = priority
	node.process_physics_priority = priority
	node.probe = self
	node.first = first
	add_child(node)
	return node


func set_measuring(value: bool) -> void:
	Profiler.enabled = value
	_physics_end = 0
	_frame_end = 0
	frames = 0
	physics_steps = 0
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), value)
	gpu_passes_available = false
	if RenderingServer.get_rendering_device() != null and EngineDebugger.is_active() and EngineDebugger.has_profiler("visual"):
		EngineDebugger.profiler_enable("visual", value)
		gpu_passes_available = value


## Czy liczba klatek jest celowo ograniczona (V-Sync albo limit FPS).
func frame_limited() -> bool:
	return Engine.max_fps > 0 or DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED


func physics_begin() -> void:
	if not Profiler.enabled:
		return
	var now: int = Time.get_ticks_usec()
	_close_gaps(now)
	_physics_start = now
	physics_steps += 1


func physics_end() -> void:
	if not Profiler.enabled:
		return
	_physics_end = Time.get_ticks_usec()
	Profiler.add("_physics_scripts", _physics_end - _physics_start)


func frame_begin() -> void:
	if not Profiler.enabled:
		return
	var now: int = Time.get_ticks_usec()
	_close_gaps(now)
	_frame_start = now
	frames += 1


func frame_end() -> void:
	if not Profiler.enabled:
		return
	_frame_end = Time.get_ticks_usec()
	Profiler.add("_frame_scripts", _frame_end - _frame_start)
	var rid: RID = get_viewport().get_viewport_rid()
	Profiler.add("_render_cpu", int(RenderingServer.viewport_get_measured_render_time_cpu(rid) * 1000.0))
	Profiler.add(Profiler.RENDER_GPU, int(RenderingServer.viewport_get_measured_render_time_gpu(rid) * 1000.0))
	if gpu_passes_available:
		_add_gpu_passes()


## Najgłębsze etapy z ostatniej zarejestrowanej klatki: pary "> nazwa" / "< nazwa" bez etapów
## w środku i pojedyncze znaczniki (do następnego znacznika).
func _add_gpu_passes() -> void:
	var rd: RenderingDevice = RenderingServer.get_rendering_device()
	if rd == null or rd.get_captured_timestamps_frame() == _last_timestamp_frame:
		return
	_last_timestamp_frame = rd.get_captured_timestamps_frame()
	var count: int = rd.get_captured_timestamps_count()
	var stack: Array = []           # [nazwa, czas, ma_dzieci]
	for i in count:
		var label: String = rd.get_captured_timestamp_name(i)
		var time: int = rd.get_captured_timestamp_gpu_time(i)
		if label.begins_with(">"):
			if not stack.is_empty():
				stack[-1][2] = true
			stack.append([label.substr(1).strip_edges(), time, false])
		elif label.begins_with("<"):
			if stack.is_empty():
				continue
			var opened: Array = stack.pop_back()
			if not bool(opened[2]):
				Profiler.add(Profiler.GPU_PASS + str(opened[0]), time - int(opened[1]))
		elif i + 1 < count:
			if not stack.is_empty():
				stack[-1][2] = true
			Profiler.add(Profiler.GPU_PASS + label.strip_edges(), rd.get_captured_timestamp_gpu_time(i + 1) - time)


## Czas od końca skryptów fizyki = krok silnika; od końca skryptów klatki = renderowanie i czekanie.
func _close_gaps(now: int) -> void:
	if _physics_end > 0:
		Profiler.add(Profiler.PHYSICS_ENGINE, now - _physics_end)
		_physics_end = 0
	if _frame_end > 0:
		Profiler.add("_after_frame", now - _frame_end)
		_frame_end = 0
