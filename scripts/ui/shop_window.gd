extends Control
## Sklep z maszynami (UI). Zakładki: „Kup maszyny” (oferta z cennika) i „Moje maszyny”
## (sprzedaż). Kafelki z obracanym podglądem 3D i najważniejszymi danymi maszyny.
##
## Okno tylko pokazuje dane i wywołuje world.buy_machine / world.sell_machine – logika
## zakupu (ceny, miejsce na placu) siedzi w warstwie gry. Na czas zakupów gra jest w pauzie.

const PreviewScript = preload("res://scripts/ui/machine_preview.gd")
const PriceListScript = preload("res://scripts/economy/price_list.gd")

const CATEGORY_NAMES := {
	"tractor": "Ciągnik", "trailer": "Przyczepa", "combine": "Kombajn",
	"header": "Heder", "seeder": "Siewnik", "cultivator": "Kultywator",
}
const STORAGE_NAMES := {"combine": "Zbiornik ziarna", "trailer": "Skrzynia", "seeder": "Zbiornik nasion"}
const ACCENT := Color("#ffd98a")
const TEXT := Color("#fffaf0")
const MUTED := Color("#cfc4b2")

var world: Node
var _money: Label
var _message: Label
var _buy_tab: Button
var _owned_tab: Button
var _buy_grid: GridContainer
var _owned_grid: GridContainer
var _buy_scroll: ScrollContainer
var _owned_scroll: ScrollContainer
var _built: bool = false


func setup(world_node: Node) -> void:
	world = world_node
	name = "ShopWindow"
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func open() -> void:
	if not _built:
		_build()
	visible = true
	get_tree().paused = true
	_message.text = "Przeciągnij myszą podgląd, aby obejrzeć maszynę z każdej strony."
	_refresh_owned()
	_update_money()
	_show_tab(true)


func close() -> void:
	visible = false
	get_tree().paused = false


func _input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_ESCAPE or event.keycode == KEY_K):
		close()
		get_viewport().set_input_as_handled()


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
	panel.offset_left = 60
	panel.offset_right = -60
	panel.offset_top = 40
	panel.offset_bottom = -40
	panel.add_theme_stylebox_override("panel", _box(Color(0.14, 0.12, 0.1, 0.97), 16, 18))
	add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	panel.add_child(column)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	column.add_child(header)
	var title := _label("Sklep z maszynami", 28, ACCENT)
	header.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_money = _label("", 22, TEXT)
	header.add_child(_money)
	var close_button := _button("Zamknij (Esc)", Color("#5a4f44"))
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	column.add_child(tabs)
	var group := ButtonGroup.new()
	_buy_tab = _tab_button("Kup maszyny", group)
	_buy_tab.pressed.connect(func(): _show_tab(true))
	tabs.add_child(_buy_tab)
	_owned_tab = _tab_button("Moje maszyny", group)
	_owned_tab.pressed.connect(func(): _show_tab(false))
	tabs.add_child(_owned_tab)
	var tab_spacer := Control.new()
	tab_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.add_child(tab_spacer)
	_message = _label("", 15, MUTED)
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	tabs.add_child(_message)

	_buy_scroll = _scroll()
	column.add_child(_buy_scroll)
	_buy_grid = _grid()
	_buy_scroll.add_child(_buy_grid)
	_owned_scroll = _scroll()
	column.add_child(_owned_scroll)
	_owned_grid = _grid()
	_owned_scroll.add_child(_owned_grid)

	var economy: Node = world.call("get_economy")
	var models: Dictionary = world.session["models_by_id"]
	for model_id in economy.prices.shop_models():
		if not models.has(model_id):
			continue
		var model: Dictionary = models[model_id]
		var price: float = float(economy.prices.machine_price(model_id))
		var button := _button("Kup", Color("#4f8a3c"))
		button.pressed.connect(func(): _buy(model_id))
		_buy_grid.add_child(_tile(model, CATEGORY_NAMES.get(str(model.get("category", "")), ""), economy.format(price), button, ""))


func _refresh_owned() -> void:
	for child in _owned_grid.get_children():
		child.queue_free()
	var economy: Node = world.call("get_economy")
	var machines: Dictionary = world.call("get_machines")
	var ids: Array = machines.keys()
	ids.sort()
	for id in ids:
		var model: Dictionary = machines[id].get_meta("definition")
		var value: float = float(economy.prices.machine_resale_price(str(model["id"])))
		var reason: String = str(world.call("sell_block_reason", str(id)))
		var button := _button("Sprzedaj", Color("#9b4a3c"))
		button.disabled = not reason.is_empty()
		button.tooltip_text = reason
		button.pressed.connect(func(): _sell(str(id)))
		var subtitle: String = "%s · %s" % [CATEGORY_NAMES.get(str(model.get("category", "")), ""), str(id)]
		_owned_grid.add_child(_tile(model, subtitle, "Odkup: " + economy.format(value), button, reason))


