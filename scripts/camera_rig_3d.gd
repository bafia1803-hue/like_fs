extends Node3D
## Kamera 3D: orbita wokół pojazdu (F) albo swobodny podgląd mapy (Home, strzałki).
## Prawy (lub środkowy) przycisk myszy + ruch: obrót. Kółko: przybliżenie.

const FOLLOW_HEIGHT_M: float = 1.6
const MIN_PITCH: float = deg_to_rad(6.0)
const MAX_PITCH: float = deg_to_rad(84.0)
const AUTO_ALIGN_DELAY_S: float = 1.6

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
var _since_drag: float = 100.0
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
			_yaw = _vehicle_yaw()
			_distance = _goal_distance
			_pitch = deg_to_rad(22.0)
			_since_drag = 100.0
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
		if button.button_index == MOUSE_BUTTON_RIGHT or button.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = button.pressed
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_goal_distance = maxf(_goal_distance / 1.15, 4.0)
			get_viewport().set_input_as_handled()
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_goal_distance = minf(_goal_distance * 1.15, 60.0 if following else 600.0)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var motion: InputEventMouseMotion = event
		_yaw -= motion.relative.x * 0.006
		_pitch = clampf(_pitch + motion.relative.y * 0.005, MIN_PITCH, MAX_PITCH)
		_since_drag = 0.0
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	_since_drag += delta
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
		# Po chwili bez obracania myszą kamera wraca za pojazd, gdy ten jedzie.
		var speed: float = 0.0
		if target is RigidBody2D:
			speed = (target as RigidBody2D).linear_velocity.length() / units
		if _since_drag > AUTO_ALIGN_DELAY_S and speed > 0.6:
			var desired: float = _vehicle_yaw()
			_yaw = lerp_angle(_yaw, desired, 1.0 - exp(-delta * 1.6))
	_distance = lerpf(_distance, _goal_distance, 1.0 - exp(-delta * 10.0))
	_apply()


func _apply() -> void:
	var offset := Vector3(sin(_yaw) * cos(_pitch), sin(_pitch), cos(_yaw) * cos(_pitch)) * _distance
	var eye: Vector3 = _pivot + offset
	eye.y = maxf(eye.y, 0.8)
	camera.global_transform = Transform3D(Basis(), eye).looking_at(_pivot, Vector3.UP)
