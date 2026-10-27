extends "res://tests/framework/test_case.gd"
## Odcinanie kępek na CPU (focus_lod.gd) musi zgadzać się z regułami shaderów: każda kępka, którą
## shader pokazałby gdziekolwiek w kawałku, mieści się w liczbie wysłanych do karty.

const FocusLod = preload("res://scripts/views/view3d/focus_lod.gd")
const FieldView = preload("res://scripts/views/view3d/field_view_3d.gd")
const NoiseTexture = preload("res://scripts/views/view3d/noise_texture.gd")

const DETAIL: float = 20.0
const FADE: float = 8.0
const THIN: float = 24.0
const VISIBLE: float = 58.0


func _sorted_random(count: int) -> PackedFloat32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var values: Array = []
	for i in count:
		values.append(rng.randf())
	values.sort()
	return PackedFloat32Array(values)


## Reguły shadera (crop.gdshader) dla jednej kępki w odległości d.
func _detail_shows(r: float, d: float) -> bool:
	return d < DETAIL and r >= FocusLod.to_simple(d, DETAIL, FADE)


func _simple_shows(r: float, d: float) -> bool:
	return r < FocusLod.to_simple(d, DETAIL, FADE) and FocusLod.keep(d, THIN, VISIBLE) > r * FocusLod.THIN_SLOPE


func test_counts_cover_every_tuft_the_shader_shows() -> void:
	var sorted := _sorted_random(729)
	var descending := sorted.duplicate()
	descending.reverse()
	for near in [0.0, 5.0, 10.0, 14.0, 19.0, 23.0, 30.0, 45.0, 57.0, 60.0]:
		var far: float = near + 22.6
		var detail: int = FocusLod.detail_count(sorted, near, DETAIL, FADE)
		var simple: int = FocusLod.simple_count(sorted, near, far, DETAIL, FADE, THIN, VISIBLE)
		for step in 24:
			var d: float = lerpf(near, far, step / 23.0)
			for i in sorted.size():
				if _simple_shows(sorted[i], d) and i >= simple:
					assert_true(false, "prosta: kępka %d w %.1f m poza liczbą %d (kawałek od %.0f m)" % [i, d, simple, near])
					return
				if _detail_shows(descending[i], d) and i >= detail:
					assert_true(false, "szczegółowa: kępka %d w %.1f m poza liczbą %d" % [i, d, detail])
					return


func test_far_chunks_send_few_tufts() -> void:
	var sorted := _sorted_random(729)
	assert_eq(FocusLod.detail_count(sorted, 0.0, DETAIL, FADE), 729, "kawałek przy pojeździe: wszystkie szczegółowe")
	assert_eq(FocusLod.detail_count(sorted, 25.0, DETAIL, FADE), 0)
	assert_eq(FocusLod.detail_count(sorted, 0.0, 0.0, FADE), 0, "jakość niska: bez szczegółowych")
	var mid: int = FocusLod.simple_count(sorted, 45.0, 67.0, DETAIL, FADE, THIN, VISIBLE)
	assert_true(mid > 0 and mid < 729 / 3, "w paśmie wsiąkania tylko część kępek: %d" % mid)
	assert_eq(FocusLod.simple_count(sorted, VISIBLE, VISIBLE + 20.0, DETAIL, FADE, THIN, VISIBLE), 0)
	assert_eq(FocusLod.thin_count(sorted, 10.0, 40.0, 55.0), 729)
	assert_eq(FocusLod.thin_count(sorted, 56.0, 40.0, 55.0), 0)


func test_canopy_mesh_faces_up_and_out() -> void:
	var mesh: ArrayMesh = FieldView.build_canopy_mesh(Vector2(16, 32), Vector2(28, 48), 0.5)
	var arrays: Array = mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_eq(int(24 + 1) * int(32 + 1) + 2 * 2 * (25 + 33), vertices.size(), "siatka 12 × 16 m co 0,5 m + ściany")
	assert_eq(uvs[0], Vector2(16, 32), "UV = położenie w polu")
	assert_eq(vertices[0], Vector3.ZERO, "wierzchołki w układzie kawałka")
	var top: int = 0
	var walls: int = 0
	for t in range(0, indices.size(), 3):
		var points: Array = []
		for k in 3:
			var p: Vector3 = vertices[indices[t + k]]
			p.y = 0.0 if colors[indices[t + k]].r > 0.5 else 1.0
			points.append(p)
		# Przód w Godocie: zgodnie z ruchem wskazówek zegara → cross(c − a, b − a) na zewnątrz.
		var face: Vector3 = (points[2] - points[0]).cross(points[1] - points[0])
		var expected: Vector3 = normals[indices[t]]
		assert_true(face.dot(expected) > 0.0, "trójkąt %d skierowany do środka" % (t / 3))
		if expected.y > 0.9:
			top += 1
		else:
			walls += 1
	assert_eq(top, 24 * 32 * 2)
	assert_eq(walls, 2 * 2 * (24 + 32))
	assert_true(mesh.custom_aabb.size.y >= 1.2, "prostopadłościan obejmuje wysokość zboża")


func test_noise_texture_tiles_without_seam() -> void:
	var image: Image = NoiseTexture.build_image(1)
	assert_eq(image.get_width(), NoiseTexture.SIZE_PX)
	assert_true(image.has_mipmaps())
	var size: int = NoiseTexture.SIZE_PX
	var worst: float = 0.0
	for i in size:
		worst = maxf(worst, absf(image.get_pixel(size - 1, i).r - image.get_pixel(0, i).r))
		worst = maxf(worst, absf(image.get_pixel(i, size - 1).r - image.get_pixel(i, 0).r))
	assert_true(worst < 0.2, "brzegi tekstury pasują do siebie (różnica %.2f)" % worst)
