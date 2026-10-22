extends RefCounted
## Trzy niezależne sloty, plik tymczasowy i poprzedni poprawny zapis .bak.
const FORMAT_VERSION: int = 1
var directory: String = "user://saves"
var last_error: String = ""
var last_warning: String = ""

func slot_path(slot: int) -> String:
	return directory.path_join("slot_%d.json" % slot)

## session: {"entered_at", "left_at"} – czas lokalny wejścia do gry i wyjścia (ostatniego zapisu) dla menu.
func write_slot(slot: int, game: Dictionary, session: Dictionary = {}) -> bool:
	last_error = ""
	if slot < 1 or slot > 3:
		return _fail("Niepoprawny numer slotu.")
	if not _game_shape_valid(game):
		return _fail("Niekompletny stan gry — zapis anulowany.")
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		return _fail("Nie można utworzyć katalogu zapisów: " + directory)
	var path: String = slot_path(slot)
	var temporary: String = path + ".tmp"
	var document: Dictionary = {"format_version": FORMAT_VERSION, "slot": slot,
		"saved_at_utc": Time.get_datetime_string_from_system(true), "session": session, "game": game}
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _fail("Nie można otworzyć pliku zapisu. Kod: " + str(FileAccess.get_open_error()))
	file.store_string(JSON.stringify(document))
	file.flush()
	var error: Error = file.get_error()
	file.close()
	if error != OK or _read_document(temporary, slot).is_empty():
		return _fail("Nie udało się zapisać lub sprawdzić pliku tymczasowego.")
	# Nie zastępuj poprawnej kopii awaryjnej uszkodzonym plikiem głównym.
	if not _read_document(path, slot).is_empty():
		var backup_temp: String = path + ".bak.tmp"
		if DirAccess.copy_absolute(path, backup_temp) != OK:
			return _fail("Nie udało się przygotować kopii poprzedniego zapisu.")
		if DirAccess.rename_absolute(backup_temp, path + ".bak") != OK:
			return _fail("Nie udało się zatwierdzić kopii poprzedniego zapisu.")
	if DirAccess.rename_absolute(temporary, path) != OK:
		return _fail("Nie udało się zatwierdzić nowego zapisu. Poprzednia wersja jest zachowana.")
	return true

func read_slot(slot: int) -> Dictionary:
	last_error = ""
	last_warning = ""
	if slot < 1 or slot > 3:
		_fail("Niepoprawny numer slotu.")
		return {}
	var document: Dictionary = _read_document(slot_path(slot), slot)
	if not document.is_empty():
		return document
	document = _read_document(slot_path(slot) + ".bak", slot)
	if not document.is_empty():
		last_warning = "Odtworzono poprzednią kopię zapisu; plik główny był niedostępny lub uszkodzony."
		return document
	_fail("Brak poprawnego zapisu w slocie %d i jego kopii awaryjnej." % slot)
	return {}

func slot_info(slot: int) -> Dictionary:
	var occupied: bool = FileAccess.file_exists(slot_path(slot)) or FileAccess.file_exists(slot_path(slot) + ".bak")
	if not occupied:
		return {"occupied": false, "loadable": false, "description": "Puste miejsce"}
	var document: Dictionary = read_slot(slot)
	if document.is_empty():
		return {"occupied": true, "loadable": false, "description": "Uszkodzony lub nieobsługiwany zapis"}
	var label: String = "Zapis: " + str(document["saved_at_utc"]).replace("T", " ") + " UTC"
	if not last_warning.is_empty():
		label += "\nDostępna kopia awaryjna"
	# Skrót stanu gry dla karty slotu w menu.
	var game: Dictionary = document.get("game", {})
	var money: Variant = game.get("economy", {}).get("money") if game.get("economy") is Dictionary else null
	return {"occupied": true, "loadable": true, "description": label,
		"entered_at": _session_time(document, "entered_at"),
		"left_at": _session_time(document, "left_at"),
		"money": float(money) if money != null else -1.0}

## „2026-10-22T16:01:33” -> „22.10.2026, 16:01”; brak (stare zapisy) -> "".
func _session_time(document: Dictionary, key: String) -> String:
	var session: Variant = document.get("session")
	if not session is Dictionary or not session.get(key) is String:
		return ""
	var stamp: String = session[key]
	if stamp.length() < 16:
		return ""
	return "%s.%s.%s, %s" % [stamp.substr(8, 2), stamp.substr(5, 2), stamp.substr(0, 4), stamp.substr(11, 5)]

func _read_document(path: String, slot: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		return {}
	var document: Dictionary = parser.data
	if int(document.get("format_version", -1)) != FORMAT_VERSION or int(document.get("slot", -1)) != slot:
		return {}
	if not document.get("game") is Dictionary or not _game_shape_valid(document["game"]):
		return {}
	if not document.get("saved_at_utc") is String:
		return {}
	return document

func _game_shape_valid(game: Dictionary) -> bool:
	for key in ["machine_instances", "connections", "field_states"]:
		if not game.get(key) is Array:
			return false
	return game.get("player") is Dictionary and game.get("references") is Dictionary and not game["machine_instances"].is_empty()

func _fail(message: String) -> bool:
	last_error = message
	return false
