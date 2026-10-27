extends Node3D
## Otoczenie świata 3D: łąka, kępki trawy i kwiatki, drzewa, zabudowania, chmury i kraty silosów.
## Wszystko jest dekoracją bez kolizji; dekoracje stoją poza granicą danych mapy (world_bounds).
## Farmę (plac, budynki, silosy, stanowiska) rysuje farm_3d.gd na podstawie map.json.

const GrassGroundShader = preload("res://shaders/grass_ground.gdshader")
const GrassTuftShader = preload("res://shaders/grass_tuft.gdshader")

const GROUND_SIZE_M: float = 1600.0
const GRASS_CHUNK_M: float = 24.0
const GRASS_VISIBLE_M: float = 75.0
## Drzewa w kafelkach (osobne MultiMesh), żeby kamera i cienie słońca odrzucały niewidoczne.
const TREE_TILE_M: float = 80.0
## Drzewa dalej niż tyle od środka mapy (horyzont) nigdy nie rzucają cienia.
const TREE_SHADOW_RADIUS_M: float = 110.0

var _world_rect := Rect2()
var _blocked: Array[Rect2] = []
var _clouds: Array[Node3D] = []
var _farm_rect := Rect2()
var _rng := RandomNumberGenerator.new()
var _grass_instances: Array[MultiMeshInstance3D] = []
var _shadow_trees: Array[MultiMeshInstance3D] = []


func configure(map_data: Dictionary) -> void:
	name = "Terrain"
	_rng.seed = 20261021
	var bounds: Dictionary = map_data["world_bounds"]
	_world_rect = Rect2(_vec(bounds["origin_m"]), _vec(bounds["size_m"]))
	var holes: Array[Vector4] = []
	for field in map_data.get("fields", []):
		var geometry: Dictionary = field["geometry"]
		var rect := Rect2(_vec(geometry["origin_m"]), _vec(geometry["size_m"]))
		_blocked.append(rect.grow(0.4))
		if is_zero_approx(float(geometry.get("rotation_deg", 0.0))):
			holes.append(Vector4(rect.position.x + 0.05, rect.position.y + 0.05, rect.end.x - 0.05, rect.end.y - 0.05))
	for point in map_data.get("unload_points", []):
		var area: Dictionary = point["area"]
		var size := Vector2(float(area["width_m"]), float(area["length_m"])) + Vector2(1.0, 1.0)
		_blocked.append(Rect2(_vec(area["center_m"]) - size * 0.5, size))
	# plac farmy: bez trawy, z dziurą w łące (rysuje go farm_3d.gd)
	for surface in map_data.get("surfaces", []):
		var rect := Rect2(_vec(surface["origin_m"]), _vec(surface["size_m"]))
		_blocked.append(rect.grow(0.5))
		_farm_rect = rect if _farm_rect.size == Vector2.ZERO else _farm_rect.merge(rect)
		if is_zero_approx(float(surface.get("rotation_deg", 0.0))):
			holes.append(Vector4(rect.position.x + 0.05, rect.position.y + 0.05, rect.end.x - 0.05, rect.end.y - 0.05))
	_build_ground(holes)
	_build_grass()
	_build_scenery()
	_build_clouds()


func _build_ground(holes: Array[Vector4]) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(GROUND_SIZE_M, GROUND_SIZE_M)
	var material := ShaderMaterial.new()
	material.shader = GrassGroundShader
	var hole_values: Array[Vector4] = []
	for i in 8:
		hole_values.append(holes[i] if i < holes.size() else Vector4.ZERO)
	material.set_shader_parameter("holes", hole_values)
	material.set_shader_parameter("hole_count", mini(holes.size(), 8))
	var ground := MeshInstance3D.new()
	ground.name = "Meadow"
	ground.mesh = plane
	ground.material_override = material
	ground.position = Vector3(_world_rect.get_center().x, 0.0, _world_rect.get_center().y)
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)


func _is_blocked(point: Vector2) -> bool:
	for rect in _blocked:
		if rect.has_point(point):
			return true
	return false


