extends Control
## Okno przeglądu nagranych tras (jak sklep: nad mapą, gra w pauzie).
##
## Lewa kolumna: lista tras. Prawa: minimapa z przebiegiem i zestawem w chwili z suwaka,
## suwak czasu, informacje i przyciski (uruchom, przerwij, zmień nazwę, usuń).
##
## Logika podglądu jest w RoutePreview (scripts/routes/route_preview.gd), rysowanie
## w RouteMinimap. To okno tylko je łączy i wywołuje polecenia systemu tras.
## Dane świata pobiera przez: get_route_system, get_controlled_vehicle,
## get_route_map_data, get_machine_shapes, get_catalog_models.

const RoutePreviewScript = preload("res://scripts/routes/route_preview.gd")
const MinimapScript = preload("res://scripts/ui/routes/route_minimap.gd")

const ACCENT := Color("#ffd98a")
const TEXT := Color("#fffaf0")
const MUTED := Color("#cfc4b2")

var world: Node
var _system: Node
var _routes: Array = []                 # trasy w kolejności listy
var _preview: RefCounted
var _list: ItemList
var _minimap: Control
var _slider: HSlider
var _time_label: Label
var _info: Label
var _message: Label
var _title: Label
var _rig: Label
var _play: Button
var _stop: Button
var _rename_edit: LineEdit
var _rename: Button
var _delete: Button
var _confirm: ConfirmationDialog
var _built: bool = false


func setup(world_node: Node) -> void:
	world = world_node
	name = "RouteBrowser"
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func open() -> void:
	if not _built:
		_build()
	_system = world.call("get_route_system")
	visible = true
	get_tree().paused = true
	var data: Dictionary = world.call("get_route_map_data")
	_minimap.call("set_map", data["map"], data["world_rect"], data["fields"])
	_minimap.call("set_live_machines", world.call("get_machine_shapes"))
	_message.text = "Przeciągnij mapę, kółkiem przybliżaj. Suwakiem przewijasz przejazd."
	_fill_list()


func close() -> void:
	visible = false
	_rename_edit.release_focus()
	get_tree().paused = false


func _input(event: InputEvent) -> void:
	if not visible or not event is InputEventKey or not event.pressed or event.echo:
		return
	if event.keycode == KEY_ESCAPE:
		if _rename_edit.has_focus():
			_rename_edit.release_focus()
		elif _confirm.visible:
			_confirm.hide()
		else:
			close()
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Lista i wybór
# ---------------------------------------------------------------------------

func _fill_list(select_id: String = "") -> void:
	var previous: String = select_id
	if previous.is_empty() and _preview != null:
		previous = str(_preview.route.get("id", ""))
	_routes = _system.routes.duplicate()
	_list.clear()
	var vehicle: Node = world.call("get_controlled_vehicle")
	var compatible: Array = _system.call("compatible", vehicle) if vehicle != null else []
	var models: Dictionary = world.call("get_catalog_models")
	var selected: int = -1
	for i in _routes.size():
		var route: Dictionary = _routes[i]
		var preview = RoutePreviewScript.new()
		var ok: bool = preview.setup(route, models)
		var text: String = "%s   %s" % [str(route.get("name", "Trasa")), _clock(preview.duration()) if ok else "?"]
		_list.add_item(text)
		_list.set_item_tooltip(i, preview.rig_name() if ok else preview.last_error)
		var fits: bool = compatible.has(route)
		_list.set_item_custom_fg_color(i, TEXT if fits else MUTED.darkened(0.25))
		if str(route.get("id", "")) == previous or (selected < 0 and fits and previous.is_empty()):
			selected = i
	if _routes.is_empty():
		_select(-1)
		return
	selected = maxi(selected, 0)
	_list.select(selected)
	_select(selected)


