extends Node2D
## Stan komórek pola (warstwa gry). Rośliny nie rosną same: każde wywołanie sleep()
## (przycisk „Sen”) przesuwa wszystkie zasiane komórki o jedną fazę wzrostu.
## Nic nie rysuje: widoki czytają stage_texture (stan każdej komórki zapisany w teksturze).
##
## Stan komórki: faza (Stage), gatunek (kod CROP_IDS) i nawożenie (bity fazy nawożenia):
##   FERT_BEFORE – nawiezione przed siewem (puste pole albo ściernisko),
##   FERT_GROWING – nawiezione w trakcie wzrostu (zasiane … przed dojrzałością).
## Każda faza liczy się raz, więc pole można nawieźć najwyżej dwa razy (poziom 0–2).
## Zbiór zużywa nawożenie (bity zerowane), kultywacja go nie kasuje.
## Zapis: jeden bajt na komórkę (faza 3 bity | gatunek 3 bity | nawożenie 2 bity), kompresja
## deflate + base64 ("field_cells_v3"); stary format v2 (tablice JSON) nadal się wczytuje.
enum Stage { PLAIN, SOWN, LIGHT, DARK, READY, HARVESTED }
const CROP_IDS: Array[String] = ["", "wheat", "barley", "oats"]   # kod gatunku = indeks (max 7)
const FERT_BEFORE: int = 1
const FERT_GROWING: int = 2
var states := PackedByteArray()
var crop_codes := PackedByteArray()
var fertilized := PackedByteArray()
var columns: int
var rows: int
var cell_m: float
var units: float
var field_id: String
var field_name: String = ""
## Czy pole należy do gracza (na cudzym polu narzędzia nie pracują).
var owned: bool = true
## Stan komórek dla widoków: R = faza (Stage), G = gatunek (0 brak, 1 pszenica, 2 jęczmień, 3 owies),
## B = poziom nawożenia (0–2).
var stage_image: Image
var stage_texture: ImageTexture
var dirty: bool = false
var render_elapsed: float = 0.0
## Indeks dla widoków: liczba komórek z widocznymi roślinami (faza >= LIGHT)
## w każdym bloku BLOCK_CELLS x BLOCK_CELLS. Widok 3D nie rysuje pustych bloków.
const BLOCK_CELLS: int = 32
var block_columns: int
var block_rows: int
var block_counts := PackedInt32Array()
## Rośnie, gdy któryś blok zmienia się z pustego na zajęty albo odwrotnie.
var blocks_revision: int = 0

func configure(data: Dictionary, settings: Dictionary, world_units: float) -> void:
	units = world_units
	field_id = str(data["id"])
	field_name = str(data.get("name", field_id))
	columns = int(data["grid"]["columns"])
	rows = int(data["grid"]["rows"])
	cell_m = float(data["grid"]["cell_size_m"])
	var geometry: Dictionary = data["geometry"]
	position = Vector2(float(geometry["origin_m"][0]), float(geometry["origin_m"][1])) * units
	rotation = deg_to_rad(float(geometry["rotation_deg"]))
	states.resize(columns * rows)
	crop_codes.resize(columns * rows)
	fertilized.resize(columns * rows)
	stage_image = Image.create_empty(columns, rows, false, Image.FORMAT_RGB8)
	stage_image.fill(Color(0, 0, 0))
	stage_texture = ImageTexture.create_from_image(stage_image)
	# Bez wejścia i fizyki; musi działać w pauzie snu, żeby nowe rośliny pojawiły się w ciemności.
	process_mode = Node.PROCESS_MODE_ALWAYS
	block_columns = ceili(float(columns) / BLOCK_CELLS)
	block_rows = ceili(float(rows) / BLOCK_CELLS)
	block_counts.resize(block_columns * block_rows)
	block_counts.fill(0)

func _process(delta: float) -> void:
	# Maksymalnie 10 aktualizacji tekstury/s, wyłącznie gdy zmieniły się dane.
	render_elapsed += delta
	if dirty and render_elapsed >= 0.1:
		stage_texture.update(stage_image)
		dirty = false
		render_elapsed = 0.0

