extends RigidBody2D
## Fizyczny człon bez napędu: nadwozie przyczepy lub przedni wózek.

const TiresScript = preload("res://scripts/sim/machines/tires.gd")
const Profiler = preload("res://scripts/core/util/profiler.gd")

var units_per_meter: float = 40.0
var supported_mass_kg: float = 1.0
var axle_local_m: Vector2 = Vector2.ZERO
var track_m: float = 1.0
var grip: float = 1.0
var rolling_resistance: float = 0.04
var response_time_s: float = 0.12
var parking_force_n: float = 0.0
var parking_brake: bool = true
var inverse_inertia_value: float = 0.0


func configure(
	physical_mass_kg: float, supported_mass: float,
	axle: Dictionary, axle_position_m: Vector2,
	physics_data: Dictionary, scale_units: float,
	brake_force_n: float
) -> void:
	units_per_meter = scale_units
	mass = physical_mass_kg
	supported_mass_kg = supported_mass
	axle_local_m = axle_position_m
	track_m = float(axle["track_m"])
	grip = float(axle["lateral_grip"])
	rolling_resistance = float(physics_data["rolling_resistance_coefficient"])
	response_time_s = float(physics_data["lateral_response_time_s"])
	parking_force_n = brake_force_n
	gravity_scale = 0.0
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector2.ZERO
	collision_layer = 3   # oba poziomy kolizji (collision_levels.gd)
	collision_mask = 3
	continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	var material := PhysicsMaterial.new()
	material.friction = 0.5
	material.bounce = 0.0
	physics_material_override = material


func add_rectangle(width_m: float, length_m: float, center_m: Vector2,
		angle_deg: float = 0.0) -> CollisionShape2D:
	var shape := RectangleShape2D.new()
	shape.size = Vector2(width_m, length_m) * units_per_meter
	var collider := CollisionShape2D.new()
	collider.shape = shape
	collider.position = center_m * units_per_meter
	collider.rotation = deg_to_rad(angle_deg)
	add_child(collider)
	return collider


func set_parking_brake(enabled: bool) -> void:
	if parking_brake != enabled:
		parking_brake = enabled
		sleeping = false


func synchronize_transform() -> void:
	# Używane wyłącznie przy inicjalizacji i zatrzymanym podpinaniu.
	PhysicsServer2D.body_set_state(
		get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform
	)
	sleeping = false


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	var started: int = Profiler.start()
	_integrate_forces_measured(state)
	Profiler.stop(Profiler.PHYSICS_TIRES, started)


func _integrate_forces_measured(state: PhysicsDirectBodyState2D) -> void:
	inverse_inertia_value = state.inverse_inertia
	var body_angle: float = state.transform.get_rotation()
	var wheel_brake: float = parking_force_n / 2.0 if parking_brake else 0.0
	for side in [-1.0, 1.0]:
		var wheel_local: Vector2 = (
			axle_local_m + Vector2(side * track_m / 2.0, 0.0)
		) * units_per_meter
		TiresScript.apply_wheel_force(
			state, wheel_local.rotated(body_angle), body_angle,
			supported_mass_kg / 2.0, 0.0, wheel_brake,
			rolling_resistance, grip, response_time_s, 2, units_per_meter
		)
