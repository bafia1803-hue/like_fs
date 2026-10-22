extends Node3D
## Trasy w 3D: tylko linia aktualnie nagrywanego przejazdu (zielona).
## Przebiegi zapisanych tras ogląda się w oknie Trasy (minimapa), nie w świecie 3D.
## Zestaw widmo przy oczekującym przejeździe rysuje RouteGhost3D.

var routes: Node2D
var units: float = 40.0

var _record := MeshInstance3D.new()
var _record_count: int = -1


func configure(route_system: Node2D, scale_units: float) -> void:
	routes = route_system
	units = scale_units
	name = "Routes3D"
	for item in [[_record, Color("#66ffb0")]]:
		var mesh_instance: MeshInstance3D = item[0]
		mesh_instance.mesh = ImmediateMesh.new()
		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = item[1]
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color.a = 0.9
		material.no_depth_test = true
		material.render_priority = 1
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		mesh_instance.material_override = material
		add_child(mesh_instance)


func _process(_delta: float) -> void:
	if not is_instance_valid(routes):
		return
	var record_revision: int = int(routes.get("record_revision"))
	if record_revision != _record_count:
		_record_count = record_revision
		_ribbon(_record.mesh, routes.get("record_path"), 0.28)


## points – ścieżka w metrach (x, y mapy).
func _ribbon(mesh: ImmediateMesh, points: PackedVector2Array, width: float) -> void:
	mesh.clear_surfaces()
	if points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in points.size():
		var p: Vector2 = points[i]
		var a: Vector2 = points[maxi(i - 1, 0)]
		var b: Vector2 = points[mini(i + 1, points.size() - 1)]
		var direction: Vector2 = (b - a).normalized()
		if direction == Vector2.ZERO:
			direction = Vector2.UP
		var side := Vector2(-direction.y, direction.x) * width * 0.5
		mesh.surface_add_vertex(Vector3(p.x - side.x, 0.12, p.y - side.y))
		mesh.surface_add_vertex(Vector3(p.x + side.x, 0.12, p.y + side.y))
	mesh.surface_end()