## Jedna noc: SOWN → LIGHT → DARK → READY. Zwraca liczbę komórek, które urosły.
## Całe pole naraz: zmieniamy surowe bajty obrazu zamiast wołać set_pixel dla każdej komórki.
func sleep() -> int:
	var grown: int = 0
	var data: PackedByteArray = stage_image.get_data()
	for index in states.size():
		var stage: int = states[index]
		if stage >= Stage.SOWN and stage < Stage.READY:
			states[index] = stage + 1
			data[index * 3] = stage + 1
			grown += 1
			if stage == Stage.SOWN:
				_count_block(index, 1)
	if grown > 0:
		stage_image.set_data(columns, rows, false, Image.FORMAT_RGB8, data)
		dirty = true
	return grown

func sow(index: int, crop: String) -> bool:
	if states[index] != Stage.PLAIN:
		return false
	crop_codes[index] = crop_code(crop)
	_set_stage(index, Stage.SOWN)
	return true

func cultivate(index: int) -> void:
	if states[index] == Stage.PLAIN:
		return
	crop_codes[index] = 0
	_set_stage(index, Stage.PLAIN)

## Zbiór: komórka staje się ścierniskiem, nawożenie zostaje zużyte.
func harvest(index: int) -> void:
	if states[index] == Stage.READY:
		crop_codes[index] = 0
		fertilized[index] = 0
		_set_stage(index, Stage.HARVESTED)

## Nawożenie komórki. Zwraca true, gdy poziom nawożenia wzrósł (tylko wtedy zużywa się nawóz).
## Puste pole i ściernisko: faza „przed siewem”; zasiane i rosnące: faza „w trakcie wzrostu”;
## dojrzałe zboże: nic.
func fertilize(index: int) -> bool:
	var stage: int = states[index]
	var bit: int = 0
	if stage == Stage.PLAIN or stage == Stage.HARVESTED:
		bit = FERT_BEFORE
	elif stage >= Stage.SOWN and stage < Stage.READY:
		bit = FERT_GROWING
	if bit == 0 or (fertilized[index] & bit) != 0:
		return false
	fertilized[index] |= bit
	_write_pixel(index)
	return true

## Poziom nawożenia komórki: 0, 1 albo 2.
func fertilizer_level(index: int) -> int:
	var bits: int = fertilized[index]
	return (bits & 1) + ((bits >> 1) & 1)

func crop_at(index: int) -> String:
	var code: int = crop_codes[index]
	return CROP_IDS[code] if code < CROP_IDS.size() else ""

static func crop_code(crop: String) -> int:
	return maxi(0, CROP_IDS.find(crop))

func _set_stage(index: int, stage: int) -> void:
	var was_visible: bool = states[index] >= Stage.LIGHT
	var now_visible: bool = stage >= Stage.LIGHT
	if was_visible != now_visible:
		_count_block(index, 1 if now_visible else -1)
	states[index] = stage
	_write_pixel(index)

func _write_pixel(index: int) -> void:
	var x: int = index % columns
	var y: int = floori(float(index) / columns)
	stage_image.set_pixel(x, y, Color8(states[index], crop_codes[index], fertilizer_level(index)))
	dirty = true

func _count_block(index: int, change: int) -> void:
	var block: int = floori(float(floori(float(index) / columns)) / BLOCK_CELLS) * block_columns + floori(float(index % columns) / BLOCK_CELLS)
	var before: int = block_counts[block]
	block_counts[block] = before + change
	if (before == 0) != (block_counts[block] == 0):
		blocks_revision += 1

## Liczba komórek z widocznymi roślinami w prostokącie bloków (włącznie).
func plants_in_blocks(from: Vector2i, to: Vector2i) -> int:
	var total: int = 0
	for by in range(maxi(0, from.y), mini(block_rows - 1, to.y) + 1):
		for bx in range(maxi(0, from.x), mini(block_columns - 1, to.x) + 1):
			total += block_counts[by * block_columns + bx]
	return total

## Czy punkt świata (piksele 2D) leży nad polem.
func contains_point(global_point: Vector2) -> bool:
	var cell: Vector2 = to_local(global_point) / (cell_m * units)
	return cell.x >= 0.0 and cell.y >= 0.0 and cell.x < columns and cell.y < rows

