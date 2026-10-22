extends RefCounted
## Przyłożenie siły opony (core/machines/tire_model.gd) do ciała w kroku fizyki.

const TireModel = preload("res://scripts/core/machines/tire_model.gd")
const GRAVITY_M_PER_S2: float = TireModel.GRAVITY_M_PER_S2


static func apply_wheel_force(state: PhysicsDirectBodyState2D, offset: Vector2, wheel_angle: float,
		load_mass_kg: float, drive_force_n: float, brake_force_n: float, rolling_resistance: float,
		grip: float, response_time_s: float, wheel_count: int, units_per_meter: float) -> void:
	var body := {"linear_velocity": state.linear_velocity, "angular_velocity": state.angular_velocity,
		"inverse_mass": state.inverse_mass, "inverse_inertia": state.inverse_inertia, "step": state.step}
	var force: Vector2 = TireModel.wheel_force(body, offset, wheel_angle, load_mass_kg, drive_force_n,
		brake_force_n, rolling_resistance, grip, response_time_s, wheel_count, units_per_meter)
	state.apply_force(force, offset)
