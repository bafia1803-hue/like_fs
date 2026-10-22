extends Node2D
## Jedno fizyczne nadwozie ze sztywnym dyszlem. Siewnik lub kultywator.
##
## Profile kolizji (physics.collision_profiles w machines.json): kilka zestawów prostokątów,
## z których aktywny jest jeden – zależnie od stanu maszyny:
##   - maszyna składana (klucz "folding"): profil złożony / rozłożony,
##   - pozostałe: "inactive" / "working" (praca włączona klawiszem B).
## Składanie: fold_progress 0 = złożony, 1 = rozłożony; czas z folding.duration_s.
## Przed rozłożeniem i w jego trakcie sprawdzane jest wolne miejsce pod skrzydłami;
## gdy coś przeszkadza, maszyna się nie rozkłada albo składa z powrotem.
const AxleBodyScript = preload("res://scripts/sim/machines/passive_axle_body.gd")

var definition: Dictionary = {}
var instance_state: Dictionary = {}
var body: RigidBody2D
var attached: bool = false
var _units: float = 40.0
var _total_mass: float = 1.0

var _profiles: Dictionary = {}          # nazwa -> Array[CollisionShape2D]
var _active_profile: String = ""
## Rośnie przy każdej zmianie aktywnych brył kolizji (trasy odświeżają wtedy swoje bryły).
var collision_revision: int = 0

var folding: Dictionary = {}
var fold_progress: float = 1.0
var _fold_target: float = 1.0
var _unfold_requested: bool = false
var _work_after_unfold: bool = false
var _carrier: RigidBody2D
var _message: String = ""
## Twarda kolizja rozłożonego profilu: włączana dopiero po pełnym rozłożeniu,
## wyłączana po pełnym złożeniu. W trakcie rozkładania skrzydła sprawdza zapytanie o miejsce.
var _spread_hard: bool = false


func configure(model: Dictionary, saved_state: Dictionary,
		materials: Array, units: float) -> void:
	definition = model
	instance_state = saved_state
	_units = units
	name = str(saved_state["instance_id"])
	_total_mass = float(model["physics"]["empty_mass_kg"])
	var storages: Dictionary = saved_state["storages"]
	for storage_value in storages.values():
		var storage: Dictionary = storage_value
		for material_value in materials:
			var material: Dictionary = material_value
			if material["id"] == storage["material_id"]:
				_total_mass += float(storage["amount_l"]) * float(material["bulk_density_kg_per_l"])
				break


func _ready() -> void:
	var axles: Array = definition["axles"]
	assert(axles.size() == 1, "Ten typ narzędzia wymaga dokładnie jednej osi.")
	var axle: Dictionary = axles[0]
	var physics_data: Dictionary = definition["physics"]
	var length_m: float = float(definition["dimensions"]["length_m"])
	var axle_y: float = -length_m / 2.0 + float(axle["distance_from_front_m"])
	var rigid_body = AxleBodyScript.new()
	rigid_body.name = "ImplementBody"
	rigid_body.configure(
		_total_mass, _total_mass, axle, Vector2(0.0, axle_y),
		physics_data, _units, float(physics_data.get("parking_brake_force_n", _total_mass * 12.0))
	)
	if definition.get("folding") is Dictionary:
		folding = definition["folding"]
		var fold_state: Variant = instance_state.get("fold_state")
		var unfolded: bool = fold_state is Dictionary and bool(fold_state.get("unfolded", false))
		fold_progress = 1.0 if unfolded else 0.0
		_fold_target = fold_progress
		_spread_hard = unfolded
		instance_state["fold_state"] = {"unfolded": unfolded}
	if physics_data.get("collision_profiles") is Dictionary:
		var profiles: Dictionary = physics_data["collision_profiles"]
		for profile_name in profiles:
			var list: Array = []
			for rect in profiles[profile_name]:
				list.append(rigid_body.add_rectangle(
					float(rect["width_m"]), float(rect["length_m"]),
					_vec(rect["center_m"]), float(rect.get("rotation_deg", 0.0))))
			_profiles[str(profile_name)] = list
		_active_profile = _wanted_profile()
		for profile_name in _profiles:
			for collider in _profiles[profile_name]:
				collider.disabled = profile_name != _active_profile
	else:
		var collision: Dictionary = physics_data["body_collision"]
		rigid_body.add_rectangle(
			float(collision["width_m"]), float(collision["length_m"]),
			_vec(collision["center_m"]), float(collision["rotation_deg"])
		)
	var drawbar: Dictionary = definition["drawbar"]
	if bool(drawbar["collision_enabled"]):
		rigid_body.add_rectangle(
			float(drawbar["width_m"]), float(drawbar["length_m"]),
			Vector2(0.0, -length_m / 2.0 - float(drawbar["length_m"]) / 2.0)
		)
	var pose: Dictionary = instance_state["transform"]
	rigid_body.position = _vec(pose["position_m"]) * _units
	rigid_body.rotation = deg_to_rad(float(pose["rotation_deg"]))
	add_child(rigid_body)
	body = rigid_body
	var motion: Dictionary = instance_state["motion"]
	body.linear_velocity = _vec(motion["linear_velocity_m_per_s"]) * _units
	body.angular_velocity = deg_to_rad(float(motion["angular_velocity_deg_per_s"]))
	set_attached(false)


