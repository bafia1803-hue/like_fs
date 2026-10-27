extends RefCounted
## Poziomy szczegółów wokół punktu skupienia (pojazd gracza albo miejsce, na które patrzy kamera).
## Płynne przejścia robi shader osobno dla każdej kępki (crop.gdshader, grass_tuft.gdshader), więc
## granice kawałków (chunków) nie są widoczne. CPU co kilka metrów ruchu liczy dla każdego kawałka,
## ILE jego kępek może być widocznych, i rysuje tylko tyle (MultiMesh.visible_instance_count):
## kępki w kawałku są posortowane wg liczby losowej r, a shader chowa je w tej samej kolejności –
## dzięki temu karta w ogóle nie dostaje kępek, które i tak byłyby schowane (a nie tylko je spłaszcza).
##
## Reguły (te same w shaderach):
##   – poziom szczegółowy pokazuje kępki z r >= to_simple(d), prosty – z r < to_simple(d),
##   – kępka znika (wsiąka), gdy keep(d) <= r · THIN_SLOPE.

const THIN_SLOPE: float = 0.92


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


## Udział wersji prostej w odległości d (0 – same szczegółowe, 1 – same proste).
static func to_simple(d: float, detail_end: float, fade_m: float) -> float:
	return clampf((d - (detail_end - fade_m)) / maxf(fade_m, 0.001), 0.0, 1.0)


## Ile kępek zostaje w odległości d (1 – wszystkie, 0 – żadna).
static func keep(d: float, thin_start: float, visible_end: float) -> float:
	return 1.0 - smoothstep(thin_start, visible_end, d)


## Liczba wartości mniejszych od limit w tablicy posortowanej rosnąco.
static func count_below(sorted: PackedFloat32Array, limit: float) -> int:
	return sorted.bsearch(limit, true)


## Ile kępek kawałka (r posortowane rosnąco) może pokazać poziom szczegółowy;
## near = najmniejsza odległość kawałka od punktu skupienia.
static func detail_count(sorted: PackedFloat32Array, near: float, detail_end: float, fade_m: float) -> int:
	if detail_end <= 0.0 or near >= detail_end:
		return 0
	return sorted.size() - count_below(sorted, to_simple(near, detail_end, fade_m))


## Ile kępek kawałka może pokazać poziom prosty (near/far – najbliższy i najdalszy punkt kawałka).
static func simple_count(sorted: PackedFloat32Array, near: float, far: float, detail_end: float,
		fade_m: float, thin_start: float, visible_end: float) -> int:
	if near >= visible_end:
		return 0
	var limit: float = minf(to_simple(far, detail_end, fade_m), keep(near, thin_start, visible_end) / THIN_SLOPE)
	return count_below(sorted, limit + 0.0001)


## Ile kępek trawy kawałka może być widocznych (trawa ma jeden poziom).
static func thin_count(sorted: PackedFloat32Array, near: float, thin_start: float, visible_end: float) -> int:
	if near >= visible_end:
		return 0
	return count_below(sorted, keep(near, thin_start, visible_end) / THIN_SLOPE + 0.0001)
