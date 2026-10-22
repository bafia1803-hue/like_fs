extends Node3D
## Farma w 3D na podstawie map.json: plac, przeszkody (silosy, elewator, wiata),
## kraty zrzutu z licznikiem silosu, przenośnik załadunku z silosu i stacja nasion.
## Strumienie ziarna pokazują przepływ odczytany z usług farmy (warstwa gry).

const YardShader = preload("res://shaders/yard_ground.gdshader")
const StreamScript = preload("res://scripts/view3d/grain_stream_3d.gd")

var world: Node
var view3d: Node
var _silo_labels: Dictionary = {}       # id silosu -> Label3D
var _streams: Dictionary = {}           # id punktu -> strumień
var _point_labels: Dictionary = {}      # id punktu -> Label3D
var _timer: float = 0.0


func configure(world_node: Node, view_node: Node) -> void:
	name = "Farm3D"
	world = world_node
	view3d = view_node
	var map_data: Dictionary = world.call("get_map_data")
	var obstacles: Dictionary = {}
	for obstacle in map_data.get("static_obstacles", []):
		obstacles[str(obstacle["id"])] = obstacle
	for surface in map_data.get("surfaces", []):
		_build_surface(surface)
	for obstacle in obstacles.values():
		_build_obstacle(obstacle)
	for point in map_data.get("unload_points", []):
		_build_unload_point(point)
	for point in map_data.get("load_points", []):
		_build_load_point(point, obstacles)
	for point in map_data.get("seed_points", []):
		_build_seed_point(point)
	for point in world.call("get_sell_points"):
		_build_sell_point(point)
	var shop: Dictionary = world.call("get_shop_data")
	if shop.get("lot") is Dictionary:
		# Malowany obrys placu, na którym stają kupione maszyny.
		var lot_origin := _vec(shop["lot"]["origin_m"])
		var lot_size := _vec(shop["lot"]["size_m"])
		_marking({"center_m": [lot_origin.x + lot_size.x * 0.5, lot_origin.y + lot_size.y * 0.5],
			"width_m": lot_size.x, "length_m": lot_size.y}, Color("#f2f0e8"))
	_update_labels()


func _build_surface(surface: Dictionary) -> void:
	var size := _vec(surface["size_m"])
	var plane := PlaneMesh.new()
	plane.size = size
	plane.center_offset = Vector3(size.x * 0.5, 0.0, size.y * 0.5)
	var material := ShaderMaterial.new()
	material.shader = YardShader
	material.set_shader_parameter("base_color", Color(str(surface.get("color", "#cdbfa6"))))
	var ground := MeshInstance3D.new()
	ground.name = "Surface_" + str(surface["id"])
	ground.mesh = plane
	ground.material_override = material
	var origin := _vec(surface["origin_m"])
	ground.position = Vector3(origin.x, 0.025, origin.y)
	ground.rotation.y = -deg_to_rad(float(surface.get("rotation_deg", 0.0)))
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	# krawężnik placu
	var border := Color("#a9a297")
	var r := Rect2(origin, size)
	for edge in [[r.position, Vector2(r.end.x, r.position.y)], [Vector2(r.position.x, r.end.y), r.end],
			[r.position, Vector2(r.position.x, r.end.y)], [Vector2(r.end.x, r.position.y), r.end]]:
		_bar(edge[0], edge[1], 0.25, 0.08, border, 0.0)


func _build_obstacle(obstacle: Dictionary) -> void:
	var visual: Dictionary = obstacle.get("visual", {})
	var model: String = str(visual.get("model", ""))
	if model.is_empty():
		return
	var scene: PackedScene = _scene("res://models/world/%s.glb" % model)
	if scene == null:
		return
	var node: Node3D = scene.instantiate()
	node.name = "Obstacle_" + str(obstacle["id"])
	var center := _vec(obstacle["center_m"])
	node.position = Vector3(center.x, 0.0, center.y)
	node.rotation.y = -deg_to_rad(float(obstacle.get("rotation_deg", 0.0)) + float(visual.get("rotation_deg", 0.0)))
	node.scale = Vector3.ONE * float(visual.get("scale", 1.0))
	add_child(node)
	if visual.has("label"):
		_label(Vector3(center.x, float(visual.get("label_height_m", 7.0)), center.y), str(visual["label"]))


