extends PanelContainer
## Raport wydajności (F4): co sekundę pokazuje, co zajęło najwięcej czasu w ostatniej sekundzie.
## Grupy (Grafika, Fizyka, Logika gry, Widok, Interfejs, Silnik) i pozycje w grupach są posortowane
## malejąco. Kolumny: ms na klatkę (średnio) i udział w czasie sekundy.
## Karta graficzna pracuje równolegle z procesorem – jej czas jest osobną pozycją, a nagłówek mówi,
## co ogranicza liczbę klatek (CPU czy GPU).

const Profiler = preload("res://scripts/core/util/profiler.gd")
const GPU_KEY: String = Profiler.RENDER_GPU

var probe: Node
var _label: RichTextLabel
var _started_usec: int = 0


func _init() -> void:
	name = "PerfReport"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	position = Vector2(12, 64)
	custom_minimum_size = Vector2(470, 0)
	add_theme_stylebox_override("panel", preload("res://scripts/ui/hud/hud_style.gd").panel(0.62, 10))
	_label = RichTextLabel.new()
	_label.bbcode_enabled = true
	_label.fit_content = true
	_label.scroll_active = false
	_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_label.custom_minimum_size = Vector2(450, 0)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("normal_font_size", 13)
	_label.add_theme_font_size_override("bold_font_size", 13)
	add_child(_label)
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS


func toggle() -> bool:
	visible = not visible
	_started_usec = Time.get_ticks_usec()
	if probe != null:
		probe.set_measuring(visible)
	Profiler.take()
	_label.text = "[b]Raport wydajności[/b] – zbieranie danych…"
	return visible


## Okres liczony zegarem rzeczywistym (czas gry zwalnia, gdy brakuje klatek).
func _process(_delta: float) -> void:
	if not visible:
		return
	var now: int = Time.get_ticks_usec()
	var seconds: float = (now - _started_usec) / 1000000.0
	if seconds < 1.0:
		return
	_started_usec = now
	var frames: int = maxi(1, probe.frames) if probe != null else 1
	var steps: int = probe.physics_steps if probe != null else 0
	if probe != null:
		probe.frames = 0
		probe.physics_steps = 0
	_label.text = format(Profiler.finish(Profiler.take()), frames, steps, seconds)


## Tekst raportu (BBCode) z sum czasów [µs] z ostatniego okresu.
static func format(totals: Dictionary, frames: int, physics_steps: int, seconds: float) -> String:
	var gpu: int = int(totals.get(GPU_KEY, 0))
	var cpu: int = 0
	for key in totals:
		if key != GPU_KEY and not str(key).begins_with("Silnik/Oczekiwanie"):
			cpu += int(totals[key])
	var bottleneck: String = "karta graficzna (GPU)" if gpu > cpu else "procesor (CPU)"
	var lines := PackedStringArray()
	lines.append("[b]Raport wydajności[/b] (F4)  %d FPS, %d kroków fizyki/s" % [roundi(frames / seconds), roundi(physics_steps / seconds)])
	lines.append("Klatka: CPU %.1f ms, GPU %.1f ms → ogranicza: [b]%s[/b]" % [cpu / 1000.0 / frames, gpu / 1000.0 / frames, bottleneck])
	lines.append(_counters())
	var budget: float = seconds * 1000000.0
	for group in Profiler.group(totals):
		lines.append("[color=#ffd98a][b]%s[/b]  %.2f ms/klatkę  %d%%[/color]" % [group["name"], int(group["usec"]) / 1000.0 / frames, roundi(int(group["usec"]) / budget * 100.0)])
		for item in group["items"]:
			var share: float = int(item["usec"]) / budget * 100.0
			if int(item["usec"]) / frames < 5:     # poniżej 0,005 ms na klatkę – pomijamy
				continue
			lines.append("   %s  [color=#cfc4b2]%.2f ms  %.1f%%[/color]" % [item["name"], int(item["usec"]) / 1000.0 / frames, share])
	return "\n".join(lines)


static func _counters() -> String:
	return "[color=#cfc4b2]Obiekty %d, wywołania rysowania %d, trójkąty %dk | ciała fizyki %d, pary kolizji %d[/color]" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		roundi(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
		Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)]
