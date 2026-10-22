extends Node3D
## „Zestaw widmo” w 3D: półprzezroczysta kopia pojazdu i narzędzia stojąca na miejscu startu
## oczekującego przejazdu (RouteSystem.armed), plus czerwony wskaźnik wysoko nad nim.
## Tylko wygląd: bez kolizji i fizyki. Pozę liczy RoutePreview (chwila 0 trasy).
##
## Przezroczysta jest tylko zewnętrzna skorupa całego zestawu (dwa przebiegi):
##   1. DEPTH_SHADER (render_priority niższy) – wszystkie części zestawu zapisują tylko głębię,
##      bez koloru. Kolejność przezroczystych obiektów ustala najpierw render_priority, więc ten
##      przebieg kończy się dla całego zestawu, zanim cokolwiek zostanie pokolorowane.
##   2. materiał koloru (next_pass, wyższy priorytet) – rysuje się tylko tam, gdzie jego głębia
##      zgadza się z zapisaną, czyli na powierzchniach widocznych z kamery. Koła, felgi czy rama
##      schowane za karoserią w ogóle nie są rysowane i nie prześwitują.

const RoutePreviewScript = preload("res://scripts/routes/route_preview.gd")
const MachineViewScript = preload("res://scripts/view3d/machine_view_3d.gd")
const GHOST_ALPHA: float = 0.45
const DEPTH_PRIORITY: int = -100
const COLOR_PRIORITY: int = -99
const MARKER_HEIGHT_M: float = 14.0

var world: Node
var _route_id: String = ""
var _ghost: Node3D
var _marker: Node3D
var _time: float = 0.0


func configure(world_node: Node) -> void:
	name = "RouteGhost3D"
	world = world_node


func _process(delta: float) -> void:
	_time += delta
	var routes: Node = world.call("get_route_system")
	var armed: Dictionary = routes.get("armed") if routes != null else {}
	var route_id: String = str(armed.get("route", {}).get("id", "")) if not armed.is_empty() else ""
	if route_id != _route_id:
		_route_id = route_id
		_rebuild(armed)
	if _marker != null:
		# Wskaźnik delikatnie unosi się i obraca, żeby był widoczny z daleka.
		_marker.position.y = MARKER_HEIGHT_M + sin(_time * 2.0) * 0.6
		_marker.rotation.y = _time * 0.8


func _rebuild(armed: Dictionary) -> void:
	if _ghost != null:
		_ghost.queue_free()
	_ghost = null
	_marker = null
	if armed.is_empty():
		return
	var preview = RoutePreviewScript.new()
	if not preview.setup(armed["route"], world.call("get_catalog_models")):
		return
	_ghost = Node3D.new()
	_ghost.name = "Ghost"
	add_child(_ghost)
	var sample: Array = preview.sample_at(0.0)
	for part in preview.parts_at(0.0):
		var model: Node3D = MachineViewScript.instantiate_model(part["model"])
		var transforms: Dictionary = part["transforms"]
		model.transform = _to_3d(transforms["body"])
		_ghost.add_child(model)
		if part["role"] == "vehicle":
			_pose_vehicle(model, part["model"], float(sample[6]) if sample.size() >= 7 else 0.0)
		else:
			_pose_tool(model, part["model"], transforms, preview.working_at(0.0), preview.unfolded_at(0.0))
	# Widmo pokazuje sam zestaw, bez ładunku (model ma ziarno do animacji zapełnienia).
	for fill in _ghost.find_children("grain_fill", "", true, false):
		fill.visible = false
	_make_ghostly(_ghost)
	# Wskaźnik wysoko nad pojazdem (porusza się w _process, więc osobny węzeł).
	var start: Transform3D = _to_3d(preview.parts_at(0.0)[0]["transforms"]["body"])
	var holder := Node3D.new()
	holder.name = "MarkerHolder"
	holder.position = Vector3(start.origin.x, 0.0, start.origin.z)
	_ghost.add_child(holder)
	_marker = _build_marker()
	holder.add_child(_marker)


