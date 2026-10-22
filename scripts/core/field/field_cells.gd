extends RefCounted
## Stan komórek jednego pola – czysta logika (bez węzłów i obrazów).
##
## Komórka: faza (Stage), gatunek (kod z CROP_IDS) i nawożenie (bity faz nawożenia):
##   FERT_BEFORE – nawiezione przed siewem (puste pole albo ściernisko),
##   FERT_GROWING – nawiezione w trakcie wzrostu (zasiane … przed dojrzałością).
## Każda faza liczy się raz, więc pole można nawieźć najwyżej dwa razy (poziom 0–2).
## Zbiór zużywa nawożenie (bity zerowane), kultywacja go nie kasuje.
## Rośliny nie rosną same: grow() („Sen”) przesuwa zasiane komórki o jedną fazę.
##
## Zapis: bajt na komórkę (faza 3 bity | gatunek 3 bity | nawożenie 2 bity), deflate + base64
## ("field_cells_v3"); starszy format v2 (tablice JSON) nadal się wczytuje.
##
## Indeks bloków: liczba komórek z widocznymi roślinami (faza >= LIGHT) w każdym bloku
## BLOCK_CELLS x BLOCK_CELLS – widok 3D nie rysuje pustych bloków.

enum Stage { PLAIN, SOWN, LIGHT, DARK, READY, HARVESTED }
const CROP_IDS: Array[String] = ["", "wheat", "barley", "oats"]   # kod gatunku = indeks (max 7)
const FERT_BEFORE: int = 1
const FERT_GROWING: int = 2
const BLOCK_CELLS: int = 32
const ENCODING: String = "field_cells_v3"
const LEGACY_ENCODINGS: Array[String] = ["field_cells_v2", "growth_batches_v1"]

var columns: int = 0
var rows: int = 0
var states := PackedByteArray()
var crop_codes := PackedByteArray()
var fertilized := PackedByteArray()
var block_columns: int = 0
var block_rows: int = 0
var block_counts := PackedInt32Array()
## Rośnie, gdy któryś blok zmienia się z pustego na zajęty albo odwrotnie.
var blocks_revision: int = 0


func setup(column_count: int, row_count: int) -> void:
	columns = column_count
	rows = row_count
	var count: int = columns * rows
	states.resize(count)
	states.fill(0)
	crop_codes.resize(count)
	crop_codes.fill(0)
	fertilized.resize(count)
	fertilized.fill(0)
	block_columns = ceili(float(columns) / BLOCK_CELLS)
	block_rows = ceili(float(rows) / BLOCK_CELLS)
	block_counts.resize(block_columns * block_rows)
	block_counts.fill(0)


func size() -> int:
	return states.size()


func stage(index: int) -> int:
	return states[index]


func crop_at(index: int) -> String:
	var code: int = crop_codes[index]
	return CROP_IDS[code] if code < CROP_IDS.size() else ""


static func crop_code(crop: String) -> int:
	return maxi(0, CROP_IDS.find(crop))


## Poziom nawożenia komórki: 0, 1 albo 2.
func fertilizer_level(index: int) -> int:
	var bits: int = fertilized[index]
	return (bits & 1) + ((bits >> 1) & 1)


## Siew na pustym polu. Zwraca true, gdy komórka została zasiana.
func sow(index: int, crop: String) -> bool:
	if states[index] != Stage.PLAIN:
		return false
	crop_codes[index] = crop_code(crop)
	_set_stage(index, Stage.SOWN)
	return true


## Kultywacja: każda faza poza pustym polem wraca do PLAIN. Zwraca true, gdy coś się zmieniło.
func cultivate(index: int) -> bool:
	if states[index] == Stage.PLAIN:
		return false
	crop_codes[index] = 0
	_set_stage(index, Stage.PLAIN)
	return true


## Zbiór: dojrzała komórka staje się ścierniskiem, nawożenie zostaje zużyte.
func harvest(index: int) -> bool:
	if states[index] != Stage.READY:
		return false
	crop_codes[index] = 0
	fertilized[index] = 0
	_set_stage(index, Stage.HARVESTED)
	return true


## Faza nawożenia, do której należy komórka (0 = nie da się nawieźć, np. dojrzałe zboże).
static func fertilize_bit(stage_value: int) -> int:
	if stage_value == Stage.PLAIN or stage_value == Stage.HARVESTED:
		return FERT_BEFORE
	if stage_value >= Stage.SOWN and stage_value < Stage.READY:
		return FERT_GROWING
	return 0


