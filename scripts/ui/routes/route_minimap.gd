extends Control
## Minimapa z góry dla podglądu tras (tylko rysowanie, bez kolizji i fizyki).
##
## Warstwy (od dołu): podłoże i place → pola (stan komórek, jak w widoku 2D) → nakładka:
## budynki, punkty farmy, przebieg trasy, maszyny w obecnych pozycjach (matowe)
## i zestaw z trasy w chwili z suwaka (wyraźny, z obrysem).
##
## Dane dostaje z zewnątrz: set_map (dane mapy + pola), set_live_machines (obecne maszyny),
## set_preview + set_time (RoutePreview). Nie zna świata gry.
## Mysz: kółko – zoom w miejscu kursora, przeciąganie – przesuwanie.

const TopView = preload("res://scripts/views/view2d/top_view.gd")
const FieldShader = preload("res://shaders/field_2d.gdshader")
const LIVE_GREY := Color(0.62, 0.6, 0.57)
const PATH_COLOR := Color("#ffd166")
const PATH_DONE_COLOR := Color("#ff9f43")
const OTHER_PATH_COLOR := Color(0.75, 0.88, 1.0, 0.75)

var _map: Dictionary = {}
var _world_rect := Rect2(0, 0, 100, 100)
var _fields: Array = []                  # {"origin", "size", "rotation", "texture", "palette"}
var _live: Array = []                    # {"model", "transforms", "unfolded"}
var _preview: RefCounted
var _time: float = 0.0
var _other_paths: Array = []             # przebiegi innych widocznych tras (PackedVector2Array)
var _selected_path_visible: bool = true

var _center := Vector2(50, 50)           # środek widoku (m)
var _scale: float = 4.0                  # piksele na metr
var _dragging: bool = false

var _ground: Control
var _field_layer: Control
var _overlay: Control
var _field_rects: Array[TextureRect] = []


func _init() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	_ground = _layer("Ground", _draw_ground)
	_field_layer = Control.new()
	_field_layer.name = "Fields"
	_field_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_field_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_field_layer)
	_overlay = _layer("Overlay", _draw_overlay)
	resized.connect(_refresh)


# ---------------------------------------------------------------------------
# Dane
# ---------------------------------------------------------------------------

func set_map(map_data: Dictionary, world_rect: Rect2, fields: Array) -> void:
	_map = map_data
	_world_rect = world_rect
	_fields = fields
	for rect in _field_rects:
		rect.queue_free()
	_field_rects.clear()
	for field in fields:
		var material := ShaderMaterial.new()
		material.shader = FieldShader
		material.set_shader_parameter("stage_tex", field["texture"])
		material.set_shader_parameter("colors", field["palette"])
		var texture_rect := TextureRect.new()
		texture_rect.texture = field["texture"]
		texture_rect.material = material
		texture_rect.stretch_mode = TextureRect.STRETCH_SCALE
		texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_field_layer.add_child(texture_rect)
		_field_rects.append(texture_rect)
	_refresh()


func set_live_machines(machines: Array) -> void:
	_live = machines
	_overlay.queue_redraw()


func set_preview(preview: RefCounted) -> void:
	_preview = preview
	_time = 0.0
	if preview != null:
		fit(preview.bounds())
	_refresh()


## Widoczność przebiegów (oko na liście): inne trasy + czy pokazać przebieg wybranej.
func set_paths(other_paths: Array, selected_visible: bool) -> void:
	_other_paths = other_paths
	_selected_path_visible = selected_visible
	_overlay.queue_redraw()


func set_time(time: float) -> void:
	_time = time
	_overlay.queue_redraw()


## Dopasowuje widok do prostokąta (metry).
func fit(rect: Rect2) -> void:
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		rect = _world_rect
	_center = rect.get_center()
	var area: Vector2 = size if size.x > 1.0 else Vector2(600, 400)
	_scale = clampf(minf(area.x / rect.size.x, area.y / rect.size.y) * 0.92, 0.5, 40.0)
	_refresh()


# ---------------------------------------------------------------------------
# Widok
# ---------------------------------------------------------------------------

