extends RefCounted
## Ruch rury rozładunkowej kombajnu – czysta logika: rozkładanie, zwłoka przed złożeniem, składanie.
## extension: 0 = złożona, 1 = rozłożona. Stan (słownik z zapisu gry) aktualizowany co krok.

var extension: float = 0.0
var idle_seconds: float = 0.0
var extend_seconds: float = 1.0
var retract_seconds: float = 1.0
var close_delay_seconds: float = 0.0


func setup(config: Dictionary, saved_state: Dictionary) -> void:
	extend_seconds = maxf(0.001, float(config["extend_seconds"]))
	retract_seconds = maxf(0.001, float(config["retract_seconds"]))
	close_delay_seconds = maxf(0.0, float(config.get("close_delay_seconds", 0.0)))
	extension = clampf(float(saved_state.get("extension", 0.0)), 0.0, 1.0)
	idle_seconds = maxf(0.0, float(saved_state.get("idle_seconds", 0.0)))


## Zwraca liczbę sekund tego kroku, przez które rura była całkowicie otwarta.
func advance(want_open: bool, delta: float) -> float:
	var open_seconds: float = 0.0
	if want_open:
		idle_seconds = 0.0
		var remaining: float = (1.0 - extension) * extend_seconds
		extension = minf(1.0, extension + delta / extend_seconds)
		if extension >= 1.0:
			open_seconds = maxf(0.0, delta - remaining)
	else:
		var hold: float = minf(delta, maxf(0.0, close_delay_seconds - idle_seconds))
		idle_seconds += delta
		if extension >= 1.0:
			open_seconds = hold
		extension = maxf(0.0, extension - (delta - hold) / retract_seconds)
	return open_seconds


func write(saved_state: Dictionary) -> void:
	saved_state["extension"] = extension
	saved_state["idle_seconds"] = idle_seconds
