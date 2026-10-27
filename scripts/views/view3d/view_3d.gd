extends Node3D
## Widok 3D (low-poly). Tylko czyta stan gry przez WorldQuery; nowe/sprzedane maszyny z EventBus.
## Interfejs widoku (wspólny z View2D): setup(query), set_active(bool), follow(vehicle), show_overview().

const EnvironmentScript = preload("res://scripts/views/view3d/world_environment_3d.gd")
const TerrainScript = preload("res://scripts/views/view3d/terrain_3d.gd")
const FarmScript = preload("res://scripts/views/view3d/farm_3d.gd")
const FieldViewScript = preload("res://scripts/views/view3d/field_view_3d.gd")
const MachineViewScript = preload("res://scripts/views/view3d/machine_view_3d.gd")
const CameraRigScript = preload("res://scripts/views/view3d/camera_rig_3d.gd")
const RouteViewScript = preload("res://scripts/views/view3d/route_view_3d.gd")
const RouteGhostScript = preload("res://scripts/views/view3d/route_ghost_3d.gd")
const Profiler = preload("res://scripts/core/util/profiler.gd")

var query: RefCounted
var camera_rig: Node3D
var _machines_node: Node3D
var _views_by_id: Dictionary = {}


func setup(world_query: RefCounted) -> void:
	name = "View3D"
	query = world_query
	var units: float = float(query.units())
	var map_data: Dictionary = query.map_data()

	var environment_node = EnvironmentScript.new()
	environment_node.name = "Environment"
	add_child(environment_node)

	var terrain = TerrainScript.new()
	terrain.configure(map_data)
	add_child(terrain)

	var definitions: Dictionary = {}
	for field_data in map_data["fields"]:
		definitions[str(field_data["id"])] = field_data
	for grid in query.field_grids():
		var field_view = FieldViewScript.new()
		field_view.configure(grid, definitions[str(grid.field_id)], query.farming_settings(),
			float(query.field_price(str(grid.field_id))), query.economy())
		add_child(field_view)

	_machines_node = Node3D.new()
	_machines_node.name = "Machines3D"
	add_child(_machines_node)
	var machines: Dictionary = query.machines()
	var ids: Array = machines.keys()
	ids.sort()
	for id in ids:
		add_machine(machines[id])

	var farm = FarmScript.new()
	add_child(farm)
	farm.configure(query, self)

	var route_view = RouteViewScript.new()
	route_view.configure(query.route_system(), units)
	add_child(route_view)

	var ghost = RouteGhostScript.new()
	ghost.configure(query)
	add_child(ghost)

	camera_rig = CameraRigScript.new()
	camera_rig.name = "CameraRig"
	add_child(camera_rig)
	camera_rig.configure(query.world_rect_m(), units)
	# Kupione i sprzedane maszyny (EventBus).
	query.events().machine_added.connect(add_machine)
	query.events().machine_removed.connect(remove_machine)


## Jakość grafiki (files/graphics.json, app/graphics_settings.gd): przekazuje ustawienia
## częściom widoku – otoczeniu (cienie, SSAO), terenowi (trawa, drzewa) i polom (kępki zboża).
func apply_quality(preset: Dictionary) -> void:
	for child in get_children():
		if child.has_method("apply_quality"):
			child.call("apply_quality", preset)


## Punkt skupienia grafiki co klatkę: pola (zboże) i teren (trawa) liczą szczegóły wokół niego.
func _process(_delta: float) -> void:
	var started: int = Profiler.start()
	_process_measured(_delta)
	Profiler.stop(Profiler.VIEW_FIELDS, started)


func _process_measured(_delta: float) -> void:
	if camera_rig == null:
		return
	var focus: Vector3 = camera_rig.call("focus_point")
	for child in get_children():
		if child.has_method("set_focus"):
			child.call("set_focus", focus)


## Nowa maszyna (np. kupiona w sklepie).
func add_machine(machine: Node2D) -> void:
	var view = MachineViewScript.new()
	view.configure(machine, float(query.units()))
	_machines_node.add_child(view)
	_views_by_id[str(machine.get_meta("instance_state")["instance_id"])] = view


## Maszyna sprzedana.
func remove_machine(machine: Node2D) -> void:
	var id: String = str(machine.get_meta("instance_state")["instance_id"])
	var view: Node = _views_by_id.get(id)
	if view != null:
		_views_by_id.erase(id)
		view.queue_free()


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