func _build_grass() -> void:
	var grass_mesh := _grass_tuft_mesh()
	var flower_mesh := _flower_mesh()
	var material := ShaderMaterial.new()
	material.shader = GrassTuftShader
	grass_mesh.surface_set_material(0, material)
	flower_mesh.surface_set_material(0, material)
	var area := _world_rect.grow(50.0)
	var root := Node3D.new()
	root.name = "Grass"
	add_child(root)
	var grass_colors := [Color("#74b54c"), Color("#62a242"), Color("#86bf56"), Color("#58953c")]
	var flower_colors := [Color("#fff8e6"), Color("#ffd75e"), Color("#ff9fb5"), Color("#c8a8ff")]
	var cz: float = area.position.y
	while cz < area.end.y:
		var cx: float = area.position.x
		while cx < area.end.x:
			var grass: Array[Transform3D] = []
			var grass_col: Array[Color] = []
			var flowers: Array[Transform3D] = []
			var flower_col: Array[Color] = []
			var count: int = int(GRASS_CHUNK_M * GRASS_CHUNK_M * 1.0)
			for i in count:
				var p := Vector2(cx + _rng.randf() * GRASS_CHUNK_M, cz + _rng.randf() * GRASS_CHUNK_M)
				if _is_blocked(p):
					continue
				var t := Transform3D(Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3.ONE * _rng.randf_range(0.7, 1.35)),
					Vector3(p.x - cx, 0.0, p.y - cz))
				if _rng.randf() < 0.06:
					flowers.append(t)
					flower_col.append(flower_colors[_rng.randi() % flower_colors.size()])
				else:
					grass.append(t)
					grass_col.append(grass_colors[_rng.randi() % grass_colors.size()])
			for pair in [[grass, grass_col, grass_mesh], [flowers, flower_col, flower_mesh]]:
				var transforms: Array = pair[0]
				if transforms.is_empty():
					continue
				var colors: Array = pair[1]
				var multimesh := MultiMesh.new()
				multimesh.transform_format = MultiMesh.TRANSFORM_3D
				multimesh.use_colors = true
				multimesh.mesh = pair[2]
				multimesh.instance_count = transforms.size()
				multimesh.buffer = _instance_buffer(transforms, colors)
				var instance := MultiMeshInstance3D.new()
				instance.multimesh = multimesh
				instance.position = Vector3(cx, 0.0, cz)
				instance.visibility_range_end = GRASS_VISIBLE_M
				instance.visibility_range_end_margin = 10.0
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				root.add_child(instance)
				_grass_instances.append(instance)
			cx += GRASS_CHUNK_M
		cz += GRASS_CHUNK_M


func _grass_tuft_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in 5:
		var angle: float = TAU * i / 5.0 + 0.4
		var out := Vector3(cos(angle), 0.0, sin(angle))
		var side := Vector3(-out.z, 0.0, out.x) * 0.035
		var base := out * 0.03
		var tip := out * 0.11 + Vector3(0.0, 0.2 + 0.1 * float(i % 3) / 2.0, 0.0)
		for v in [base - side, base + side, tip]:
			st.set_color(Color.WHITE)
			st.add_vertex(v)
	st.generate_normals()
	return st.commit()


func _flower_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stem := Color("#5d9e43")
	for v in [Vector3(-0.01, 0, 0), Vector3(0.01, 0, 0), Vector3(0.0, 0.2, 0)]:
		st.set_color(stem)
		st.add_vertex(v)
	# płatki: mały, płaski wielokąt na górze
	var center := Vector3(0.0, 0.2, 0.0)
	for i in 5:
		var a0: float = TAU * i / 5.0
		var a1: float = TAU * (i + 1) / 5.0
		for v in [center, center + Vector3(cos(a0), 0.15, sin(a0)) * 0.05, center + Vector3(cos(a1), 0.15, sin(a1)) * 0.05]:
			st.set_color(Color.WHITE)
			st.add_vertex(v)
	st.generate_normals()
	return st.commit()


