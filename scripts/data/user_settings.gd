extends RefCounted
## Ustawienia gracza niezależne od zapisu gry (user://settings.cfg): tryb widoku, pełny ekran.

const DEFAULT_PATH: String = "user://settings.cfg"

var path: String = DEFAULT_PATH


func get_value(section: String, key: String, default_value: Variant) -> Variant:
	var config := ConfigFile.new()
	if config.load(path) != OK:
		return default_value
	return config.get_value(section, key, default_value)


func set_value(section: String, key: String, value: Variant) -> void:
	var config := ConfigFile.new()
	config.load(path)
	config.set_value(section, key, value)
	config.save(path)
