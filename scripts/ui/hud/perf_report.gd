extends PanelContainer
## Raport wydajności (F4): co sekundę rozpisuje kartę graficzną i silnik (czekanie) w ostatniej sekundzie,
## posortowane malejąco (ms na klatkę, udział w sekundzie); reszta czasu procesora w jednej linii.
## Nagłówek mówi, co ogranicza liczbę klatek (CPU czy GPU). Shift+F4: test składników karty
## (app/gpu_cost_probe.gd) – ile ms oszczędza wyłączenie cieni, SSAO, zboża, trawy, drzew…

const Profiler = preload("res://scripts/core/util/profiler.gd")

var probe: Node
## Nazwa jakości grafiki (G), do nagłówka.
var quality_name: String = ""
var _label: RichTextLabel
var _started_usec: int = 0
var _test_results: Array = []
var _test_base_ms: float = 0.0
var _test_status: String = ""


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
	if probe != null:
		probe.frames = 0
		probe.physics_steps = 0
	var limited: bool = probe != null and probe.frame_limited()
	var passes: bool = probe != null and probe.gpu_passes_available
	_label.text = format(Profiler.finish(Profiler.take(), limited), frames, seconds, passes, device_line()) + _test_text()


## Karta graficzna, na której działa gra, i rozdzielczość: obraz 3D (liczony) / okno.
func device_line() -> String:
	var viewport: Viewport = get_viewport()
	var window: Vector2i = get_window().size if get_window() != null else Vector2i.ZERO
	var scale: float = viewport.scaling_3d_scale if viewport != null else 1.0
	var text: String = "Karta: %s%s\nObraz 3D %d×%d (okno %d×%d)" % [
		RenderingServer.get_video_adapter_name(), adapter_kind(RenderingServer.get_video_adapter_type()),
		roundi(window.x * scale), roundi(window.y * scale), window.x, window.y]
	if not quality_name.is_empty():
		text += " | grafika: " + quality_name
	if RenderingServer.get_video_adapter_type() == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
		text += "\n[color=#ff9b7a]Gra działa na karcie ZINTEGROWANEJ (słabej). Jeśli laptop ma też dedykowaną:\nWindows → Ustawienia → System → Ekran → Grafika → Godot / gra → Wysoka wydajność.[/color]"
	return text


static func adapter_kind(type: int) -> String:
	match type:
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU:
			return " (zintegrowana)"
		RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
			return " (dedykowana)"
		RenderingDevice.DEVICE_TYPE_CPU:
			return " (programowa – procesor)"
		RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
			return " (wirtualna)"
	return ""


## Wynik testu składników (Shift+F4).
func show_gpu_test(results: Array, base_ms: float) -> void:
	_test_results = results
	_test_base_ms = base_ms
	_test_status = ""


func show_gpu_test_progress(text: String) -> void:
	_test_status = text


func _test_text() -> String:
	var lines := PackedStringArray()
	lines.append("")
	if not _test_status.is_empty():
		lines.append("[color=#ffd98a]%s[/color]" % _test_status)
	if _test_results.is_empty():
		if _test_status.is_empty():
			lines.append("[color=#cfc4b2]Shift+F4 – test składników: każdy wyłączany na chwilę, ile ms karty oszczędza.[/color]")
		return "\n".join(lines)
	lines.append("[color=#ffd98a][b]Test składników karty[/b] (klatka %.1f ms; ile oszczędza wyłączenie)[/color]" % _test_base_ms)
	for entry in _test_results:
		var ms: float = float(entry[1])
		lines.append("   %s  [color=#cfc4b2]%s%.2f ms  %d%%[/color]" % [entry[0], "+" if ms < 0.0 else "−", absf(ms), roundi(absf(ms) / maxf(_test_base_ms, 0.001) * 100.0)])
	return "\n".join(lines)


## Tekst raportu (BBCode): tylko karta graficzna i silnik, rozpisane; reszta w jednej linii.
static func format(totals: Dictionary, frames: int, seconds: float, passes: bool = false, device: String = "") -> String:
	var gpu: int = int(totals.get("_gpu_total", 0))
	var cpu: int = int(totals.get("_cpu_total", 0))
	var wall: float = seconds * 1000000.0
	var bottleneck: String = "karta graficzna (GPU)" if gpu > cpu else "procesor (CPU)"
	var lines := PackedStringArray()
	lines.append("[b]Raport wydajności[/b] (F4)  %d FPS, klatka %.1f ms" % [roundi(frames / seconds), wall / 1000.0 / frames])
	lines.append("Karta %.1f ms, procesor %.1f ms na klatkę → ogranicza: [b]%s[/b]" % [gpu / 1000.0 / frames, cpu / 1000.0 / frames, bottleneck])
	if not device.is_empty():
		lines.append("[color=#cfc4b2]%s[/color]" % device)
	lines.append(_counters())
	var rest: int = 0
	for group in Profiler.group(totals):
		if group["name"] != "Karta graficzna" and group["name"] != "Silnik":
			rest += int(group["usec"])
			continue
		lines.append("[color=#ffd98a][b]%s[/b]  %.2f ms/klatkę[/color]" % [group["name"], int(group["usec"]) / 1000.0 / frames])
		for item in group["items"]:
			if int(item["usec"]) / frames < 5:     # poniżej 0,005 ms na klatkę – pomijamy
				continue
			lines.append("   %s  [color=#cfc4b2]%.2f ms  %.1f%%[/color]" % [item["name"], int(item["usec"]) / 1000.0 / frames, int(item["usec"]) / wall * 100.0])
		if group["name"] == "Karta graficzna" and not passes:
			lines.append("   [color=#cfc4b2](etapy karty: gra uruchomiona z edytora, Forward+; albo Shift+F4)[/color]")
	lines.append("[color=#cfc4b2]Reszta (renderowanie CPU, fizyka, logika, widoki, interfejs): %.2f ms/klatkę[/color]" % (rest / 1000.0 / frames))
	return "\n".join(lines)


static func _counters() -> String:
	return "[color=#cfc4b2]Obiekty %d, wywołania rysowania %d, trójkąty %dk | ciała fizyki %d, pary kolizji %d[/color]" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		roundi(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
		Performance.get_monitor(Performance.PHYSICS_2D_ACTIVE_OBJECTS),
		Performance.get_monitor(Performance.PHYSICS_2D_COLLISION_PAIRS)]