func to_screen(point_m: Vector2) -> Vector2:
	return (point_m - _center) * _scale + size * 0.5


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event
		if button.pressed and (button.button_index == MOUSE_BUTTON_WHEEL_UP or button.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var factor: float = 1.2 if button.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2
			var anchor_m: Vector2 = (button.position - size * 0.5) / _scale + _center
			_scale = clampf(_scale * factor, 0.5, 40.0)
			_center = anchor_m - (button.position - size * 0.5) / _scale
			_refresh()
			accept_event()
		elif button.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_dragging = button.pressed
			accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_center -= (event as InputEventMouseMotion).relative / _scale
		_refresh()
		accept_event()


func _refresh() -> void:
	for i in _field_rects.size():
		var field: Dictionary = _fields[i]
		var rect: TextureRect = _field_rects[i]
		rect.position = to_screen(field["origin"])
		rect.size = (field["size"] as Vector2) * _scale
		rect.pivot_offset = Vector2.ZERO
		rect.rotation = float(field["rotation"])
	_ground.queue_redraw()
	_overlay.queue_redraw()


func _layer(layer_name: String, painter: Callable) -> Control:
	var layer := Control.new()
	layer.name = layer_name
	layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.draw.connect(func(): painter.call(layer))
	add_child(layer)
	return layer


# ---------------------------------------------------------------------------
# Rysowanie
# ---------------------------------------------------------------------------

func _draw_ground(canvas: Control) -> void:
	canvas.draw_rect(Rect2(Vector2.ZERO, size), Color("#2f3a2a"))
	var grass := Color(str(_map.get("default_surface", {}).get("color", "#558a45")))
	canvas.draw_rect(_screen_rect(_world_rect), grass)
	for surface in _map.get("surfaces", []):
		var rect := Rect2(_vec(surface["origin_m"]), _vec(surface["size_m"]))
		canvas.draw_rect(_screen_rect(rect), Color(str(surface.get("color", "#cdbfa6"))))


func _draw_overlay(canvas: Control) -> void:
	var font: Font = ThemeDB.fallback_font
	# punkty farmy (kraty, skup) i plac sklepu
	for key in ["unload_points", "sell_points"]:
		for point in _map.get(key, []):
			var area: Dictionary = point["area"]
			var half := Vector2(float(area["width_m"]), float(area["length_m"])) * 0.5
			var center := _vec(area["center_m"])
			canvas.draw_rect(_screen_rect(Rect2(center - half, half * 2.0)), Color("#55606a") if key == "unload_points" else Color("#5f7350"))
	var shop: Dictionary = _map.get("shop", {})
	if shop.get("lot") is Dictionary:
		canvas.draw_rect(_screen_rect(Rect2(_vec(shop["lot"]["origin_m"]), _vec(shop["lot"]["size_m"]))), Color(1, 1, 1, 0.7), false, 1.5)
	# budynki i przeszkody
	for obstacle in _map.get("static_obstacles", []):
		var color := _building_color(str(obstacle.get("visual", {}).get("model", "")))
		var center := to_screen(_vec(obstacle["center_m"]))
		if str(obstacle.get("shape", "")) == "circle":
			var radius: float = float(obstacle["radius_m"]) * _scale
			canvas.draw_circle(center, radius, color)
			canvas.draw_arc(center, radius, 0.0, TAU, 24, color.darkened(0.35), 1.5)
		else:
			var size_px := Vector2(float(obstacle["width_m"]), float(obstacle["length_m"])) * _scale
			canvas.draw_set_transform(center, deg_to_rad(float(obstacle.get("rotation_deg", 0.0))))
			canvas.draw_rect(Rect2(-size_px * 0.5, size_px), color)
			canvas.draw_rect(Rect2(-size_px * 0.5, size_px), color.darkened(0.35), false, 1.5)
			canvas.draw_set_transform(Vector2.ZERO, 0.0)
	# maszyny w obecnych pozycjach: matowe
	for machine in _live:
		_draw_machine(canvas, machine["model"], machine["transforms"], float(machine.get("unfolded", 1.0)), true)
	# inne widoczne trasy: jaśniejsze, bez znaczników
	for other in _other_paths:
		if (other as PackedVector2Array).size() < 2:
			continue
		var line := PackedVector2Array()
		for point in other:
			line.append(to_screen(point))
		canvas.draw_polyline(line, Color(0, 0, 0, 0.3), maxf(3.0, _scale * 0.35) + 2.0, true)
		canvas.draw_polyline(line, OTHER_PATH_COLOR, maxf(3.0, _scale * 0.35), true)
	if _preview == null:
		return
	# przebieg wybranej trasy: część przejechana do chwili z suwaka ciemniejsza
	var points: PackedVector2Array = _preview.path_points()
	if points.size() >= 2 and _selected_path_visible:
		var screen := PackedVector2Array()
		for point in points:
			screen.append(to_screen(point))
		canvas.draw_polyline(screen, Color(0, 0, 0, 0.45), maxf(4.0, _scale * 0.5) + 3.0, true)
		canvas.draw_polyline(screen, PATH_COLOR, maxf(4.0, _scale * 0.5), true)
		# Część przejechana: punkty z czasem ≤ chwila suwaka + dokładna pozycja pojazdu (czasy z RoutePreview).
		var done := PackedVector2Array()
		for point in _preview.path_until(_time):
			done.append(to_screen(point))
		if done.size() >= 2:
			canvas.draw_polyline(done, PATH_DONE_COLOR, maxf(4.0, _scale * 0.5), true)
		canvas.draw_circle(screen[0], 7.0, Color("#7bd36b"))
		canvas.draw_string(font, screen[0] + Vector2(10, -8), "start", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
		canvas.draw_circle(screen[-1], 7.0, Color("#ff6b5b"))
		canvas.draw_string(font, screen[-1] + Vector2(10, -8), "koniec", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
	# zestaw w chwili z suwaka: wyraźny
	var unfolded: float = _preview.unfolded_at(_time)
	for part in _preview.parts_at(_time):
		_draw_machine(canvas, part["model"], part["transforms"], unfolded if part["role"] == "tool" else 1.0, false)


## Maszyna z góry: nadwozie, koła i dyszel. live = obecna pozycja (matowa).
func _draw_machine(canvas: Control, model: Dictionary, transforms: Dictionary, unfolded: float, live: bool) -> void:
	if model.is_empty():
		return
	var base := Color.from_string(str(model.get("visual", {}).get("body_color", "#999999")), Color.GRAY)
	var fill: Color = base.lerp(LIVE_GREY, 0.65) if live else base
	fill.a = 0.55 if live else 1.0
	var outline: Color = Color(0.2, 0.2, 0.2, 0.5) if live else Color.WHITE
	var tire := Color(0.15, 0.15, 0.15, 0.5 if live else 1.0)
	var dims: Dictionary = model["dimensions"]
	var length: float = float(dims["length_m"])
	var width: float = float(dims["width_m"])
	# Maszyna składana: szerokość jak w danym stanie rozłożenia.
	if model.get("folding") is Dictionary:
		var folded: Array = model.get("physics", {}).get("collision_profiles", {}).get(str(model["folding"].get("folded_profile", "folded")), [])
		if not folded.is_empty():
			width = lerpf(float(folded[0]["width_m"]), width, clampf(unfolded, 0.0, 1.0))
	var body: Transform2D = transforms["body"]
	if model.get("drawbar") is Dictionary:
		var plug := _plug_position(model)
		_line(canvas, body * Vector2(0.0, -length * 0.5), body * plug, Color(0.3, 0.3, 0.3, fill.a), 0.18)
	if transforms.has("front_carriage"):
		var carriage: Transform2D = transforms["front_carriage"]
		_line(canvas, carriage.origin, carriage * _plug_position(model), Color(0.3, 0.3, 0.3, fill.a), 0.18)
	for axle in model.get("axles", []):
		var member: String = str(axle.get("body_member", "body"))
		var xf: Transform2D = transforms.get(member, body) if member == "front_carriage" else body
		var y: float = 0.0 if member == "front_carriage" else -length * 0.5 + float(axle["distance_from_front_m"])
		for side in [-1.0, 1.0]:
			var center := Vector2(side * float(axle["track_m"]) * 0.5, y)
			_rect(canvas, xf, center, Vector2(float(axle["tire_width_m"]), float(axle["tire_length_m"])), tire, Color(0, 0, 0, 0))
	if TopView.custom(model):
		# Własny wygląd z góry z konfiguracji (visual.top_view).
		for part in TopView.parts(model):
			var color: Color = part["color"]
			if live:
				color = color.lerp(LIVE_GREY, 0.65)
				color.a = 0.55
			_rect(canvas, body * Transform2D(float(part["rotation"]), part["center"]), Vector2.ZERO, part["size"], color, Color(0, 0, 0, 0))
		_rect(canvas, body, Vector2.ZERO, Vector2(width, length), Color(0, 0, 0, 0), outline)
		return
	_rect(canvas, body, Vector2.ZERO, Vector2(width, length), fill, outline)
	# przód maszyny
	_line(canvas, body * Vector2(-width * 0.45, -length * 0.5), body * Vector2(width * 0.45, -length * 0.5),
		Color("#ffe071") if not live else Color(0.9, 0.85, 0.6, 0.5), 0.25)


func _rect(canvas: Control, xf: Transform2D, center: Vector2, size_m: Vector2, fill: Color, outline: Color) -> void:
	var half: Vector2 = size_m * 0.5
	var points := PackedVector2Array()
	for corner in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]:
		points.append(to_screen(xf * (center + corner)))
	canvas.draw_colored_polygon(points, fill)
	if outline.a > 0.0:
		points.append(points[0])
		canvas.draw_polyline(points, outline, 1.5, true)


func _line(canvas: Control, a_m: Vector2, b_m: Vector2, color: Color, width_m: float) -> void:
	canvas.draw_line(to_screen(a_m), to_screen(b_m), color, maxf(1.5, width_m * _scale), true)


func _plug_position(model: Dictionary) -> Vector2:
	for port in model.get("hitch_ports", []):
		if str(port.get("role", "")) == "plug":
			return _vec(port["position_m"])
	return Vector2(0.0, -float(model["dimensions"]["length_m"]) * 0.5)


func _building_color(model: String) -> Color:
	match model:
		"silo_tower":
			return Color("#c9c6bf")
		"barn":
			return Color("#b5503d")
		"shop_building":
			return Color("#3f8f9b")
		"grain_buyer":
			return Color("#a27a4c")
	return Color("#9a8f80")


func _screen_rect(rect_m: Rect2) -> Rect2:
	return Rect2(to_screen(rect_m.position), rect_m.size * _scale)


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
