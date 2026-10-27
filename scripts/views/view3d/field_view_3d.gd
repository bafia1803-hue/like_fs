extends Node3D
## Widok 3D jednego pola: powierzchnia gleby i kępki roślin.
## Stan komórek czyta wyłącznie z tekstury field_grid.stage_texture, więc zmiana fazy
## (siew, wzrost, zbiór, kultywacja) nie wymaga przebudowy siatek na CPU.
##
## Kępka to 4 proste „wykałaczki” (statyczne, bez wiatru). Kępki kawałka pola 16 × 16 m to MultiMesh
## (1 wywołanie rysowania na poziom szczegółów); kawałki bez roślin są ukryte.
## Pod kępkami leży łan (crop_canopy.gdshader): siatka co 0,5 m podnoszona w shaderze do wysokości
## roślin – zwarta pokrywa pola, dzięki której daleko nie potrzeba kępek wcale.
##
## Poziomy szczegółów liczone są wokół PUNKTU SKUPIENIA, nie kamery: pojazdu gracza, a przy wolnej
## kamerze miejsca, na które patrzy (set_focus z View3D). Kółko wokół punktu:
##   – do crop_detail_m kępki szczegółowe (48 trójkątów),
##   – w paśmie crop_fade_m każda kępka osobno przechodzi na wersję prostą (12 trójkątów),
##   – od crop_thin_from_m kępek ubywa stopniowo (wsiąkają w łan), do crop_visible_m,
##   – dalej pole pokazuje sam łan (wysoki na far_factor wysokości roślin).
## Przejścia robi shader dla każdej kępki (crop.gdshader), więc nie ma skoków na granicach kawałków.
## CPU (focus_lod.gd) co 2 m ruchu liczy, ile kępek każdego kawałka może być widocznych – kępki
## w kawałku są posortowane wg liczby losowej r, w kolejności, w jakiej shader je chowa – i rysuje
## tylko tyle (visible_instance_count). Schowane kępki w ogóle nie trafiają do karty.

const CropShader = preload("res://shaders/crop.gdshader")
const CanopyShader = preload("res://shaders/crop_canopy.gdshader")
const FocusLod = preload("res://scripts/views/view3d/focus_lod.gd")
const GroundShader = preload("res://shaders/field_ground.gdshader")
const NoiseTexture = preload("res://scripts/views/view3d/noise_texture.gd")

const TUFTS_PER_CHUNK: int = 27         # 16 m / 27 ≈ 0,6 m między kępkami
const CHUNK_M: float = 16.0
## Pełne kępki (8 ścian na wykałaczkę) do tej odległości, dalej 3 ściany, a za CROP_VISIBLE_M
## pole pokazuje już tylko kolorowa powierzchnia gleby.
const CROP_DETAIL_M: float = 40.0
const CROP_VISIBLE_M: float = 110.0
const CROP_FADE_M: float = 12.0
const CROP_THIN_FROM_M: float = 70.0
## Przeliczenie widoczności kawałków po przesunięciu punktu skupienia o tyle metrów.
const REFRESH_MOVE_M: float = 2.0
## Oczko siatki łanu [m].
const CANOPY_STEP_M: float = 0.5
const Profiler = preload("res://scripts/core/util/profiler.gd")

var grid: Node2D
var _crop_material: ShaderMaterial
var _simple_material: ShaderMaterial
var _canopy_material: ShaderMaterial
## [węzeł kawałka, blok od, blok do, prostokąt w metrach (lokalnie), szczegółowa, prosta,
##  r kępek posortowane rosnąco (PackedFloat32Array), łan]
var _chunks: Array = []
var _detail_m: float = CROP_DETAIL_M
var _fade_m: float = CROP_FADE_M
var _thin_from_m: float = CROP_THIN_FROM_M
var _visible_m: float = CROP_VISIBLE_M
var _focus_local := Vector2(INF, INF)
var _blocks_revision: int = -1
var tufts_enabled: bool = true


var _sale_sign: Label3D


