extends RefCounted
## Wspólny wygląd elementów HUD (panele, duże przyciski akcji).


## Półprzezroczysty, zaokrąglony panel.
static func panel(alpha: float, margin: float) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.11, 0.09, alpha)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(margin)
	style.content_margin_left = 14
	style.content_margin_right = 14
	return style


## Duży przycisk akcji na dole ekranu (zakup pola, usługa, trasa) w danym kolorze.
static func action_button(color: Color, hover: Color, font: Color) -> Button:
	var button := Button.new()
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", 18)
	var normal := StyleBoxFlat.new()
	normal.bg_color = color
	normal.set_corner_radius_all(10)
	normal.set_content_margin_all(10)
	button.add_theme_stylebox_override("normal", normal)
	var hovered: StyleBoxFlat = normal.duplicate()
	hovered.bg_color = hover
	button.add_theme_stylebox_override("hover", hovered)
	button.add_theme_stylebox_override("pressed", normal)
	button.add_theme_color_override("font_color", font)
	button.add_theme_color_override("font_hover_color", font)
	return button


## Ustawia przycisk na środku dołu ekranu (nad paskiem akcji).
static func place_bottom_center(control: Control, half_width: float, top: float, bottom: float) -> void:
	control.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	control.offset_top = top
	control.offset_bottom = bottom
	control.offset_left = -half_width
	control.offset_right = half_width
