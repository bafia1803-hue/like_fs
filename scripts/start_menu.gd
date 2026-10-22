extends Control
## Menu startowe: rysowany w kodzie krajobraz (niebo, słońce, wzgórza, pola, farma, chmury),
## tytuł i trzy karty gospodarstw (slotów zapisu) z krótkim podsumowaniem zapisu.
## Interfejs dla GameApp bez zmian: configure, refresh, set_message, set_busy,
## sygnały start_requested(slot, new_game) i quit_requested.

signal start_requested(slot: int, new_game: bool)
signal quit_requested

const IconButtonScript = preload("res://scripts/ui/icon_button.gd")
const PriceListScript = preload("res://scripts/economy/price_list.gd")
const ACCENT := Color("#ffd98a")
const TEXT := Color("#fffaf0")
const MUTED := Color("#d8cdbb")

var manager: RefCounted
var _cards: Array[Dictionary] = []
var _message: Label
var _confirmation: ConfirmationDialog
var _pending_slot: int = 0
var _busy: bool = false
var _landscape: Control
var _time: float = 0.0


func configure(save_manager: RefCounted) -> void:
	manager = save_manager


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_landscape = Control.new()
	_landscape.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_landscape.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_landscape.draw.connect(_draw_landscape)
	add_child(_landscape)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	column.add_theme_constant_override("separation", 18)
	column.offset_top = 56
	column.offset_bottom = -24
	column.offset_left = 24
	column.offset_right = -24
	add_child(column)

	var title := _label("GOSPODARSTWO", 64, TEXT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_color_override("font_shadow_color", Color(0.2, 0.12, 0.05, 0.55))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 4)
	title.add_theme_constant_override("outline_size", 10)
	title.add_theme_color_override("font_outline_color", Color(0.35, 0.22, 0.1, 0.55))
	column.add_child(title)
	var subtitle := _label("Uprawiaj, zbieraj i rozwijaj swoją farmę", 22, Color("#fff6e0"))
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.35))
	subtitle.add_theme_constant_override("shadow_offset_y", 2)
	column.add_child(subtitle)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer)

	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override("separation", 22)
	column.add_child(cards)
	for slot in range(1, 4):
		cards.add_child(_make_card(slot))

	_message = _label("", 18, ACCENT)
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_message.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_message.add_theme_constant_override("shadow_offset_y", 2)
	column.add_child(_message)

	var spacer_bottom := Control.new()
	spacer_bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(spacer_bottom)

	# Prawy dolny róg: pełny ekran, folder zapisów, wyjście z gry.
	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 12)
	tools.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	tools.offset_left = -220
	tools.offset_top = -76
	tools.offset_right = -20
	tools.offset_bottom = -20
	tools.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	tools.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(tools)
	var fullscreen: Button = IconButtonScript.new("fullscreen", "Pełny ekran / okno (F11)")
	fullscreen.pressed.connect(func(): preload("res://scripts/display_settings.gd").toggle())
	tools.add_child(fullscreen)
	var folder: Button = IconButtonScript.new("folder", "Folder zapisów")
	folder.pressed.connect(_open_folder)
	tools.add_child(folder)
	var quit_button: Button = IconButtonScript.new("exit", "Wyjdź z gry")
	quit_button.pressed.connect(func(): quit_requested.emit())
	tools.add_child(quit_button)

	_confirmation = ConfirmationDialog.new()
	_confirmation.title = "Rozpocząć nową grę?"
	_confirmation.ok_button_text = "Nowa gra"
	_confirmation.cancel_button_text = "Anuluj"
	_confirmation.confirmed.connect(func(): start_requested.emit(_pending_slot, true))
	add_child(_confirmation)
	refresh()


func _process(delta: float) -> void:
	_time += delta
	if is_visible_in_tree():
		_landscape.queue_redraw()


# ---------------------------------------------------------------------------
# Karty slotów
# ---------------------------------------------------------------------------

func _make_card(slot: int) -> Control:
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(300, 300)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.11, 0.09, 0.84)
	style.set_corner_radius_all(18)
	style.set_content_margin_all(20)
	style.border_width_top = 5
	style.border_color = ACCENT
	style.shadow_color = Color(0, 0, 0, 0.3)
	style.shadow_size = 12
	style.shadow_offset = Vector2(0, 6)
	card.add_theme_stylebox_override("panel", style)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	card.add_child(column)
	var heading := _label("Gospodarstwo %d" % slot, 26, ACCENT)
	column.add_child(heading)
	var status := _label("", 15, MUTED)
	column.add_child(status)
	var details := VBoxContainer.new()
	details.add_theme_constant_override("separation", 4)
	details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(details)
	var play := _button("Graj dalej", Color("#4f8a3c"))
	play.pressed.connect(func(): _load_slot(slot))
	column.add_child(play)
	var new_game := _button("Nowa gra", Color("#5a4f44"))
	new_game.pressed.connect(func(): _new_slot(slot))
	column.add_child(new_game)
	_cards.append({"slot": slot, "status": status, "details": details, "play": play, "new": new_game, "style": style})
	return card