func configure(field_grid: Node2D, field_data: Dictionary, settings: Dictionary,
		price: float = -1.0, economy: RefCounted = null) -> void:
	grid = field_grid
	name = "Field_" + str(field_data["id"])
	# Pokazuje nowe rośliny także w pauzie snu (nie obsługuje wejścia).
	process_mode = Node.PROCESS_MODE_ALWAYS
	var geometry: Dictionary = field_data["geometry"]
	var origin: Array = geometry["origin_m"]
	position = Vector3(float(origin[0]), 0.0, float(origin[1]))
	rotation.y = -deg_to_rad(float(geometry.get("rotation_deg", 0.0)))
	var colors: Dictionary = settings["colors"]
	var soil_color := Color(str(field_data["soil_surface"]["color"]))
	_build_ground(colors, soil_color)
	_build_crops(colors)
	if price >= 0.0 and economy != null:
		var size: Vector2 = Vector2(grid.columns, grid.rows) * float(grid.cell_m)
		_sale_sign = Label3D.new()
		_sale_sign.name = "SaleSign"
		_sale_sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_sale_sign.pixel_size = 0.02
		_sale_sign.font_size = 72
		_sale_sign.outline_size = 18
		_sale_sign.modulate = Color("#ffd98a")
		_sale_sign.outline_modulate = Color(0.12, 0.1, 0.08, 0.9)
		_sale_sign.text = "%s\nNa sprzedaż: %s" % [str(field_data.get("name", "")), economy.call("format", price)]
		_sale_sign.position = Vector3(size.x * 0.5, 7.0, size.y * 0.5)
		_sale_sign.visible = not bool(grid.owned)
		add_child(_sale_sign)


func _build_ground(colors: Dictionary, soil_color: Color) -> void:
	var size: Vector2 = Vector2(grid.columns, grid.rows) * float(grid.cell_m)
	var plane := PlaneMesh.new()
	plane.size = size
	plane.center_offset = Vector3(size.x * 0.5, 0.0, size.y * 0.5)
	var material := ShaderMaterial.new()
	material.shader = GroundShader
	material.set_shader_parameter("stage_tex", grid.stage_texture)
	material.set_shader_parameter("grid_size", Vector2(grid.columns, grid.rows))
	material.set_shader_parameter("cell_m", grid.cell_m)
	material.set_shader_parameter("color_soil", soil_color)
	material.set_shader_parameter("color_sown", Color(str(colors["sown"])))
	material.set_shader_parameter("color_light", Color(str(colors["light"])))
	material.set_shader_parameter("color_dark", Color(str(colors["dark"])))
	material.set_shader_parameter("color_ready", Color(str(colors["ready"])))
	material.set_shader_parameter("color_harvested", Color(str(colors["harvested"])))
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = plane
	ground.material_override = material
	ground.position.y = 0.03
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)


func _process(_delta: float) -> void:
	var started: int = Profiler.start()
	_process_measured(_delta)
	Profiler.stop(Profiler.VIEW_FIELDS, started)


func _process_measured(_delta: float) -> void:
	if _sale_sign != null:
		_sale_sign.visible = not bool(grid.owned)
	if grid != null and int(grid.blocks_revision) != _blocks_revision:
		_blocks_revision = int(grid.blocks_revision)
		for chunk in _chunks:
			chunk[0].visible = int(grid.call("plants_in_blocks", chunk[1], chunk[2])) > 0


## Punkt skupienia (świat 3D, metry): shader liczy od niego przejścia, a tu włączane są poziomy kawałków.
func set_focus(point: Vector3) -> void:
	for material in [_crop_material, _simple_material, _canopy_material]:
		material.set_shader_parameter("focus", point)
	var local3: Vector3 = to_local(point)
	var local := Vector2(local3.x, local3.z)
	if local.distance_to(_focus_local) < REFRESH_MOVE_M:
		return
	_focus_local = local
	_update_levels()