func _build_scenery() -> void:
	var trees := {
		"tree_round": _mesh_of("res://models/world/tree_round.glb"),
		"tree_pine": _mesh_of("res://models/world/tree_pine.glb"),
		"bush": _mesh_of("res://models/world/bush.glb"),
	}
	var placements := {"tree_round": [], "tree_pine": [], "bush": []}
	var rect := _world_rect
	# pas drzew tuż za granicą mapy
	var perimeter: Array = []
	var step: float = 7.0
	var x: float = rect.position.x - 10.0
	while x <= rect.end.x + 10.0:
		perimeter.append([Vector2(x, rect.position.y), Vector2(0, -1)])
		perimeter.append([Vector2(x, rect.end.y), Vector2(0, 1)])
		x += step
	var z: float = rect.position.y
	while z <= rect.end.y:
		perimeter.append([Vector2(rect.position.x, z), Vector2(-1, 0)])
		perimeter.append([Vector2(rect.end.x, z), Vector2(1, 0)])
		z += step
	# dom i bele przy farmie, za granicą mapy
	var yard := Rect2(rect.position.x - 30.0, 205.0, 28.0, 50.0)
	for entry in perimeter:
		var base: Vector2 = entry[0]
		var normal: Vector2 = entry[1]
		for layer in 2:
			if _rng.randf() < 0.25:
				continue
			var offset: float = 8.0 + layer * 9.0 + _rng.randf_range(-2.5, 3.5)
			var p: Vector2 = base + normal * offset + Vector2(_rng.randf_range(-2.5, 2.5), _rng.randf_range(-2.5, 2.5))
			if yard.has_point(p):
				continue
			var kind: String = "tree_pine" if _rng.randf() < 0.3 else "tree_round"
			placements[kind].append(_tree_transform(p, _rng.randf_range(1.1, 1.75)))
			if _rng.randf() < 0.35:
				var b: Vector2 = p - normal * _rng.randf_range(3.0, 5.0) + Vector2(_rng.randf_range(-2, 2), _rng.randf_range(-2, 2))
				placements["bush"].append(_tree_transform(b, _rng.randf_range(0.9, 1.5)))
	# odległy horyzont: rzadkie kępy drzew
	for i in 260:
		var angle: float = _rng.randf() * TAU
		var dist: float = _rng.randf_range(120.0, 420.0)
		var p: Vector2 = rect.get_center() + Vector2(cos(angle), sin(angle)) * dist
		if rect.grow(30.0).has_point(p) or yard.has_point(p):
			continue
		var kind: String = "tree_pine" if _rng.randf() < 0.35 else "tree_round"
		placements[kind].append(_tree_transform(p, _rng.randf_range(1.4, 2.4)))
	# Kafelki TREE_TILE_M: kamera i każda kaskada cieni rysuje tylko kafelki w swoim zasięgu
	# (jeden MultiMesh na całą mapę byłby rysowany w całości kilka razy na klatkę).
	var center: Vector2 = rect.get_center()
	for kind in placements:
		var mesh: Mesh = trees[kind]
		if mesh == null:
			continue
		var tiles: Dictionary = {}       # [x, z, cień] -> Array[Transform3D]
		for value in placements[kind]:
			var transform: Transform3D = value
			var point := Vector2(transform.origin.x, transform.origin.z)
			var key: Array = [floori(point.x / TREE_TILE_M), floori(point.y / TREE_TILE_M), point.distance_to(center) < TREE_SHADOW_RADIUS_M]
			if not tiles.has(key):
				tiles[key] = []
			tiles[key].append(transform)
		for key in tiles:
			var list: Array = tiles[key]
			var multimesh := MultiMesh.new()
			multimesh.transform_format = MultiMesh.TRANSFORM_3D
			multimesh.mesh = mesh
			multimesh.instance_count = list.size()
			multimesh.buffer = _instance_buffer(list, [])
			var instance := MultiMeshInstance3D.new()
			instance.name = "Scenery_%s_%d_%d" % [kind, key[0], key[1]]
			instance.multimesh = multimesh
			if bool(key[2]):
				_shadow_trees.append(instance)
			else:
				instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			add_child(instance)
	var fx: float = rect.position.x
	_place("res://models/world/house.glb", Vector3(fx - 16.0, 0.0, 228.0), deg_to_rad(90.0))
	for i in 5:
		_place("res://models/world/hay_bale.glb", Vector3(fx - 22.0, 0.0, 240.0 + i * 1.4), 0.0)
	_place("res://models/world/hay_bale.glb", Vector3(fx - 22.0, 1.25, 240.7), 0.0)
	for i in 12:
		_place("res://models/world/fence.glb", Vector3(fx - 28.0, 0.0, 209.0 + i * 4.0), deg_to_rad(90.0))