## Nawożenie komórki. Zwraca true, gdy poziom nawożenia wzrósł (tylko wtedy zużywa się nawóz).
func fertilize(index: int) -> bool:
	var bit: int = fertilize_bit(states[index])
	if bit == 0 or (fertilized[index] & bit) != 0:
		return false
	fertilized[index] |= bit
	return true


## Jedna noc: SOWN → LIGHT → DARK → READY. Zwraca indeksy komórek, które urosły.
func grow() -> PackedInt32Array:
	var grown := PackedInt32Array()
	for index in states.size():
		var value: int = states[index]
		if value >= Stage.SOWN and value < Stage.READY:
			states[index] = value + 1
			grown.append(index)
			if value == Stage.SOWN:
				_count_block(index, 1)
	return grown


## Pasy upraw w jednej fazie (kolumny dzielone na równe pasy; start nowej gry).
func fill_strips(crop_ids: Array, stage_value: int) -> void:
	if crop_ids.is_empty():
		return
	for index in columns * rows:
		var strip: int = mini(int(index % columns * crop_ids.size() / columns), crop_ids.size() - 1)
		states[index] = stage_value
		crop_codes[index] = crop_code(str(crop_ids[strip]))
		fertilized[index] = 0
	rebuild_blocks()


## Liczba komórek z widocznymi roślinami w prostokącie bloków (włącznie).
func plants_in_blocks(from: Vector2i, to: Vector2i) -> int:
	var total: int = 0
	for by in range(maxi(0, from.y), mini(block_rows - 1, to.y) + 1):
		for bx in range(maxi(0, from.x), mini(block_columns - 1, to.x) + 1):
			total += block_counts[by * block_columns + bx]
	return total


## Liczba komórek w danej fazie.
func count_stage(stage_value: int) -> int:
	return states.count(stage_value)


## Migawka do zapisu gry: bajt na komórkę, skompresowany.
func export_state() -> Dictionary:
	var packed := PackedByteArray()
	packed.resize(states.size())
	for index in states.size():
		packed[index] = states[index] | (crop_codes[index] << 3) | (fertilized[index] << 6)
	return {"encoding": ENCODING, "columns": columns, "rows": rows,
		"cells": Marshalls.raw_to_base64(packed.compress(FileAccess.COMPRESSION_DEFLATE))}


## Rozpakowanie "field_cells_v3" do bajtów komórek (pusta tablica = błąd).
static func unpack_cells(data: Dictionary, count: int) -> PackedByteArray:
	if not data.get("cells") is String:
		return PackedByteArray()
	var compressed: PackedByteArray = Marshalls.base64_to_raw(str(data["cells"]))
	var packed: PackedByteArray = compressed.decompress(count, FileAccess.COMPRESSION_DEFLATE)
	return packed if packed.size() == count else PackedByteArray()


## Wczytuje "field_cells_v3" oraz starsze "field_cells_v2" / "growth_batches_v1".
func restore_state(data: Dictionary) -> bool:
	if int(data.get("columns", 0)) != columns or int(data.get("rows", 0)) != rows:
		return false
	var count: int = states.size()
	match str(data.get("encoding", "")):
		ENCODING:
			var packed: PackedByteArray = unpack_cells(data, count)
			if packed.is_empty():
				return false
			for index in count:
				var value: int = packed[index]
				states[index] = mini(value & 7, Stage.HARVESTED)
				crop_codes[index] = (value >> 3) & 7
				fertilized[index] = (value >> 6) & 3
		"field_cells_v2", "growth_batches_v1":
			if data.get("states", []).size() != count or data.get("crops", []).size() != count:
				return false
			for index in count:
				states[index] = int(data["states"][index])
				crop_codes[index] = crop_code(str(data["crops"][index]))
				fertilized[index] = 0
		_:
			return false
	rebuild_blocks()
	return true


func rebuild_blocks() -> void:
	block_counts.fill(0)
	for index in states.size():
		if states[index] >= Stage.LIGHT:
			_count_block(index, 1)
	blocks_revision += 1


func _set_stage(index: int, stage_value: int) -> void:
	var was_visible: bool = states[index] >= Stage.LIGHT
	var now_visible: bool = stage_value >= Stage.LIGHT
	if was_visible != now_visible:
		_count_block(index, 1 if now_visible else -1)
	states[index] = stage_value


func _count_block(index: int, change: int) -> void:
	var block: int = floori(float(floori(float(index) / columns)) / BLOCK_CELLS) * block_columns + floori(float(index % columns) / BLOCK_CELLS)
	var before: int = block_counts[block]
	block_counts[block] = before + change
	if (before == 0) != (block_counts[block] == 0):
		blocks_revision += 1
