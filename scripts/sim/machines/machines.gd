extends RefCounted
## Protokół maszyny – jedyne miejsce z dostępem „kaczym” do węzłów maszyn.
##
## Każdy węzeł maszyny tworzy MachineFactory: ma metadane "definition" (model z machines.json)
## i "instance_state" (stan z zapisu) oraz metody protokołu:
##   pose_body() -> Node2D          węzeł, którego transformacja jest pozą maszyny
##   motion_body() -> RigidBody2D   ciało, którego prędkość jest prędkością maszyny (może być null)
##   cargo_body() -> RigidBody2D    ciało niosące ładunek (wylot, obszar odbioru)
##   change_cargo_mass(delta_kg)    zmiana masy ładunku (napełnianie, rozładunek, zużycie)
##   is_attached() -> bool          czy jest podpięta jako narzędzie
## Zdolności opcjonalne (sprawdzane has_method): zaczep ciągnięty (get_hitch_body, snap_by,
## set_attached), zawieszany (attach_to_carrier, get_hitch_position), narzędzie robocze
## (get_work_transform), składane (is_foldable, get_fold_progress, set_fold_progress).
##
## Stan sterowania trasą ustawia wyłącznie RouteSystem (metadane ROUTE_*).

const FieldWorkRules = preload("res://scripts/core/field/field_work_rules.gd")

const REQUIRED_METHODS: Array[String] = ["pose_body", "motion_body", "cargo_body", "change_cargo_mass", "is_attached"]
const ROUTE_MODE: String = "route_mode"            # "" | "playing" | "held"
const ROUTE_SPEED: String = "route_speed_m_s"
const ROUTE_RECORDING: String = "route_recording"


static func id(machine: Node) -> String:
	return str(machine.get_meta("instance_state")["instance_id"])


static func model(machine: Node) -> Dictionary:
	return machine.get_meta("definition")


static func state(machine: Node) -> Dictionary:
	return machine.get_meta("instance_state")


static func kind(machine: Node) -> String:
	return str(model(machine)["physics_kind"])


static func display_name(machine: Node) -> String:
	return str(model(machine).get("name", machine.name))


## Brakujące metody protokołu (pusta lista = maszyna spełnia protokół).
static func missing_methods(machine: Node) -> PackedStringArray:
	var result := PackedStringArray()
	for method in REQUIRED_METHODS:
		if not machine.has_method(method):
			result.append(method)
	return result


static func pose_body(machine: Node) -> Node2D:
	return machine.call("pose_body") as Node2D


static func motion_body(machine: Node) -> RigidBody2D:
	return machine.call("motion_body") as RigidBody2D


static func cargo_body(machine: Node) -> RigidBody2D:
	return machine.call("cargo_body") as RigidBody2D


## Poza maszyny w świecie (piksele fizyki).
static func pose_transform(machine: Node) -> Transform2D:
	return pose_body(machine).global_transform


## Poza maszyny w metrach.
static func pose_m(machine: Node, units: float) -> Transform2D:
	var xf: Transform2D = pose_transform(machine)
	return Transform2D(xf.get_rotation(), xf.origin / units)


## Prędkość maszyny [m/s] (0, gdy maszyna nie ma ruchomego ciała).
static func speed_m_s(machine: Node, units: float) -> float:
	var body: RigidBody2D = motion_body(machine)
	return 0.0 if body == null else body.linear_velocity.length() / units


static func change_cargo_mass(machine: Node, delta_kg: float) -> void:
	machine.call("change_cargo_mass", delta_kg)


static func is_attached(machine: Node) -> bool:
	return bool(machine.call("is_attached"))


static func is_working(machine: Node) -> bool:
	return machine != null and machine.has_meta("instance_state") and FieldWorkRules.is_working(state(machine))


static func has_work(machine: Node) -> bool:
	return machine != null and model(machine).get("work") is Dictionary


static func is_foldable(machine: Node) -> bool:
	return machine != null and machine.has_method("is_foldable") and bool(machine.call("is_foldable"))


## Rozłożenie narzędzia składanego (1 = rozłożone; maszyny nieskładane zawsze 1).
static func fold_progress(machine: Node) -> float:
	return float(machine.call("get_fold_progress")) if machine.has_method("get_fold_progress") else 1.0


static func route_mode(machine: Node) -> String:
	return str(machine.get_meta(ROUTE_MODE, ""))


static func on_route(machine: Node) -> bool:
	return not route_mode(machine).is_empty()


static func route_speed_m_s(machine: Node) -> float:
	return float(machine.get_meta(ROUTE_SPEED, 0.0))


static func is_recording(machine: Node) -> bool:
	return bool(machine.get_meta(ROUTE_RECORDING, false))


## Prędkość pokazywana graczowi [km/h]: na trasie prędkość odtwarzania, inaczej rzeczywista.
static func display_speed_kmh(machine: Node) -> float:
	if on_route(machine):
		return route_speed_m_s(machine) * 3.6
	return float(machine.call("get_speed_kmh")) if machine.has_method("get_speed_kmh") else 0.0
