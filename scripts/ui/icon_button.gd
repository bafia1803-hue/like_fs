extends Button
## Okrągły przycisk z ikoną rysowaną w kodzie (wektor – ostra w każdej rozdzielczości).
## icon_name: "record", "pause", "routes", "cart", "sleep", "save", "exit", "fullscreen", "folder".
## Nazwa przycisku pokazuje się jako podpowiedź (tooltip). badge: mały licznik w rogu (pusty = brak).

const BG := Color(0.13, 0.11, 0.09, 0.72)
const BG_HOVER := Color(0.24, 0.2, 0.16, 0.85)
const BG_PRESSED := Color(0.32, 0.26, 0.19, 0.9)
const RING := Color(1.0, 0.85, 0.54, 0.35)
const INK := Color("#fffaf0")
const ACCENT := Color("#ffd98a")

var icon_name: String = ""
var icon_color: Color = INK
var badge: String = "":
	set(value):
		if badge != value:
			badge = value
			queue_redraw()


func _init(name_of_icon: String = "", hint: String = "", diameter: float = 56.0) -> void:
	icon_name = name_of_icon
	tooltip_text = hint
	focus_mode = Control.FOCUS_NONE
	custom_minimum_size = Vector2(diameter, diameter)
	flat = true
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for state in ["normal", "hover", "pressed", "disabled", "focus", "hover_pressed"]:
		add_theme_stylebox_override(state, StyleBoxEmpty.new())
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)


func set_icon(name_of_icon: String, color: Color = INK) -> void:
	if icon_name != name_of_icon or icon_color != color:
		icon_name = name_of_icon
		icon_color = color
		queue_redraw()


