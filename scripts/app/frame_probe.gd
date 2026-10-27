extends Node
## Pomiar przerw między skryptami w klatce – to, czego nie da się zmierzyć w samych skryptach:
##   – krok silnika fizyki (Rapier: kolizje, całkowanie) następuje po wszystkich _physics_process
##     danego kroku; mierzymy czas od końca skryptów fizyki do początku następnej części klatki,
##   – renderowanie i oczekiwanie (V-Sync, karta) następuje po wszystkich _process; mierzymy czas
##     od końca skryptów klatki do początku następnej klatki i dzielimy go wg czasu renderowania
##     zmierzonego przez RenderingServer (CPU i GPU).
## Dwa węzły-wartownicy: pierwszy (najniższy priorytet) i ostatni (najwyższy) w każdej fazie.

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


## Czas od końca skryptów fizyki = krok silnika; od końca skryptów klatki = renderowanie i czekanie.
func _close_gaps(now: int) -> void:
	if _physics_end > 0:
		Profiler.add(Profiler.PHYSICS_ENGINE, now - _physics_end)
		_physics_end = 0
	if _frame_end > 0:
		Profiler.add("_after_frame", now - _frame_end)
		_frame_end = 0
