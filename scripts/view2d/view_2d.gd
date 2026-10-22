extends Node2D
## Widok 2D (z góry), taki jak przed grafiką 3D. Tylko czyta stan gry.
## Interfejs widoku (wspólny z View3D): setup(world), set_active(bool), follow(vehicle), show_overview().
## Sterowanie kamerą: strzałki – przesuwanie, kółko – zoom, przeciąganie myszą – przesuwanie.

const MapViewScript = preload("res://scripts/view2d/map_view_2d.gd")
const FarmViewScript = preload("res://scripts/view2d/farm_view_2d.gd")
const MachineViewScript = preload("res://scripts/view2d/machine_view_2d.gd")
const RouteViewScript = preload("res://scripts/view2d/route_view_2d.gd")
const FieldShader = preload("res://shaders/field_2d.gdshader")
const CAMERA_SPEED_SCREEN: float = 600.0

var world: Node
var units: float = 40.0
var _camera: Camera2D
var _target: Node2D
var _following: bool = false
var _world_rect := Rect2()
var _minimum_zoom: float = 0.01
var _maximum_zoom: float = 4.0
var _dragging: bool = false
var _machines_node: Node2D
var _views_by_id: Dictionary = {}


func setup(world_node: Node) -> void:
	name = "View2D"
	world = world_node
	units = float(world.call("get_units_per_meter"))
	var rect_m: Rect2 = world.call("get_world_rect_m")
	_world_rect = Rect2(rect_m.position * units, rect_m.size * units)

	var map_view = MapViewScript.new()
	map_view.name = "Map2D"
	if not map_view.configure(world.call("get_map_data"), units):
		push_warning("Widok 2D: " + str(map_view.last_error))
	add_child(map_view)

	var settings: Dictionary = world.call("get_farming_settings")
	var fields_by_id: Dictionary = {}
	for field_data in world.call("get_map_data")["fields"]:
		fields_by_id[str(field_data["id"])] = field_data
	for grid in world.call("get_field_grids"):
		add_child(_field_sprite(grid, fields_by_id.get(str(grid.field_id), {}), settings))

	var farm = FarmViewScript.new()
	farm.configure(world)
	add_child(farm)

	var routes = RouteViewScript.new()
	routes.configure(world.call("get_route_system"), units, world.call("get_catalog_models"))
	add_child(routes)

	_machines_node = Node2D.new()
	_machines_node.name = "Machines2D"
	add_child(_machines_node)
	var all_machines: Dictionary = world.call("get_machines")
	var ids: Array = all_machines.keys()
	ids.sort()
	for id in ids:
		add_machine(all_machines[id])

	_camera = Camera2D.new()
	_camera.name = "Camera2D"
	_camera.position_smoothing_enabled = false
	add_child(_camera)
	_fit_zoom_limits()


## Sprite pola: kolor każdej komórki z tekstury stanu (bez kopii danych w widoku).
func _field_sprite(grid: Node2D, field_data: Dictionary, settings: Dictionary) -> Sprite2D:
	var colors: Dictionary = settings.get("colors", {})
	var palette: Array[Color] = [Color(str(field_data.get("soil_surface", {}).get("color", "#795137")))]
	for key in ["sown", "light", "dark", "ready", "harvested"]:
		palette.append(Color(str(colors.get(key, "#888888"))))
	var material := ShaderMaterial.new()
	material.shader = FieldShader
	material.set_shader_parameter("stage_tex", grid.stage_texture)
	material.set_shader_parameter("colors", palette)
	var sprite := Sprite2D.new()
	sprite.name = "Field2D_" + str(grid.field_id)
	sprite.texture = grid.stage_texture
	sprite.material = material
	sprite.centered = false
	sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	sprite.position = grid.position
	sprite.rotation = grid.rotation
	sprite.scale = Vector2.ONE * float(grid.cell_m) * units
	return sprite


func add_machine(machine: Node2D) -> void:
	var view = MachineViewScript.new()
	view.configure(machine, units)
	_machines_node.add_child(view)
	_views_by_id[str(machine.get_meta("instance_state")["instance_id"])] = view


func remove_machine(machine: Node2D) -> void:
	var id: String = str(machine.get_meta("instance_state")["instance_id"])
	var view: Node = _views_by_id.get(id)
	if view != null:
		_views_by_id.erase(id)
		view.queue_free()


func set_active(active: bool) -> void:
	visible = active
	set_process(active)
	set_process_unhandled_input(active)
	if active and is_inside_tree():
		_camera.make_current()


func follow(vehicle: Node2D) -> void:
	_target = vehicle
	_following = vehicle != null
	if _following and is_instance_valid(_target):
		_camera.position = _target.global_position
		if _camera.zoom.x < 0.5:
			_camera.zoom = Vector2.ONE


func show_overview() -> void:
	_following = false
	_fit_zoom_limits()
	_camera.position = _world_rect.get_center()
	_camera.zoom = Vector2.ONE * _minimum_zoom * 4.0


func _fit_zoom_limits() -> void:
	var viewport_size: Vector2 = get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	var available := Vector2(maxf(viewport_size.x - 80.0, 1.0), maxf(viewport_size.y - 200.0, 1.0))
	var fit_zoom: float = minf(available.x / _world_rect.size.x, available.y / _world_rect.size.y)
	_minimum_zoom = fit_zoom / 4.0
	_maximum_zoom = maxf(4.0, fit_zoom * 4.0)


func _process(delta: float) -> void:
	var direction := Vector2(
		float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_UP))
	)
	if get_viewport().gui_get_focus_owner() is LineEdit:
		direction = Vector2.ZERO
	if direction.length_squared() > 0.0:
		_following = false
		_camera.position += direction.normalized() * CAMERA_SPEED_SCREEN * delta / _camera.zoom.x
	elif _following and is_instance_valid(_target):
		_camera.position = _target.global_position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event
		if button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1.15)
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0 / 1.15)
			get_viewport().set_input_as_handled()
		elif button.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_dragging = button.pressed
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		_following = false
		_camera.position -= (event as InputEventMouseMotion).relative / _camera.zoom.x
		get_viewport().set_input_as_handled()


func _zoom(multiplier: float) -> void:
	_camera.zoom = Vector2.ONE * clampf(_camera.zoom.x * multiplier, _minimum_zoom, _maximum_zoom)
