extends Node
## Test kosztu składników obrazu na karcie graficznej (Shift+F4).
## Dla każdego składnika (cienie, SSAO, zboże, trawa, drzewa, rozdzielczość…): pomiar czasu karty
## z RenderingServer ze składnikiem i zaraz potem bez niego (po kilku klatkach rozgrzewki),
## różnica = koszt składnika. Składniki zależą od siebie (np. cienie drzew), więc suma kosztów
## nie musi równać się czasowi klatki. Na koniec wszystko wraca do poprzedniego stanu.
## Wynik: lista [nazwa, ms] posortowana malejąco (sygnał finished).

signal progress(text: String)
signal finished(results: Array, base_ms: float)

const WARMUP_FRAMES: int = 6
const MEASURE_FRAMES: int = 20

var running: bool = false
var _views: Node


func setup(views: Node) -> void:
	name = "GpuCostProbe"
	_views = views
	process_mode = Node.PROCESS_MODE_ALWAYS


func start() -> String:
	if running:
		return "Test karty graficznej już trwa."
	var view: Node = _views.active_view()
	if not view.has_method("cost_components"):
		return "Test karty graficznej działa w widoku 3D (V)."
	var components: Array = view.call("cost_components")
	_run(components)
	return "Test karty graficznej: składniki wyłączane po kolei (ok. %d s)…" % ceili((components.size() + 3) * 0.5)


func _run(components: Array) -> void:
	running = true
	var viewport: Viewport = get_viewport()
	var rid: RID = viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(rid, true)
	var scale: float = viewport.scaling_3d_scale
	var msaa: Viewport.MSAA = viewport.msaa_3d
	var fxaa: Viewport.ScreenSpaceAA = viewport.screen_space_aa
	components = components.duplicate()
	components.append(["Rozdzielczość sceny 3D (połowa pikseli)", func(on: bool): viewport.scaling_3d_scale = scale if on else scale * 0.707])
	components.append(["Wygładzanie krawędzi (MSAA/FXAA)", func(on: bool):
		viewport.msaa_3d = msaa if on else Viewport.MSAA_DISABLED
		viewport.screen_space_aa = fxaa if on else Viewport.SCREEN_SPACE_AA_DISABLED])
	# Pomiar parami (ze składnikiem, zaraz potem bez niego): odporny na wahania czasu karty.
	var results: Array = []
	var base_sum: float = 0.0
	for component in components:
		progress.emit("Test karty: %s…" % component[0])
		var with_it: float = await _measure(rid)
		component[1].call(false)
		var without: float = await _measure(rid)
		component[1].call(true)
		base_sum += with_it
		results.append([str(component[0]), with_it - without])
	var base: float = base_sum / maxf(1.0, components.size())
	results.sort_custom(func(a, b): return float(a[1]) > float(b[1]))
	running = false
	finished.emit(results, base)


## Średni czas karty [ms] z MEASURE_FRAMES klatek po WARMUP_FRAMES klatkach rozgrzewki.
func _measure(rid: RID) -> float:
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	var total: float = 0.0
	for i in MEASURE_FRAMES:
		await get_tree().process_frame
		total += RenderingServer.viewport_get_measured_render_time_gpu(rid)
	return total / MEASURE_FRAMES
