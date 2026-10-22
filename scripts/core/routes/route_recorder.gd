extends RefCounted
## Nagrywanie trasy – czysta logika doboru próbek.
## Próbki co sample_seconds, a przy zmianie ruchu (start/postój), pracy narzędzia (B) albo
## początku/końcu składania dwie próbki (poprzednia i bieżąca), żeby odtworzenie przełączyło
## się dokładnie w tym miejscu. Postoje też są nagrywane.

const Sample = preload("res://scripts/core/routes/route_sample.gd")

var samples: Array = []
var time: float = 0.0
var sample_seconds: float = 0.05
var _next: float = 0.0
var _previous: Array = []
var _moving: bool = false


func start(first: Array, seconds_per_sample: float) -> void:
	sample_seconds = seconds_per_sample
	samples = [first]
	time = 0.0
	_next = sample_seconds
	_previous = first
	_moving = false


## Przesuwa zegar nagrania; potem wołający pobiera próbkę w nowej chwili i podaje ją do record().
func advance(delta: float) -> float:
	time += delta
	return time


func record(point: Array, moving: bool) -> void:
	var previous_fold: float = float(_previous[Sample.TOOL_UNFOLDED])
	var fold: float = float(point[Sample.TOOL_UNFOLDED])
	var fold_edge: bool = (previous_fold > 0.0 and previous_fold < 1.0) != (fold > 0.0 and fold < 1.0)
	if moving != _moving or float(point[Sample.TOOL_WORKING]) != float(_previous[Sample.TOOL_WORKING]) or fold_edge:
		append(_previous)
		append(point)
		_moving = moving
	if time + 0.0000001 >= _next:
		append(point)
		while _next <= time + 0.0000001:
			_next += sample_seconds
	_previous = point


## Dodaje próbkę; próbka z tą samą chwilą co ostatnia zastępuje ją, starsza jest pomijana.
func append(point: Array) -> void:
	if is_equal_approx(float(samples[-1][0]), float(point[0])):
		samples[-1] = point
	elif float(point[0]) > float(samples[-1][0]):
		samples.append(point)


## Ostatnia próbka nagrania. Zwraca false, gdy nagranie jest zbyt krótkie, by je zachować.
func finish(last: Array) -> bool:
	append(last)
	return samples.size() >= 2 and time >= 0.1