## Skręt kół jak na starcie nagrania.
func _pose_vehicle(model: Node3D, definition: Dictionary, steering: float) -> void:
	for axle in definition.get("axles", []):
		for side in ["L", "R"]:
			var node: Node3D = model.find_child("steer_%s_%s" % [axle["id"], side], true, false) as Node3D
			if node != null:
				node.rotation.y = -deg_to_rad(float(axle["max_steering_deg"]) * float(axle["steering_ratio"]) * steering)


## Wózek przyczepy, rozłożenie skrzydeł i opuszczenie narzędzia jak na starcie nagrania.
func _pose_tool(model: Node3D, definition: Dictionary, transforms: Dictionary, working: bool, unfolded: float) -> void:
	if transforms.has("front_carriage"):
		var carriage: Node3D = model.find_child("carriage", true, false) as Node3D
		if carriage != null:
			var relative: float = (transforms["front_carriage"] as Transform2D).get_rotation() - (transforms["body"] as Transform2D).get_rotation()
			carriage.rotation.y = -wrapf(relative, -PI, PI)
	for side in [["wing_L", -1.0], ["wing_R", 1.0]]:
		var wing: Node3D = model.find_child(side[0], true, false) as Node3D
		if wing != null:
			wing.rotation.z = float(side[1]) * PI * 0.5 * (1.0 - unfolded)
	var lift: Node3D = model.find_child("lift", true, false) as Node3D
	if lift != null and not working and str(definition.get("physics_kind", "")) != "rigid_mounted":
		lift.position.y = float(definition.get("visual", {}).get("lift_height_m", 0.4))
	for side in [["marker_L", -1.0], ["marker_R", 1.0]]:
		var marker: Node3D = model.find_child(side[0], true, false) as Node3D
		if marker != null and not working:
			marker.rotation.z = float(side[1]) * deg_to_rad(100.0)


func _make_ghostly(root: Node) -> void:
	var depth_shader := Shader.new()
	depth_shader.code = """
shader_type spatial;
// Przebieg 1 zestawu widmo: tylko głębia, kolor niewidoczny.
render_mode unshaded, cull_back, depth_draw_always, blend_mix, shadows_disabled;
void fragment() {
	ALBEDO = vec3(0.0);
	ALPHA = 0.0;
}
"""
	for child in root.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = child
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		if mesh_instance.mesh == null:
			continue
		for i in mesh_instance.mesh.get_surface_count():
			var source: Material = mesh_instance.get_surface_override_material(i)
			if source == null:
				source = mesh_instance.mesh.surface_get_material(i)
			var color: StandardMaterial3D = source.duplicate() if source is StandardMaterial3D else StandardMaterial3D.new()
			color.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			color.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
			color.albedo_color = Color(color.albedo_color.lerp(Color("#bfe3ff"), 0.35), GHOST_ALPHA)
			color.render_priority = COLOR_PRIORITY
			var depth := ShaderMaterial.new()
			depth.shader = depth_shader
			depth.render_priority = DEPTH_PRIORITY
			depth.next_pass = color
			mesh_instance.set_surface_override_material(i, depth)


func _build_marker() -> Node3D:
	var marker := Node3D.new()
	marker.name = "StartMarker"
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(1.0, 0.18, 0.15, 0.6)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cone := CylinderMesh.new()
	cone.top_radius = 1.6
	cone.bottom_radius = 0.0
	cone.height = 3.2
	cone.radial_segments = 4
	cone.rings = 1
	var tip := MeshInstance3D.new()
	tip.mesh = cone
	tip.material_override = material
	tip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.add_child(tip)
	var beam_mesh := CylinderMesh.new()
	beam_mesh.top_radius = 0.12
	beam_mesh.bottom_radius = 0.12
	beam_mesh.height = MARKER_HEIGHT_M - 3.0
	beam_mesh.radial_segments = 6
	var beam := MeshInstance3D.new()
	beam.mesh = beam_mesh
	var beam_material: StandardMaterial3D = material.duplicate()
	beam_material.albedo_color = Color(1.0, 0.2, 0.15, 0.25)
	beam.material_override = beam_material
	beam.position.y = -1.6 - beam_mesh.height * 0.5
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.add_child(beam)
	return marker


func _to_3d(xf: Transform2D) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, -xf.get_rotation()), Vector3(xf.origin.x, 0.0, xf.origin.y))
