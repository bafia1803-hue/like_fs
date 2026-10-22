extends SceneTree
## Runner testów (bez zewnętrznych wtyczek).
##
##   godot --headless --path . -s tests/run_tests.gd                 – wszystkie testy
##   godot --headless --path . -s tests/run_tests.gd -- unit         – tylko jednostkowe
##   godot --headless --path . -s tests/run_tests.gd -- integration  – tylko integracyjne
##   godot --headless --path . -s tests/run_tests.gd -- unit field   – filtr nazwy pliku
##
## Każdy plik tests/<rodzaj>/test_*.gd rozszerza framework/test_case.gd; metody test_* mogą
## używać await (np. klatek fizyki). Kod wyjścia = liczba nieudanych testów (0 = sukces).

const SUITES: Array[String] = ["unit", "integration"]

var _passed: int = 0
var _failed: int = 0
var _failures: PackedStringArray = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var suites: Array[String] = SUITES.duplicate()
	var name_filter: String = ""
	if not args.is_empty() and SUITES.has(args[0]):
		suites = [args[0]]
		if args.size() > 1:
			name_filter = args[1]
	elif not args.is_empty():
		name_filter = args[0]
	var started: int = Time.get_ticks_msec()
	for suite in suites:
		for path in _collect("res://tests/" + suite):
			if name_filter.is_empty() or path.get_file().contains(name_filter):
				await _run_file(path)
	print("")
	for line in _failures:
		print(line)
	print("\nTesty: %d zaliczonych, %d nieudanych (%.1f s)" % [_passed, _failed, (Time.get_ticks_msec() - started) / 1000.0])
	quit(mini(_failed, 125))


func _collect(directory: String) -> PackedStringArray:
	var result := PackedStringArray()
	var dir := DirAccess.open(directory)
	if dir == null:
		return result
	for sub in dir.get_directories():
		result.append_array(_collect(directory.path_join(sub)))
	for file in dir.get_files():
		if file.begins_with("test_") and file.ends_with(".gd"):
			result.append(directory.path_join(file))
	result.sort()
	return result


func _run_file(path: String) -> void:
	var script: GDScript = load(path)
	if script == null or not script.can_instantiate():
		_failed += 1
		_failures.append("BŁĄD WCZYTANIA: " + path)
		return
	print("● ", path.trim_prefix("res://tests/"))
	var methods: Array = []
	for method in script.get_script_method_list():
		var method_name: String = method["name"]
		if method_name.begins_with("test_") and not methods.has(method_name):
			methods.append(method_name)
	for method_name in methods:
		var case = script.new()
		case.tree = self
		case.current_test = method_name
		await case.before_each()
		await case.call(method_name)
		await case.after_each()
		if case.failures.is_empty():
			_passed += 1
			print("    ✓ ", method_name)
		else:
			_failed += 1
			print("    ✗ ", method_name)
			for failure in case.failures:
				_failures.append("%s :: %s — %s" % [path.get_file(), method_name, failure])