func refresh() -> void:
	_busy = false
	for card in _cards:
		var info: Dictionary = manager.call("slot_info", card["slot"])
		var details: VBoxContainer = card["details"]
		for child in details.get_children():
			child.queue_free()
		var style: StyleBoxFlat = card["style"]
		if not bool(info["occupied"]):
			card["status"].text = "Wolne miejsce"
			details.add_child(_label("Zacznij nową farmę\nz dwoma ciągnikami, kombajnem\ni polem na start.", 16, TEXT))
			card["play"].visible = false
			card["new"].text = "Rozpocznij"
			style.border_color = Color("#9fd47f")
		elif not bool(info["loadable"]):
			card["status"].text = str(info["description"])
			card["play"].visible = false
			card["new"].text = "Nowa gra"
			style.border_color = Color("#ff9b8a")
		else:
			card["status"].text = "Zapisano " + str(info.get("saved_at", ""))
			var money: float = float(info.get("money", -1.0))
			if money >= 0.0:
				details.add_child(_stat("Konto", PriceListScript.format_money(money)))
			details.add_child(_stat("Maszyny", str(info.get("machines", 0))))
			if int(info.get("fields", -1)) >= 0:
				details.add_child(_stat("Pola", str(info["fields"])))
			details.add_child(_stat("Trasy", str(info.get("routes", 0))))
			card["play"].visible = true
			card["new"].text = "Nowa gra"
			style.border_color = ACCENT
		card["play"].disabled = false
		card["new"].disabled = false


func set_message(text: String) -> void:
	_message.text = text


func set_busy(value: bool) -> void:
	_busy = value
	if not value:
		refresh()
		return
	for card in _cards:
		card["play"].disabled = true
		card["new"].disabled = true


func _load_slot(slot: int) -> void:
	if not _busy:
		start_requested.emit(slot, false)


func _new_slot(slot: int) -> void:
	if _busy:
		return
	var info: Dictionary = manager.call("slot_info", slot)
	if bool(info["occupied"]):
		_pending_slot = slot
		_confirmation.dialog_text = "Nowa gra zastąpi postęp w gospodarstwie %d. Kontynuować?" % slot
		_confirmation.popup_centered(Vector2i(460, 180))
	else:
		start_requested.emit(slot, true)


func _open_folder() -> void:
	DirAccess.make_dir_recursive_absolute(str(manager.get("directory")))
	OS.shell_open(ProjectSettings.globalize_path(str(manager.get("directory"))))


# ---------------------------------------------------------------------------
# Krajobraz w tle
# ---------------------------------------------------------------------------

func _draw_landscape() -> void:
	var canvas: Control = _landscape
	var w: float = size.x
	var h: float = size.y
	var horizon: float = h * 0.58
	# niebo: gradient
	canvas.draw_polygon(PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, horizon), Vector2(0, horizon)]),
		PackedColorArray([Color("#7fbfe6"), Color("#7fbfe6"), Color("#fbe5b8"), Color("#fbe5b8")]))
	# słońce z poświatą
	var sun := Vector2(w * 0.8, horizon - h * 0.2)
	for i in 5:
		canvas.draw_circle(sun, h * (0.16 - i * 0.025), Color(1.0, 0.95, 0.75, 0.08 + i * 0.04))
	canvas.draw_circle(sun, h * 0.055, Color("#fff4cf"))
	# chmury (powoli płyną)
	for cloud in [[0.12, 0.14, 1.0], [0.48, 0.09, 0.8], [0.7, 0.2, 1.2], [0.3, 0.26, 0.7]]:
		var x: float = fposmod(cloud[0] * w + _time * 12.0 * cloud[2], w + 300.0) - 150.0
		_cloud(canvas, Vector2(x, h * cloud[1]), h * 0.035 * cloud[2])
	# wzgórza: dalsze i bliższe
	_hills(canvas, horizon - h * 0.06, h * 0.05, 1.7, 0.4, Color("#a9cf7b"), w, h)
	_hills(canvas, horizon - h * 0.015, h * 0.035, 2.6, 1.9, Color("#86bb5c"), w, h)
	# farma na horyzoncie: stodoła, silos, drzewa
	var base_y: float = horizon - h * 0.012
	_barn(canvas, Vector2(w * 0.055, base_y), h * 0.075)
	_silo(canvas, Vector2(w * 0.11, base_y), h * 0.12)
	_silo(canvas, Vector2(w * 0.128, base_y), h * 0.1)
	for tree in [0.015, 0.155, 0.33, 0.62, 0.66, 0.9, 0.94]:
		_tree(canvas, Vector2(w * tree, base_y + h * 0.004), h * (0.03 + 0.012 * sin(tree * 40.0)))
	# pola: pasy w perspektywie (złote, zielone, brązowe)
	var colors: Array[Color] = [Color("#e6bd4f"), Color("#d9a93d"), Color("#79b04f"), Color("#6aa046"), Color("#8b5b3c"), Color("#7a4f34")]
	var bands: int = 9
	for i in bands:
		var t0: float = pow(float(i) / bands, 1.6)
		var t1: float = pow(float(i + 1) / bands, 1.6)
		var y0: float = lerpf(horizon, h, t0)
		var y1: float = lerpf(horizon, h, t1)
		var color: Color = colors[(i / 2) % colors.size()] if i % 2 == 0 else colors[(i / 2) % colors.size()].darkened(0.06)
		canvas.draw_rect(Rect2(0, y0, w, y1 - y0 + 1.0), color)
	# bruzdy zbiegające się do punktu na horyzoncie
	var vanish := Vector2(w * 0.5, horizon - h * 0.2)
	for i in 25:
		var x: float = lerpf(-w * 0.6, w * 1.6, float(i) / 24.0)
		var start: Vector2 = vanish.lerp(Vector2(x, h), (horizon - vanish.y) / (h - vanish.y))
		canvas.draw_line(start, Vector2(x, h), Color(0, 0, 0, 0.06), 2.0)
	# przyciemnienie dołu pod karty
	canvas.draw_polygon(PackedVector2Array([Vector2(0, h * 0.45), Vector2(w, h * 0.45), Vector2(w, h), Vector2(0, h)]),
		PackedColorArray([Color(0, 0, 0, 0.0), Color(0, 0, 0, 0.0), Color(0.1, 0.06, 0.02, 0.45), Color(0.1, 0.06, 0.02, 0.45)]))