func _select(index: int) -> void:
	_preview = null
	if index >= 0 and index < _routes.size():
		var preview = RoutePreviewScript.new()
		if preview.setup(_routes[index], world.call("get_catalog_models")):
			_preview = preview
	_minimap.call("set_preview", _preview)
	_slider.editable = _preview != null
	_slider.max_value = _preview.duration() if _preview != null else 1.0
	_slider.set_value_no_signal(0.0)
	_title.text = _preview.title() if _preview != null else ("Brak nagranych tras" if _routes.is_empty() else "Uszkodzona trasa")
	_rig.text = _preview.rig_name() if _preview != null else "Nagraj trasę przyciskiem nagrywania w lewym dolnym rogu ekranu."
	_rename_edit.text = _preview.title() if _preview != null else ""
	_on_time(0.0)
	_update_buttons()


func _on_time(time: float) -> void:
	_minimap.call("set_time", time)
	if _preview == null:
		_time_label.text = "0:00 / 0:00"
		_info.text = ""
		return
	_time_label.text = "%s / %s" % [_clock(time), _clock(_preview.duration())]
	var parts := PackedStringArray(["prędkość %.1f km/h" % _preview.speed_kmh_at(time)])
	if not _preview.tool_model.is_empty():
		parts.append("praca narzędzia: " + ("tak" if _preview.working_at(time) else "nie"))
		if _preview.tool_model.get("folding") is Dictionary:
			var unfold: float = _preview.unfolded_at(time)
			parts.append("rozłożony" if unfold >= 1.0 else ("złożony" if unfold <= 0.0 else "rozkładanie %d%%" % roundi(unfold * 100.0)))
	_info.text = "  ·  ".join(parts)


func _update_buttons() -> void:
	var vehicle: Node = world.call("get_controlled_vehicle")
	var route: Dictionary = _preview.route if _preview != null else {}
	var playing: bool = vehicle != null and _system.tasks.has(vehicle)
	var fits: bool = vehicle != null and not route.is_empty() and _system.call("compatible", vehicle).has(route)
	_play.disabled = not fits or playing or not _system.recording.is_empty()
	_play.tooltip_text = "" if fits else "Trasa nagrana innym zestawem niż sterowany teraz."
	_stop.disabled = not playing
	_rename.disabled = route.is_empty()
	_delete.disabled = route.is_empty()


# ---------------------------------------------------------------------------
# Polecenia
# ---------------------------------------------------------------------------

func _on_play() -> void:
	var vehicle: Node = world.call("get_controlled_vehicle")
	if _preview == null or vehicle == null:
		return
	var reply: Array = [""]
	var listener := func(text: String): reply[0] = text
	_system.message.connect(listener)
	_system.call("start", vehicle, _preview.route)
	_system.message.disconnect(listener)
	if _system.tasks.has(vehicle):
		close()
	else:
		_message.text = str(reply[0])


func _on_stop() -> void:
	var vehicle: Node = world.call("get_controlled_vehicle")
	if vehicle != null:
		_system.call("stop", vehicle)
		_message.text = "Przerwano odtwarzanie."
	_update_buttons()


func _on_rename() -> void:
	if _preview == null:
		return
	_rename_edit.release_focus()
	var id: String = str(_preview.route["id"])
	_system.call("rename_route", id, _rename_edit.text)
	_message.text = "Zmieniono nazwę. Zapisz grę (F9), aby ją utrwalić."
	_fill_list(id)


func _on_delete_confirmed() -> void:
	if _preview == null:
		return
	var reply: Array = [""]
	var listener := func(text: String): reply[0] = text
	_system.message.connect(listener)
	_system.call("delete_route", str(_preview.route["id"]))
	_system.message.disconnect(listener)
	_message.text = str(reply[0])
	_preview = null
	_fill_list()


# ---------------------------------------------------------------------------
# Budowa okna
# ---------------------------------------------------------------------------

