extends PanelContainer
var system: Node
var world: Node
var _name: LineEdit
var _list: OptionButton
var _status: Label
var _record: Button
var _finish: Button
var _cancel: Button
var _play: Button
var _stop: Button
var _choices: Array = []
var _vehicle: RigidBody2D
var _timer: float = 0.0
var _fingerprint: String = ""
var _toggle: Button
var _preview: CheckButton
var _rename: LineEdit
var _rename_button: Button
var _delete: Button
var _confirmation: ConfirmationDialog
var _pending_delete: String = ""

func configure(route_system: Node, world_node: Node) -> void:
	system = route_system
	world = world_node

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	offset_left = 16
	offset_right = 400
	offset_top = -435
	offset_bottom = -76
	_toggle = Button.new()
	_toggle.text = "Trasy"
	_toggle.focus_mode = Control.FOCUS_NONE
	get_parent().add_child(_toggle)
	_toggle.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_toggle.offset_left = 16
	_toggle.offset_right = 240
	_toggle.offset_top = -62
	_toggle.offset_bottom = -16
	_toggle.pressed.connect(func(): set_panel_open(not visible))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)
	var title := Label.new()
	title.text = "TRASY I CZYNNOŚCI"
	column.add_child(title)
	_name = LineEdit.new()
	_name.placeholder_text = "Nazwa nowego nagrania"
	_name.max_length = 80
	column.add_child(_name)
	_name.text_submitted.connect(func(_text: String): _name.release_focus())
	var row := HBoxContainer.new()
	column.add_child(row)
	_record = _button("Rozpocznij", row)
	_finish = _button("Zakończ", row)
	_cancel = _button("Odrzuć", row)
	_record.pressed.connect(func():
		_name.release_focus()
		system.call_deferred("begin_recording", _vehicle, _name.text))
	_finish.pressed.connect(func(): system.call_deferred("finish_recording"))
	_cancel.pressed.connect(func(): system.call_deferred("cancel_recording"))
	_list = OptionButton.new()
	_list.custom_minimum_size.x = 360
	_list.fit_to_longest_item = false
	_list.focus_mode = Control.FOCUS_NONE
	column.add_child(_list)
	_list.item_selected.connect(func(_index: int):
		_sync_name()
		_update_preview())
	_preview = CheckButton.new()
	_preview.text = "Pokaż przebieg wybranej trasy"
	_preview.focus_mode = Control.FOCUS_NONE
	column.add_child(_preview)
	_preview.toggled.connect(func(_enabled: bool): _update_preview())
	_rename = LineEdit.new()
	_rename.placeholder_text = "Nazwa wybranej trasy"
	_rename.max_length = 80
	column.add_child(_rename)
	_rename.text_submitted.connect(func(_text: String): _rename.release_focus())
	var edit_row := HBoxContainer.new()
	column.add_child(edit_row)
	_rename_button = _button("Zmień nazwę", edit_row)
	_delete = _button("Usuń trasę", edit_row)
	_rename_button.pressed.connect(func():
		_release_text_focus()
		var route: Dictionary = _selected_route()
		if not route.is_empty():
			system.rename_route(str(route["id"]), _rename.text))
	_confirmation = ConfirmationDialog.new()
	_confirmation.title = "Usunąć trasę?"
	_confirmation.ok_button_text = "Usuń"
	_confirmation.cancel_button_text = "Anuluj"
	add_child(_confirmation)
	_delete.pressed.connect(func():
		_release_text_focus()
		var route: Dictionary = _selected_route()
		if not route.is_empty():
			_pending_delete = str(route["id"])
			_confirmation.dialog_text = "Usunąć trasę „%s”?" % str(route["name"])
			_confirmation.popup_centered(Vector2i(450, 160)))
	_confirmation.confirmed.connect(func(): system.delete_route(_pending_delete))
	var row2 := HBoxContainer.new()
	column.add_child(row2)
	_play = _button("Uruchom trasę", row2)
	_stop = _button("Przerwij", row2)
	_play.pressed.connect(func():
		if _list.selected >= 0 and _list.selected < _choices.size():
			system.call_deferred("start", _vehicle, _choices[_list.selected]))
	_stop.pressed.connect(func(): system.call_deferred("stop", _vehicle))
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	var note := Label.new()
	note.text = "F9: utrwala trasy, przerywa zadania i odrzuca nagranie."
	note.add_theme_font_size_override("font_size", 12)
	column.add_child(note)
	system.changed.connect(func(): _fingerprint = ""; _refresh())
	set_panel_open(false)

