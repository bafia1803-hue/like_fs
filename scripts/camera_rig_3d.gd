extends Node3D
## Kamera 3D: orbita wokół pojazdu (F) albo swobodny podgląd mapy (Home, strzałki).
## Przeciąganie myszą (lewy, prawy lub środkowy przycisk): obrót i nachylenie. Kółko: przybliżenie.
## Przy śledzeniu pojazdu kąt ustawiony myszą jest względny wobec pojazdu i obraca się razem z nim.

const FOLLOW_HEIGHT_M: float = 1.6
const MIN_PITCH: float = deg_to_rad(6.0)
const MAX_PITCH: float = deg_to_rad(84.0)
const ROTATE_SPEED: float = 0.006
const PITCH_SPEED: float = 0.005

var camera: Camera3D
var units: float = 40.0
var target: Node2D = null          # ciało pojazdu w symulacji 2D
var target_view: Node3D = null     # jego model 3D (płynna, interpolowana poza)
var following: bool = false

var _pivot := Vector3.ZERO
var _yaw: float = 0.0              # 0 = kamera za pojazdem patrzącym w -Z
var _pitch: float = deg_to_rad(24.0)
var _distance: float = 16.0
var _goal_distance: float = 16.0
var _dragging: bool = false
var _drag_button: int = 0
var _yaw_offset: float = 0.0       # kąt kamery względem pojazdu (przy śledzeniu)
var _world_rect := Rect2()


func _ready() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 55.0
	camera.near = 0.2
	camera.far = 2500.0
	add_child(camera)
	camera.make_current()


func configure(world_rect_m: Rect2, scale_units: float) -> void:
	_world_rect = world_rect_m
	units = scale_units


func follow(vehicle: Node2D, snap: bool = true, view: Node3D = null) -> void:
	var was_following: bool = following
	target = vehicle
	if view != null or vehicle == null:
		target_view = view
	following = vehicle != null
	if following:
		_pivot = _target_point()
		_goal_distance = clampf(_goal_distance, 7.0, 45.0) if was_following else 16.0
		if snap:
			_yaw_offset = 0.0
			_yaw = _vehicle_yaw()
			_distance = _goal_distance
			_pitch = deg_to_rad(22.0)
			_apply()


func show_overview() -> void:
	following = false
	var center := _world_rect.get_center()
	_pivot = Vector3(center.x, 0.0, center.y)
	_yaw = deg_to_rad(-25.0)
	_pitch = deg_to_rad(52.0)
	_goal_distance = maxf(_world_rect.size.x, _world_rect.size.y) * 1.05
	_distance = _goal_distance
	_apply()


func _target_point() -> Vector3:
	if is_instance_valid(target_view):
		return target_view.global_position + Vector3(0.0, FOLLOW_HEIGHT_M, 0.0)
	var p: Vector2 = target.global_transform.origin / units
	return Vector3(p.x, FOLLOW_HEIGHT_M, p.y)


func _vehicle_yaw() -> float:
	if is_instance_valid(target_view):
		return target_view.global_rotation.y
	# Obrót 2D -> 3D: yaw = -kąt. Kamera ustawiona za pojazdem.
	return -target.global_transform.get_rotation()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button: InputEventMouseButton = event
		if button.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			if button.pressed and not _dragging:
				_start_drag(button.button_index)
			elif not button.pressed and button.button_index == _drag_button:
				_stop_drag()
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_goal_distance = maxf(_goal_distance / 1.15, 4.0)
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_goal_distance = minf(_goal_distance * 1.15, 60.0 if following else 600.0)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var motion: InputEventMouseMotion = event
		# Przycisk puszczony poza oknem lub nad panelem: kończymy obracanie.
		if not Input.is_mouse_button_pressed(_drag_button):
			_stop_drag()
			return
		var turn: float = -motion.relative.x * ROTATE_SPEED
		if following:
			_yaw_offset = wrapf(_yaw_offset + turn, -PI, PI)
		else:
			_yaw += turn
		_pitch = clampf(_pitch + motion.relative.y * PITCH_SPEED, MIN_PITCH, MAX_PITCH)
		get_viewport().set_input_as_handled()


var _drag_start_position := Vector2.ZERO


func _start_drag(button_index: int) -> void:
	_dragging = true
	_drag_button = button_index
	_drag_start_position = get_viewport().get_mouse_position()
	# Ukryty, przechwycony kursor: obrót bez dojeżdżania do krawędzi ekranu.
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _stop_drag() -> void:
	if not _dragging:
		return
	_dragging = false
	_drag_button = 0
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_viewport().warp_mouse(_drag_start_position)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_EXIT_TREE:
		_stop_drag()


func _process(delta: float) -> void:
	var pan := Vector2(
		float(Input.is_physical_key_pressed(KEY_RIGHT)) - float(Input.is_physical_key_pressed(KEY_LEFT)),
		float(Input.is_physical_key_pressed(KEY_DOWN)) - float(Input.is_physical_key_pressed(KEY_UP))
	)
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit:
		pan = Vector2.ZERO
	if pan.length_squared() > 0.0:
		following = false
		var forward := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
		var speed: float = maxf(_distance, 10.0) * 1.2
		_pivot += (right * pan.x - forward * pan.y) * speed * delta
		_pivot.y = 0.0
	elif following and is_instance_valid(target):
		_pivot = _target_point()
		# Kamera obraca się razem z pojazdem, zachowując kąt ustawiony myszą.
		_yaw = _vehicle_yaw() + _yaw_offset
	_distance = lerpf(_distance, _goal_distance, 1.0 - exp(-delta * 10.0))
	_apply()


func _apply() -> void:
	var offset := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	var eye: Vector3 = _pivot + offset
	eye.y = maxf(eye.y, 0.8)
	camera.global_transform = Transform3D(Basis(), eye).looking_at(_pivot, Vector3.UP)
