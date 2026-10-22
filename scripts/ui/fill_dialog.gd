extends Control
## Małe okienko na środku ekranu: wybór ziarna przy załadunku z silosu albo kupnie nasion.
## Pokazuje opcje z farm_services.offer_for(); niedostępne są wyszarzone z powodem
## (np. „w środku jest pszenica”). Na czas wyboru gra jest w pauzie.

signal chosen(point_id: String, machine_id: String, material: String)

const ACCENT := Color("#ffd98a")
const TEXT := Color("#fffaf0")
const MUTED := Color("#cfc4b2")

var _panel: PanelContainer
var _column: VBoxContainer
var _offer: Dictionary = {}


func _init() -> void:
	name = "FillDialog"
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
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(380, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.12, 0.1, 0.97)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 10)
	_panel.add_child(_column)


func open(offer: Dictionary) -> void:
	_offer = offer
	for child in _column.get_children():
		child.queue_free()
	var verb: String = "Co załadować?" if str(offer["kind"]) == "load" else "Jakie nasiona kupić?"
	_column.add_child(_label(str(offer["title"]), 22, ACCENT))
	_column.add_child(_label("%s  (teraz %s)" % [verb, offer.get("storage", "")], 15, MUTED))
	for option in offer["options"]:
		var button := _button("%s — %s" % [option["label"], option["detail"]], Color("#4f8a3c"))
		button.disabled = not bool(option["enabled"])
		if button.disabled:
			button.text += "  (%s)" % option["reason"]
		var material: String = str(option["material"])
		button.pressed.connect(func(): _choose(material))
		_column.add_child(button)
	var cancel := _button("Anuluj (Esc)", Color("#5a4f44"))
	cancel.pressed.connect(close)
	_column.add_child(cancel)
	visible = true
	get_tree().paused = true


func close() -> void:
	visible = false
	get_tree().paused = false


func _choose(material: String) -> void:
	var offer: Dictionary = _offer
	close()
	chosen.emit(str(offer["point_id"]), str(offer["machine_id"]), material)


func _input(event: InputEvent) -> void:
	if visible and event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()


func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	return label


func _button(text: String, color: Color) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size = Vector2(0, 42)
	button.add_theme_font_size_override("font_size", 16)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = color.lightened(0.15) if state == "hover" else (Color("#4a433c") if state == "disabled" else color)
		box.set_corner_radius_all(8)
		box.set_content_margin_all(8)
		button.add_theme_stylebox_override(state, box)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_disabled_color", Color("#9d9286"))
	return button