func _build() -> void:
	_built = true
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.03, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 40
	panel.offset_right = -40
	panel.offset_top = 30
	panel.offset_bottom = -30
	panel.add_theme_stylebox_override("panel", _box(Color(0.14, 0.12, 0.1, 0.97), 16, 18))
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	column.add_child(header)
	header.add_child(_label("Nagrane trasy", 28, ACCENT))
	_message = _label("", 15, MUTED)
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	header.add_child(_message)
	var close_button := _button("Zamknij (Esc)", Color("#5a4f44"))
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	column.add_child(body)

	# lewa kolumna: lista
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	left.add_theme_constant_override("separation", 8)
	body.add_child(left)
	_list = ItemList.new()
	_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_list.focus_mode = Control.FOCUS_NONE
	_list.add_theme_font_size_override("font_size", 16)
	_list.add_theme_stylebox_override("panel", _box(Color("#2a241e"), 10, 8))
	_list.add_theme_color_override("font_color", TEXT)
	_list.item_selected.connect(_select)
	left.add_child(_list)
	left.add_child(_label("Jasne nazwy pasują do sterowanego zestawu.", 13, MUTED))

	# prawa kolumna: tytuł, minimapa, suwak, przyciski
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 8)
	body.add_child(right)
	_title = _label("", 22, TEXT)
	right.add_child(_title)
	_rig = _label("", 15, MUTED)
	right.add_child(_rig)
	var map_frame := PanelContainer.new()
	map_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_frame.add_theme_stylebox_override("panel", _box(Color("#2a241e"), 10, 4))
	right.add_child(map_frame)
	_minimap = MinimapScript.new()
	_minimap.custom_minimum_size = Vector2(400, 260)
	map_frame.add_child(_minimap)

	var timeline := HBoxContainer.new()
	timeline.add_theme_constant_override("separation", 12)
	right.add_child(timeline)
	_slider = HSlider.new()
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.step = 0.05
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.value_changed.connect(_on_time)
	timeline.add_child(_slider)
	_time_label = _label("0:00 / 0:00", 16, TEXT)
	_time_label.custom_minimum_size = Vector2(110, 0)
	timeline.add_child(_time_label)
	var fit := _button("Dopasuj widok", Color("#3a332c"))
	fit.pressed.connect(func(): if _preview != null: _minimap.call("fit", _preview.bounds()))
	timeline.add_child(fit)
	_info = _label("", 15, MUTED)
	right.add_child(_info)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	right.add_child(actions)
	_play = _button("Uruchom trasę", Color("#4f8a3c"))
	_play.pressed.connect(_on_play)
	actions.add_child(_play)
	_stop = _button("Przerwij", Color("#8a6a3c"))
	_stop.pressed.connect(_on_stop)
	actions.add_child(_stop)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	_rename_edit = LineEdit.new()
	_rename_edit.custom_minimum_size = Vector2(220, 38)
	_rename_edit.max_length = 80
	_rename_edit.placeholder_text = "Nazwa trasy"
	_rename_edit.text_submitted.connect(func(_text: String): _on_rename())
	actions.add_child(_rename_edit)
	_rename = _button("Zmień nazwę", Color("#3a332c"))
	_rename.pressed.connect(_on_rename)
	actions.add_child(_rename)
	_delete = _button("Usuń", Color("#9b4a3c"))
	_delete.pressed.connect(func():
		if _preview != null:
			_confirm.dialog_text = "Usunąć trasę „%s”?" % _preview.title()
			_confirm.popup_centered(Vector2i(420, 150)))
	actions.add_child(_delete)
	_confirm = ConfirmationDialog.new()
	_confirm.title = "Usunąć trasę?"
	_confirm.ok_button_text = "Usuń"
	_confirm.cancel_button_text = "Anuluj"
	_confirm.process_mode = Node.PROCESS_MODE_ALWAYS
	_confirm.confirmed.connect(_on_delete_confirmed)
	add_child(_confirm)


static func _clock(seconds: float) -> String:
	var total: int = roundi(maxf(seconds, 0.0))
	return "%d:%02d" % [total / 60, total % 60]


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _box(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(margin)
	return style


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(110, 38)
	button.add_theme_font_size_override("font_size", 16)
	button.add_theme_stylebox_override("normal", _box(color, 8, 8))
	button.add_theme_stylebox_override("hover", _box(color.lightened(0.15), 8, 8))
	button.add_theme_stylebox_override("pressed", _box(color, 8, 8))
	button.add_theme_stylebox_override("disabled", _box(Color("#4a433c"), 8, 8))
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_disabled_color", Color("#8d8377"))
	return button
