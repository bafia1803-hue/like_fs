extends RefCounted
## Odczyt dokumentu JSON (obiekt na najwyższym poziomie) z czytelnym błędem.

var last_error: String = ""


## Obiekt z pliku albo pusty słownik (wtedy last_error opisuje problem).
func read_object(path: String) -> Dictionary:
	last_error = ""
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "Nie można otworzyć pliku: %s. Kod błędu: %s" % [path, FileAccess.get_open_error()]
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parser := JSON.new()
	if parser.parse(text) != OK:
		last_error = "Błąd JSON w %s, linia %d: %s" % [path, parser.get_error_line(), parser.get_error_message()]
		return {}
	if not parser.data is Dictionary:
		last_error = "Główny element JSON musi być obiektem: " + path
		return {}
	var result: Dictionary = parser.data
	if result.is_empty():
		last_error = "Plik zawiera pusty obiekt: " + path
	return result
