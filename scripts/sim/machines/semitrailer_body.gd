extends RigidBody2D
## Nadwozie naczepy: kilka nieskrętnych osi z tyłu (np. tandem), przód oparty na siodle tira
## (po podpięciu) albo na nogach podporowych (po odpięciu).
##
## Rozkład ciężaru liczony z geometrii: środek masy w środku nadwozia, podparcie z przodu
## (sworzeń albo nogi) i środek grupy osi. Część na siodle przejmuje tir (set_coupled_load_kg),
## część na osiach naczepy dociska jej koła.

const TiresScript = preload("res://scripts/sim/machines/tires.gd")
const AxleGroups = preload("res://scripts/core/machines/axle_groups.gd")
const Profiler = preload("res://scripts/core/util/profiler.gd")

var units_per_meter: float = 40.0
var axles: Array[Dictionary] = []          # {"y": m, "track": m, "grip": float}
var legs: Dictionary = {}                   # {"y": m, "track": m, "friction": float}
var kingpin_y: float = 0.0
var rolling_resistance: float = 0.03
var response_time_s: float = 0.12
var parking_force_n: float = 0.0
## Hamulec roboczy naczepy (hamuje razem z tirem): opóźnienie w g dla ciężaru na osiach naczepy.
var service_decel_g: float = 0.0
var attached: bool = false
var carrier_braking: bool = false
var total_mass_kg: float = 1.0


func configure(model: Dictionary, mass_kg: float, scale_units: float) -> void:
	units_per_meter = scale_units
	total_mass_kg = mass_kg
	mass = mass_kg
	var length: float = float(model["dimensions"]["length_m"])
	# Tandem liczy się jak jedna oś w środku grupy (axle_groups.gd); widok pokazuje wszystkie koła.
	for axle in AxleGroups.physical(model["axles"]):
		axles.append({"y": -length / 2.0 + float(axle["distance_from_front_m"]),
			"track": float(axle["track_m"]), "grip": float(axle.get("lateral_grip", 1.0))})
	var leg_data: Dictionary = model["landing_legs"]
	legs = {"y": -length / 2.0 + float(leg_data["distance_from_front_m"]), "track": float(leg_data["track_m"]),
		"friction": float(leg_data.get("friction", 0.8))}
	for port in model["hitch_ports"]:
		if str(port["role"]) == "plug":
			kingpin_y = float(port["position_m"][1])
	var physics_data: Dictionary = model["physics"]
	rolling_resistance = float(physics_data["rolling_resistance_coefficient"])
	response_time_s = float(physics_data["lateral_response_time_s"])
	parking_force_n = float(physics_data.get("parking_brake_force_n", mass_kg * 8.0))
	service_decel_g = float(physics_data.get("service_brake_decel_g", 0.0))
	gravity_scale = 0.0
	linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	angular_damp = 0.0
	center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = Vector2.ZERO
	continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	var material := PhysicsMaterial.new()
	material.friction = 0.5
	material.bounce = 0.0
	physics_material_override = material


## Środek grupy osi (m, lokalnie).
func axle_group_y() -> float:
	var sum: float = 0.0
	for axle in axles:
		sum += float(axle["y"])
	return sum / maxf(1.0, axles.size())


## Udział ciężaru na przednim podparciu (sworzeń albo nogi), 0..1.
func front_share() -> float:
	var front_y: float = kingpin_y if attached else float(legs["y"])
	var rear_y: float = axle_group_y()
	if rear_y - front_y <= 0.01:
		return 0.0
	return clampf(rear_y / (rear_y - front_y), 0.0, 1.0)


## Nacisk na siodło tira (kg).
func coupled_load_kg() -> float:
	return total_mass_kg * front_share() if attached else 0.0


func synchronize_transform() -> void:
	PhysicsServer2D.body_set_state(get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, global_transform)
	sleeping = false


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	var started: int = Profiler.start()
	_integrate_forces_measured(state)
	Profiler.stop(Profiler.PHYSICS_TIRES, started)


func _integrate_forces_measured(state: PhysicsDirectBodyState2D) -> void:
	var body_angle: float = state.transform.get_rotation()
	var share_front: float = front_share()
	var wheel_count: int = axles.size() * 2 + (0 if attached else 2)
	var axle_load: float = total_mass_kg * (1.0 - share_front) / maxf(1.0, axles.size())
	var brake_total: float = 0.0
	if not attached:
		brake_total = parking_force_n
	elif carrier_braking:
		brake_total = total_mass_kg * (1.0 - share_front) * TiresScript.GRAVITY_M_PER_S2 * service_decel_g
	var wheel_brake: float = brake_total / maxf(1.0, axles.size() * 2.0)
	for axle in axles:
		for side in [-1.0, 1.0]:
			var local := Vector2(side * float(axle["track"]) / 2.0, float(axle["y"])) * units_per_meter
			TiresScript.apply_wheel_force(state, local.rotated(body_angle), body_angle, axle_load / 2.0, 0.0,
				wheel_brake, rolling_resistance, float(axle["grip"]), response_time_s, wheel_count, units_per_meter)
	if attached:
		return
	# Nogi podporowe: stopy na ziemi trą w każdym kierunku (jak zablokowane koło).
	var leg_load: float = total_mass_kg * share_front / 2.0
	var friction: float = float(legs["friction"])
	for side in [-1.0, 1.0]:
		var local := Vector2(side * float(legs["track"]) / 2.0, float(legs["y"])) * units_per_meter
		TiresScript.apply_wheel_force(state, local.rotated(body_angle), body_angle, leg_load, 0.0,
			leg_load * TiresScript.GRAVITY_M_PER_S2 * friction, 0.0, friction, response_time_s, wheel_count, units_per_meter)
