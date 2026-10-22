extends HBoxContainer
## Sterowanie nagrywaniem trasy na ekranie (lewy dolny róg), jak w odtwarzaczu:
## trójkąt = zacznij nagrywać, dwie kreski = zatrzymaj. Po zatrzymaniu okienko
## RecordSaveDialog pyta o nazwę: Zapisz / Kontynuuj / Usuń przejazd.
## Stan czyta przez WorldQuery (system tras, sterowany pojazd), polecenia wydaje przez GameActions.

const SaveDialogScript = preload("res://scripts/ui/routes/record_save_dialog.gd")
const IconButtonScript = preload("res://scripts/ui/icon_button.gd")

var query: RefCounted
var _actions: RefCounted
var _button: Button
var _label: Label
var _dot: Control
var _dialog: Control
var _timer: float = 0.0
var _blink: float = 0.0


func setup(world_query: RefCounted, game_actions: RefCounted, dialog_parent: Node) -> void:
	query = world_query
	_actions = game_actions
	name = "RecordControls"
	add_theme_constant_override("separation", 10)
	_button = IconButtonScript.new("record", "Nagraj trasę")
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
	return query.route_system() if query != null else null


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
	var vehicle: Node = query.controlled_vehicle()
	var busy: bool = vehicle != null and system.tasks.has(vehicle)
	_button.disabled = not recording and busy
	_dot.visible = recording
	# Samo kółko z ikoną; czas widać tylko w trakcie nagrywania.
	_label.visible = recording
	if recording:
		var seconds: int = roundi(system.recording_time())
		_label.text = "%d:%02d" % [seconds / 60, seconds % 60]
		_button.tooltip_text = "Zatrzymaj nagrywanie"
		_button.call("set_icon", "pause")
	else:
		_button.tooltip_text = "Zestaw jedzie trasą" if busy else "Nagraj trasę sterowanego zestawu"
		_button.call("set_icon", "record", Color("#ff6b5b"))
	_button.queue_redraw()


func _on_pressed() -> void:
	var system: Node = _system()
	if system == null:
		return
	if system.recording.is_empty():
		_actions.begin_recording()
	else:
		# Koniec nagrania także w ruchu, ale wolno (jak start) – inaczej komunikat.
		var problem: String = _actions.recording_stop_problem()
		if not problem.is_empty():
			query.events().notice.emit(problem)
			return
		_dialog.call("open", "Trasa " + Time.get_datetime_string_from_system().replace("T", " ").left(16), system.recording_time())
	_refresh()


func _on_decided(action: String, title: String) -> void:
	var system: Node = _system()
	if system == null or system.recording.is_empty():
		return
	match action:
		"save":
			_actions.finish_recording(title)
		"discard":
			_actions.cancel_recording()
			query.events().notice.emit("Usunięto nagrany przejazd.")
		_:
			pass   # "continue": nagrywanie trwa dalej
	_refresh()
