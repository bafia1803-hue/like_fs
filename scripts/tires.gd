extends RefCounted

const GRAVITY_M_PER_S2: float = 9.81


static func apply_wheel_force(
	state: PhysicsDirectBodyState2D,
	offset: Vector2,
	wheel_angle: float,
	load_mass_kg: float,
	drive_force_n: float,
	brake_force_n: float,
	rolling_resistance: float,
	grip: float,
	response_time_s: float,
	wheel_count: int,
	units_per_meter: float
) -> void:
	var forward: Vector2 = Vector2.UP.rotated(wheel_angle)
	var lateral: Vector2 = Vector2.RIGHT.rotated(wheel_angle)

	# Prędkość punktu koła = przesunięcie nadwozia + jego obrót.
	var rotation_velocity := Vector2(
		-offset.y,
		offset.x
	) * state.angular_velocity

	var wheel_velocity_m: Vector2 = (
		state.linear_velocity + rotation_velocity
	) / units_per_meter

	var longitudinal_speed: float = wheel_velocity_m.dot(forward)
	var lateral_speed: float = wheel_velocity_m.dot(lateral)

	var normal_force_n: float = load_mass_kg * GRAVITY_M_PER_S2

	# Opona przeciwdziała przesuwaniu się w bok.
	var lateral_force_n: float = (
		-lateral_speed
		* load_mass_kg
		/ maxf(response_time_s, 0.02)
	)

	# Ograniczenie zabezpiecza przed zmianą kierunku prędkości
	# wskutek zbyt dużej siły hamującej w jednym kroku.
	var lateral_stop_limit: float = _stop_force_limit(
		state,
		offset,
		lateral,
		lateral_speed,
		wheel_count
	)

	lateral_force_n = clampf(
		lateral_force_n,
		-lateral_stop_limit,
		lateral_stop_limit
	)

	var resistance_n: float = (
		normal_force_n * rolling_resistance
		+ brake_force_n
	)

	var longitudinal_stop_limit: float = _stop_force_limit(
		state,
		offset,
		forward,
		longitudinal_speed,
		wheel_count
	)

	var longitudinal_force_n: float = (
		drive_force_n
		- signf(longitudinal_speed)
		* minf(resistance_n, longitudinal_stop_limit)
	)

	var force_n: Vector2 = (
		forward * longitudinal_force_n
		+ lateral * lateral_force_n
	)

	# Napęd, hamowanie i siła boczna korzystają
	# z tego samego ograniczonego zapasu przyczepności.
	force_n = force_n.limit_length(
		normal_force_n * maxf(grip, 0.0)
	)

	state.apply_force(force_n * units_per_meter, offset)


static func _stop_force_limit(
	state: PhysicsDirectBodyState2D,
	offset: Vector2,
	direction: Vector2,
	speed_m_per_s: float,
	wheel_count: int
) -> float:
	var lever: float = offset.cross(direction)

	var inverse_effective_mass: float = (
		state.inverse_mass
		+ lever * lever * state.inverse_inertia
	)

	if inverse_effective_mass <= 0.0:
		return 0.0

	var effective_mass: float = 1.0 / inverse_effective_mass

	return (
		absf(speed_m_per_s)
		* effective_mass
		/ maxf(state.step, 0.000001)
		/ float(maxi(wheel_count, 1))
	)
