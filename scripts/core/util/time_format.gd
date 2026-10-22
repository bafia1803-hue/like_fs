extends RefCounted
## Formatowanie czasu dla interfejsu.


## Łączny czas gry "h:mm" (godziny bez górnej granicy, bez sekund), np. 3725 s -> "1:02".
static func play_time(seconds: float) -> String:
	var minutes: int = int(maxf(seconds, 0.0) / 60.0)
	return "%d:%02d" % [minutes / 60, minutes % 60]