## Ile kępek każdego kawałka rysować (z zapasem na ruch punktu skupienia do następnego przeliczenia).
func _update_levels() -> void:
	var margin: float = REFRESH_MOVE_M + 0.5
	for chunk in _chunks:
		var distance: Vector2 = FocusLod.rect_distance(_focus_local, chunk[3])
		var near: float = maxf(0.0, distance.x - margin)
		var far: float = distance.y + margin
		var sorted: PackedFloat32Array = chunk[6]
		_show_count(chunk[4], FocusLod.detail_count(sorted, near, _detail_m, _fade_m))
		_show_count(chunk[5], FocusLod.simple_count(sorted, near, far, _detail_m, _fade_m, _thin_from_m, _visible_m))


func _show_count(instance: MultiMeshInstance3D, count: int) -> void:
	instance.visible = tufts_enabled and count > 0
	instance.multimesh.visible_instance_count = count if count < instance.multimesh.instance_count else -1


## Kępki włączone (test kosztu karty Shift+F4 wyłącza je na chwilę).
func set_tufts_enabled(on: bool) -> void:
	tufts_enabled = on
	if is_finite(_focus_local.x):
		_update_levels()


## Liczba kępek wysłanych do karty (do testów i raportu).
func drawn_tufts() -> int:
	var total: int = 0
	for chunk in _chunks:
		if not (chunk[0] as Node3D).visible:
			continue
		for level in [chunk[4], chunk[5]]:
			var instance: MultiMeshInstance3D = level
			if instance.visible:
				var count: int = instance.multimesh.visible_instance_count
				total += instance.multimesh.instance_count if count < 0 else count
	return total


## Łany kawałków (test kosztu karty Shift+F4).
func canopy_nodes() -> Array:
	return _chunks.map(func(chunk): return chunk[7])


