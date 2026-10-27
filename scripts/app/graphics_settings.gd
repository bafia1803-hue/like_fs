extends Node
## Jakość grafiki 3D: presety z files/graphics.json (niska / średnia / wysoka), klawisz G.
## Ustawia to, co należy do okna (rozdzielczość sceny 3D, wygładzanie, rozmiar mapy cieni),
## a resztę przekazuje widokowi 3D (apply_quality: cienie, SSAO, trawa, drzewa, zboże).
## Wybór zapisuje się w user://settings.cfg ([graphics] quality).
##
## Rozdzielczość: scena 3D jest liczona najwyżej w max_render_height_px pikseli wysokości
## i skalowana do okna (FSR w Forward+). Na laptopie z ekranem 2560×1600 przy jakości średniej
## karta liczy ok. 2,2 razy mniej pikseli niż w pełnej rozdzielczości.

signal changed(name: String)

const JsonFile = preload("res://scripts/data/json_file.gd")
const UserSettings = preload("res://scripts/data/user_settings.gd")
const PRESETS_PATH: String = "res://files/graphics.json"

var settings = UserSettings.new()
var presets: Dictionary = {}
var order: Array = []
var current: String = ""
var _views: Node


func setup(views: Node) -> void:
	name = "GraphicsSettings"
	_views = views
	var data: Dictionary = JsonFile.new().read_object(PRESETS_PATH)
	presets = data.get("presets", {})
	order = data.get("order", presets.keys())
	var fallback: String = default_quality(data, RenderingServer.get_video_adapter_type())
	var saved: String = str(settings.get_value("graphics", "quality", fallback))
	current = saved if presets.has(saved) else fallback
	get_viewport().size_changed.connect(_apply_viewport)
	apply()


## Jakość bez zapisanego wyboru: na karcie zintegrowanej niższa (integrated_default).
static func default_quality(data: Dictionary, adapter_type: int) -> String:
	var presets_data: Dictionary = data.get("presets", {})
	var result: String = str(data.get("default", "medium"))
	if adapter_type == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU and presets_data.has(str(data.get("integrated_default", ""))):
		result = str(data["integrated_default"])
	return result


func preset() -> Dictionary:
	return presets.get(current, {})


func display_name() -> String:
	return str(preset().get("name", current))


## Następny poziom jakości. Zwraca komunikat dla gracza.
func cycle() -> String:
	if order.is_empty():
		return ""
	current = str(order[(order.find(current) + 1) % order.size()])
	settings.set_value("graphics", "quality", current)
	apply()
	return "Grafika: %s (G zmienia)" % display_name()


func apply() -> void:
	if presets.is_empty():
		return
	_apply_viewport()
	var data: Dictionary = preset()
	RenderingServer.directional_shadow_atlas_set_size(int(data.get("shadow_atlas_px", 4096)), true)
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_SOFT_LOW if int(data.get("shadow_atlas_px", 4096)) < 4096 else RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	# Jeśli SSAO jest włączone: w połowie rozdzielczości i w niskiej jakości (pełne kosztowało ~27 ms
	# na słabszej karcie). Poświata bez dwusześciennego skalowania (tańsze składanie).
	RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_LOW, true, 0.5, 1, 50.0, 300.0)
	RenderingServer.environment_glow_set_use_bicubic_upscale(false)
	for view in _views.views():
		if view.has_method("apply_quality"):
			view.call("apply_quality", data)
	changed.emit(display_name())


## Skala sceny 3D: rozdzielczość okna ograniczona do max_render_height_px.
static func render_scale(window_height_px: float, max_height_px: float) -> float:
	if window_height_px <= 0.0 or max_height_px <= 0.0:
		return 1.0
	return clampf(max_height_px / window_height_px, 0.5, 1.0)


func _apply_viewport() -> void:
	var data: Dictionary = preset()
	var viewport: Viewport = get_viewport()
	var window: Window = get_window()
	var pixels: float = float(window.size.y) if window != null else 0.0
	var scale: float = render_scale(pixels, float(data.get("max_render_height_px", 1080)))
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if scale < 0.999 else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = scale
	match int(data.get("msaa", 0)):
		2:
			viewport.msaa_3d = Viewport.MSAA_2X
		4:
			viewport.msaa_3d = Viewport.MSAA_4X
		_:
			viewport.msaa_3d = Viewport.MSAA_DISABLED
	# FXAA istnieje tylko w Forward+ / Mobile (renderer z RenderingDevice).
	if RenderingServer.get_rendering_device() != null:
		viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(data.get("fxaa", false)) else Viewport.SCREEN_SPACE_AA_DISABLED