func _hills(canvas: Control, base: float, height: float, frequency: float, phase: float, color: Color, w: float, h: float) -> void:
	var points := PackedVector2Array([Vector2(0, h)])
	for i in 41:
		var x: float = w * i / 40.0
		points.append(Vector2(x, base - height * (0.5 + 0.5 * sin(x / w * TAU * frequency + phase))))
	points.append(Vector2(w, h))
	canvas.draw_colored_polygon(points, color)


func _cloud(canvas: Control, center: Vector2, r: float) -> void:
	for blob in [[-1.4, 0.3, 0.8], [-0.5, -0.2, 1.1], [0.6, 0.0, 1.0], [1.5, 0.35, 0.7]]:
		canvas.draw_circle(center + Vector2(blob[0], blob[1]) * r, r * blob[2], Color(1, 1, 1, 0.85))


func _barn(canvas: Control, foot: Vector2, s: float) -> void:
	var body := Rect2(foot + Vector2(-s * 0.7, -s * 0.8), Vector2(s * 1.4, s * 0.8))
	canvas.draw_rect(body, Color("#c9533f"))
	canvas.draw_colored_polygon(PackedVector2Array([body.position + Vector2(-s * 0.1, 0), Vector2(body.end.x + s * 0.1, body.position.y),
		foot + Vector2(0, -s * 1.3)]), Color("#7a4a40"))
	canvas.draw_rect(Rect2(foot + Vector2(-s * 0.22, -s * 0.5), Vector2(s * 0.44, s * 0.5)), Color("#f4ead5"), false, 2.0)


func _silo(canvas: Control, foot: Vector2, s: float) -> void:
	canvas.draw_rect(Rect2(foot + Vector2(-s * 0.16, -s), Vector2(s * 0.32, s)), Color("#e8e4dc"))
	canvas.draw_circle(foot + Vector2(0, -s), s * 0.16, Color("#d0cbc2"))


func _tree(canvas: Control, foot: Vector2, s: float) -> void:
	canvas.draw_rect(Rect2(foot + Vector2(-s * 0.08, -s * 0.6), Vector2(s * 0.16, s * 0.6)), Color("#8b5a3c"))
	canvas.draw_circle(foot + Vector2(0, -s * 0.95), s * 0.55, Color("#5f9a42"))
	canvas.draw_circle(foot + Vector2(s * 0.2, -s * 1.1), s * 0.35, Color("#77b354"))


# ---------------------------------------------------------------------------

func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _stat(name_text: String, value: String) -> Control:
	var row := HBoxContainer.new()
	var name_label := _label(name_text, 16, MUTED)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	row.add_child(_label(value, 16, TEXT))
	return row


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 44)
	button.add_theme_font_size_override("font_size", 18)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = color.lightened(0.15) if state == "hover" else (Color("#4a433c") if state == "disabled" else color)
		box.set_corner_radius_all(10)
		box.set_content_margin_all(8)
		button.add_theme_stylebox_override(state, box)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TEXT)
	button.add_theme_color_override("font_disabled_color", Color("#9d9286"))
	return button
