extends RefCounted
## Wczytuje sesję gry: szablon zapisu (save.json) z odwołaniami do mapy i katalogu maszyn,
## sprawdza zgodność identyfikatorów i wersji, indeksuje modele, egzemplarze i pola.

const JsonFile = preload("res://scripts/data/json_file.gd")

var last_error: String = ""


func load_session(save_path: String) -> Dictionary:
	last_error = ""

	var save_data: Dictionary = _read_object(save_path)
	if save_data.is_empty():
		return {}

	var save_type: String = str(save_data.get("document_type", ""))
	if save_type not in ["save_template", "save_game"]:
		_fail("Nieobsługiwany typ pliku zapisu: " + save_type)
		return {}

	if save_data.get("schema_version") != 1:
		_fail("Nieobsługiwana wersja zapisu.")
		return {}

	var references: Dictionary = _get_dictionary(
		save_data, "references", "save.json"
	)
	if not last_error.is_empty():
		return {}

	var map_reference: Dictionary = _get_dictionary(
		references, "map", "references"
	)
	var catalog_reference: Dictionary = _get_dictionary(
		references, "machine_catalog", "references"
	)
	if not last_error.is_empty():
		return {}

	var base_directory: String = save_path.get_base_dir()
	var map_path: String = _resolve_reference(
		base_directory, map_reference
	)
	var catalog_path: String = _resolve_reference(
		base_directory, catalog_reference
	)
	if not last_error.is_empty():
		return {}

	var map_data: Dictionary = _read_object(map_path)
	if map_data.is_empty():
		return {}

	var catalog_data: Dictionary = _read_object(catalog_path)
	if catalog_data.is_empty():
		return {}

	if not _check_document(map_data, "map_definition"):
		return {}

	if not _check_document(catalog_data, "machine_catalog"):
		return {}

	if map_data.get("map_id") != map_reference.get("id"):
		_fail("ID mapy nie zgadza się z odwołaniem w save.json.")
		return {}

	if map_data.get("map_revision") != map_reference.get("revision"):
		_fail("Wersja mapy nie zgadza się z zapisem.")
		return {}

	if catalog_data.get("catalog_id") != catalog_reference.get("id"):
		_fail("ID katalogu maszyn nie zgadza się z zapisem.")
		return {}

	if catalog_data.get("catalog_revision") != catalog_reference.get("revision"):
		_fail("Wersja katalogu maszyn nie zgadza się z zapisem.")
		return {}

	var models: Dictionary = _index_items(
		catalog_data.get("machines"),
		"id",
		"Katalog maszyn"
	)
	if not last_error.is_empty():
		return {}

	var instances: Dictionary = _index_items(
		save_data.get("machine_instances"),
		"instance_id",
		"Egzemplarze maszyn"
	)
	if not last_error.is_empty():
		return {}

	for instance_id in instances:
		var instance: Dictionary = instances[instance_id]
		var model_id: String = str(instance.get("model_id", ""))

		if not models.has(model_id):
			_fail(
				"Maszyna %s odwołuje się do nieznanego modelu: %s"
				% [instance_id, model_id]
			)
			return {}

	var fields: Dictionary = _index_items(
		map_data.get("fields"),
		"id",
		"Pola na mapie"
	)
	if not last_error.is_empty():
		return {}

	var field_states: Dictionary = _index_items(
		save_data.get("field_states"),
		"field_id",
		"Stany pól"
	)
	if not last_error.is_empty():
		return {}

	for field_id in fields:
		if not field_states.has(field_id):
			_fail("Brak stanu pola w zapisie: " + str(field_id))
			return {}

	for field_id in field_states:
		if not fields.has(field_id):
			_fail("Zapis zawiera nieznane pole: " + str(field_id))
			return {}

	return {
		"save_data": save_data,
		"map_data": map_data,
		"catalog_data": catalog_data,
		"models_by_id": models,
		"instances_by_id": instances,
		"field_states_by_id": field_states
	}


func _read_object(path: String) -> Dictionary:
	var reader = JsonFile.new()
	var result: Dictionary = reader.read_object(path)
	if not reader.last_error.is_empty():
		_fail(reader.last_error)
	return result


func _get_dictionary(
	source: Dictionary,
	key: String,
	context: String
) -> Dictionary:
	var value: Variant = source.get(key)

	if not value is Dictionary:
		_fail("Brak obiektu '%s' w %s." % [key, context])
		return {}

	return value


func _resolve_reference(
	base_directory: String,
	reference: Dictionary
) -> String:
	var filename: Variant = reference.get("file")

	if not filename is String or str(filename).is_empty():
		_fail("Odwołanie do pliku nie zawiera poprawnego pola 'file'.")
		return ""

	var path: String = filename

	if path.begins_with("res://") or path.begins_with("user://"):
		return path

	return base_directory.path_join(path).simplify_path()


func _check_document(
	document: Dictionary,
	expected_type: String
) -> bool:
	if document.get("document_type") != expected_type:
		_fail("Oczekiwany document_type: " + expected_type)
		return false

	if document.get("schema_version") != 1:
		_fail("Nieobsługiwany schema_version w " + expected_type)
		return false

	return true


func _index_items(
	items: Variant,
	id_key: String,
	context: String
) -> Dictionary:
	var result: Dictionary = {}

	if not items is Array:
		_fail(context + ": oczekiwano tablicy.")
		return {}

	for item in items:
		if not item is Dictionary:
			_fail(context + ": każdy element musi być obiektem.")
			return {}

		var item_data: Dictionary = item
		var item_id: Variant = item_data.get(id_key)

		if not item_id is String or str(item_id).is_empty():
			_fail(context + ": brak poprawnego " + id_key)
			return {}

		if result.has(item_id):
			_fail(context + ": powtórzone ID " + str(item_id))
			return {}

		result[item_id] = item_data

	return result


func _fail(message: String) -> void:
	# Zachowujemy pierwszy błąd, żeby kolejne go nie zasłoniły.
	if last_error.is_empty():
		last_error = message
		push_error("SessionLoader: " + message)
