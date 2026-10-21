extends Node3D
## Trasy w 3D: nagrywana linia (zielona), podgląd wybranej trasy (żółta),
## okrąg startu i strzałka kierunku. Dane pochodzą z RouteSystem (2D).

var routes: Node2D
var units: float = 40.0

var _record := MeshInstance3D.new()
var _preview := MeshInstance3D.new()
var _start := MeshInstance3D.new()
var _record_count: int = -1
var _preview_count: int = -1
var _preview_id: String = "__none__"


func configure(route_system: Node2D, scale_units: float) -> void:
	routes = route_system
	units = scale_units
	name = "Routes3D"
	for item in [[_record, Color("#66ffb0")], [_preview, Color("#ffd166")], [_start, Color("#ffcf4d")]]:
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
	var record_line: Line2D = routes.get("_record_line")
	var preview_line: Line2D = routes.get("_preview_line")
	if record_line != null and record_line.get_point_count() != _record_count:
		_record_count = record_line.get_point_count()
		_ribbon(_record.mesh, record_line.points, 0.28)
	var selected: Dictionary = routes.get("_selected")
	var selected_id: String = str(selected.get("id", "")) if selected != null else ""
	if preview_line != null and (preview_line.get_point_count() != _preview_count or selected_id != _preview_id):
		_preview_count = preview_line.get_point_count()
		_preview_id = selected_id
		_ribbon(_preview.mesh, preview_line.points, 0.22)
		_start_marker(selected)


func _ribbon(mesh: ImmediateMesh, points: PackedVector2Array, width: float) -> void:
	mesh.clear_surfaces()
	if points.size() < 2:
		return
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in points.size():
		var p: Vector2 = points[i] / units
		var a: Vector2 = points[maxi(i - 1, 0)] / units
		var b: Vector2 = points[mini(i + 1, points.size() - 1)] / units
		var direction: Vector2 = (b - a).normalized()
		if direction == Vector2.ZERO:
			direction = Vector2.UP
		var side := Vector2(-direction.y, direction.x) * width * 0.5
		mesh.surface_add_vertex(Vector3(p.x - side.x, 0.12, p.y - side.y))
		mesh.surface_add_vertex(Vector3(p.x + side.x, 0.12, p.y + side.y))
	mesh.surface_end()


func _start_marker(selected: Dictionary) -> void:
	var mesh: ImmediateMesh = _start.mesh
	mesh.clear_surfaces()
	if selected == null or not selected.get("samples") is Array or (selected["samples"] as Array).is_empty():
		return
	var first: Array = selected["samples"][0]
	var center := Vector2(float(first[1]), float(first[2]))
	var radius: float = float(routes.get("settings").get("start_distance_m", 3.0))
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	for i in 65:
		var angle: float = TAU * i / 64.0
		var dir := Vector2(cos(angle), sin(angle))
		var inner: Vector2 = center + dir * (radius - 0.12)
		var outer: Vector2 = center + dir * (radius + 0.12)
		mesh.surface_add_vertex(Vector3(inner.x, 0.13, inner.y))
		mesh.surface_add_vertex(Vector3(outer.x, 0.13, outer.y))
	mesh.surface_end()
	# strzałka kierunku startu
	var forward := Vector2.UP.rotated(float(first[3]))
	var side := Vector2(-forward.y, forward.x)
	var tip: Vector2 = center + forward * 1.6
	var base: Vector2 = center + forward * 0.2
	mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for v in [base - side * 0.6, base + side * 0.6, tip]:
		mesh.surface_add_vertex(Vector3(v.x, 0.14, v.y))
	mesh.surface_end()
