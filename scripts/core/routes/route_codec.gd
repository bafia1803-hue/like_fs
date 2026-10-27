extends RefCounted
## Zwarty zapis próbek trasy w pliku gry – czysta logika.
##
## W pamięci trasa ma "samples" (tablica tablic liczb, route_data.gd). W zapisie gry próbki są
## kodowane jako "samples_packed": każda kolumna osobno, liczby stałoprzecinkowe (SCALES),
## zapisane jako różnice kolejnych próbek (int32), skompresowane deflate i base64.
## Ruch jest płynny, więc różnice są małe i powtarzalne – 30-minutowe nagranie zajmuje
## zamiast kilku MB tekstu JSON zwykle kilkadziesiąt–kilkaset kB.
##
## Dokładność: czas 0,1 ms, położenie 0,1 mm, kąty 0,01 mrad, skręt i rozłożenie 1e-4.
## Trasa, której czasy po zaokrągleniu przestałyby rosnąć, zostaje zapisana bez kodowania.

const ENCODING: String = "route_q_v1"
## Mnożnik stałoprzecinkowy każdej kolumny (route_sample.gd).
const SCALES: Array[float] = [10000.0, 10000.0, 10000.0, 100000.0, 100000.0, 100000.0, 10000.0, 1.0, 10000.0]


## Kopia trasy do zapisu (z "samples_packed" zamiast "samples", gdy kodowanie się udało).
static func pack(route: Dictionary) -> Dictionary:
	var samples: Array = route.get("samples", [])
	if samples.size() < 2:
		return route.duplicate(true)
	var columns: int = (samples[0] as Array).size()
	if columns > SCALES.size():
		return route.duplicate(true)
	var rows: int = samples.size()
	var values := PackedInt32Array()
	values.resize(rows * columns)
	for column in columns:
		var scale: float = SCALES[column]
		var previous: int = 0
		for row in rows:
			var quantized: int = roundi(float(samples[row][column]) * scale)
			if column == 0 and row > 0 and quantized <= previous:
				return route.duplicate(true)       # czasy zlałyby się po zaokrągleniu
			values[column * rows + row] = quantized - previous
			previous = quantized
	var packed: Dictionary = route.duplicate(true)
	packed.erase("samples")
	packed["samples_packed"] = {"encoding": ENCODING, "rows": rows, "columns": columns,
		"data": Marshalls.raw_to_base64(values.to_byte_array().compress(FileAccess.COMPRESSION_DEFLATE))}
	return packed


## Trasa z zapisu z odtworzonymi "samples" (trasy bez kodowania wracają bez zmian).
## Pusty słownik, gdy dane są uszkodzone.
static func unpack(route: Dictionary) -> Dictionary:
	if not route.get("samples_packed") is Dictionary:
		return route
	var packed: Dictionary = route["samples_packed"]
	var rows: int = int(packed.get("rows", 0))
	var columns: int = int(packed.get("columns", 0))
	if str(packed.get("encoding", "")) != ENCODING or rows < 2 or columns < 1 or columns > SCALES.size() or not packed.get("data") is String:
		return {}
	var raw: PackedByteArray = Marshalls.base64_to_raw(str(packed["data"])).decompress(rows * columns * 4, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != rows * columns * 4:
		return {}
	var values: PackedInt32Array = raw.to_int32_array()
	var samples: Array = []
	samples.resize(rows)
	for row in rows:
		var sample: Array = []
		sample.resize(columns)
		samples[row] = sample
	for column in columns:
		var scale: float = SCALES[column]
		var total: int = 0
		for row in rows:
			total += values[column * rows + row]
			samples[row][column] = float(total) / scale
	var result: Dictionary = route.duplicate(true)
	result.erase("samples_packed")
	result["samples"] = samples
	return result