func get_hitch_body(_port: Dictionary) -> RigidBody2D:
	return body


func set_attached(value: bool) -> void:
	attached = value
	body.call("set_parking_brake", not value)
	instance_state["parking_brake_engaged"] = not value
	if not value:
		var work_state: Dictionary = instance_state["work_state"]
		work_state["enabled"] = false
		work_state["lowered"] = false
		_carrier = null
		_unfold_requested = false
		_work_after_unfold = false


func snap_by(shift: Vector2) -> void:
	var velocity: Vector2 = body.linear_velocity
	var spin: float = body.angular_velocity
	body.global_position += shift
	body.call("synchronize_transform")
	body.linear_velocity = velocity
	body.angular_velocity = spin


func _physics_process(delta: float) -> void:
	if not is_instance_valid(body):
		return
	if not folding.is_empty():
		_update_folding(delta)
	_update_profile()
	var pose: Dictionary = instance_state["transform"]
	pose["position_m"] = [body.position.x / _units, body.position.y / _units]
	pose["rotation_deg"] = rad_to_deg(body.rotation)
	var motion: Dictionary = instance_state["motion"]
	motion["linear_velocity_m_per_s"] = [body.linear_velocity.x / _units, body.linear_velocity.y / _units]
	motion["angular_velocity_deg_per_s"] = rad_to_deg(body.angular_velocity)


func get_diagnostics() -> String:
	return "%s | masa z zawartością: %.0f kg | %s" % [
		definition["name"], _total_mass, "podpięty" if attached else "odpięty"
	]


func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


func get_work_transform() -> Transform2D:
	return body.global_transform


# Protokół maszyny (sim/machines/machines.gd)
func pose_body() -> Node2D:
	return body


func motion_body() -> RigidBody2D:
	return body


func cargo_body() -> RigidBody2D:
	return body


func is_attached() -> bool:
	return attached


func change_cargo_mass(delta_kg: float) -> void:
	_total_mass = maxf(1.0, _total_mass + delta_kg)
	body.mass = _total_mass
	body.set("supported_mass_kg", _total_mass)
	body.inertia = 0.0


# ---------------------------------------------------------------------------
# Profile kolizji
# ---------------------------------------------------------------------------

func _is_working() -> bool:
	var work_state: Variant = instance_state.get("work_state")
	return work_state is Dictionary and bool(work_state.get("enabled", false)) and bool(work_state.get("lowered", false))


func _wanted_profile() -> String:
	var wanted: String
	if not folding.is_empty():
		wanted = str(folding.get("unfolded_profile", "unfolded")) if _spread_hard else str(folding.get("folded_profile", "folded"))
	else:
		wanted = "working" if _is_working() else "inactive"
	return wanted if _profiles.has(wanted) else _active_profile


func _update_profile() -> void:
	if _profiles.is_empty():
		return
	var wanted: String = _wanted_profile()
	if wanted == _active_profile or wanted.is_empty():
		return
	for collider in _profiles.get(_active_profile, []):
		collider.set_deferred("disabled", true)
	for collider in _profiles[wanted]:
		collider.set_deferred("disabled", false)
	_active_profile = wanted
	collision_revision += 1
	body.sleeping = false


## Aktywne bryły kolizji w metrach (dla widoku 2D): [{"center", "size", "rotation"}].
func get_footprint_rects() -> Array:
	var result: Array = []
	var source: Array = []
	if _profiles.has(_active_profile):
		source = definition["physics"]["collision_profiles"][_active_profile]
	else:
		source = [definition["physics"]["body_collision"]]
	# W ruchu (miękka strefa): widok pokazuje też aktualny zasięg skrzydeł.
	if not folding.is_empty() and not _spread_hard and fold_progress > 0.0:
		source = definition["physics"]["collision_profiles"].get(str(folding.get("folded_profile", "folded")), source)
		for rect in _wing_rects(fold_progress):
			result.append(rect)
	for rect in source:
		result.append({"center": _vec(rect["center_m"]), "size": Vector2(float(rect["width_m"]), float(rect["length_m"])),
			"rotation": deg_to_rad(float(rect.get("rotation_deg", 0.0)))})
	return result


# ---------------------------------------------------------------------------
# Składanie (klawisz B: rozłóż + opuść / podnieś + złóż)
# ---------------------------------------------------------------------------

func is_foldable() -> bool:
	return not folding.is_empty()


func get_fold_progress() -> float:
	return fold_progress


## Czy skrzydła są w ruchu (rozkładanie/składanie).
func is_folding_moving() -> bool:
	return fold_progress != _fold_target or _unfold_requested


