extends RefCounted
## Układanie kupionych maszyn na placu sklepu.
##
## Plac jest skanowany wierszami od lewego górnego rogu (krok STEP_M): pierwsze miejsce,
## w którym obrys nowej maszyny (+ odstęp) mieści się w placu i nie nachodzi na nic zajętego,
## wygrywa. Dzięki temu maszyny ustawiają się w równych rzędach wyrównanych do góry placu,
## a przy zajętym fragmencie algorytm sam przeskakuje dalej – niezależnie od rozmiaru maszyny.
## Po kolizji skok w prawo od razu za przeszkodę, więc sprawdzeń jest mało.

const STEP_M: float = 0.5


## lot: plac (metry, świat). footprint: obrys maszyny lokalnie (MachineFootprint.local_rect).
## occupied: zajęte prostokąty (metry, świat). Zwraca pozycję środka maszyny albo null.
static func find_spot(lot: Rect2, footprint: Rect2, occupied: Array, spacing: float) -> Variant:
	var size: Vector2 = footprint.size
	if size.x > lot.size.x or size.y > lot.size.y:
		return null
	var y: float = lot.position.y
	while y + size.y <= lot.end.y + 0.0001:
		var x: float = lot.position.x
		while x + size.x <= lot.end.x + 0.0001:
			var candidate := Rect2(Vector2(x, y), size)
			var skip_to: float = -INF
			for value in occupied:
				var other: Rect2 = value
				if candidate.grow(spacing).intersects(other):
					skip_to = maxf(skip_to, other.end.x + spacing)
			if skip_to == -INF:
				return candidate.position - footprint.position
			# Przeskok tuż za przeszkodę, wyrównany do siatki kroku.
			x = lot.position.x + ceilf((skip_to - lot.position.x) / STEP_M) * STEP_M
		y += STEP_M
	return null
