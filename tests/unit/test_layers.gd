extends "res://tests/framework/test_case.gd"
## Reguła zależności warstw (docs/ARCHITEKTURA_DOCELOWA.md, rozdział 3): preload w danej warstwie
## może wskazywać tylko warstwy dozwolone; core nie tworzy węzłów i nie czyta plików.

const ALLOWED := {
	"core": ["core"],
	"data": ["core", "data"],
	"sim": ["core", "data", "sim"],
	"views": ["core", "views", "sim/machines/machines.gd"],
	"ui": ["core", "ui", "views", "sim/machines/machines.gd"],
	"app": ["app", "core", "data", "sim", "views", "ui"],
}
const FILE_IO: Array[String] = ["FileAccess.open", "FileAccess.file_exists", "get_file_as_string", "ConfigFile.new", "DirAccess."]


func _files(directory: String) -> PackedStringArray:
	var result := PackedStringArray()
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	for sub in dir.get_directories():
		result.append_array(_files(directory.path_join(sub)))
	for file in dir.get_files():
		if file.ends_with(".gd"):
			result.append(directory.path_join(file))
	return result


func _preloads(text: String) -> PackedStringArray:
	var result := PackedStringArray()
	var regex := RegEx.create_from_string("(?:preload|extends)\\s*\\(?\\s*\"res://scripts/([^\"]+)\"")
	for found in regex.search_all(text):
		result.append(found.get_string(1))
	return result


func test_preloads_follow_layer_rules() -> void:
	for layer in ALLOWED:
		for path in _files("res://scripts/" + layer):
			var text: String = FileAccess.get_file_as_string(path)
			for target in _preloads(text):
				var ok: bool = false
				for allowed in ALLOWED[layer]:
					ok = ok or target == allowed or target.begins_with(allowed + "/")
				assert_true(ok, "%s → %s (warstwa %s)" % [path.trim_prefix("res://scripts/"), target, layer])


func test_core_has_no_nodes_and_no_file_io() -> void:
	for path in _files("res://scripts/core"):
		var text: String = FileAccess.get_file_as_string(path)
		assert_true(text.begins_with("extends RefCounted"), path + " musi być RefCounted")
		for call in FILE_IO:
			assert_false(text.contains(call), "%s używa %s" % [path, call])
		assert_false(text.contains(".new()") and (text.contains("Node2D.new()") or text.contains("Node.new()")), path + " tworzy węzły")


func test_presentation_does_not_reach_into_world() -> void:
	for layer in ["views", "ui"]:
		for path in _files("res://scripts/" + layer):
			var text: String = FileAccess.get_file_as_string(path)
			assert_false(text.contains("world.call("), path + " woła świat bezpośrednio")
			assert_false(text.contains("_ground_body") or text.contains("_carrier"), path + " czyta pola prywatne maszyn")
