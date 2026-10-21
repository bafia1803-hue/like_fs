extends Node2D
## Dane + warstwa kolorów. Jeden zegar na pole, żadnych Timerów na komórkach.
enum Stage { PLAIN, SOWN, LIGHT, DARK, READY, HARVESTED }
var states := PackedByteArray()
var crops := PackedStringArray()
var generations := PackedInt32Array()
var columns: int
var rows: int
var cell_m: float
var units: float
var field_id: String
var tick_seconds: float = 10.0
var elapsed: float = 0.0
var running: bool = false
var pending: Array = []
var batches: Array = []
var palette: Array[Color] = []
var image: Image
var texture: ImageTexture
var dirty: bool = false
var render_elapsed: float = 0.0

func configure(data: Dictionary, settings: Dictionary, world_units: float) -> void:
	units = world_units
	field_id = str(data["id"])
	columns = int(data["grid"]["columns"])
	rows = int(data["grid"]["rows"])
	cell_m = float(data["grid"]["cell_size_m"])
	tick_seconds = maxf(0.1, float(settings["growth_tick_seconds"]))
	var geometry: Dictionary = data["geometry"]
	position = Vector2(float(geometry["origin_m"][0]), float(geometry["origin_m"][1])) * units
	rotation = deg_to_rad(float(geometry["rotation_deg"]))
	states.resize(columns * rows)
	crops.resize(columns * rows)
	generations.resize(columns * rows)
	palette.append(Color(str(data["soil_surface"]["color"])))
	for key in ["sown", "light", "dark", "ready", "harvested"]:
		palette.append(Color(str(settings["colors"][key])))
	image = Image.create_empty(columns, rows, false, Image.FORMAT_RGBA8)
	image.fill(palette[Stage.PLAIN])
	texture = ImageTexture.create_from_image(image)
	var sprite := Sprite2D.new()
	sprite.texture = texture
	sprite.centered = false
	sprite.scale = Vector2.ONE * cell_m * units
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(sprite)

func _process(delta: float) -> void:
	# Maksymalnie 10 aktualizacji tekstury/s, wyłącznie gdy zmieniły się dane.
	render_elapsed += delta
	if dirty and render_elapsed >= 0.1:
		texture.update(image)
		dirty = false
		render_elapsed = 0.0

func advance(delta: float) -> void:
	if not running:
		return
	elapsed += delta
	while elapsed >= tick_seconds:
		elapsed -= tick_seconds
		_tick()

func _tick() -> void:
	var remaining: Array = []
	for batch_value in batches:
		var batch: Dictionary = batch_value
		var next_stage: int = int(batch["stage"]) + 1
		var valid: Array = []
		for entry in batch["cells"]:
			var index: int = int(entry[0])
			if generations[index] == int(entry[1]) and states[index] == int(batch["stage"]):
				_set_stage(index, next_stage)
				valid.append(entry)
		if next_stage < Stage.READY and not valid.is_empty():
			remaining.append({"stage": next_stage, "cells": valid})
	batches = remaining
	# Najpierw wzrost starych partii, POTEM zamknięcie bufora nowych zasiewów.
	if not pending.is_empty():
		batches.append({"stage": Stage.SOWN, "cells": pending})
		pending = []

func sow(index: int, crop: String) -> bool:
	if states[index] != Stage.PLAIN:
		return false
	generations[index] += 1
	crops[index] = crop
	_set_stage(index, Stage.SOWN)
	pending.append([index, generations[index]])
	running = true
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
	states[index] = stage
	image.set_pixel(index % columns, floori(float(index) / columns), palette[stage])
	dirty = true

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

## JSON-ready migawka do przyszłego systemu zapisu. Nie tworzy pliku automatycznie.
func export_state() -> Dictionary:
	return {"encoding": "growth_batches_v1", "columns": columns, "rows": rows,
		"states": Array(states), "crops": Array(crops), "generations": Array(generations),
		"tick_seconds": tick_seconds, "elapsed": elapsed, "running": running,
		"pending": pending.duplicate(true), "batches": batches.duplicate(true)}

func restore_state(data: Dictionary) -> bool:
	if str(data.get("encoding", "")) != "growth_batches_v1":
		return false
	if int(data.get("columns", 0)) != columns or int(data.get("rows", 0)) != rows:
		return false
	for key in ["states", "crops", "generations"]:
		if data.get(key, []).size() != states.size():
			return false
	states = PackedByteArray(data["states"])
	crops = PackedStringArray(data["crops"])
	generations = PackedInt32Array(data["generations"])
	tick_seconds = maxf(0.1, float(data["tick_seconds"]))
	elapsed = float(data["elapsed"])
	running = bool(data["running"])
	pending = data["pending"].duplicate(true)
	batches = data["batches"].duplicate(true)
	for index in states.size():
		_set_stage(index, int(states[index]))
	return true
