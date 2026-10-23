extends PanelContainer
## Licznik klatek na sekundę (prawy górny róg, na lewo od informatora). Odświeżany 2 razy/s;
## kolor ostrzega o spadkach: zielony ≥ 50, żółty ≥ 30, czerwony poniżej.

const REFRESH_SECONDS: float = 0.5

var _label: Label
var _timer: float = 0.0


func _init() -> void:
	name = "FpsLabel"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_right = -340
	offset_left = -440
	offset_top = 12
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	add_theme_stylebox_override("panel", preload("res://scripts/ui/hud/hud_style.gd").panel(0.5, 6))
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", 14)
	add_child(_label)
	_refresh()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_SECONDS:
		_timer = 0.0
		_refresh()


func _refresh() -> void:
	var fps: float = Engine.get_frames_per_second()
	_label.text = "%d FPS" % roundi(fps)
	var color := Color("#9be37a")
	if fps < 30.0:
		color = Color("#ff8c7a")
	elif fps < 50.0:
		color = Color("#ffd98a")
	_label.add_theme_color_override("font_color", color)
