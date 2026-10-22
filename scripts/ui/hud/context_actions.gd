extends Control
## Przyciski kontekstowe nad paskiem akcji (warstwa UI):
##   – zakup pola, gdy sterowany pojazd stoi nad cudzym polem,
##   – usługa punktu farmy (załadunek z silosu, zakup w magazynie, przerwanie napełniania),
##   – pasek przejazdu trasy: „Uruchom trasę” na miejscu startu i „Odwołaj przejazd”.
## Stan czyta przez WorldQuery, polecenia wydaje przez GameActions; komunikaty → EventBus.notice.

const Style = preload("res://scripts/ui/hud/hud_style.gd")

signal fill_dialog_requested(offer: Dictionary)

var _query: RefCounted
var _actions: RefCounted
var _field_button: Button
var _field_offer: String = ""
var _service_button: Button
var _service_offer: Dictionary = {}
var _route_bar: HBoxContainer
var _route_start_button: Button


func setup(query: RefCounted, actions: RefCounted) -> void:
	name = "ContextActions"
	_query = query
	_actions = actions
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_field_button = Style.action_button(Color("#e0a93b"), Color("#f0bd52"), Color("#2b2118"))
	_field_button.name = "BuyFieldButton"
	_field_button.visible = false
	Style.place_bottom_center(_field_button, 190, -132, -82)
	_field_button.pressed.connect(_on_field_pressed)
	add_child(_field_button)
	_service_button = Style.action_button(Color("#5b8fd0"), Color("#73a5e0"), Color("#fffaf0"))
	_service_button.name = "ServiceButton"
	_service_button.visible = false
	Style.place_bottom_center(_service_button, 190, -132, -82)
	_service_button.pressed.connect(_on_service_pressed)
	add_child(_service_button)
	_route_bar = HBoxContainer.new()
	_route_bar.name = "RouteStartBar"
	_route_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_route_bar.add_theme_constant_override("separation", 12)
	Style.place_bottom_center(_route_bar, 260, -132, -82)
	_route_bar.visible = false
	add_child(_route_bar)
	_route_start_button = Style.action_button(Color("#4f8a3c"), Color("#62a24c"), Color("#fffaf0"))
	_route_start_button.custom_minimum_size = Vector2(220, 0)
	_route_start_button.text = "Uruchom trasę"
	_route_start_button.pressed.connect(_on_route_start_pressed)
	_route_bar.add_child(_route_start_button)
	var cancel_button: Button = Style.action_button(Color("#9b4a3c"), Color("#b05a4a"), Color("#fffaf0"))
	cancel_button.custom_minimum_size = Vector2(220, 0)
	cancel_button.text = "Odwołaj przejazd"
	cancel_button.pressed.connect(_on_route_cancel_pressed)
	_route_bar.add_child(cancel_button)


func refresh() -> void:
	_update_field_button()
	_update_service_button()
	_update_route_bar()


func _notify(text: String) -> void:
	_query.events().notice.emit(text)


func _update_field_button() -> void:
	var offer: Dictionary = _query.field_offer()
	_field_offer = str(offer.get("id", ""))
	_field_button.visible = not offer.is_empty()
	if not offer.is_empty():
		_field_button.text = "Kup pole: %s — %s" % [offer["name"], _query.format_money(float(offer["price"]))]


func _on_field_pressed() -> void:
	if not _field_offer.is_empty():
		_notify(_actions.buy_field(_field_offer))


func _update_service_button() -> void:
	_service_offer = _query.service_offer()
	_service_button.visible = not _service_offer.is_empty()
	if _service_offer.is_empty():
		return
	if bool(_service_offer["active"]):
		_service_button.text = "Przerwij napełnianie"
	elif str(_service_offer["kind"]) == "load":
		_service_button.text = "Załaduj z silosu…"
	else:
		_service_button.text = _query.purchase_label(_service_offer)


func _on_service_pressed() -> void:
	if _service_offer.is_empty():
		return
	if bool(_service_offer["active"]):
		_notify(_actions.cancel_fill(str(_service_offer["machine_id"])))
		return
	if str(_service_offer["kind"]) == "supply":
		# Magazyn: maszyna przyjmuje jeden towar (ziarno siewne albo nawóz) – zakup rusza od razu.
		_notify(_actions.start_purchase(_service_offer))
		return
	fill_dialog_requested.emit(_service_offer)


## Pasek przejazdu: przed startem (zestaw widmo) „Uruchom trasę” + „Odwołaj przejazd”,
## w trakcie jazdy sterowanego zestawu trasą samo „Odwołaj przejazd” (przerywa trasę).
func _update_route_bar() -> void:
	var dropped: String = _actions.drop_invalid_armed_route()
	if not dropped.is_empty():
		_notify(dropped)
	var routes: Node = _query.route_system()
	var status: Dictionary = routes.armed_status()
	var armed: bool = bool(status.get("valid", false))
	var vehicle: RigidBody2D = _query.controlled_vehicle()
	var driving: bool = is_instance_valid(vehicle) and routes.tasks.has(vehicle)
	_route_bar.visible = armed or driving
	_route_start_button.visible = armed and bool(status.get("at_start", false))
	# Przyciski pola i usług ustępują miejsca paskowi przejazdu.
	var lift: float = -60.0 if _route_bar.visible else 0.0
	for button in [_field_button, _service_button]:
		button.offset_top = -132 + lift
		button.offset_bottom = -82 + lift


func _on_route_cancel_pressed() -> void:
	var text: String = _actions.cancel_route()
	if not text.is_empty():
		_notify(text)
	_update_route_bar()


func _on_route_start_pressed() -> void:
	_notify(_actions.start_armed_route())
	_update_route_bar()
