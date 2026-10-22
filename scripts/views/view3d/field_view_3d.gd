extends Node3D
## Widok 3D jednego pola: powierzchnia gleby i kępki roślin.
## Stan komórek czyta wyłącznie z tekstury field_grid.stage_texture, więc zmiana fazy
## (siew, wzrost, zbiór, kultywacja) nie wymaga przebudowy siatek na CPU.
##
## Optymalizacja: kępka to 4 proste „wykałaczki” (statyczne, bez wiatru), wszystkie kępki
## kawałka pola to jeden MultiMesh (1 wywołanie rysowania), a kawałki bez roślin
## (wg field_grid.block_counts) są w ogóle ukryte.

const CropShader = preload("res://shaders/crop.gdshader")
const GroundShader = preload("res://shaders/field_ground.gdshader")

const TUFTS_PER_CHUNK: int = 27         # 16 m / 27 ≈ 0,6 m między kępkami
const CHUNK_M: float = 16.0
## Pełne kępki (8 ścian na wykałaczkę) do tej odległości, dalej 3 ściany, a za CROP_VISIBLE_M
## pole pokazuje już tylko kolorowa powierzchnia gleby.
const CROP_DETAIL_M: float = 40.0
const CROP_VISIBLE_M: float = 110.0

var grid: Node2D
var _crop_material: ShaderMaterial
## [węzeł kawałka, blok od, blok do]
var _chunks: Array = []
var _blocks_revision: int = -1


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
	if _sale_sign != null:
		_sale_sign.visible = not bool(grid.owned)
	if grid != null and int(grid.blocks_revision) != _blocks_revision:
		_blocks_revision = int(grid.blocks_revision)
		for chunk in _chunks:
			chunk[0].visible = int(grid.call("plants_in_blocks", chunk[1], chunk[2])) > 0


func _build_crops(colors: Dictionary) -> void:
	_crop_material = ShaderMaterial.new()
	_crop_material.shader = CropShader
	_crop_material.set_shader_parameter("stage_tex", grid.stage_texture)
	_crop_material.set_shader_parameter("color_light", Color(str(colors["light"])))
	_crop_material.set_shader_parameter("color_dark", Color(str(colors["dark"])))
	_crop_material.set_shader_parameter("color_ready", Color(str(colors["ready"])))
	var mesh: ArrayMesh = build_tuft_mesh(true)
	mesh.surface_set_material(0, _crop_material)
	var simple_mesh: ArrayMesh = build_tuft_mesh(false)
	simple_mesh.surface_set_material(0, _crop_material)
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
			var buffer := PackedFloat32Array()
			buffer.resize(count_x * count_z * 16)
			var i: int = 0
			var origin := Vector3(chunk_x * spacing, 0.0, chunk_z * spacing)
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
					var o: int = i * 16
					# Układ bufora: 3 wiersze bazy z przesunięciem (12 liczb) + 4 dane własne.
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
					buffer[o + 14] = rng.randf()
					buffer[o + 15] = 0.0
					i += 1
			var chunk := Node3D.new()
			chunk.position = origin
			chunk.visible = false
			root.add_child(chunk)
			for level in 2:
				var multimesh := MultiMesh.new()
				multimesh.transform_format = MultiMesh.TRANSFORM_3D
				multimesh.use_custom_data = true
				multimesh.mesh = mesh if level == 0 else simple_mesh
				multimesh.instance_count = count_x * count_z
				multimesh.buffer = buffer
				var instance := MultiMeshInstance3D.new()
				instance.multimesh = multimesh
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				instance.extra_cull_margin = 0.3
				# Bez marginesów na granicy poziomów: margines działa jak histereza
				# i mógłby na chwilę ukryć oba poziomy naraz.
				if level == 0:
					instance.visibility_range_end = CROP_DETAIL_M
				else:
					instance.visibility_range_begin = CROP_DETAIL_M
					instance.visibility_range_end = CROP_VISIBLE_M
				chunk.add_child(instance)
			var end := Vector2(origin.x + count_x * spacing, origin.z + count_z * spacing) - Vector2(0.01, 0.01)
			_chunks.append([chunk,
				Vector2i(floori(origin.x / block_m), floori(origin.z / block_m)),
				Vector2i(floori(end.x / block_m), floori(end.y / block_m))])


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
