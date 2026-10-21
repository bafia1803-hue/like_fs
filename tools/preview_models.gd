extends SceneTree
## Podgląd modeli: godot --rendering-driver opengl3 -s tools/preview_models.gd -- <katalog_wyjściowy>
## Renderuje każdą maszynę i dekoracje w scenie z oświetleniem gry.

const MACHINES := ["tractor_basic", "trailer_basic", "combine_basic", "header_grain", "seeder_basic", "cultivator_basic"]
const WORLD := ["tree_round", "tree_pine", "bush", "barn", "house", "silo_tower", "grain_pit", "hay_bale", "fence", "grain_elevator", "seed_station"]
const EnvScript = preload("res://scripts/view3d/world_environment_3d.gd")

var out_dir: String = "user://"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty():
		out_dir = args[0]
	call_deferred("_run")


func _run() -> void:
	var root3 := Node3D.new()
	get_root().add_child(root3)
	var env = EnvScript.new()
	root3.add_child(env)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("#86c95f")
	mat.roughness = 1.0
	ground.material_override = mat
	root3.add_child(ground)
	var camera := Camera3D.new()
	camera.fov = 40
	root3.add_child(camera)
	camera.make_current()

	for id in MACHINES:
		var scene: PackedScene = load("res://models/machines/%s.glb" % id)
		var model: Node3D = scene.instantiate()
		root3.add_child(model)
		var aabb := _aabb(model)
		var size: float = maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
		var center := aabb.get_center()
		for view in [["front", Vector3(-1.0, 0.55, -1.15)], ["back", Vector3(1.1, 0.6, 1.0)]]:
			var dir: Vector3 = view[1].normalized()
			camera.look_at_from_position(center + dir * size * 1.55, center, Vector3.UP)
			await _frames(4)
			_save("%s_%s" % [id, view[0]])
		model.queue_free()
		await _frames(1)

	var x := -40.0
	var spawned: Array[Node3D] = []
	for id in WORLD:
		var scene: PackedScene = load("res://models/world/%s.glb" % id)
		var model: Node3D = scene.instantiate()
		root3.add_child(model)
		var aabb := _aabb(model)
		model.position.x = x - aabb.position.x
		x += aabb.size.x + 3.0
		spawned.append(model)
	var mid := (x - 40.0) * 0.5 - 20.0
	camera.look_at_from_position(Vector3(mid - 5, 18, 42), Vector3(mid - 5, 3, 0), Vector3.UP)
	await _frames(4)
	_save("world_models")
	quit()


func _aabb(node: Node) -> AABB:
	var result := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = child
		var box: AABB = mi.global_transform * mi.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	return result


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _save(name: String) -> void:
	var image := get_root().get_texture().get_image()
	var path := out_dir.path_join(name + ".png")
	image.save_png(path)
	print("zapisano ", path)
