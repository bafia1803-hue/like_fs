extends Node3D
## Widok 3D jednego pola: powierzchnia gleby i kępki roślin.
## Stan komórek czyta wyłącznie z tekstury field_grid.stage_texture, więc zmiana fazy
## (siew, wzrost, zbiór, kultywacja) nie wymaga przebudowy siatek na CPU.

const CropShader = preload("res://shaders/crop.gdshader")
const GroundShader = preload("res://shaders/field_ground.gdshader")

const TUFT_SPACING_M: float = 0.5
const CHUNK_M: float = 16.0
## Pełne kępki do tej odległości, dalej uproszczone (mniej wierzchołków), a za CROP_VISIBLE_M
## pole pokazuje już tylko kolorowa powierzchnia gleby.
const CROP_DETAIL_M: float = 45.0
const CROP_VISIBLE_M: float = 115.0

var grid: Node2D
var _crop_material: ShaderMaterial


func configure(field_grid: Node2D, field_data: Dictionary, settings: Dictionary) -> void:
	grid = field_grid
	name = "Field_" + str(field_data["id"])
	var geometry: Dictionary = field_data["geometry"]
	var origin: Array = geometry["origin_m"]
	position = Vector3(float(origin[0]), 0.0, float(origin[1]))
	rotation.y = -deg_to_rad(float(geometry.get("rotation_deg", 0.0)))
	var colors: Dictionary = settings["colors"]
	var soil_color := Color(str(field_data["soil_surface"]["color"]))
	_build_ground(colors, soil_color)
	_build_crops(colors)


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
	var tufts_x: int = int(round(size.x / TUFT_SPACING_M))
	var tufts_z: int = int(round(size.y / TUFT_SPACING_M))
	var per_chunk: int = int(round(CHUNK_M / TUFT_SPACING_M))
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(name)
	var root := Node3D.new()
	root.name = "Crops"
	add_child(root)
	for chunk_z in range(0, tufts_z, per_chunk):
		for chunk_x in range(0, tufts_x, per_chunk):
			var count_x: int = mini(per_chunk, tufts_x - chunk_x)
			var count_z: int = mini(per_chunk, tufts_z - chunk_z)
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.use_custom_data = true
			multimesh.mesh = mesh
			multimesh.instance_count = count_x * count_z
			var far_multimesh := MultiMesh.new()
			far_multimesh.transform_format = MultiMesh.TRANSFORM_3D
			far_multimesh.use_custom_data = true
			far_multimesh.mesh = simple_mesh
			far_multimesh.instance_count = count_x * count_z
			var buffer := PackedFloat32Array()
			buffer.resize(multimesh.instance_count * 16)
			var i: int = 0
			var origin := Vector3(chunk_x * TUFT_SPACING_M, 0.0, chunk_z * TUFT_SPACING_M)
			for tz in count_z:
				for tx in count_x:
					var local := Vector3((tx + 0.5) * TUFT_SPACING_M, 0.03, (tz + 0.5) * TUFT_SPACING_M)
					local.x += rng.randf_range(-0.08, 0.08)
					local.z += rng.randf_range(-0.08, 0.08)
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
			multimesh.buffer = buffer
			far_multimesh.buffer = buffer
			var near := MultiMeshInstance3D.new()
			near.multimesh = multimesh
			# Bez marginesów na granicy poziomów: margines działa jak histereza
			# i przy obu ustawionych mógłby na chwilę ukryć oba poziomy naraz.
			near.visibility_range_end = CROP_DETAIL_M
			var far := MultiMeshInstance3D.new()
			far.multimesh = far_multimesh
			far.visibility_range_begin = CROP_DETAIL_M
			far.visibility_range_end = CROP_VISIBLE_M
			far.visibility_range_end_margin = 8.0
			for instance in [near, far]:
				instance.position = origin
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				instance.extra_cull_margin = 0.3
				root.add_child(instance)


## Kępka źdźbeł z kłosami i liśćmi; wysokość jednostkowa (skalowana w shaderze).
## UV = środek źdźbła, UV2 = (część, położenie wzdłuż części).
## detailed = false: wersja na dalszy plan (3 źdźbła, bez drugiego kłosa i liści).
static func build_tuft_mesh(detailed: bool = true) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var stalks: Array[Vector2] = []
	for gz in 2:
		for gx in 3:
			stalks.append(Vector2((gx - 1) * 0.15 + rng.randf_range(-0.05, 0.05),
				(gz - 0.5) * 0.2 + rng.randf_range(-0.05, 0.05)))
	var ear_start: float = 0.68
	if not detailed:
		stalks = [stalks[0], stalks[2], stalks[4]]
	for stalk in stalks:
		var yaw: float = rng.randf() * PI
		var side := Vector3(cos(yaw), 0.0, sin(yaw))
		var tall: float = rng.randf_range(0.88, 1.08)
		var center := Vector3(stalk.x, 0.0, stalk.y)
		var lean := Vector3(rng.randf_range(-0.04, 0.04), 0.0, rng.randf_range(-0.04, 0.04))
		var stem_w: float = 0.022
		var ear_w: float = 0.05
		var p := func(y: float, w: float) -> Array:
			var c: Vector3 = center + lean * y + Vector3(0.0, y * tall, 0.0)
			return [c - side * w, c + side * w]
		var a: Array = p.call(0.0, stem_w)
		var b: Array = p.call(ear_start, stem_w)
		_quad(st, a[0], a[1], b[1], b[0], stalk, 0.0, 0.0, ear_start)
		var c0: Array = p.call(ear_start, ear_w)
		var c1: Array = p.call(1.0, ear_w * 0.7)
		_quad(st, c0[0], c0[1], c1[1], c1[0], stalk, 1.0, 0.0, 1.0)
		if not detailed:
			continue
		# drugi, prostopadły kłos daje objętość
		var side2 := Vector3(-side.z, 0.0, side.x)
		var e0: Vector3 = center + lean * ear_start + Vector3(0.0, ear_start * tall, 0.0)
		var e1: Vector3 = center + lean + Vector3(0.0, tall, 0.0)
		_quad(st, e0 - side2 * ear_w * 0.8, e0 + side2 * ear_w * 0.8, e1 + side2 * ear_w * 0.55, e1 - side2 * ear_w * 0.55, stalk, 1.0, 0.0, 1.0)
		# liść odchylony na zewnątrz
		var out := Vector3(stalk.x, 0.0, stalk.y).normalized() if stalk.length() > 0.01 else side2
		var l0: Vector3 = center + Vector3(0.0, 0.05, 0.0)
		var l1: Vector3 = center + out * 0.16 + Vector3(0.0, 0.5 * tall, 0.0)
		var lw := Vector3(-out.z, 0.0, out.x) * 0.035
		_quad(st, l0 - lw, l0 + lw, l1 + lw * 0.2, l1 - lw * 0.2, stalk, 2.0, 0.0, 1.0)
	st.generate_normals()
	st.index()
	return st.commit()


static func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		stalk: Vector2, part: float, t0: float, t1: float) -> void:
	# a,b – dół; c,d – góra. UV2.y – wysokość wzdłuż części (do cieniowania).
	var verts := [a, b, c, a, c, d]
	for v in verts:
		st.set_uv(stalk)
		st.set_uv2(Vector2(part, v.y))
		st.add_vertex(v)
