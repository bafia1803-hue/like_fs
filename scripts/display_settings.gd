extends RefCounted
## Tryb okna: pełny ekran albo okno. Zapamiętywany w user://settings.cfg ([display] fullscreen).
## Domyślnie pełny ekran. F11 przełącza (obsługuje GameApp, działa w menu i w grze).

const SETTINGS_PATH: String = "user://settings.cfg"


static func is_fullscreen() -> bool:
	var mode: int = DisplayServer.window_get_mode()
	return mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN


## Ustawia tryb zapisany w ustawieniach (wywołać raz przy starcie gry).
static func apply_saved() -> void:
	var config := ConfigFile.new()
	config.load(SETTINGS_PATH)
	set_fullscreen(bool(config.get_value("display", "fullscreen", true)), false)


static func toggle() -> void:
	set_fullscreen(not is_fullscreen())


static func set_fullscreen(on: bool, save: bool = true) -> void:
	if DisplayServer.get_name() == "headless":
		return
	if on:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		# Po wyjściu z pełnego ekranu: wygodne, duże okno na środku ekranu.
		var screen: Rect2i = DisplayServer.screen_get_usable_rect()
		var size := Vector2i(int(screen.size.x * 0.8), int(screen.size.y * 0.8))
		DisplayServer.window_set_size(size)
		DisplayServer.window_set_position(screen.position + (screen.size - size) / 2)
	if save:
		var config := ConfigFile.new()
		config.load(SETTINGS_PATH)
		config.set_value("display", "fullscreen", on)
		config.save(SETTINGS_PATH)