func _build_crops(colors: Dictionary) -> void:
	_crop_material = ShaderMaterial.new()
	_crop_material.shader = CropShader
	_crop_material.set_shader_parameter("stage_tex", grid.stage_texture)
	_crop_material.set_shader_parameter("color_light", Color(str(colors["light"])))
	_crop_material.set_shader_parameter("color_dark", Color(str(colors["dark"])))
	_crop_material.set_shader_parameter("color_ready", Color(str(colors["ready"])))
	_crop_material.set_shader_parameter("lod_level", 0)
	_simple_material = _crop_material.duplicate()
	_simple_material.set_shader_parameter("lod_level", 1)
	_canopy_material = ShaderMaterial.new()
	_canopy_material.shader = CanopyShader
	_canopy_material.set_shader_parameter("stage_tex", grid.stage_texture)
	_canopy_material.set_shader_parameter("grid_size", Vector2(grid.columns, grid.rows))
	_canopy_material.set_shader_parameter("cell_m", float(grid.cell_m))
	_canopy_material.set_shader_parameter("step_m", CANOPY_STEP_M)
	_canopy_material.set_shader_parameter("noise_tex", NoiseTexture.texture())
	_canopy_material.set_shader_parameter("noise_cells", float(NoiseTexture.CELLS))
	_canopy_material.set_shader_parameter("color_light", Color(str(colors["light"])))
	_canopy_material.set_shader_parameter("color_dark", Color(str(colors["dark"])))
	_canopy_material.set_shader_parameter("color_ready", Color(str(colors["ready"])))
	_apply_lod_uniforms()
	var mesh: ArrayMesh = build_tuft_mesh(true)
	mesh.surface_set_material(0, _crop_material)
	var simple_mesh: ArrayMesh = build_tuft_mesh(false)
	simple_mesh.surface_set_material(0, _simple_material)
	var size: Vector2 = Vector2(grid.columns, grid.rows) * float(grid.cell_m)
	var spacing: float = CHUNK_M / TUFTS_PER_CHUNK
	var tufts_x: int = int(round(size.x / spacing))
	var tufts_z: int = int(round(size.y / spacing))
	var block_m: float = float(grid.BLOCK_CELLS) * float(grid.cell_m)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(name)
	var root := Node3D.new()
	root.name = "Crops"
	add_child(root)
	for chunk_z in range(0, tufts_z, TUFTS_PER_CHUNK):
		for chunk_x in range(0, tufts_x, TUFTS_PER_CHUNK):
			var count_x: int = mini(TUFTS_PER_CHUNK, tufts_x - chunk_x)
			var count_z: int = mini(TUFTS_PER_CHUNK, tufts_z - chunk_z)
			var origin := Vector3(chunk_x * spacing, 0.0, chunk_z * spacing)
			# Każda kępka: 12 liczb przekształcenia + komórka (x, y) + r + 0.
			var tufts: Array = []
			for tz in count_z:
				for tx in count_x:
					var local := Vector3((tx + 0.5) * spacing, 0.03, (tz + 0.5) * spacing)
					local.x += rng.randf_range(-0.12, 0.12)
					local.z += rng.randf_range(-0.12, 0.12)
					var cell := Vector2i(
						clampi(int((origin.x + local.x) / grid.cell_m), 0, grid.columns - 1),
						clampi(int((origin.z + local.z) / grid.cell_m), 0, grid.rows - 1)
					)
					var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * rng.randf_range(0.9, 1.15))
					tufts.append([rng.randf(), basis, local, cell])
			# Kolejność znikania: poziom prosty chowa najpierw duże r (sortowanie rosnąco),
			# szczegółowy – małe r (malejąco); wtedy widoczne kępki to zawsze początek bufora.
			tufts.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
			var sorted := PackedFloat32Array()
			for tuft in tufts:
				sorted.append(float(tuft[0]))
			var ascending: PackedFloat32Array = _tuft_buffer(tufts)
			tufts.reverse()
			var descending: PackedFloat32Array = _tuft_buffer(tufts)
			var chunk := Node3D.new()
			chunk.position = origin
			chunk.visible = false
			root.add_child(chunk)
			var levels: Array = []
			for level in 2:
				var multimesh := MultiMesh.new()
				multimesh.transform_format = MultiMesh.TRANSFORM_3D
				multimesh.use_custom_data = true
				multimesh.mesh = mesh if level == 0 else simple_mesh
				multimesh.instance_count = tufts.size()
				multimesh.buffer = descending if level == 0 else ascending
				var instance := MultiMeshInstance3D.new()
				instance.multimesh = multimesh
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				instance.extra_cull_margin = 0.3
				instance.visible = false
				chunk.add_child(instance)
				levels.append(instance)
			var end := Vector2(origin.x + count_x * spacing, origin.z + count_z * spacing) - Vector2(0.01, 0.01)
			# Łan kawałka sięga do krawędzi pola (ostatni rząd kępek kończy się tuż przed nią).
			var canopy_end := Vector2(size.x if chunk_x + count_x >= tufts_x else end.x + 0.01,
				size.y if chunk_z + count_z >= tufts_z else end.y + 0.01)
			var canopy := MeshInstance3D.new()
			canopy.name = "Canopy"
			canopy.mesh = build_canopy_mesh(Vector2(origin.x, origin.z), canopy_end, CANOPY_STEP_M)
			canopy.material_override = _canopy_material
			canopy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			chunk.add_child(canopy)
			_chunks.append([chunk,
				Vector2i(floori(origin.x / block_m), floori(origin.z / block_m)),
				Vector2i(floori(end.x / block_m), floori(end.y / block_m)),
				Rect2(Vector2(origin.x, origin.z), Vector2(count_x, count_z) * spacing), levels[0], levels[1],
				sorted, canopy])


## Bufor MultiMesh kępek: [r, Basis, położenie, komórka] → 16 liczb na kępkę.
static func _tuft_buffer(tufts: Array) -> PackedFloat32Array:
	var buffer := PackedFloat32Array()
	buffer.resize(tufts.size() * 16)
	for i in tufts.size():
		var basis: Basis = tufts[i][1]
		var local: Vector3 = tufts[i][2]
		var cell: Vector2i = tufts[i][3]
		var o: int = i * 16
		buffer[o + 0] = basis.x.x
		buffer[o + 1] = basis.y.x
		buffer[o + 2] = basis.z.x
		buffer[o + 3] = local.x
		buffer[o + 4] = basis.x.y
		buffer[o + 5] = basis.y.y
		buffer[o + 6] = basis.z.y
		buffer[o + 7] = local.y
		buffer[o + 8] = basis.x.z
		buffer[o + 9] = basis.y.z
		buffer[o + 10] = basis.z.z
		buffer[o + 11] = local.z
		buffer[o + 12] = float(cell.x)
		buffer[o + 13] = float(cell.y)
		buffer[o + 14] = float(tufts[i][0])
		buffer[o + 15] = 0.0
	return buffer