func _draw() -> void:
	var c: Vector2 = size * 0.5
	var r: float = minf(size.x, size.y) * 0.5 - 1.0
	var bg: Color = BG
	if disabled:
		bg = Color(0.13, 0.11, 0.09, 0.45)
	elif is_pressed() or button_pressed:
		bg = BG_PRESSED
	elif is_hovered():
		bg = BG_HOVER
	draw_circle(c, r, bg)
	draw_arc(c, r - 0.5, 0.0, TAU, 48, RING if not is_hovered() else Color(ACCENT, 0.8), 2.0, true)
	var ink: Color = icon_color if not disabled else Color(0.6, 0.56, 0.5)
	var s: float = r * 0.5          # skala ikony
	match icon_name:
		"record":
			draw_colored_polygon(PackedVector2Array([c + Vector2(-0.55, -0.85) * s, c + Vector2(-0.55, 0.85) * s, c + Vector2(0.95, 0.0) * s]), ink)
		"pause":
			for x in [-0.6, 0.15]:
				draw_rect(Rect2(c + Vector2(x, -0.8) * s, Vector2(0.45, 1.6) * s), ink)
		"routes":
			_icon_routes(c, s, ink)
		"cart":
			_icon_cart(c, s, ink)
		"sleep":
			_icon_sleep(c, s, ink, bg)
		"save":
			_icon_save(c, s, ink, bg)
		"exit":
			_icon_exit(c, s, ink)
		"fullscreen":
			for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
				var p: Vector2 = c + corner * 0.85 * s
				draw_line(p, p - Vector2(corner.x * 0.55 * s, 0.0), ink, 2.5, true)
				draw_line(p, p - Vector2(0.0, corner.y * 0.55 * s), ink, 2.5, true)
		"folder":
			var body := Rect2(c + Vector2(-1.0, -0.45) * s, Vector2(2.0, 1.35) * s)
			draw_rect(body, ink, false, 2.5)
			draw_polyline(PackedVector2Array([c + Vector2(-1.0, -0.45) * s, c + Vector2(-1.0, -0.8) * s, c + Vector2(-0.3, -0.8) * s, c + Vector2(-0.1, -0.45) * s]), ink, 2.5, true)
	if not badge.is_empty():
		var p: Vector2 = c + Vector2(r * 0.72, -r * 0.72)
		draw_circle(p, r * 0.36, Color("#e0a93b"))
		var font: Font = get_theme_default_font()
		var font_size: int = int(r * 0.45)
		var text_size: Vector2 = font.get_string_size(badge, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		draw_string(font, p + Vector2(-text_size.x * 0.5, font_size * 0.35), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color("#2b2118"))


## Trasa: punkt startu i mety połączone falującą linią.
func _icon_routes(c: Vector2, s: float, ink: Color) -> void:
	var start: Vector2 = c + Vector2(-0.8, 0.7) * s
	var finish: Vector2 = c + Vector2(0.8, -0.7) * s
	var points := PackedVector2Array()
	for i in 17:
		var t: float = float(i) / 16.0
		var base: Vector2 = start.lerp(finish, t)
		var normal := Vector2(0.7, 0.7)
		points.append(base + normal * sin(t * TAU) * 0.35 * s)
	draw_polyline(points, ink, 2.5, true)
	draw_circle(start, 0.28 * s, Color("#7bd36b"))
	draw_arc(start, 0.28 * s, 0.0, TAU, 20, ink, 1.5, true)
	draw_circle(finish, 0.28 * s, Color("#ff6b5b"))
	draw_arc(finish, 0.28 * s, 0.0, TAU, 20, ink, 1.5, true)


## Koszyk sklepowy: rączka, kosz, dwa kółka.
func _icon_cart(c: Vector2, s: float, ink: Color) -> void:
	var handle: Vector2 = c + Vector2(-1.05, -0.75) * s
	var top_left: Vector2 = c + Vector2(-0.7, -0.45) * s
	var top_right: Vector2 = c + Vector2(1.0, -0.45) * s
	var bottom_right: Vector2 = c + Vector2(0.75, 0.35) * s
	var bottom_left: Vector2 = c + Vector2(-0.45, 0.35) * s
	draw_line(handle, top_left + Vector2(-0.1, 0.0) * s, ink, 2.5, true)
	draw_polyline(PackedVector2Array([top_left, top_right, bottom_right, bottom_left, top_left]), ink, 2.5, true)
	draw_line(bottom_left, c + Vector2(-0.5, 0.6) * s, ink, 2.5, true)
	draw_line(c + Vector2(-0.5, 0.6) * s, c + Vector2(0.8, 0.6) * s, ink, 2.5, true)
	draw_circle(c + Vector2(-0.35, 0.92) * s, 0.17 * s, ink)
	draw_circle(c + Vector2(0.65, 0.92) * s, 0.17 * s, ink)


## Księżyc (sierp) z gwiazdką.
func _icon_sleep(c: Vector2, s: float, ink: Color, bg: Color) -> void:
	var moon: Vector2 = c + Vector2(-0.15, 0.1) * s
	draw_circle(moon, 0.85 * s, Color("#ffd98a"))
	draw_circle(moon + Vector2(0.45, -0.3) * s, 0.72 * s, Color(bg, 1.0))
	_star(c + Vector2(0.62, -0.55) * s, 0.32 * s, ink)


func _star(center: Vector2, radius: float, color: Color) -> void:
	var points := PackedVector2Array()
	for i in 10:
		var angle: float = -PI * 0.5 + PI * i / 5.0
		var length: float = radius if i % 2 == 0 else radius * 0.45
		points.append(center + Vector2(cos(angle), sin(angle)) * length)
	draw_colored_polygon(points, color)


## Dyskietka: obudowa ze ściętym rogiem, etykieta i osłona.
func _icon_save(c: Vector2, s: float, ink: Color, bg: Color) -> void:
	var outline := PackedVector2Array([c + Vector2(-0.9, -0.9) * s, c + Vector2(0.6, -0.9) * s, c + Vector2(0.9, -0.6) * s,
		c + Vector2(0.9, 0.9) * s, c + Vector2(-0.9, 0.9) * s])
	draw_colored_polygon(outline, ink)
	draw_rect(Rect2(c + Vector2(-0.5, -0.9) * s, Vector2(0.95, 0.6) * s), Color(bg, 1.0))
	draw_rect(Rect2(c + Vector2(0.1, -0.8) * s, Vector2(0.22, 0.42) * s), ink)
	draw_rect(Rect2(c + Vector2(-0.6, 0.15) * s, Vector2(1.2, 0.6) * s), Color(bg, 1.0))


## Wyjście: framuga drzwi i strzałka na zewnątrz.
func _icon_exit(c: Vector2, s: float, ink: Color) -> void:
	draw_polyline(PackedVector2Array([c + Vector2(0.1, -0.95) * s, c + Vector2(-0.85, -0.95) * s,
		c + Vector2(-0.85, 0.95) * s, c + Vector2(0.1, 0.95) * s]), ink, 2.5, true)
	draw_line(c + Vector2(-0.35, 0.0) * s, c + Vector2(0.95, 0.0) * s, ink, 2.5, true)
	draw_colored_polygon(PackedVector2Array([c + Vector2(1.05, 0.0) * s, c + Vector2(0.55, -0.42) * s, c + Vector2(0.55, 0.42) * s]), ink)
