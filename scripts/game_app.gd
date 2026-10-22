extends Node
const SaveManagerScript = preload("res://scripts/save_manager.gd")
const MenuScript = preload("res://scripts/start_menu.gd")
const WorldScript = preload("res://scripts/world.gd")
const DisplaySettings = preload("res://scripts/display_settings.gd")
var manager = SaveManagerScript.new()
var _menu: Control
var _world: Node
var _active_slot: int = 0
var _busy: bool = false
var _starting_new: bool = false
var _load_warning: String = ""
var _error_dialog: AcceptDialog
## Łączny czas gry: bez zegara w tle – przy każdym zapisie dodaje się czas od poprzedniego zapisu
## (albo od wejścia do gry). _play_time_s to suma z ostatniego zapisu, _play_mark – chwila tego zapisu.
var _play_time_s: float = 0.0
var _play_mark: float = 0.0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	DisplaySettings.apply_saved()
	get_tree().auto_accept_quit = false
	var menu = MenuScript.new()
	menu.name = "StartMenu"
	menu.configure(manager)
	menu.start_requested.connect(_request_start)
	menu.quit_requested.connect(func(): request_action("quit"))
	add_child(menu)
	_menu = menu
	_error_dialog = AcceptDialog.new()
	_error_dialog.title = "Nie udało się zapisać gry"
	_error_dialog.ok_button_text = "Wróć do gry"
	add_child(_error_dialog)

## F11: pełny ekran / okno – w menu i w grze (także w pauzie, bo GameApp działa zawsze).
func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F11:
		DisplaySettings.toggle()
		get_viewport().set_input_as_handled()

func _request_start(slot: int, new_game: bool) -> void:
	if _busy or is_instance_valid(_world):
		return
	_busy = true
	_menu.call("set_busy", true)
	_menu.call("set_message", "Wczytywanie świata…")
	call_deferred("_start", slot, new_game)

func _start(slot: int, new_game: bool) -> void:
	var saved: Dictionary = {}
	var previous_play_time: float = 0.0
	_load_warning = ""
	if not new_game:
		var document: Dictionary = manager.read_slot(slot)
		if document.is_empty():
			_busy = false
			_menu.call("set_busy", false)
			_menu.call("set_message", manager.last_error)
			return
		saved = document["game"]
		previous_play_time = SaveManagerScript.play_time_s(document)
		_load_warning = manager.last_warning
	_active_slot = slot
	_starting_new = new_game
	_play_time_s = previous_play_time
	_play_mark = Time.get_unix_time_from_system()
	var world = WorldScript.new()
	world.name = "World"
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	world.saved_game = saved
	world.save_slot = slot
	world.managed_by_menu = true
	world.world_ready.connect(_on_world_ready, CONNECT_DEFERRED)
	world.world_failed.connect(_on_world_failed, CONNECT_DEFERRED)
	world.save_requested.connect(func(): request_action("save"))
	world.menu_requested.connect(func(): request_action("menu"))
	world.quit_requested.connect(func(): request_action("quit"))
	_world = world
	_menu.hide()
	add_child(world)

func _on_world_ready() -> void:
	_busy = false
	if _starting_new:
		request_action("save") # Slot jest tworzony dopiero po poprawnym uruchomieniu świata.
	elif not _load_warning.is_empty():
		_world.call("show_save_message", _load_warning)

func _on_world_failed(message: String) -> void:
	get_tree().paused = false
	if is_instance_valid(_world):
		_world.free()
	_world = null
	_active_slot = 0
	_busy = false
	_menu.show()
	_menu.call("refresh")
	_menu.call("set_message", "Nie udało się wczytać gry: " + message)

func request_action(action: String) -> void:
	if _busy:
		return
	if not is_instance_valid(_world):
		if action == "quit":
			get_tree().quit()
		return
	_busy = true
	call_deferred("_perform_action", action)

func _perform_action(action: String) -> void:
	# Callback odroczony kończy bieżące aktualizacje fizyki/sterowania.
	# Zebranie danych i zapis są synchroniczne; świat nie zmienia się pomiędzy nimi.
	var previous_pause: bool = get_tree().paused
	get_tree().paused = true
	var game: Dictionary = _world.call("capture_save")
	var now: float = Time.get_unix_time_from_system()
	var total: float = _play_time_s + maxf(now - _play_mark, 0.0)
	var success: bool = manager.write_slot(_active_slot, game, {"play_time_s": roundf(total)})
	if not success:
		get_tree().paused = previous_pause
		_busy = false
		_world.call("show_save_message", "Błąd zapisu: " + manager.last_error)
		_error_dialog.dialog_text = manager.last_error + "\nGra pozostała otwarta. Spróbuj zapisać ponownie."
		_error_dialog.popup_centered(Vector2i(520, 200))
		return
	_play_time_s = total
	_play_mark = now
	if action == "quit":
		get_tree().quit()
		return
	if action == "menu":
		_world.free()
		_world = null
		_active_slot = 0
		get_tree().paused = false
		_menu.show()
		_menu.call("refresh")
		_menu.call("set_message", "Gra została zapisana.")
	else:
		get_tree().paused = previous_pause
		_world.call("show_save_message", "Zapisano grę w slocie %d." % _active_slot)
	_busy = false

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_WM_GO_BACK_REQUEST:
		request_action("quit")
