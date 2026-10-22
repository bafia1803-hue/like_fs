extends PanelContainer
## Panel diagnostyczny (F3): prędkość, masa, zaczep, zbiorniki, przeładunek, ostatni komunikat.
## Pokazuje też błąd uruchomienia świata.

var _label: Label


func _init() -> void:
	name = "StatusPanel"
	position = Vector2(12, 64)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", preload("res://scripts/ui/hud/hud_style.gd").panel(0.42, 10))
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_shadow_color", Color.BLACK)
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.text = "Wczytywanie świata..."
	add_child(_label)


func show_lines(lines: PackedStringArray) -> void:
	_label.text = "\n".join(lines)


func show_error(message: String) -> void:
	visible = true
	_label.text = "Nie udało się uruchomić świata.\n" + message
	_label.add_theme_color_override("font_color", Color("#ff8c8c"))
