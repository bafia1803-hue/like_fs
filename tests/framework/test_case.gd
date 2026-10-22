extends RefCounted
## Bazowa klasa testu. Asercje zapisują błędy (test biegnie dalej), runner zbiera wyniki.

var tree: SceneTree
var current_test: String = ""
var failures: PackedStringArray = []


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func fail(message: String) -> void:
	failures.append(message)


func assert_true(value: bool, message: String = "oczekiwano true") -> bool:
	if not value:
		fail(message)
	return value


func assert_false(value: bool, message: String = "oczekiwano false") -> bool:
	return assert_true(not value, message)


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	if typeof(actual) != typeof(expected) and not (_is_number(actual) and _is_number(expected)):
		fail("%s oczekiwano %s (%s), jest %s (%s)" % [message, str(expected), type_string(typeof(expected)), str(actual), type_string(typeof(actual))])
		return false
	if actual != expected:
		fail("%s oczekiwano %s, jest %s" % [message, str(expected), str(actual)])
		return false
	return true


func assert_near(actual: float, expected: float, epsilon: float = 0.0001, message: String = "") -> bool:
	if absf(actual - expected) > epsilon:
		fail("%s oczekiwano %.6f ± %.6f, jest %.6f" % [message, expected, epsilon, actual])
		return false
	return true


func assert_has(text: String, part: String, message: String = "") -> bool:
	if not text.contains(part):
		fail("%s tekst „%s” nie zawiera „%s”" % [message, text, part])
		return false
	return true


func assert_empty(text: String, message: String = "") -> bool:
	if not text.is_empty():
		fail("%s oczekiwano pustego tekstu, jest „%s”" % [message, text])
		return false
	return true


## Czeka n klatek fizyki (testy integracyjne).
func frames(count: int) -> void:
	for i in count:
		await tree.physics_frame


func _is_number(value: Variant) -> bool:
	return value is int or value is float
