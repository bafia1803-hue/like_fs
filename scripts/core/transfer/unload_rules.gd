extends RefCounted
## Zasady rozładunku przyczep i naczep – czysta logika.
##   tipper   – wywrotka: po opóźnieniu cały ładunek w jednym kroku,
##   conveyor – taśmociąg w podłodze: po otwarciu drzwi stały strumień max_transfer_l_per_s.


## Odliczanie opóźnienia nad miejscem rozładunku. Zmienia state ("zone_id", "start_elapsed_seconds").
## Zwraca liczbę sekund tego kroku, w których ziarno już płynie (0 w trakcie odliczania).
static func delay_step(state: Dictionary, zone_id: String, delay: float, delta: float) -> float:
	if str(state.get("zone_id", "")) != zone_id:
		state["zone_id"] = zone_id
		state["start_elapsed_seconds"] = 0.0
	var elapsed: float = clampf(float(state.get("start_elapsed_seconds", 0.0)), 0.0, delay)
	var usable: float = maxf(0.0, delta - maxf(0.0, delay - elapsed))
	state["start_elapsed_seconds"] = minf(delay, elapsed + delta)
	return usable


## Zerowanie odliczania po opuszczeniu miejsca rozładunku.
static func leave_zone(state: Dictionary) -> void:
	state["zone_id"] = ""
	state["start_elapsed_seconds"] = 0.0


## Ile litrów może wypłynąć w tym kroku: wywrotka bez limitu, taśmociąg wg wydajności.
static func limit_l(mode: String, rate_l_per_s: float, usable_seconds: float) -> float:
	return rate_l_per_s * usable_seconds if mode == "conveyor" else INF


## Komunikat po kroku rozładunku.
static func status(mode: String, target_kind: String, moved: float, delta: float) -> String:
	if moved <= 0.0:
		return "Skup nie przyjmuje tego ziarna" if target_kind == "sell" else "Silos pełny lub nie przyjmuje tego ziarna"
	if mode == "conveyor":
		return ("Sprzedaż" if target_kind == "sell" else "Rozładunek") + ": %.0f l/s" % (moved / delta)
	return ("Sprzedano %.0f l" if target_kind == "sell" else "Zrzucono %.0f l") % moved
