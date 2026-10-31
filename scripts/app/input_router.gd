extends Node
## Klawisze gry → polecenia. Jedna tabela (BINDINGS) zamiast rozproszonej obsługi wejścia.
## Polecenia zmieniające przeguby (E) i zestaw sterowany (TAB) są odraczane poza krok fizyki.

const BINDINGS := {
	KEY_F9: "save",
	KEY_ESCAPE: "menu",
	KEY_HOME: "overview",
	KEY_F: "follow",
	KEY_B: "toggle_work",
	KEY_R: "routes",
	KEY_K: "shop",
	KEY_N: "sleep",
	KEY_V: "toggle_view",
	KEY_F3: "debug",
	KEY_F4: "perf_report",
	KEY_TAB: "switch_vehicle",
	KEY_E: "toggle_attachment",
	KEY_G: "graphics",
	KEY_H: "worker",
}

var _world: Node
var _actions: RefCounted
var _views: Node
var _hud: Node
var _sleep: Node
var _graphics: Node
var _gpu_test: Node


func setup(world: Node, actions: RefCounted, views: Node, hud: Node, sleep: Node, graphics: Node = null, gpu_test: Node = null) -> void:
	name = "InputRouter"
	_world = world
	_actions = actions
	_views = views
	_hud = hud
	_sleep = sleep
	_graphics = graphics
	_gpu_test = gpu_test


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var key: InputEventKey = event
	if not BINDINGS.has(key.keycode):
		return
	run(str(BINDINGS[key.keycode]), key.shift_pressed)
	get_viewport().set_input_as_handled()


## Wykonuje akcję o nazwie z BINDINGS (także z testów). shift – kierunek przy TAB.
func run(action: String, shift: bool = false) -> void:
	match action:
		"save":
			_world.save_requested.emit()
		"menu":
			_world.menu_requested.emit()
		"overview":
			_views.show_overview()
		"follow":
			_views.follow_player()
		"toggle_work":
			_notify(_actions.toggle_work())
		"routes":
			_hud.open_route_browser()
		"shop":
			_hud.open_shop()
		"sleep":
			_sleep.start()
		"toggle_view":
			_notify(_views.toggle())
		"debug":
			_hud.toggle_debug()
		"perf_report":
			if shift and _gpu_test != null:
				_hud.show_perf_report()
				_notify(_gpu_test.start())
			else:
				_notify(_hud.toggle_perf_report())
		"switch_vehicle":
			# TAB – następny pojazd, Shift+TAB – poprzedni.
			call_deferred("_deferred_switch", -1 if shift else 1)
		"worker":
			# Planowanie odpytuje fizykę – poza krokiem fizyki.
			call_deferred("_deferred_worker")
		"graphics":
			if _graphics != null:
				_notify(_graphics.cycle())
		"toggle_attachment":
			# Zmiany przegubów wykonujemy poza callbackami fizyki.
			call_deferred("_deferred_attach")


func _deferred_switch(direction: int) -> void:
	_notify(_actions.switch_vehicle(direction))


func _deferred_worker() -> void:
	_notify(_actions.toggle_worker())


func _deferred_attach() -> void:
	var text: String = _actions.toggle_attachment()
	_notify(text)
	print(text)


func _notify(text: String) -> void:
	if not text.is_empty():
		_hud.notify(text)
