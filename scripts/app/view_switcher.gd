extends Node
## Widoki gry (2D z góry i 3D low-poly): tworzenie, przełączanie (V), zapamiętanie trybu.
## Nieaktywny widok jest odłączony od drzewa sceny, więc nie zużywa czasu procesora ani karty.
## Widoki mają wspólny interfejs: setup(query), set_active(bool), follow(vehicle), show_overview().

const View2DScript = preload("res://scripts/views/view2d/view_2d.gd")
const View3DScript = preload("res://scripts/views/view3d/view_3d.gd")
const UserSettings = preload("res://scripts/data/user_settings.gd")
const VIEW_2D: String = "2d"
const VIEW_3D: String = "3d"

var mode: String = VIEW_3D
var settings = UserSettings.new()
var _views: Dictionary = {}              # tryb -> węzeł widoku
var _host: Node
var _query: RefCounted


## host – węzeł, do którego dołączany jest aktywny widok (świat, Node3D).
func setup(host: Node, query: RefCounted) -> void:
	name = "ViewSwitcher"
	_host = host
	_query = query
	mode = _load_mode()
	for view_mode in [VIEW_2D, VIEW_3D]:
		var view: Node = View2DScript.new() if view_mode == VIEW_2D else View3DScript.new()
		_host.add_child(view)
		view.call("setup", query)
		_views[view_mode] = view
	query.events().controlled_changed.connect(func(vehicle: RigidBody2D): active_view().call("follow", vehicle))
	_apply()


func active_view() -> Node:
	return _views.get(mode)


func views() -> Array:
	return _views.values()


## Przełącza widok; zwraca komunikat dla gracza.
func toggle() -> String:
	mode = VIEW_2D if mode == VIEW_3D else VIEW_3D
	_apply()
	settings.set_value("view", "mode", mode)
	return "Widok " + mode.to_upper()


func follow_player() -> void:
	active_view().call("follow", _query.controlled_vehicle())


func show_overview() -> void:
	active_view().call("show_overview")


func _apply() -> void:
	for view_mode in _views:
		var view: Node = _views[view_mode]
		var active: bool = view_mode == mode
		if active and not view.is_inside_tree():
			_host.add_child(view)
		elif not active and view.is_inside_tree():
			_host.remove_child(view)
		view.call("set_active", active)
	follow_player()


func _load_mode() -> String:
	var saved: String = str(settings.get_value("view", "mode", VIEW_3D))
	return saved if saved == VIEW_2D or saved == VIEW_3D else VIEW_3D


func _exit_tree() -> void:
	# Odłączone widoki nie są dziećmi świata, więc zwalniamy je ręcznie.
	for view in _views.values():
		if is_instance_valid(view) and not view.is_inside_tree():
			view.queue_free()