## Siatka łanu jednego kawałka: płaska siatka co step_m od start do end (metry w polu) i ściany
## dookoła (do ziemi). Wierzchołki w układzie kawałka (start = 0), UV = położenie w polu;
## wysokość ustawia shader (crop_canopy.gdshader), stąd stały prostopadłościan widoczności.
## Przednie ściany trójkątów zgodnie z ruchem wskazówek zegara (konwencja Godota): góra do góry,
## ściany na zewnątrz.
static func build_canopy_mesh(start: Vector2, end: Vector2, step_m: float) -> ArrayMesh:
	var size: Vector2 = end - start
	var nx: int = maxi(1, ceili(size.x / step_m - 0.001))
	var nz: int = maxi(1, ceili(size.y / step_m - 0.001))
	var vertices := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for iz in nz + 1:
		for ix in nx + 1:
			var local := Vector2(size.x * ix / nx, size.y * iz / nz)
			vertices.append(Vector3(local.x, 0.0, local.y))
			uvs.append(start + local)
			colors.append(Color(0, 0, 0, 1))
			normals.append(Vector3.UP)
	for iz in nz:
		for ix in nx:
			var a: int = iz * (nx + 1) + ix
			var b: int = a + 1
			var c: int = a + nx + 1
			var d: int = c + 1
			indices.append_array([a, b, c, b, d, c])
	# Ściany: obwód (kolejne wierzchołki brzegu) z normalną na zewnątrz.
	var sides: Array = [
		[range(nx + 1).map(func(ix): return ix), Vector3(0, 0, -1)],
		[range(nx + 1).map(func(ix): return nz * (nx + 1) + ix), Vector3(0, 0, 1)],
		[range(nz + 1).map(func(iz): return iz * (nx + 1)), Vector3(-1, 0, 0)],
		[range(nz + 1).map(func(iz): return iz * (nx + 1) + nx), Vector3(1, 0, 0)],
	]
	for side in sides:
		var border: Array = side[0]
		var normal: Vector3 = side[1]
		var top_first: int = vertices.size()
		for index in border:
			for bottom in 2:
				vertices.append(vertices[index])
				uvs.append(uvs[index])
				colors.append(Color(1, 0, 0, 1) if bottom == 1 else Color(0, 1, 0, 1))
				normals.append(normal)
		for k in border.size() - 1:
			var top_a: int = top_first + k * 2
			var bottom_a: int = top_a + 1
			var top_b: int = top_a + 2
			var bottom_b: int = top_a + 3
			for triangle in [[top_a, top_b, bottom_a], [top_b, bottom_b, bottom_a]]:
				indices.append_array(_facing(triangle, vertices, colors, normal))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.custom_aabb = AABB(Vector3(0.0, -0.1, 0.0), Vector3(size.x, 1.4, size.y))
	return mesh


## Trójkąt ściany przodem w stronę normal (w Godocie przód = zgodnie z ruchem wskazówek zegara,
## czyli cross(c − a, b − a) wskazuje na zewnątrz). Do obliczenia górna krawędź ma y = 1.
static func _facing(triangle: Array, vertices: PackedVector3Array, colors: PackedColorArray, normal: Vector3) -> Array:
	var points: Array = []
	for index in triangle:
		var point: Vector3 = vertices[index]
		point.y = 0.0 if colors[index].r > 0.5 else 1.0
		points.append(point)
	var face: Vector3 = (points[2] - points[0]).cross(points[1] - points[0])
	return triangle if face.dot(normal) > 0.0 else [triangle[0], triangle[2], triangle[1]]


