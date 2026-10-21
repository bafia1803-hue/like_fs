extends Node3D
## Widok 3D (low-poly). Tylko czyta stan gry przez interfejs świata (metody get_*).
## Interfejs widoku (wspólny z View2D): setup(world), set_active(bool), follow(vehicle), show_overview().

const EnvironmentScript = preload("res://scripts/view3d/world_environment_3d.gd")
const TerrainScript = preload("res://scripts/view3d/terrain_3d.gd")
const FarmScript = preload("res://scripts/view3d/farm_3d.gd")
const FieldViewScript = preload("res://scripts/view3d/field_view_3d.gd")
const MachineViewScript = preload("res://scripts/view3d/machine_view_3d.gd")
const CameraRigScript = preload("res://scripts/view3d/camera_rig_3d.gd")
const RouteViewScript = preload("res://scripts/view3d/route_view_3d.gd")

var world: Node
var camera_rig: Node3D
var _machines_node: Node3D
var _views_by_id: Dictionary = {}


func setup(world_node: Node) -> void:
	name = "View3D"
	world = world_node
	var units: float = float(world.call("get_units_per_meter"))
	var map_data: Dictionary = world.call("get_map_data")

	var environment_node = EnvironmentScript.new()
	environment_node.name = "Environment"
	add_child(environment_node)

	var terrain = TerrainScript.new()
	terrain.configure(map_data)
	add_child(terrain)

	var definitions: Dictionary = {}
	for field_data in map_data["fields"]:
		definitions[str(field_data["id"])] = field_data
	for grid in world.call("get_field_grids"):
		var field_view = FieldViewScript.new()
		field_view.configure(grid, definitions[str(grid.field_id)], world.call("get_farming_settings"))
		add_child(field_view)

	_machines_node = Node3D.new()
	_machines_node.name = "Machines3D"
	add_child(_machines_node)
	var machines: Dictionary = world.call("get_machines")
	var ids: Array = machines.keys()
	ids.sort()
	for id in ids:
		var view = MachineViewScript.new()
		view.configure(machines[id], units)
		_machines_node.add_child(view)
		_views_by_id[str(id)] = view

	var farm = FarmScript.new()
	add_child(farm)
	farm.configure(world, self)

	var route_view = RouteViewScript.new()
	route_view.configure(world.call("get_route_system"), units)
	add_child(route_view)

	camera_rig = CameraRigScript.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.configure(world.call("get_world_rect_m"), units)


func set_active(active: bool) -> void:
	visible = active
	if active and is_inside_tree() and camera_rig.camera != null:
		camera_rig.camera.make_current()


func follow(vehicle: Node2D) -> void:
	if vehicle == null:
		return
	var state: Dictionary = vehicle.get_meta("instance_state")
	camera_rig.call("follow", vehicle, true, _views_by_id.get(str(state["instance_id"])))


func show_overview() -> void:
	camera_rig.call("show_overview")


## Model 3D danej maszyny (lub null).
func view_of(machine: Node) -> Node3D:
	var state: Dictionary = machine.get_meta("instance_state")
	return _views_by_id.get(str(state["instance_id"])) as Node3D


## Wysokość, na którą spada ziarno w punkcie: ładunek maszyny pod spodem albo grunt.
func surface_below(point: Vector3) -> float:
	for view in _machines_node.get_children():
		if view.has_method("grain_surface_height"):
			var height: float = float(view.call("grain_surface_height", point))
			if height >= 0.0:
				return height
	return 0.08