## Bufor MultiMesh (TRANSFORM_3D: 12 liczb na instancję, z kolorem 16) zamiast tysięcy wywołań
## set_instance_transform – szybsze budowanie świata.
static func _instance_buffer(transforms: Array, colors: Array) -> PackedFloat32Array:
	var stride: int = 16 if not colors.is_empty() else 12
	var buffer := PackedFloat32Array()
	buffer.resize(transforms.size() * stride)
	for i in transforms.size():
		var t: Transform3D = transforms[i]
		var o: int = i * stride
		buffer[o] = t.basis.x.x
		buffer[o + 1] = t.basis.y.x
		buffer[o + 2] = t.basis.z.x
		buffer[o + 3] = t.origin.x
		buffer[o + 4] = t.basis.x.y
		buffer[o + 5] = t.basis.y.y
		buffer[o + 6] = t.basis.z.y
		buffer[o + 7] = t.origin.y
		buffer[o + 8] = t.basis.x.z
		buffer[o + 9] = t.basis.y.z
		buffer[o + 10] = t.basis.z.z
		buffer[o + 11] = t.origin.z
		if stride == 16:
			var c: Color = colors[i]
			buffer[o + 12] = c.r
			buffer[o + 13] = c.g
			buffer[o + 14] = c.b
			buffer[o + 15] = c.a
	return buffer


## Jakość grafiki: zasięg trawy i cienie drzew.
func apply_quality(preset: Dictionary) -> void:
	var grass_m: float = float(preset.get("grass_visible_m", GRASS_VISIBLE_M))
	for instance in _grass_instances:
		instance.visible = grass_m > 0.0
		instance.visibility_range_end = grass_m
		instance.visibility_range_end_margin = minf(10.0, grass_m * 0.15)
	var shadows: bool = bool(preset.get("tree_shadows", true)) and int(preset.get("shadow_splits", 4)) > 0
	for instance in _shadow_trees:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _tree_transform(p: Vector2, s: float) -> Transform3D:
	var basis := Basis(Vector3.UP, _rng.randf() * TAU).scaled(Vector3(s, s * _rng.randf_range(0.9, 1.15), s))
	return Transform3D(basis, Vector3(p.x, 0.0, p.y))


func _place(path: String, position_m: Vector3, yaw: float, scale_factor: float = 1.0) -> void:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		return
	var node: Node3D = scene.instantiate()
	node.position = position_m
	node.rotation.y = yaw
	node.scale = Vector3.ONE * scale_factor
	add_child(node)


func _mesh_of(path: String) -> Mesh:
	var scene: PackedScene = load(path) as PackedScene
	if scene == null:
		return null
	var node: Node = scene.instantiate()
	var result: Mesh = null
	for child in node.find_children("*", "MeshInstance3D", true, false):
		result = (child as MeshInstance3D).mesh
		break
	node.free()
	return result


func _build_clouds() -> void:
	var scene: PackedScene = load("res://models/world/cloud.glb") as PackedScene
	if scene == null:
		return
	var center := _world_rect.get_center()
	for i in 16:
		var cloud: Node3D = scene.instantiate()
		var angle: float = _rng.randf() * TAU
		var dist: float = _rng.randf_range(60.0, 520.0)
		cloud.position = Vector3(center.x + cos(angle) * dist, _rng.randf_range(75.0, 110.0), center.y + sin(angle) * dist)
		cloud.rotation.y = _rng.randf() * TAU
		cloud.scale = Vector3.ONE * _rng.randf_range(0.9, 2.0)
		for child in cloud.find_children("*", "MeshInstance3D", true, false):
			(child as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(cloud)
		_clouds.append(cloud)


func _process(delta: float) -> void:
	var center := _world_rect.get_center()
	# Z wysokiego widoku mapy chmury zasłaniałyby pole, więc je wtedy chowamy.
	var camera := get_viewport().get_camera_3d()
	var show_clouds: bool = camera == null or camera.global_position.y < 70.0
	for cloud in _clouds:
		cloud.visible = show_clouds
		cloud.position.x += delta * 1.2
		if cloud.position.x > center.x + 600.0:
			cloud.position.x -= 1200.0


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
