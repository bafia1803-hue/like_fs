extends Node2D
## Stan komórek pola (warstwa gry). Rośliny nie rosną same: każde wywołanie sleep()
## (przycisk „Sen”) przesuwa wszystkie zasiane komórki o jedną fazę wzrostu.
## Nic nie rysuje: widoki czytają stage_texture (stan każdej komórki zapisany w teksturze).
enum Stage { PLAIN, SOWN, LIGHT, DARK, READY, HARVESTED }
var states := PackedByteArray()
var crops := PackedStringArray()
var generations := PackedInt32Array()
var columns: int
var rows: int
var cell_m: float
var units: float
var field_id: String
## Stan komórek dla widoków: R = faza (Stage), G = gatunek (0 brak, 1 pszenica, 2 jęczmień, 3 inny).
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
	columns = int(data["grid"]["columns"])
	rows = int(data["grid"]["rows"])
	cell_m = float(data["grid"]["cell_size_m"])
	var geometry: Dictionary = data["geometry"]
	position = Vector2(float(geometry["origin_m"][0]), float(geometry["origin_m"][1])) * units
	rotation = deg_to_rad(float(geometry["rotation_deg"]))
	states.resize(columns * rows)
	crops.resize(columns * rows)
	generations.resize(columns * rows)
	stage_image = Image.create_empty(columns, rows, false, Image.FORMAT_RG8)
	stage_image.fill(Color(0, 0, 0))
	stage_texture = ImageTexture.create_from_image(stage_image)
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
			data[index * 2] = stage + 1
			grown += 1
			if stage == Stage.SOWN:
				_count_block(index, 1)
	if grown > 0:
		stage_image.set_data(columns, rows, false, Image.FORMAT_RG8, data)
		dirty = true
	return grown

func sow(index: int, crop: String) -> bool:
	if states[index] != Stage.PLAIN:
		return false
	generations[index] += 1
	crops[index] = crop
	_set_stage(index, Stage.SOWN)
	return true

func cultivate(index: int) -> void:
	if states[index] == Stage.PLAIN:
		return
	generations[index] += 1
	crops[index] = ""
	_set_stage(index, Stage.PLAIN)

func harvest(index: int) -> void:
	if states[index] == Stage.READY:
		generations[index] += 1
		crops[index] = ""
		_set_stage(index, Stage.HARVESTED)

func _set_stage(index: int, stage: int) -> void:
	var was_visible: bool = states[index] >= Stage.LIGHT
	var now_visible: bool = stage >= Stage.LIGHT
	if was_visible != now_visible:
		_count_block(index, 1 if now_visible else -1)
	states[index] = stage
	var x: int = index % columns
	var y: int = floori(float(index) / columns)
	stage_image.set_pixel(x, y, Color8(stage, _crop_code(crops[index]), 0))
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

func _crop_code(crop: String) -> int:
	match crop:
		"":
			return 0
		"wheat":
			return 1
		"barley":
			return 2
	return 3

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

## Migawka do zapisu gry.
func export_state() -> Dictionary:
	return {"encoding": "field_cells_v2", "columns": columns, "rows": rows,
		"states": Array(states), "crops": Array(crops), "generations": Array(generations)}

## Przyjmuje też stary format "growth_batches_v1" (zegar wzrostu jest pomijany).
func restore_state(data: Dictionary) -> bool:
	if not ["field_cells_v2", "growth_batches_v1"].has(str(data.get("encoding", ""))):
		return false
	if int(data.get("columns", 0)) != columns or int(data.get("rows", 0)) != rows:
		return false
	for key in ["states", "crops", "generations"]:
		if data.get(key, []).size() != states.size():
			return false
	states = PackedByteArray(data["states"])
	crops = PackedStringArray(data["crops"])
	generations = PackedInt32Array(data["generations"])
	block_counts.fill(0)
	var pixels := PackedByteArray()
	pixels.resize(states.size() * 2)
	for index in states.size():
		pixels[index * 2] = states[index]
		pixels[index * 2 + 1] = _crop_code(crops[index])
		if states[index] >= Stage.LIGHT:
			_count_block(index, 1)
	stage_image.set_data(columns, rows, false, Image.FORMAT_RG8, pixels)
	dirty = true
	blocks_revision += 1
	return true