func _build_unload_point(point: Dictionary) -> void:
	var area: Dictionary = point["area"]
	var center := _vec(area["center_m"])
	var size := Vector2(float(area["width_m"]), float(area["length_m"]))
	var scene: PackedScene = _scene("res://models/world/grain_pit.glb")
	if scene != null:
		var pit: Node3D = scene.instantiate()
		pit.name = "UnloadPoint_" + str(point["id"])
		pit.position = Vector3(center.x, 0.0, center.y)
		pit.rotation.y = -deg_to_rad(float(area.get("rotation_deg", 0.0)))
		var model_size := _model_size(pit)
		if model_size.x > 0.0:
			pit.scale = Vector3((size.x + 0.9) / model_size.x, 1.0, (size.y + 0.9) / model_size.y)
		add_child(pit)
	var label := _label(Vector3(center.x + size.x * 0.5 + 1.2, 2.8, center.y - size.y * 0.5 - 0.8), str(point["name"]))
	_silo_labels[str(point["id"])] = label
	_post(Vector3(center.x + size.x * 0.5 + 1.2, 0.0, center.y - size.y * 0.5 - 0.8))


func _build_sell_point(point: Dictionary) -> void:
	var area: Dictionary = point["area"]
	var center := _vec(area["center_m"])
	var size := Vector2(float(area["width_m"]), float(area["length_m"]))
	var scene: PackedScene = _scene("res://models/world/grain_pit.glb")
	if scene != null:
		var pit: Node3D = scene.instantiate()
		pit.name = "SellPoint_" + str(point["id"])
		pit.position = Vector3(center.x, 0.0, center.y)
		pit.rotation.y = -deg_to_rad(float(area.get("rotation_deg", 0.0)))
		var model_size := _model_size(pit)
		if model_size.x > 0.0:
			pit.scale = Vector3((size.x + 0.9) / model_size.x, 1.0, (size.y + 0.9) / model_size.y)
		add_child(pit)
	_marking(area, Color("#9be37a"))
	_point_labels[str(point["id"])] = _label(Vector3(center.x + size.x * 0.5 + 1.2, 2.8, center.y + size.y * 0.5), str(point["name"]))
	_post(Vector3(center.x + size.x * 0.5 + 1.2, 0.0, center.y + size.y * 0.5))


func _build_load_point(point: Dictionary, obstacles: Dictionary) -> void:
	var outlet := _vec(point["outlet_m"])
	var height: float = float(point.get("outlet_height_m", 4.8))
	var visual: Dictionary = point.get("visual", {})
	var spout_top := Vector3(outlet.x, height + 0.9, outlet.y)
	# przenośnik rurowy z dachu silosu nad wylot
	var silo: Dictionary = obstacles.get(str(visual.get("from_obstacle_id", "")), {})
	if not silo.is_empty():
		var silo_center := _vec(silo["center_m"])
		var silo_scale: float = float(silo.get("visual", {}).get("scale", 1.0))
		var start := Vector3(silo_center.x, (0.4 + 10.0 + 0.6) * silo_scale, silo_center.y)
		var direction := (Vector3(outlet.x, 0.0, outlet.y) - Vector3(silo_center.x, 0.0, silo_center.y)).normalized()
		start += direction * float(silo.get("radius_m", 3.0)) * 0.8
		_tube(start, spout_top, 0.24, Color("#ddd7c5"))
		for t in [0.15, 0.5, 0.85]:
			_tube(start.lerp(spout_top, t - 0.02), start.lerp(spout_top, t + 0.02), 0.28, Color("#8e8983"))
		var support: Dictionary = obstacles.get(str(visual.get("support_obstacle_id", "")), {})
		if not support.is_empty():
			var s := _vec(support["center_m"])
			var along: float = clampf((Vector2(s.x, s.y) - Vector2(start.x, start.z)).dot(Vector2(direction.x, direction.z)) / Vector2(spout_top.x - start.x, spout_top.z - start.z).length(), 0.0, 1.0)
			var top: Vector3 = start.lerp(spout_top, along)
			_tube(Vector3(s.x, 0.0, s.y), Vector3(s.x, top.y, s.y), 0.16, Color("#6e6a66"))
			_tube(Vector3(s.x, top.y, s.y), top, 0.1, Color("#6e6a66"))
	# rura spustowa nad wylotem
	_tube(spout_top, Vector3(outlet.x, height, outlet.y), 0.2, Color("#8e8983"))
	_tube(Vector3(outlet.x, height + 0.15, outlet.y), Vector3(outlet.x, height - 0.05, outlet.y), 0.26, Color("#4d4846"))
	_marking(point["area"], Color("#ffd166"))
	_point_labels[str(point["id"])] = _label(Vector3(outlet.x, height + 2.0, outlet.y), str(point["name"]))