func _button(label: String, parent: Node) -> Button:
	var button := Button.new()
	button.text = label
	button.focus_mode = Control.FOCUS_NONE
	parent.add_child(button)
	return button

func _process(delta: float) -> void:
	_timer += delta
	if _timer >= 0.25:
		_timer = 0.0
		var paused_count: int = 0
		for task in system.tasks.values():
			if bool(task.get("paused", false)):
				paused_count += 1
		_toggle.text = "Trasy (%d, pauza: %d)" % [system.tasks.size(), paused_count]
		if not system.recording.is_empty():
			_toggle.text = "Trasy — nagrywanie %.0f s" % float(system.recording["time"])
		if visible:
			_refresh()

func _refresh() -> void:
	_vehicle = world.get("_controlled_vehicle") as RigidBody2D
	if _vehicle == null:
		return
	var choices: Array = system.compatible(_vehicle)
	var fingerprint: String = str(_vehicle.get_instance_id())
	for route in choices:
		fingerprint += ":" + str(route.get("id", "")) + ":" + str(route.get("name", ""))
	if fingerprint != _fingerprint:
		var selected_id: String = ""
		if _list.selected >= 0 and _list.selected < _choices.size():
			selected_id = str(_choices[_list.selected]["id"])
		_fingerprint = fingerprint
		_choices = choices
		_list.clear()
		var selected: int = 0
		for i in choices.size():
			_list.add_item(str(choices[i].get("name", "Trasa")))
			if choices[i].get("id") == selected_id:
				selected = i
		if choices.is_empty():
			_list.add_item("Brak tras dla tego zestawu")

		else:
			_list.select(selected)
		_sync_name()
		_update_preview()
	var recording: Dictionary = system.recording
	var playing: bool = system.tasks.has(_vehicle)
	_record.disabled = not recording.is_empty() or playing
	_finish.disabled = recording.is_empty()
	_cancel.disabled = recording.is_empty()
	_play.disabled = choices.is_empty() or playing or bool(_vehicle.get_meta("route_recording", false))
	_stop.disabled = not playing
	_list.disabled = choices.is_empty()
	_rename_button.disabled = choices.is_empty()
	_delete.disabled = choices.is_empty()
	_preview.disabled = choices.is_empty()
	var status: String = "Aktywne odtwarzania: %d" % system.tasks.size()
	if not recording.is_empty():
		status += " | Nagrywanie: %.1f s" % float(recording["time"])
	elif playing:
		if bool(system.tasks[_vehicle].get("paused", false)):
			status += " | PAUZA — oczekiwanie na wolny przejazd"
		status += " | %.1f / %.1f s" % [float(system.tasks[_vehicle]["time"]), float(system.tasks[_vehicle]["route"]["samples"][-1][0])]
	elif str(_vehicle.get_meta("route_mode", "")) == "held":
		status += " | Postój. W/S/A/D: sterowanie ręczne."
	_status.text = status

func set_panel_open(opened: bool) -> void:
	_release_text_focus()
	visible = opened
	if not opened:
		_preview.set_pressed_no_signal(false)
		_confirmation.hide()
		system.preview({})
	else:
		_refresh()

func _release_text_focus() -> void:
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus == _name or focus == _rename:
		focus.release_focus()

func _selected_route() -> Dictionary:
	if _list.selected >= 0 and _list.selected < _choices.size():
		return _choices[_list.selected]
	return {}

func _sync_name() -> void:
	if not _rename.has_focus():
		_rename.text = str(_selected_route().get("name", ""))

func _update_preview() -> void:
	if visible and _preview.button_pressed:
		system.preview(_selected_route())
	else:
		system.preview({})

func _input(event: InputEvent) -> void:
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus != _name and focus != _rename:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not focus.get_global_rect().has_point(event.position):
			focus.release_focus()
	elif event is InputEventScreenTouch and event.pressed:
		if not focus.get_global_rect().has_point(event.position):
			focus.release_focus()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		focus.release_focus()
		get_viewport().set_input_as_handled()