func get_fold_seconds() -> float:
	return maxf(0.1, float(folding.get("duration_s", 4.0)))


## Klawisz B dla maszyny składanej. Zwraca komunikat (pusty, gdy wynik przyjdzie później).
func toggle_fold_work(carrier: RigidBody2D) -> String:
	_carrier = carrier
	var work_state: Dictionary = instance_state["work_state"]
	var title: String = str(definition["name"])
	if _is_working():
		work_state["enabled"] = false
		work_state["lowered"] = false
		_work_after_unfold = false
		_fold_target = 0.0
		return title + ": podnoszenie i składanie"
	if _fold_target >= 1.0 and fold_progress < 1.0:
		# Drugie B w trakcie rozkładania: wracamy do złożenia.
		_fold_target = 0.0
		_work_after_unfold = false
		return title + ": składanie"
	if fold_progress >= 1.0:
		work_state["enabled"] = true
		work_state["lowered"] = true
		return ""
	# Złożony albo w trakcie składania: najpierw sprawdzamy miejsce (w kroku fizyki).
	_unfold_requested = true
	return ""


## Odtwarzanie trasy: ustawia rozłożenie bez sprawdzania (trasa była już przejechana).
func set_fold_progress(value: float) -> void:
	if folding.is_empty():
		return
	fold_progress = clampf(value, 0.0, 1.0)
	_fold_target = fold_progress
	_unfold_requested = false
	_work_after_unfold = false
	_spread_hard = fold_progress >= 1.0
	instance_state["fold_state"] = {"unfolded": fold_progress >= 1.0}


## Komunikat dla gracza z ostatniego kroku fizyki (odbiera go FieldWork).
func take_message() -> String:
	var text: String = _message
	_message = ""
	return text


func _update_folding(delta: float) -> void:
	var title: String = str(definition["name"])
	if _unfold_requested:
		_unfold_requested = false
		if _wings_blocked(1.0):
			_message = title + ": brak miejsca na rozłożenie. Odsuń się od przeszkody."
			_fold_target = fold_progress if fold_progress <= 0.0 else 0.0
			return
		_fold_target = 1.0
		_work_after_unfold = true
		_message = title + ": rozkładanie (%.0f s)" % get_fold_seconds()
	if fold_progress == _fold_target:
		return
	var next: float = move_toward(fold_progress, _fold_target, delta / get_fold_seconds())
	if _fold_target > fold_progress and _wings_blocked(next):
		_fold_target = 0.0
		_work_after_unfold = false
		_message = title + ": przeszkoda pod skrzydłem — składanie z powrotem."
		return
	fold_progress = next
	if fold_progress >= 1.0:
		_spread_hard = true
	elif fold_progress <= 0.0:
		_spread_hard = false
	instance_state["fold_state"] = {"unfolded": fold_progress >= 1.0}
	if fold_progress >= 1.0 and _work_after_unfold:
		_work_after_unfold = false
		var work_state: Dictionary = instance_state["work_state"]
		work_state["enabled"] = attached
		work_state["lowered"] = attached
		var limit: String = ""
		var work: Variant = definition.get("work")
		if work is Dictionary and work.has("max_working_speed_kmh"):
			limit = " (max %d km/h)" % roundi(float(work["max_working_speed_kmh"]))
		_message = title + ": rozłożony i opuszczony" + limit
	elif fold_progress <= 0.0 and _fold_target <= 0.0:
		_message = title + ": złożony"


## Prostokąty pod skrzydłami (metry, lokalnie) przy danym rozłożeniu.
## Skrzydło obraca się z pionu do poziomu: jego zasięg w poziomie = długość * sin(kąt).
func _wing_rects(progress: float) -> Array:
	var result: Array = []
	var reach_factor: float = sin(clampf(progress, 0.0, 1.0) * PI * 0.5)
	for wing in folding.get("wings", []):
		var side: float = -1.0 if str(wing.get("side", "left")) == "left" else 1.0
		var hinge: Vector2 = _vec(wing["hinge_m"])
		var reach: float = maxf(0.05, float(wing["length_m"]) * reach_factor)
		result.append({"center": hinge + Vector2(side * reach * 0.5, 0.0),
			"size": Vector2(reach, float(wing["depth_m"])), "rotation": 0.0})
	return result


func _wings_blocked(progress: float) -> bool:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var exclude: Array[RID] = [body.get_rid()]
	if is_instance_valid(_carrier):
		exclude.append(_carrier.get_rid())
	for rect in _wing_rects(progress):
		var shape := RectangleShape2D.new()
		shape.size = (rect["size"] as Vector2) * _units
		var query := PhysicsShapeQueryParameters2D.new()
		query.shape = shape
		query.transform = body.global_transform * Transform2D(0.0, (rect["center"] as Vector2) * _units)
		query.exclude = exclude
		query.collision_mask = body.collision_mask
		if not space.intersect_shape(query, 1).is_empty():
			return true
	return false
