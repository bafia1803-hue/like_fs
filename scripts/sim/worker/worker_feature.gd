extends RefCounted
## Włącznik funkcji pracownika (files/workers.json). Cała funkcja jest odcięta od reszty gry:
## gdy "enabled" jest false (albo plik nie istnieje), system pracownika nie powstaje, klawisz H
## nic nie robi, a w menu nie ma przycisku testu. Na mapach spoza "maps" też nie powstaje.

const JsonFile = preload("res://scripts/data/json_file.gd")
const WorkerSystemScript = preload("res://scripts/sim/worker/worker_system.gd")
const SETTINGS_PATH: String = "res://files/workers.json"


## Ustawienia pracownika ({} – funkcja wyłączona).
static func settings() -> Dictionary:
	if not FileAccess.file_exists(SETTINGS_PATH):
		return {}
	var data: Dictionary = JsonFile.new().read_object(SETTINGS_PATH)
	if data.is_empty() or not bool(data.get("enabled", false)):
		return {}
	return data


static func enabled_for(map_id: String) -> bool:
	var data: Dictionary = settings()
	return not data.is_empty() and Array(data.get("maps", [])).has(map_id)


## Zapis-szablon mapy testowej pracownika ("" – brak testu w menu).
static func test_save_path() -> String:
	var data: Dictionary = settings()
	var path: String = str(data.get("test_save", ""))
	return path if not path.is_empty() and FileAccess.file_exists(path) else ""


## Tworzy system pracownika, jeśli funkcja jest włączona dla mapy (inaczej null).
static func create(context: RefCounted) -> Node2D:
	var map_id: String = str(context.session["save_data"]["references"]["map"]["id"])
	if not enabled_for(map_id):
		return null
	var system = WorkerSystemScript.new()
	context.root.add_child(system)
	system.setup(context, settings())
	return system
