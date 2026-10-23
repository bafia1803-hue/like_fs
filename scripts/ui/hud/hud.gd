extends Node
## Interfejs gry (HUD) złożony z małych kontrolek. Czyta stan przez WorldQuery, zmienia go
## wyłącznie przez GameActions, komunikaty dostaje z EventBus.notice.
##
## Warstwy: "Interface" (panele, przyciski), "ShopLayer" (okna: sklep, trasy, napełnianie;
## działają w pauzie), "SleepCurtain" (zasłona snu nad wszystkim).

signal save_requested
signal menu_requested
signal sleep_requested

const HudStyle = preload("res://scripts/ui/hud/hud_style.gd")
const ToastScript = preload("res://scripts/ui/hud/toast.gd")
const MoneyPanelScript = preload("res://scripts/ui/hud/money_panel.gd")
const DebugPanelScript = preload("res://scripts/ui/hud/debug_panel.gd")
const ContextActionsScript = preload("res://scripts/ui/hud/context_actions.gd")
const SeedCropScript = preload("res://scripts/ui/hud/seed_crop_selector.gd")
const SleepCurtainScript = preload("res://scripts/ui/hud/sleep_curtain.gd")
const FpsLabelScript = preload("res://scripts/ui/hud/fps_label.gd")
const IconButtonScript = preload("res://scripts/ui/icon_button.gd")
const InformatorScript = preload("res://scripts/ui/informator.gd")
const ShopWindowScript = preload("res://scripts/ui/shop_window.gd")
const RouteBrowserScript = preload("res://scripts/ui/routes/route_browser.gd")
const RecordControlsScript = preload("res://scripts/ui/routes/record_controls.gd")
const FillDialogScript = preload("res://scripts/ui/fill_dialog.gd")
const REFRESH_SECONDS: float = 0.15

var interface: CanvasLayer
var debug_panel: PanelContainer
var toast: Label
var shop: Control
var route_browser: Control
var sleep_curtain: CanvasLayer
var _query: RefCounted
var _actions: RefCounted
var _context_actions: Control
var _seed_crop: HBoxContainer
var _routes_button: Button
var _fill_dialog: Control
var _show_debug: bool = false
var _timer: float = 0.0
var _ready_to_refresh: bool = false


func _init() -> void:
	name = "Hud"
	interface = CanvasLayer.new()
	interface.name = "Interface"
	add_child(interface)
	debug_panel = DebugPanelScript.new()
	interface.add_child(debug_panel)
	toast = ToastScript.new()
	interface.add_child(toast)


## Buduje resztę interfejsu po udanym uruchomieniu świata.
## with_menu_buttons – przyciski „Zapisz” i „Menu” (gra uruchomiona z menu startowego).
func setup(query: RefCounted, actions: RefCounted, with_menu_buttons: bool) -> void:
	_query = query
	_actions = actions
	query.events().notice.connect(notify)
	var informator = InformatorScript.new()
	interface.add_child(informator)
	interface.add_child(FpsLabelScript.new())
	var money = MoneyPanelScript.new()
	interface.add_child(money)
	money.setup(query)
	var controls := Control.new()
	controls.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	interface.add_child(controls)
	controls.add_child(_action_bar(with_menu_buttons))
	_context_actions = ContextActionsScript.new()
	controls.add_child(_context_actions)
	_context_actions.setup(query, actions)
	_seed_crop = SeedCropScript.new()
	controls.add_child(_seed_crop)
	_seed_crop.setup(query, actions)
	# Okna nad interfejsem (pod zasłoną snu).
	var window_layer := CanvasLayer.new()
	window_layer.name = "ShopLayer"
	window_layer.layer = 50
	window_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(window_layer)
	shop = ShopWindowScript.new()
	shop.call("setup", query, actions)
	window_layer.add_child(shop)
	route_browser = RouteBrowserScript.new()
	route_browser.call("setup", query, actions)
	window_layer.add_child(route_browser)
	controls.add_child(_route_column(window_layer))
	_fill_dialog = FillDialogScript.new()
	_fill_dialog.chosen.connect(func(point_id, machine_id, material): notify(_actions.request_fill(point_id, machine_id, material)))
	window_layer.add_child(_fill_dialog)
	_context_actions.fill_dialog_requested.connect(func(offer: Dictionary): _fill_dialog.call("open", offer))
	sleep_curtain = SleepCurtainScript.new()
	add_child(sleep_curtain)
	debug_panel.visible = _show_debug
	informator.call("configure", query)
	_ready_to_refresh = true
	_refresh()


