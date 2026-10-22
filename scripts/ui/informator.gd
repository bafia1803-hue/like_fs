extends PanelContainer
## Informator: panel w prawym górnym rogu z informacjami o sterowanej maszynie
## i podpiętym narzędziu (pojemności zbiorników, prędkość, przeładunek...).
##
## Treść dostarczają skrypty z PROVIDERS (scripts/ui/info/). Każdy dostaje maszynę
## i zwraca wiersze; Informator tylko je wyświetla. Nowa informacja = nowy dostawca.

const PROVIDERS: Array[String] = [
	"res://scripts/ui/info/speed_info.gd",
	"res://scripts/ui/info/work_info.gd",
	"res://scripts/ui/info/storage_info.gd",
	"res://scripts/ui/info/status_info.gd",
]
const REFRESH_SECONDS: float = 0.2

var query: RefCounted
var _providers: Array = []
var _column: VBoxContainer
var _timer: float = 0.0


func _init() -> void:
	name = "Informator"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -330
	offset_right = -14
	offset_top = 12
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.13, 0.11, 0.09, 0.5)
	style.set_corner_radius_all(10)
	style.set_content_margin_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	add_theme_stylebox_override("panel", style)
	_column = VBoxContainer.new()
	_column.add_theme_constant_override("separation", 3)
	_column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_column)
	visible = false


func configure(world_query: RefCounted) -> void:
	query = world_query
	_providers.clear()
	for path in PROVIDERS:
		var script: Script = load(path)
		if script != null:
			_providers.append(script.new())
	visible = true
	refresh()


## Dodaje dostawcę w czasie działania (np. z innego systemu gry).
func add_provider(provider: RefCounted) -> void:
	_providers.append(provider)


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= REFRESH_SECONDS:
		_timer = 0.0
		refresh()


func refresh() -> void:
	if query == null:
		return
	var vehicle: Node = query.controlled_vehicle()
	if not is_instance_valid(vehicle):
		return
	var sections: Array = [[vehicle, "vehicle"]]
	var implement: Node = query.attached_machine(vehicle)
	if implement != null:
		sections.append([implement, "implement"])
	var entries: Array = []
	for section in sections:
		var machine: Node = section[0]
		entries.append({"title": str(machine.get_meta("definition").get("name", machine.name))})
		for provider in _providers:
			entries.append_array(provider.call("rows", machine, section[1], query))
	_render(entries)


## Ponownie używa istniejących wierszy, żeby nie tworzyć kontrolek co odświeżenie.
func _render(entries: Array) -> void:
	while _column.get_child_count() < entries.size():
		_column.add_child(_make_row())
	for i in _column.get_child_count():
		var row: Control = _column.get_child(i)
		row.visible = i < entries.size()
		if row.visible:
			_fill_row(row, entries[i], i > 0)


func _make_row() -> Control:
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 1)
	var line := HBoxContainer.new()
	line.name = "Line"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(line)
	for label_name in ["Label", "Value"]:
		var label := Label.new()
		label.name = label_name
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_color_override("font_color", Color("#fffaf0"))
		label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
		label.add_theme_constant_override("shadow_offset_y", 1)
		if label_name == "Label":
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		else:
			label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		line.add_child(label)
	var bar := ProgressBar.new()
	bar.name = "Bar"
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 8)
	bar.max_value = 1.0
	bar.step = 0.001
	var background := StyleBoxFlat.new()
	background.bg_color = Color(1, 1, 1, 0.15)
	background.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("background", background)
	var fill := StyleBoxFlat.new()
	fill.set_corner_radius_all(4)
	bar.add_theme_stylebox_override("fill", fill)
	box.add_child(bar)
	return box


func _fill_row(row: Control, entry: Dictionary, spaced: bool) -> void:
	var label: Label = row.get_node("Line/Label")
	var value: Label = row.get_node("Line/Value")
	var bar: ProgressBar = row.get_node("Bar")
	if entry.has("title"):
		label.text = str(entry["title"])
		label.add_theme_font_size_override("font_size", 16)
		label.add_theme_color_override("font_color", Color("#ffd98a"))
		value.text = ""
		bar.visible = false
		row.add_theme_constant_override("separation", 1)
		label.custom_minimum_size.y = 26.0 if spaced else 0.0
		label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
		return
	label.custom_minimum_size.y = 0.0
	label.text = str(entry.get("label", ""))
	label.add_theme_font_size_override("font_size", 14)
	label.add_theme_color_override("font_color", Color("#fffaf0"))
	value.text = str(entry.get("value", ""))
	value.add_theme_font_size_override("font_size", 14)
	var ratio: float = float(entry.get("ratio", -1.0))
	bar.visible = ratio >= 0.0
	if bar.visible:
		bar.value = ratio
		var fill: StyleBoxFlat = bar.get_theme_stylebox("fill")
		fill.bg_color = entry.get("color", Color("#f2c55c"))
