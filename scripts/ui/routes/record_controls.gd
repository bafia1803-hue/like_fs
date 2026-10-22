extends HBoxContainer
## Sterowanie nagrywaniem trasy na ekranie (lewy dolny róg), jak w odtwarzaczu:
## trójkąt = zacznij nagrywać, dwie kreski = zatrzymaj. Po zatrzymaniu okienko
## RecordSaveDialog pyta o nazwę: Zapisz / Kontynuuj / Usuń przejazd.
## Korzysta wyłącznie z systemu tras (begin/finish/cancel_recording) i sterowanego pojazdu.

const SaveDialogScript = preload("res://scripts/ui/routes/record_save_dialog.gd")

var world: Node
var _button: Button
var _label: Label
var _dot: Control
var _dialog: Control
var _timer: float = 0.0
var _blink: float = 0.0


func setup(world_node: Node, dialog_parent: Node) -> void:
	world = world_node
	name = "RecordControls"
	add_theme_constant_override("separation", 10)
	_button = Button.new()
	_button.custom_minimum_size = Vector2(46, 46)
	_button.focus_mode = Control.FOCUS_NONE
	_button.tooltip_text = "Nagrywanie trasy"
	for state in ["normal", "hover", "pressed", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = Color("#3a332c") if state != "hover" else Color("#4c433a")
		if state == "disabled":
			box.bg_color = Color("#2a2520")
		box.set_corner_radius_all(23)
		_button.add_theme_stylebox_override(state, box)
	_button.draw.connect(_draw_icon)
	_button.pressed.connect(_on_pressed)
	add_child(_button)
	_dot = Control.new()
	_dot.custom_minimum_size = Vector2(14, 14)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_dot.draw.connect(func(): _dot.draw_circle(Vector2(7, 7), 6.0, Color("#ff4d4d", 0.4 + 0.6 * absf(sin(_blink * 3.0)))))
	add_child(_dot)
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color("#fffaf0"))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	_label.add_theme_constant_override("shadow_offset_y", 1)
	_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(_label)
	_dialog = SaveDialogScript.new()
	_dialog.decided.connect(_on_decided)
	dialog_parent.add_child(_dialog)
	_refresh()


func _process(delta: float) -> void:
	_blink += delta
	_timer += delta
	if _recording():
		_dot.queue_redraw()
	if _timer >= 0.2:
		_timer = 0.0
		_refresh()


func _system() -> Node:
	return world.call("get_route_system") if world != null and bool(world.get("_world_loaded")) else null


func _recording() -> bool:
	var system: Node = _system()
	return system != null and not system.recording.is_empty()


func _refresh() -> void:
	var system: Node = _system()
	if system == null:
		visible = false
		return
	visible = true
	var recording: bool = not system.recording.is_empty()
	var vehicle: Node = world.call("get_controlled_vehicle")
	var busy: bool = vehicle != null and system.tasks.has(vehicle)
	_button.disabled = not recording and busy
	_dot.visible = recording
	if recording:
		var seconds: int = roundi(float(system.recording["time"]))
		_label.text = "Nagrywanie  %d:%02d" % [seconds / 60, seconds % 60]
		_button.tooltip_text = "Zatrzymaj nagrywanie"
	else:
		_label.text = "Nagraj trasę" if not busy else "Zestaw jedzie trasą"
		_button.tooltip_text = "Zacznij nagrywać trasę sterowanego zestawu"
	_button.queue_redraw()


func _draw_icon() -> void:
	var center: Vector2 = _button.size * 0.5
	var color := Color("#fffaf0") if not _button.disabled else Color("#7d736a")
	if _recording():
		# dwie kreski: zatrzymaj
		for x in [-6.0, 3.0]:
			_button.draw_rect(Rect2(center + Vector2(x, -9.0), Vector2(5.0, 18.0)), color)
	else:
		# trójkąt: nagrywaj
		_button.draw_colored_polygon(PackedVector2Array([center + Vector2(-6, -10), center + Vector2(-6, 10), center + Vector2(10, 0)]), Color("#ff6b5b") if not _button.disabled else color)


func _on_pressed() -> void:
	var system: Node = _system()
	if system == null:
		return
	if system.recording.is_empty():
		system.call("begin_recording", world.call("get_controlled_vehicle"), "")
	else:
		_dialog.call("open", "Trasa " + Time.get_datetime_string_from_system().replace("T", " ").left(16), float(system.recording["time"]))
	_refresh()


func _on_decided(action: String, title: String) -> void:
	var system: Node = _system()
	if system == null or system.recording.is_empty():
		return
	match action:
		"save":
			system.call("finish_recording", title)
		"discard":
			system.call("cancel_recording")
			world.call("show_save_message", "Usunięto nagrany przejazd.")
		_:
			pass   # "continue": nagrywanie trwa dalej
	_refresh()