func _build_seed_point(point: Dictionary) -> void:
	var outlet := _vec(point["outlet_m"])
	var visual: Dictionary = point.get("visual", {})
	var scene: PackedScene = _scene("res://models/world/%s.glb" % str(visual.get("model", "seed_station")))
	if scene != null:
		var station: Node3D = scene.instantiate()
		station.name = "SeedStation_" + str(point["id"])
		station.position = Vector3(outlet.x, 0.0, outlet.y)
		station.rotation.y = -deg_to_rad(float(visual.get("rotation_deg", 0.0)))
		add_child(station)
	_marking(point["area"], Color("#7fd1ff"))
	_point_labels[str(point["id"])] = _label(Vector3(outlet.x, 6.2, outlet.y), str(point["name"]))


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= 0.4:
		_timer = 0.0
		_update_labels()
	for state in world.call("get_farm_points"):
		var definition: Dictionary = state["definition"]
		var id: String = str(definition["id"])
		var flowing: bool = float(state["flow_l_per_s"]) > 0.0
		if not _streams.has(id):
			if not flowing:
				continue
			var stream = StreamScript.new()
			stream.name = "Stream_" + id
			add_child(stream)
			_streams[id] = stream
		var outlet := _vec(definition["outlet_m"])
		var height: float = float(definition.get("outlet_height_m", 3.0))
		var top := Vector3(outlet.x, height - 0.1, outlet.y)
		var bottom: float = float(view3d.call("surface_below", top))
		var width: float = 0.3 if str(state["kind"]) == "load" else 0.16
		_streams[id].call("update_stream", flowing, top, bottom, width)


func _update_labels() -> void:
	for point in world.call("get_sell_points"):
		var sell_label: Label3D = _point_labels.get(str(point["id"]))
		if sell_label != null:
			sell_label.text = "%s\nsprzedano %.0f l" % [point["name"], float(point["sold_l"])] if float(point["sold_l"]) > 0.0 else str(point["name"])
	for silo in world.call("get_silos"):
		var label: Label3D = _silo_labels.get(str(silo["id"]))
		if label == null:
			continue
		var lines := PackedStringArray([str(silo["name"]), "%.0f / %.0f l" % [float(silo["amount_l"]), float(silo["capacity_l"])]])
		label.text = "\n".join(lines)


# ---------------------------------------------------------------------------

func _label(position_m: Vector3, text: String) -> Label3D:
	var label := Label3D.new()
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.pixel_size = 0.01
	label.font_size = 64
	label.outline_size = 16
	label.modulate = Color("#fffaf0")
	label.outline_modulate = Color(0.12, 0.1, 0.08, 0.85)
	label.position = position_m
	label.text = text
	add_child(label)
	return label


func _post(base: Vector3) -> void:
	_tube(base, base + Vector3(0.0, 2.3, 0.0), 0.06, Color("#8a5a36"))


## Malowane linie na placu wokół stanowiska.
func _marking(area: Dictionary, color: Color) -> void:
	var half := Vector2(float(area["width_m"]), float(area["length_m"])) * 0.5
	var pose := Transform2D(deg_to_rad(float(area.get("rotation_deg", 0.0))), _vec(area["center_m"]))
	var corners: Array[Vector2] = [pose * Vector2(-half.x, -half.y), pose * Vector2(half.x, -half.y), pose * half, pose * Vector2(-half.x, half.y)]
	for i in 4:
		_bar(corners[i], corners[(i + 1) % 4], 0.18, 0.012, color, 0.03)


## Płaska belka na ziemi między dwoma punktami.
func _bar(a: Vector2, b: Vector2, width: float, height: float, color: Color, y: float) -> void:
	var length: float = a.distance_to(b)
	if length < 0.01:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3(width, height, length + width)
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color, 1.0)
	var mid: Vector2 = (a + b) * 0.5
	instance.position = Vector3(mid.x, y + height * 0.5, mid.y)
	instance.rotation.y = atan2(b.x - a.x, b.y - a.y)
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


## Walec (rura, słup) między dwoma punktami w świecie.
func _tube(a: Vector3, b: Vector3, radius: float, color: Color) -> void:
	var length: float = a.distance_to(b)
	if length < 0.01:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length
	mesh.radial_segments = 8
	mesh.rings = 1
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = _material(color, 0.8)
	var up: Vector3 = (b - a) / length
	var side: Vector3 = up.cross(Vector3.RIGHT)
	if side.length_squared() < 0.01:
		side = up.cross(Vector3.FORWARD)
	side = side.normalized()
	instance.transform = Transform3D(Basis(up.cross(side), up, side), (a + b) * 0.5)
	add_child(instance)


func _material(color: Color, roughness: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	return material


func _model_size(node: Node3D) -> Vector2:
	var result := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = (child as MeshInstance3D).get_aabb()
		result = box if first else result.merge(box)
		first = false
	return Vector2(result.size.x, result.size.z)


func _scene(path: String) -> PackedScene:
	return load(path) as PackedScene if ResourceLoader.exists(path) else null


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
