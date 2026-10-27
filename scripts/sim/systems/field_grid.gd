extends Node2D
## Pole na mapie (warstwa gry): położenie, własność, geometria komórek i tekstura stanu dla widoków.
## Zasady komórek (fazy, nawożenie, zapis) są w core/field/field_cells.gd; ten węzeł tylko
## przekłada zmiany komórek na piksele tekstury i odpowiada na pytania geometryczne.
##
## Tekstura stage_texture: R = faza (Stage), G = gatunek (0 brak, 1 pszenica, 2 jęczmień, 3 owies),
## B = poziom nawożenia (0–2). Widoki czytają wyłącznie ją.

const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const CellRaster = preload("res://scripts/core/field/cell_raster.gd")
const Stage = FieldCells.Stage
const BLOCK_CELLS: int = FieldCells.BLOCK_CELLS
const Profiler = preload("res://scripts/core/util/profiler.gd")

var cells = FieldCells.new()
var cell_m: float
var units: float
var field_id: String
var field_name: String = ""
## Czy pole należy do gracza (na cudzym polu narzędzia nie pracują).
var owned: bool = true
var stage_image: Image
var stage_texture: ImageTexture
var dirty: bool = false
var render_elapsed: float = 0.0

var columns: int:
	get:
		return cells.columns
var rows: int:
	get:
		return cells.rows
var states: PackedByteArray:
	get:
		return cells.states
var blocks_revision: int:
	get:
		return cells.blocks_revision


func configure(data: Dictionary, _settings: Dictionary, world_units: float) -> void:
	units = world_units
	field_id = str(data["id"])
	field_name = str(data.get("name", field_id))
	cells.setup(int(data["grid"]["columns"]), int(data["grid"]["rows"]))
	cell_m = float(data["grid"]["cell_size_m"])
	var geometry: Dictionary = data["geometry"]
	position = Vector2(float(geometry["origin_m"][0]), float(geometry["origin_m"][1])) * units
	rotation = deg_to_rad(float(geometry["rotation_deg"]))
	stage_image = Image.create_empty(cells.columns, cells.rows, false, Image.FORMAT_RGB8)
	stage_image.fill(Color(0, 0, 0))
	stage_texture = ImageTexture.create_from_image(stage_image)
	# Bez wejścia i fizyki; musi działać w pauzie snu, żeby nowe rośliny pojawiły się w ciemności.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	var started: int = Profiler.start()
	_process_measured(delta)
	Profiler.stop(Profiler.FIELD_TEXTURE, started)


func _process_measured(delta: float) -> void:
	# Maksymalnie 10 aktualizacji tekstury/s, wyłącznie gdy zmieniły się dane.
	render_elapsed += delta
	if dirty and render_elapsed >= 0.1:
		stage_texture.update(stage_image)
		dirty = false
		render_elapsed = 0.0


# ---------------------------------------------------------------------------
# Zmiany komórek (zasady w FieldCells, tu tylko piksele)
# ---------------------------------------------------------------------------

func stage(index: int) -> int:
	return cells.stage(index)


func crop_at(index: int) -> String:
	return cells.crop_at(index)


func fertilizer_level(index: int) -> int:
	return cells.fertilizer_level(index)


func sow(index: int, crop: String) -> bool:
	if not cells.sow(index, crop):
		return false
	_write_pixel(index)
	return true


func cultivate(index: int) -> void:
	if cells.cultivate(index):
		_write_pixel(index)


func harvest(index: int) -> void:
	if cells.harvest(index):
		_write_pixel(index)


func fertilize(index: int) -> bool:
	if not cells.fertilize(index):
		return false
	_write_pixel(index)
	return true


## Jedna noc. Całe pole naraz: zmieniamy surowe bajty obrazu zamiast set_pixel dla każdej komórki.
func sleep() -> int:
	var grown: PackedInt32Array = cells.grow()
	if grown.is_empty():
		return 0
	var data: PackedByteArray = stage_image.get_data()
	for index in grown:
		data[index * 3] = cells.states[index]
	stage_image.set_data(cells.columns, cells.rows, false, Image.FORMAT_RGB8, data)
	dirty = true
	return grown.size()


func fill_strips(crop_ids: Array, stage_value: int) -> void:
	if crop_ids.is_empty():
		return
	cells.fill_strips(crop_ids, stage_value)
	_rebuild_image()


func plants_in_blocks(from: Vector2i, to: Vector2i) -> int:
	return cells.plants_in_blocks(from, to)


func export_state() -> Dictionary:
	return cells.export_state()


static func unpack_cells(data: Dictionary, count: int) -> PackedByteArray:
	return FieldCells.unpack_cells(data, count)


func restore_state(data: Dictionary) -> bool:
	if not cells.restore_state(data):
		return false
	_rebuild_image()
	return true


func _write_pixel(index: int) -> void:
	var x: int = index % cells.columns
	var y: int = floori(float(index) / cells.columns)
	stage_image.set_pixel(x, y, Color8(cells.states[index], cells.crop_codes[index], cells.fertilizer_level(index)))
	dirty = true


func _rebuild_image() -> void:
	var pixels := PackedByteArray()
	pixels.resize(cells.size() * 3)
	for index in cells.size():
		pixels[index * 3] = cells.states[index]
		pixels[index * 3 + 1] = cells.crop_codes[index]
		pixels[index * 3 + 2] = cells.fertilizer_level(index)
	stage_image.set_data(cells.columns, cells.rows, false, Image.FORMAT_RGB8, pixels)
	dirty = true


# ---------------------------------------------------------------------------
# Geometria
# ---------------------------------------------------------------------------

## Czy punkt świata (piksele 2D) leży nad polem.
func contains_point(global_point: Vector2) -> bool:
	var cell: Vector2 = to_local(global_point) / (cell_m * units)
	return cell.x >= 0.0 and cell.y >= 0.0 and cell.x < cells.columns and cell.y < cells.rows


func cells_in_rectangle(pose: Transform2D, size_m: Vector2) -> PackedInt32Array:
	var half: Vector2 = size_m * 0.5
	return cells_in_polygon(pose, PackedVector2Array([Vector2(-half.x, -half.y), Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)]))


## Komórki, których środek leży w wielokącie (punkty w metrach, lokalnie względem pose).
## Rasteryzacja wierszami (core/field/cell_raster.gd).
func cells_in_polygon(pose: Transform2D, points_m: PackedVector2Array) -> PackedInt32Array:
	var to_cells: Transform2D = global_transform.affine_inverse() * pose
	var scale: float = 1.0 / (cell_m * units)
	var local := PackedVector2Array()
	for point in points_m:
		local.append(to_cells * (point * units) * scale)
	return CellRaster.cells_in_polygon(local, cells.columns, cells.rows)