## Dolny pasek: okrągłe przyciski z ikonami, wyśrodkowane jako grupa (nazwy w podpowiedziach).
func _action_bar(with_menu_buttons: bool) -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.name = "ActionBar"
	bar.alignment = BoxContainer.ALIGNMENT_CENTER
	bar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -200
	bar.offset_right = 200
	bar.offset_top = -72
	bar.offset_bottom = -16
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.add_theme_constant_override("separation", 14)
	var actions: Array = [["cart", "Sklep (K)", open_shop], ["sleep", "Sen (N)", sleep_requested.emit]]
	if with_menu_buttons:
		# Wyjście z gry tylko z menu; tu: zapis i powrót do menu.
		actions.append(["save", "Zapisz grę (F9)", save_requested.emit])
		actions.append(["exit", "Menu (Esc)", menu_requested.emit])
	for action in actions:
		var icon_button: Button = IconButtonScript.new(action[0], action[1])
		icon_button.pressed.connect(action[2])
		bar.add_child(icon_button)
	return bar


## Lewy dolny róg, jeden pod drugim: nagrywanie trasy i okno tras.
func _route_column(dialog_parent: Node) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.name = "RouteColumn"
	column.add_theme_constant_override("separation", 12)
	column.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	column.offset_left = 16
	column.offset_bottom = -16
	column.offset_top = -140
	column.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var record = RecordControlsScript.new()
	record.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(record)
	record.call("setup", _query, _actions, dialog_parent)
	_routes_button = IconButtonScript.new("routes", "Trasy (R)")
	_routes_button.pressed.connect(open_route_browser)
	# Do lewej: czas nagrywania obok przycisku poszerza kolumnę, a przycisk tras ma zostać na miejscu.
	_routes_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(_routes_button)
	return column


func _process(delta: float) -> void:
	if not _ready_to_refresh:
		return
	_timer += delta
	if _timer >= REFRESH_SECONDS:
		_timer = 0.0
		_refresh()


func _refresh() -> void:
	_update_debug()
	_context_actions.refresh()
	_seed_crop.refresh()
	_update_routes_button()


## Krótki komunikat u góry ekranu.
func notify(text: String) -> void:
	toast.show_message(text)
	if _ready_to_refresh:
		_update_debug()


func show_error(message: String) -> void:
	debug_panel.show_error(message)


func toggle_debug() -> void:
	_show_debug = not _show_debug
	debug_panel.visible = _show_debug
	_update_debug()


func _update_debug() -> void:
	if not _show_debug or _query == null:
		return
	var lines: PackedStringArray = _query.diagnostics()
	lines.append(toast.last_message)
	debug_panel.show_lines(lines)


func windows_open() -> bool:
	return (shop != null and shop.visible) or (route_browser != null and route_browser.visible)


func open_shop() -> void:
	if _query == null or get_tree().paused or windows_open():
		return
	shop.call("open")


func open_route_browser() -> void:
	if _query == null or get_tree().paused or windows_open():
		return
	route_browser.call("open")


func _update_routes_button() -> void:
	var routes: Node = _query.route_system()
	var paused_count: int = 0
	for task in routes.tasks.values():
		if bool(task.get("paused", false)):
			paused_count += 1
	# Licznik zestawów jadących trasą (w rogu ikony); szczegóły w podpowiedzi.
	_routes_button.set("badge", "" if routes.tasks.is_empty() else str(routes.tasks.size()))
	var hint: String = "Trasy (R)"
	if not routes.tasks.is_empty():
		hint += " — w drodze: %d" % routes.tasks.size()
		if paused_count > 0:
			hint += ", czeka: %d" % paused_count
	_routes_button.tooltip_text = hint
