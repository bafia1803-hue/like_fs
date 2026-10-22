extends Label
## Krótki komunikat u góry ekranu (podpięcie, zapis, zmiana pojazdu…), znika po 3,5 s.

const SHOW_SECONDS: float = 3.5
const FADE_SECONDS: float = 0.6

## Ostatni komunikat (także pusty) – panel diagnostyczny pokazuje go w ostatnim wierszu.
var last_message: String = ""
var _time: float = 0.0


func _init() -> void:
	name = "Toast"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	offset_top = 18
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_theme_font_size_override("font_size", 18)
	add_theme_color_override("font_color", Color("#fffaf0"))
	add_theme_color_override("font_outline_color", Color(0.12, 0.1, 0.08, 0.9))
	add_theme_constant_override("outline_size", 6)
	visible = false


func show_message(message: String) -> void:
	last_message = message
	if message.is_empty():
		return
	text = message
	visible = true
	modulate.a = 1.0
	_time = SHOW_SECONDS


func _process(delta: float) -> void:
	if _time > 0.0:
		_time -= delta
		modulate.a = clampf(_time / FADE_SECONDS, 0.0, 1.0)
		visible = _time > 0.0
