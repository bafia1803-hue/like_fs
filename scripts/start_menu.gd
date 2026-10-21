extends Control
signal start_requested(slot: int, new_game: bool)
signal quit_requested
var manager: RefCounted
var _rows: Array[Dictionary] = []
var _message: Label
var _confirmation: ConfirmationDialog
var _pending_slot: int = 0
var _busy: bool = false

func configure(save_manager: RefCounted) -> void:
	manager = save_manager

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color("#17251f")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 24)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override("separation", 16)
	scroll.add_child(column)
	var title := Label.new()
	title.text = "GOSPODARSTWO"
	title.add_theme_font_size_override("font_size", 32)
	title.add_theme_color_override("font_color", Color("#e9ce83"))
	column.add_child(title)
	var description := Label.new()
	description.text = "Wybierz jeden z trzech zapisów. Każdy slot to osobna rozgrywka."
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(description)
	for slot in range(1, 4):
		var panel := PanelContainer.new()
		var style := StyleBoxFlat.new()
		style.bg_color = Color("#2b3a30")
		style.set_corner_radius_all(10)
		style.content_margin_left = 18
		style.content_margin_right = 18
		style.content_margin_top = 14
		style.content_margin_bottom = 14
		panel.add_theme_stylebox_override("panel", style)
		column.add_child(panel)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		panel.add_child(row)
		var info := VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var heading := Label.new()
		heading.text = "SLOT %d" % slot
		heading.add_theme_font_size_override("font_size", 22)
		info.add_child(heading)
		var details := Label.new()
		details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(details)
		var actions := VBoxContainer.new()
		row.add_child(actions)
		var load_button := _button("Wczytaj", actions)
		load_button.pressed.connect(func(): _load_slot(slot))
		var new_button := _button("Nowa gra", actions)
		new_button.pressed.connect(func(): _new_slot(slot))
		_rows.append({"slot": slot, "label": details, "load": load_button, "new": new_button})
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.add_theme_color_override("font_color", Color("#e9ce83"))
	column.add_child(_message)
	var bottom := HBoxContainer.new()
	column.add_child(bottom)
	var folder := _button("Folder zapisów", bottom)
	folder.pressed.connect(_open_folder)
	var quit_button := _button("Wyjdź z gry", bottom)
	quit_button.pressed.connect(func(): quit_requested.emit())
	_confirmation = ConfirmationDialog.new()
	_confirmation.title = "Rozpocząć nową grę?"
	_confirmation.ok_button_text = "Nowa gra"
	_confirmation.cancel_button_text = "Anuluj"
	_confirmation.confirmed.connect(func(): start_requested.emit(_pending_slot, true))
	add_child(_confirmation)
	refresh()

func _button(text: String, parent: Node) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(150, 40)
	parent.add_child(button)
	return button

func refresh() -> void:
	_busy = false
	for row in _rows:
		var info: Dictionary = manager.call("slot_info", row["slot"])
		row["label"].text = info["description"]
		row["load"].disabled = not bool(info["loadable"])
		row["new"].disabled = false

func set_message(text: String) -> void:
	_message.text = text

func set_busy(value: bool) -> void:
	_busy = value
	if not value:
		refresh()
		return
	for row in _rows:
		row["load"].disabled = true
		row["new"].disabled = true

func _load_slot(slot: int) -> void:
	if not _busy:
		start_requested.emit(slot, false)

func _new_slot(slot: int) -> void:
	if _busy:
		return
	var info: Dictionary = manager.call("slot_info", slot)
	if bool(info["occupied"]):
		_pending_slot = slot
		_confirmation.dialog_text = "Nowa gra zastąpi postęp w slocie %d. Kontynuować?" % slot
		_confirmation.popup_centered(Vector2i(430, 180))
	else:
		start_requested.emit(slot, true)

func _open_folder() -> void:
	DirAccess.make_dir_recursive_absolute(str(manager.get("directory")))
	OS.shell_open(ProjectSettings.globalize_path(str(manager.get("directory"))))
