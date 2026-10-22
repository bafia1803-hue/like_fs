extends PanelContainer
## Pieniądze gracza (lewy górny róg) i zmiana stanu konta (+/−), sumowana przez 2 s.

var _query: RefCounted
var _money: Label
var _change_label: Label
var _change: float = 0.0
var _change_time: float = 0.0


func _init() -> void:
	name = "MoneyPanel"
	position = Vector2(12, 10)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_theme_stylebox_override("panel", preload("res://scripts/ui/hud/hud_style.gd").panel(0.5, 8))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	_money = Label.new()
	_money.add_theme_font_size_override("font_size", 20)
	_money.add_theme_color_override("font_color", Color("#ffd98a"))
	_money.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_money)
	_change_label = Label.new()
	_change_label.add_theme_font_size_override("font_size", 16)
	_change_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_change_label.modulate.a = 0.0
	row.add_child(_change_label)


func setup(query: RefCounted) -> void:
	_query = query
	_money.text = query.format_money(query.money())
	query.events().money_changed.connect(_on_money_changed)


func _on_money_changed(money: float, change: float, _reason: String) -> void:
	_money.text = _query.format_money(money)
	# Zmiany z kilku kolejnych kroków (np. sprzedaż przez kilka sekund) sumują się w jeden napis.
	_change += change
	_change_time = 2.0
	_change_label.text = ("+" if _change >= 0.0 else "−") + _query.format_money(absf(_change))
	_change_label.add_theme_color_override("font_color", Color("#9be37a") if _change >= 0.0 else Color("#ff9b8a"))
	_change_label.modulate.a = 1.0


func _process(delta: float) -> void:
	if _change_time > 0.0:
		_change_time -= delta
		_change_label.modulate.a = clampf(_change_time / 0.5, 0.0, 1.0)
		if _change_time <= 0.0:
			_change = 0.0