func _show_tab(buy: bool) -> void:
	_buy_tab.button_pressed = buy
	_owned_tab.button_pressed = not buy
	_buy_scroll.visible = buy
	_owned_scroll.visible = not buy


func _buy(model_id: String) -> void:
	_message.text = str(world.call("buy_machine", model_id))
	_refresh_owned()
	_update_money()


func _sell(instance_id: String) -> void:
	_message.text = str(world.call("sell_machine", instance_id))
	_refresh_owned()
	_update_money()


func _update_money() -> void:
	var economy: Node = world.call("get_economy")
	_money.text = "Konto: " + economy.format(economy.get_money())


# ---------------------------------------------------------------------------
# Kafelek
# ---------------------------------------------------------------------------

func _tile(model: Dictionary, subtitle: String, price_text: String, action: Button, note: String) -> Control:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(320, 0)
	tile.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile.add_theme_stylebox_override("panel", _box(Color("#2a241e"), 12, 12))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	tile.add_child(column)
	var preview = PreviewScript.new()
	preview.setup(model)
	column.add_child(preview)
	column.add_child(_label(str(model["name"]), 19, TEXT))
	if not subtitle.is_empty():
		column.add_child(_label(subtitle, 13, MUTED))
	for line in describe(model):
		column.add_child(_label(line, 14, MUTED))
	if not note.is_empty():
		column.add_child(_label(note, 13, Color("#ff9b8a")))
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	column.add_child(footer)
	var price := _label(price_text, 18, ACCENT)
	price.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(price)
	footer.add_child(action)
	return tile


## Najważniejsze dane maszyny do kafelka.
static func describe(model: Dictionary) -> Array[String]:
	var lines: Array[String] = []
	if model.get("drive") is Dictionary:
		var drive: Dictionary = model["drive"]
		var kw: float = float(drive.get("engine_power_kw", 0.0))
		if kw > 0.0:
			lines.append("Moc: %d kW (%d KM)" % [roundi(kw), roundi(kw * 1.36)])
		lines.append("Prędkość maks.: %d km/h" % roundi(float(drive.get("forward_speed_kmh", 0.0))))
	for storage in model.get("storage_definitions", []):
		var title: String = STORAGE_NAMES.get(str(model.get("category", "")), "Pojemność")
		lines.append("%s: %s" % [title, PriceListScript.format_money(float(storage["capacity_l"]), "l")])
	var work: Variant = model.get("work")
	if work is Dictionary and work.get("area") is Dictionary:
		lines.append("Szerokość robocza: %s m" % _decimal(float(work["area"]["width_m"])))
		if work.has("max_working_speed_kmh"):
			lines.append("Prędkość pracy: do %d km/h" % roundi(float(work["max_working_speed_kmh"])))
	if model.get("folding") is Dictionary:
		var folded: Array = model.get("physics", {}).get("collision_profiles", {}).get(str(model["folding"].get("folded_profile", "folded")), [])
		if not folded.is_empty():
			lines.append("Składany, w transporcie %s m" % _decimal(float(folded[0]["width_m"])))
	return lines


static func _decimal(value: float) -> String:
	return ("%.1f" % value).replace(".", ",")


# ---------------------------------------------------------------------------
# Drobne elementy wyglądu
# ---------------------------------------------------------------------------

func _label(text: String, size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
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
	var normal := _box(color, 8, 8)
	var hover := _box(color.lightened(0.15), 8, 8)
	var disabled := _box(Color("#4a433c"), 8, 8)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", normal)
	button.add_theme_stylebox_override("disabled", disabled)
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_disabled_color", Color("#8d8377"))
	return button


func _tab_button(text: String, group: ButtonGroup) -> Button:
	var button := _button(text, Color("#3a332c"))
	button.toggle_mode = true
	button.button_group = group
	button.custom_minimum_size = Vector2(170, 40)
	button.add_theme_stylebox_override("pressed", _box(Color("#6b5a3f"), 8, 8))
	return button


func _scroll() -> ScrollContainer:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	return scroll


func _grid() -> GridContainer:
	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 14)
	return grid