## Kępka: 4 nieregularne „wykałaczki” o wysokości jednostkowej (skalowanej w shaderze).
## detailed: przekrój kwadratowy, 4 ściany boczne + 4 ściany czubka (8 ścian, 9 wierzchołków).
## Dalszy plan: trójścienny ostrosłup (3 ściany, 4 wierzchołki).
## UV = środek wykałaczki na wysokości danego pierścienia, COLOR.rg = środek podstawy + 0,5,
## UV2.x = część: 0 podstawa, 1 pierścień kłosa, 2 czubek.
static func build_tuft_mesh(detailed: bool = true) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var bases: Array[Vector2] = [Vector2(-0.07, -0.05), Vector2(0.06, -0.07), Vector2(0.08, 0.06), Vector2(-0.05, 0.08)]
	var vertex: int = 0
	for base_value in bases:
		var base: Vector2 = base_value + Vector2(rng.randf_range(-0.03, 0.03), rng.randf_range(-0.03, 0.03))
		var lean: Vector2 = base.normalized() * rng.randf_range(0.03, 0.08) + Vector2(rng.randf_range(-0.03, 0.03), rng.randf_range(-0.03, 0.03))
		var tall: float = rng.randf_range(0.82, 1.08)
		var width: float = rng.randf_range(0.022, 0.032)
		var yaw: float = rng.randf() * TAU
		var sides: int = 4 if detailed else 3
		var rings: Array = [[0.0, width, 0.0]]
		if detailed:
			rings.append([0.7, width * 0.8, 1.0])
		var start: int = vertex
		for ring in rings:
			var y: float = float(ring[0]) * tall
			var center: Vector2 = base + lean * float(ring[0])
			for k in sides:
				var angle: float = yaw + TAU * k / sides
				var radial := Vector3(cos(angle), 0.0, sin(angle))
				st.set_uv(center)
				st.set_uv2(Vector2(float(ring[2]), 0.0))
				st.set_color(Color(base.x + 0.5, base.y + 0.5, 0.0))
				st.set_normal((radial * 0.6 + Vector3.UP).normalized())
				st.add_vertex(Vector3(center.x, y, center.y) + radial * float(ring[1]))
				vertex += 1
		var apex_center: Vector2 = base + lean
		st.set_uv(apex_center)
		st.set_uv2(Vector2(2.0, 0.0))
		st.set_color(Color(base.x + 0.5, base.y + 0.5, 0.0))
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(apex_center.x, tall, apex_center.y))
		var apex: int = vertex
		vertex += 1
		if detailed:
			for k in sides:
				var a: int = start + k
				var b: int = start + (k + 1) % sides
				var c: int = a + sides
				var d: int = b + sides
				for index in [a, c, b, b, c, d, c, apex, d]:
					st.add_index(index)
		else:
			for k in sides:
				for index in [start + k, apex, start + (k + 1) % sides]:
					st.add_index(index)
	return st.commit()


## Jakość grafiki (files/graphics.json): zasięgi kółka szczegółów wokół punktu skupienia.
func apply_quality(preset: Dictionary) -> void:
	_detail_m = clampf(float(preset.get("crop_detail_m", CROP_DETAIL_M)), 0.0, 1000.0)
	_fade_m = maxf(0.5, float(preset.get("crop_fade_m", CROP_FADE_M)))
	_visible_m = maxf(_detail_m, float(preset.get("crop_visible_m", CROP_VISIBLE_M)))
	_thin_from_m = clampf(float(preset.get("crop_thin_from_m", CROP_THIN_FROM_M)), _detail_m, _visible_m)
	_apply_lod_uniforms()
	if is_finite(_focus_local.x):
		_update_levels()


func _apply_lod_uniforms() -> void:
	for material in [_crop_material, _simple_material, _canopy_material]:
		if material == null:
			continue
		material.set_shader_parameter("detail_end", _detail_m)
		material.set_shader_parameter("fade_m", _fade_m)
		material.set_shader_parameter("thin_start", _thin_from_m)
		material.set_shader_parameter("visible_end", _visible_m)
