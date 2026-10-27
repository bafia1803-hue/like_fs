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


## Składniki obrazu do testu kosztu karty graficznej (Shift+F4): [nazwa, Callable(włączony: bool)].
## Test wyłącza po kolei każdy składnik na chwilę i mierzy, o ile krócej liczy karta.
func cost_components() -> Array:
	var result: Array = []
	var environment_node: Node = get_node_or_null("Environment")
	var terrain: Node = get_node_or_null("Terrain")
	if environment_node != null:
		var sun: DirectionalLight3D = environment_node.get("sun")
		var env: Environment = environment_node.get("environment")
		result.append(["Cienie słońca", _toggle_property(sun, "shadow_enabled")])
		result.append(["SSAO (przyciemnienie zakamarków)", _toggle_property(env, "ssao_enabled")])
		result.append(["Poświata (glow)", _toggle_property(env, "glow_enabled")])
		result.append(["Mgła", _toggle_property(env, "fog_enabled")])
		result.append(["Niebo proceduralne", func(on: bool): env.background_mode = Environment.BG_SKY if on else Environment.BG_CLEAR_COLOR])
	var fields: Array = []
	var canopies: Array = []
	var soil: Array = []
	for child in get_children():
		if child.has_method("set_tufts_enabled"):
			fields.append(child)
			canopies.append_array(child.call("canopy_nodes"))
			soil.append(child.get_node_or_null("Ground"))
	result.append(["Zboże (kępki)", func(on: bool):
		for field in fields:
			field.call("set_tufts_enabled", on)])
	result.append(["Łan (pokrywa zboża)", _toggle_visible(canopies)])
	result.append(["Gleba pól (shader stanu)", _toggle_visible(soil)])
	if terrain != null:
		result.append(["Trawa i kwiatki", _toggle_visible([terrain.get_node_or_null("Grass")])])
		var trees: Array = []
		for child in terrain.get_children():
			if str(child.name).begins_with("Scenery_"):
				trees.append(child)
		result.append(["Drzewa i krzewy", _toggle_visible(trees)])
		result.append(["Łąka (shader podłoża)", _toggle_visible([terrain.get_node_or_null("Meadow")])])
	result.append(["Farma i budynki", _toggle_visible([get_node_or_null("Farm3D")])])
	result.append(["Maszyny", _toggle_visible([_machines_node])])
	return result


func _toggle_property(target: Object, property: String) -> Callable:
	var original: bool = bool(target.get(property))
	return func(on: bool): target.set(property, original if on else false)


func _toggle_visible(nodes: Array) -> Callable:
	var valid: Array = nodes.filter(func(node): return node != null)
	return func(on: bool):
		for node in valid:
			(node as Node3D).visible = on


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
