extends Node3D
## Strumień sypiącego się ziarna (rura kombajnu, wysyp z przyczepy).
## Pozycję ustawia się w układzie świata: górny punkt wylotu i wysokość, na którą ziarno spada.

const StreamShader = preload("res://shaders/grain_stream.gdshader")

var _core := MeshInstance3D.new()
var _kernels := CPUParticles3D.new()
var _splash := CPUParticles3D.new()
var _material := ShaderMaterial.new()
var _cylinder := CylinderMesh.new()
var _active: bool = false
var _strength: float = 0.0
var _width: float = 0.22


func _ready() -> void:
	top_level = true
	_cylinder.radial_segments = 6
	_cylinder.rings = 1
	_cylinder.height = 1.0
	_material.shader = StreamShader
	_core.mesh = _cylinder
	_core.material_override = _material
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core.visible = false
	add_child(_core)

	var grain_material := StandardMaterial3D.new()
	grain_material.albedo_color = Color("#f2c55c")
	grain_material.roughness = 1.0
	var kernel := BoxMesh.new()
	kernel.size = Vector3(0.06, 0.06, 0.06)
	kernel.material = grain_material
	for particles in [_kernels, _splash]:
		particles.mesh = kernel
		particles.local_coords = false
		particles.emitting = false
		particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(particles)
	_kernels.amount = 90
	_kernels.lifetime = 0.8
	_kernels.direction = Vector3.DOWN
	_kernels.spread = 8.0
	_kernels.initial_velocity_min = 0.3
	_kernels.initial_velocity_max = 0.9
	_kernels.gravity = Vector3(0, -9.8, 0)
	_kernels.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_kernels.emission_sphere_radius = 0.1
	_kernels.angular_velocity_min = -360.0
	_kernels.angular_velocity_max = 360.0
	_kernels.scale_amount_min = 0.6
	_kernels.scale_amount_max = 1.3

	_splash.amount = 40
	_splash.lifetime = 0.45
	_splash.direction = Vector3.UP
	_splash.spread = 70.0
	_splash.initial_velocity_min = 0.6
	_splash.initial_velocity_max = 1.8
	_splash.gravity = Vector3(0, -9.8, 0)
	_splash.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_splash.emission_sphere_radius = 0.25
	_splash.scale_amount_min = 0.5
	_splash.scale_amount_max = 1.0


## top – punkt wylotu (świat), bottom_y – wysokość powierzchni, na którą spada ziarno.
## width – szerokość strumienia (m), drift – przesunięcie dołu strumienia w poziomie (np. przy wysypie z klapy).
func update_stream(active: bool, top: Vector3, bottom_y: float, width: float = 0.22, drift := Vector3.ZERO) -> void:
	_width = width
	_strength = move_toward(_strength, 1.0 if active else 0.0, get_process_delta_time() * 4.0)
	var visible_now: bool = _strength > 0.01
	_core.visible = visible_now
	_kernels.emitting = active
	_splash.emitting = active
	if not visible_now and not active:
		return
	var bottom := Vector3(top.x, minf(bottom_y, top.y - 0.05), top.z) + drift
	var height: float = maxf(top.distance_to(bottom), 0.05)
	# Rdzeń: walec od wylotu do miejsca upadku, rozszerza się w dół.
	_cylinder.top_radius = _width * 0.35 * _strength
	_cylinder.bottom_radius = _width * 0.6 * _strength
	var mid: Vector3 = (top + bottom) * 0.5
	var axis: Vector3 = (top - bottom).normalized()
	var side: Vector3 = axis.cross(Vector3.FORWARD)
	if side.length_squared() < 0.01:
		side = axis.cross(Vector3.RIGHT)
	side = side.normalized()
	var basis := Basis(side, axis, side.cross(axis))
	_core.global_transform = Transform3D(basis.scaled(Vector3(1.0, height, 1.0)), mid)
	_material.set_shader_parameter("length_m", height)
	_material.set_shader_parameter("speed", 2.2 + height * 0.4)
	_kernels.global_position = top
	_kernels.lifetime = clampf(sqrt(2.0 * height / 9.8), 0.15, 1.2)
	_kernels.emission_sphere_radius = _width * 0.4
	_splash.global_position = bottom
