extends Control
## Okienko po zatrzymaniu nagrywania: nazwa trasy + Zapisz / Kontynuuj / Usuń przejazd.
## Na czas decyzji gra jest w pauzie (nagrywanie stoi). Esc = Kontynuuj.

signal decided(action: String, title: String)   # action: "save" | "continue" | "discard"

var _name: LineEdit
var _info: Label


func _init() -> void:
	name = "RecordSaveDialog"
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0.05, 0.04, 0.03, 0.4)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(440, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.12, 0.1, 0.97)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	panel.add_child(column)
	var title := Label.new()
	title.text = "Nagrywanie zatrzymane"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color("#ffd98a"))
	column.add_child(title)
	_info = Label.new()
	_info.add_theme_color_override("font_color", Color("#cfc4b2"))
	column.add_child(_info)
	_name = LineEdit.new()
	_name.max_length = 80
	_name.placeholder_text = "Nazwa przejazdu"
	_name.custom_minimum_size = Vector2(0, 40)
	_name.text_submitted.connect(func(_text: String): _decide("save"))
	column.add_child(_name)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)
	for entry in [["Zapisz", "save", Color("#4f8a3c")], ["Kontynuuj", "continue", Color("#3a5f8a")], ["Usuń przejazd", "discard", Color("#9b4a3c")]]:
		var button := Button.new()
		button.text = entry[0]
		button.focus_mode = Control.FOCUS_NONE
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.custom_minimum_size = Vector2(0, 40)
		for state in ["normal", "hover", "pressed"]:
			var box := StyleBoxFlat.new()
			box.bg_color = (entry[2] as Color).lightened(0.15) if state == "hover" else entry[2]
			box.set_corner_radius_all(8)
			box.set_content_margin_all(8)
			button.add_theme_stylebox_override(state, box)
		var action: String = entry[1]
		button.pressed.connect(func(): _decide(action))
		row.add_child(button)


func open(default_name: String, seconds: float) -> void:
	_name.text = default_name
	_info.text = "Długość przejazdu: %d:%02d. Nazwij go i zapisz albo nagrywaj dalej." % [roundi(seconds) / 60, roundi(seconds) % 60]
	visible = true
	get_tree().paused = true
	_name.grab_focus()
	_name.select_all()


func _decide(action: String) -> void:
	var title: String = _name.text
	_name.release_focus()
	visible = false
	get_tree().paused = false
	decided.emit(action, title)


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_decide("continue")
		get_viewport().set_input_as_handled()
