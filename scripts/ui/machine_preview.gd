extends SubViewportContainer
## Podgląd 3D maszyny na kafelku sklepu: własny mały świat 3D (światło, podest, kamera).
## Przeciąganie myszą obraca maszynę.

const MachineViewScript = preload("res://scripts/view3d/machine_view_3d.gd")

var _viewport: SubViewport
var _pivot: Node3D
var _camera: Camera3D
var _dragging: bool = false
var _pitch: float = deg_to_rad(24.0)
var _distance: float = 10.0
var _target := Vector3.ZERO


func setup(definition: Dictionary) -> void:
	stretch = true
	custom_minimum_size = Vector2(0, 190)
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_DRAG
	tooltip_text = "Przeciągnij, aby obrócić"
	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.render_target_update_mode = SubViewport.UPDATE_WHEN_VISIBLE
	add_child(_viewport)

	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("#3a332c")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("#fff3df")
	environment.ambient_light_energy = 0.3
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	_viewport.add_child(world_environment)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color("#fff1d6")
	sun.light_energy = 0.9
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(-35.0), 0.0)
	sun.shadow_enabled = true
	_viewport.add_child(sun)

	_pivot = Node3D.new()
	_viewport.add_child(_pivot)
	var model: Node3D = MachineViewScript.instantiate_model(definition)
	_pivot.add_child(model)
	var bounds: AABB = _bounds(model)
	# Maszyna na środku podestu, kamera dobrana do jej rozmiaru.
	model.position = Vector3(-bounds.get_center().x, 0.0, -bounds.get_center().z)
	var radius: float = maxf(bounds.size.x, bounds.size.z) * 0.5
	var plinth := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = radius + 0.6
	disc.bottom_radius = radius + 0.7
	disc.height = 0.12
	disc.radial_segments = 32
	plinth.mesh = disc
	plinth.position.y = -0.06
	var plinth_material := StandardMaterial3D.new()
	plinth_material.albedo_color = Color("#5a4f44")
	plinth_material.roughness = 1.0
	plinth.material_override = plinth_material
	_pivot.add_child(plinth)
	_target = Vector3(0.0, bounds.size.y * 0.4, 0.0)
	_distance = maxf(bounds.size.length() * 1.05, 3.0)
	# Startowe ustawienie: 3/4 z boku (obrót zgodny z ruchem wskazówek zegara patrząc z góry).
	_pivot.rotation.y = deg_to_rad(-125.0)

	_camera = Camera3D.new()
	_camera.fov = 35.0
	_viewport.add_child(_camera)
	_update_camera()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		accept_event()
	elif event is InputEventMouseMotion and _dragging:
		_pivot.rotation.y += event.relative.x * 0.012
		_pitch = clampf(_pitch + event.relative.y * 0.006, deg_to_rad(5.0), deg_to_rad(70.0))
		_update_camera()
		accept_event()


func _update_camera() -> void:
	var offset := Vector3(0.0, sin(_pitch), cos(_pitch)) * _distance
	_camera.look_at_from_position(_target + offset, _target, Vector3.UP)


func _bounds(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	for child in node.find_children("*", "MeshInstance3D", true, false):
		var mesh_instance: MeshInstance3D = child
		var box: AABB = _relative_transform(mesh_instance, node) * mesh_instance.get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


func _relative_transform(child: Node3D, root: Node3D) -> Transform3D:
	var result: Transform3D = Transform3D.IDENTITY
	var node: Node = child
	while node != null and node != root:
		result = (node as Node3D).transform * result
		node = node.get_parent()
	return result
