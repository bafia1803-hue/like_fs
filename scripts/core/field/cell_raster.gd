extends RefCounted
## Rasteryzacja wielokąta na siatce komórek pola – czysta logika.
## Komórka należy do obszaru, gdy jej środek leży w wielokącie (reguła parzystości, linia skanowania
## przez środki wierszy). Koszt: liczba wierszy × liczba krawędzi + liczba trafionych komórek,
## zamiast sprawdzania każdej komórki prostokąta otaczającego.


## points – wierzchołki w układzie komórek (1 = jedna komórka, (0,0) = lewy górny róg pola).
## Zwraca indeksy komórek (wiersz × columns + kolumna), wierszami od góry.
static func cells_in_polygon(points: PackedVector2Array, columns: int, rows: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	if points.size() < 3:
		return result
	var top: float = INF
	var bottom: float = -INF
	for point in points:
		top = minf(top, point.y)
		bottom = maxf(bottom, point.y)
	var first_row: int = maxi(0, ceili(top - 0.5))
	var last_row: int = mini(rows - 1, floori(bottom - 0.5))
	var crossings: Array[float] = []
	for y in range(first_row, last_row + 1):
		var center_y: float = y + 0.5
		crossings.clear()
		for i in points.size():
			var a: Vector2 = points[i]
			var b: Vector2 = points[(i + 1) % points.size()]
			if (a.y <= center_y) != (b.y <= center_y):
				crossings.append(a.x + (center_y - a.y) * (b.x - a.x) / (b.y - a.y))
		crossings.sort()
		for pair in range(0, crossings.size() - 1, 2):
			var from_x: int = maxi(0, ceili(crossings[pair] - 0.5))
			var to_x: int = mini(columns - 1, floori(crossings[pair + 1] - 0.5))
			for x in range(from_x, to_x + 1):
				result.append(y * columns + x)
	return result
