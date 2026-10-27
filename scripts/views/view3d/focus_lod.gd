extends RefCounted
## Poziomy szczegółów wokół punktu skupienia (pojazd gracza albo miejsce, na które patrzy kamera).
## Kawałki (chunki) włącza się tylko zgrubnie – płynne przejścia robi shader osobno dla każdej
## kępki (crop.gdshader, grass_tuft.gdshader), więc granice kawałków nie są widoczne.

## Odległość punktu od prostokąta: x = najbliższy punkt prostokąta, y = najdalszy narożnik.
static func rect_distance(point: Vector2, rect: Rect2) -> Vector2:
	var nearest := Vector2(clampf(point.x, rect.position.x, rect.end.x), clampf(point.y, rect.position.y, rect.end.y))
	var farthest: float = 0.0
	for corner in [rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)]:
		farthest = maxf(farthest, point.distance_to(corner))
	return Vector2(point.distance_to(nearest), farthest)


## Czy kawałek potrzebuje poziomu szczegółowego: jakaś jego część bliżej niż detail_end.
static func needs_detail(distance: Vector2, detail_end: float) -> bool:
	return detail_end > 0.0 and distance.x < detail_end


## Czy kawałek potrzebuje poziomu prostego: część w paśmie przejścia albo dalej, ale przed visible_end.
static func needs_simple(distance: Vector2, detail_end: float, fade_m: float, visible_end: float) -> bool:
	return distance.y > detail_end - fade_m and distance.x < visible_end