func cells_in_rectangle(pose: Transform2D, size_m: Vector2) -> PackedInt32Array:
	var half: Vector2 = size_m * units * 0.5
	var corners: Array[Vector2] = [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]
	var bounds := Rect2(to_local(pose * corners[0]) / (cell_m * units), Vector2.ZERO)
	for corner in corners:
		bounds = bounds.expand(to_local(pose * corner) / (cell_m * units))
	var result := PackedInt32Array()
	var inverse: Transform2D = pose.affine_inverse()
	for y in range(maxi(0, floori(bounds.position.y)), mini(rows, ceili(bounds.end.y))):
		for x in range(maxi(0, floori(bounds.position.x)), mini(columns, ceili(bounds.end.x))):
			var point: Vector2 = inverse * to_global(Vector2(x + 0.5, y + 0.5) * cell_m * units)
			if absf(point.x) <= half.x and absf(point.y) <= half.y:
				result.append(y * columns + x)
	return result

## Komórki, których środek leży w wielokącie (punkty w metrach, lokalnie względem pose).
func cells_in_polygon(pose: Transform2D, points_m: PackedVector2Array) -> PackedInt32Array:
	var local_points := PackedVector2Array()
	for point in points_m:
		local_points.append(point * units)
	var bounds := Rect2(to_local(pose * local_points[0]) / (cell_m * units), Vector2.ZERO)
	for point in local_points:
		bounds = bounds.expand(to_local(pose * point) / (cell_m * units))
	var result := PackedInt32Array()
	var inverse: Transform2D = pose.affine_inverse()
	for y in range(maxi(0, floori(bounds.position.y)), mini(rows, ceili(bounds.end.y))):
		for x in range(maxi(0, floori(bounds.position.x)), mini(columns, ceili(bounds.end.x))):
			var point: Vector2 = inverse * to_global(Vector2(x + 0.5, y + 0.5) * cell_m * units)
			if Geometry2D.is_point_in_polygon(point, local_points):
				result.append(y * columns + x)
	return result


## Wypełnia pole pasami upraw w jednej fazie (kolumny dzielone na równe pasy; start nowej gry).
func fill_strips(crop_ids: Array, stage: int) -> void:
	if crop_ids.is_empty():
		return
	for index in columns * rows:
		var strip: int = mini(int(index % columns * crop_ids.size() / columns), crop_ids.size() - 1)
		states[index] = stage
		crop_codes[index] = crop_code(str(crop_ids[strip]))
		fertilized[index] = 0
	_rebuild_image()


## Migawka do zapisu gry: bajt na komórkę, skompresowany (zwykle kilka kB zamiast setek kB JSON).
func export_state() -> Dictionary:
	var packed := PackedByteArray()
	packed.resize(states.size())
	for index in states.size():
		packed[index] = states[index] | (crop_codes[index] << 3) | (fertilized[index] << 6)
	return {"encoding": "field_cells_v3", "columns": columns, "rows": rows,
		"cells": Marshalls.raw_to_base64(packed.compress(FileAccess.COMPRESSION_DEFLATE))}


## Rozpakowanie "field_cells_v3" do bajtów komórek (pusta tablica = błąd). Używa też walidacja zapisu.
static func unpack_cells(data: Dictionary, count: int) -> PackedByteArray:
	if not data.get("cells") is String:
		return PackedByteArray()
	var compressed: PackedByteArray = Marshalls.base64_to_raw(str(data["cells"]))
	var packed: PackedByteArray = compressed.decompress(count, FileAccess.COMPRESSION_DEFLATE)
	return packed if packed.size() == count else PackedByteArray()


## Wczytuje "field_cells_v3" oraz starsze "field_cells_v2" / "growth_batches_v1" (tablice JSON).
func restore_state(data: Dictionary) -> bool:
	if int(data.get("columns", 0)) != columns or int(data.get("rows", 0)) != rows:
		return false
	var count: int = states.size()
	match str(data.get("encoding", "")):
		"field_cells_v3":
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
	_rebuild_image()
	return true


func _rebuild_image() -> void:
	block_counts.fill(0)
	var pixels := PackedByteArray()
	pixels.resize(states.size() * 3)
	for index in states.size():
		pixels[index * 3] = states[index]
		pixels[index * 3 + 1] = crop_codes[index]
		pixels[index * 3 + 2] = fertilizer_level(index)
		if states[index] >= Stage.LIGHT:
			_count_block(index, 1)
	stage_image.set_data(columns, rows, false, Image.FORMAT_RGB8, pixels)
	dirty = true
	blocks_revision += 1
