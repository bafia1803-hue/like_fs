extends "res://tests/framework/test_case.gd"

const CellRaster = preload("res://scripts/core/field/cell_raster.gd")
const FieldWorkRules = preload("res://scripts/core/field/field_work_rules.gd")
const Stage = preload("res://scripts/core/field/field_cells.gd").Stage


## Odniesienie: sprawdzenie środka każdej komórki (dawny, wolny sposób).
func _brute(points: PackedVector2Array, columns: int, rows: int) -> PackedInt32Array:
	var result := PackedInt32Array()
	for y in rows:
		for x in columns:
			if Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), points):
				result.append(y * columns + x)
	return result


func test_rectangle_cells() -> void:
	var cells: PackedInt32Array = CellRaster.cells_in_polygon(PackedVector2Array([Vector2(1, 1), Vector2(3, 1), Vector2(3, 3), Vector2(1, 3)]), 5, 5)
	assert_eq(Array(cells), [6, 7, 11, 12])


func test_matches_point_in_polygon_for_rotated_triangle() -> void:
	var triangle := PackedVector2Array()
	for point in [Vector2(0, -6), Vector2(40, 6), Vector2(-40, 6)]:
		triangle.append(point.rotated(0.37) + Vector2(50.2, 30.7))
	var fast: Array = Array(CellRaster.cells_in_polygon(triangle, 100, 60))
	var slow: Array = Array(_brute(triangle, 100, 60))
	var different: int = 0
	for index in fast:
		different += 0 if slow.has(index) else 1
	for index in slow:
		different += 0 if fast.has(index) else 1
	# Komórki ze środkiem praktycznie na krawędzi mogą wypaść różnie (zaokrąglenia).
	assert_true(different <= 2, "różnica %d komórek z %d" % [different, slow.size()])


func test_clips_to_field() -> void:
	var cells: PackedInt32Array = CellRaster.cells_in_polygon(PackedVector2Array([Vector2(-5, -5), Vector2(2, -5), Vector2(2, 1), Vector2(-5, 1)]), 4, 4)
	assert_eq(Array(cells), [0, 1])
	assert_true(CellRaster.cells_in_polygon(PackedVector2Array([Vector2(10, 10), Vector2(12, 10), Vector2(12, 12)]), 4, 4).is_empty())


func test_cell_needs_work_filter() -> void:
	assert_false(FieldWorkRules.cell_needs_work("fertilize", Stage.SOWN, 2), "już nawiezione w tej fazie")
	assert_true(FieldWorkRules.cell_needs_work("fertilize", Stage.SOWN, 1))
	assert_false(FieldWorkRules.cell_needs_work("fertilize", Stage.READY, 0))
	assert_false(FieldWorkRules.cell_needs_work("cultivate", Stage.PLAIN, 0))
	assert_true(FieldWorkRules.cell_needs_work("sow", Stage.READY, 0), "komunikat o zbiorze")
	assert_false(FieldWorkRules.cell_needs_work("harvest", Stage.DARK, 0))
