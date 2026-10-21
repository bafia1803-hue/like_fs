extends RefCounted
## Bazowy dostawca informacji dla Informatora.
## Nowy rodzaj informacji: utwórz skrypt "extends" tego pliku, nadpisz rows()
## i dopisz jego ścieżkę do Informator.PROVIDERS.
##
## Wiersz to słownik:
##   "label": String      – opis po lewej (wymagany)
##   "value": String      – wartość po prawej (opcjonalna)
##   "ratio": float       – 0..1 rysuje pasek postępu (opcjonalne, -1 = brak paska)
##   "color": Color       – kolor paska (opcjonalny)


## machine – maszyna z warstwy gry (pojazd albo podpięte narzędzie),
## role – "vehicle" albo "implement", world – interfejs świata (get_* w world.gd).
func rows(_machine: Node, _role: String, _world: Node) -> Array:
	return []
