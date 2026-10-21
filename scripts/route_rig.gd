extends RefCounted
## Adapter istniejących maszyn. Pozy sterowane w metrach/radianach.
var vehicle: RigidBody2D
var tool: Node2D
var link: Dictionary = {}
var units: float
var bodies: Array[RigidBody2D] = []
var shapes: Array[Dictionary] = []
var _saved: Array[Dictionary] = []
var kind: String = ""
var last_error: String = ""
var reach: float = 1.0

func configure(parent: RigidBody2D, hitches: Node, scale_units: float) -> bool:
	vehicle = parent
	units = scale_units
	link = hitches.call("get_route_link", parent)
	tool = link.get("child") as Node2D
	bodies.append(vehicle)
	if tool != null:
		kind = str(tool.get_meta("definition")["physics_kind"])
		if kind == "towed_turntable":
			bodies.append(tool.get("body"))
			bodies.append(tool.get("carriage"))
		elif kind == "towed_single_axle":
			bodies.append(tool.get("body"))
		elif kind != "rigid_mounted":
			last_error = "Nieobsługiwany typ narzędzia."
			return false
	for i in bodies.size():
		for owner_id in bodies[i].get_shape_owners():
			if bodies[i].is_shape_owner_disabled(owner_id):
				continue
			var local: Transform2D = bodies[i].shape_owner_get_transform(owner_id)
			for j in bodies[i].shape_owner_get_shape_count(owner_id):
				var shape: Shape2D = bodies[i].shape_owner_get_shape(owner_id, j)
				if not shape is RectangleShape2D:
					last_error = "Odtwarzanie obsługuje obecne prostokątne kolizje maszyn."
					return false
				var half: Vector2 = shape.size * 0.5
				var corners := PackedVector2Array()
				for p in [Vector2(-half.x,-half.y), Vector2(half.x,-half.y), half, Vector2(-half.x,half.y)]:
					corners.append(local * p)
				shapes.append({"body": i, "corners": corners, "mask": bodies[i].collision_mask})
				reach = maxf(reach, (bodies[i].global_position.distance_to(vehicle.global_position) + local.origin.length() + half.length()) / units + 2.0)
	if shapes.is_empty():
		last_error = "Brak brył kolizji pojazdu."
		return false
	return true

func signature() -> Dictionary:
	var model: Dictionary = vehicle.get_meta("definition")
	var child: Dictionary = tool.get_meta("definition") if tool != null else {}
	return {"vehicle_model": model["id"], "tool_model": child.get("id", ""),
		"vehicle_config": JSON.stringify(model, "", true).sha256_text(),
		"tool_config": JSON.stringify(child, "", true).sha256_text(),
		"socket": link.get("socket", {}).get("id", ""), "plug": link.get("plug", {}).get("id", "")}

func sample(time: float) -> Array:
	var body_angle: float = 0.0
	var drawbar_angle: float = 0.0
	if kind == "towed_turntable" or kind == "towed_single_axle":
		body_angle = angle_difference(vehicle.global_rotation, bodies[1].global_rotation)
	if kind == "towed_turntable":
		drawbar_angle = angle_difference(bodies[1].global_rotation, bodies[2].global_rotation)
	return [time, vehicle.global_position.x / units, vehicle.global_position.y / units,
		vehicle.global_rotation, body_angle, drawbar_angle, float(vehicle.call("get_recorded_steering")),
		1.0 if tool_working() else 0.0]


## Czy podpięte narzędzie pracuje (opuszczone/włączone klawiszem B).
func tool_working() -> bool:
	if tool == null or not tool.get_meta("definition").get("work") is Dictionary:
		return false
	var work_state: Variant = tool.get_meta("instance_state").get("work_state")
	return work_state is Dictionary and bool(work_state.get("enabled", false)) and bool(work_state.get("lowered", false))


## Odtworzenie: ustawia pracę narzędzia tak jak w nagraniu.
func set_tool_working(value: bool) -> void:
	if tool == null or not tool.get_meta("definition").get("work") is Dictionary:
		return
	var state: Dictionary = tool.get_meta("instance_state")
	if not state.get("work_state") is Dictionary:
		state["work_state"] = {}
	state["work_state"]["enabled"] = value
	state["work_state"]["lowered"] = value

static func interpolate(a: Array, b: Array, time: float) -> Array:
	var weight: float = clampf((time - float(a[0])) / maxf(0.000001, float(b[0]) - float(a[0])), 0.0, 1.0)
	var result: Array = [time, lerpf(a[1], b[1], weight), lerpf(a[2], b[2], weight),
		lerp_angle(a[3], b[3], weight), lerp_angle(a[4], b[4], weight), lerp_angle(a[5], b[5], weight)]
	if a.size() >= 7 and b.size() >= 7:
		result.append(lerpf(float(a[6]), float(b[6]), weight))
	if a.size() >= 8 and b.size() >= 8:
		# Praca narzędzia się nie interpoluje: obowiązuje stan z początku odcinka.
		result.append(float(b[7]) if weight >= 1.0 else float(a[7]))
	return result

func poses(sample_data: Array) -> Array[Transform2D]:
	var parent := Transform2D(float(sample_data[3]), Vector2(sample_data[1], sample_data[2]) * units)
	var result: Array[Transform2D] = [parent]
	if kind == "towed_turntable" or kind == "towed_single_axle":
		var anchor: Vector2 = parent * (_vec(link["socket"]["position_m"]) * units)
		var body_angle: float = float(sample_data[3]) + float(sample_data[4])
		var plug: Vector2 = _vec(link["plug"]["position_m"]) * units
		if kind == "towed_turntable":
			var carriage_angle: float = body_angle + float(sample_data[5])
			var pivot: Vector2 = anchor - plug.rotated(carriage_angle)
			var pivot_local: Vector2 = _vec(tool.get_meta("definition")["front_carriage"]["pivot_in_body_m"]) * units
			result.append(Transform2D(body_angle, pivot - pivot_local.rotated(body_angle)))
			result.append(Transform2D(carriage_angle, pivot))
		else:
			result.append(Transform2D(body_angle, anchor - plug.rotated(body_angle)))
	return result

func lock() -> void:
	if not _saved.is_empty():
		return
	vehicle.call("set_controls", 0.0, 0.0, true)
	for body in bodies:
		_saved.append({"freeze": body.freeze, "mode": body.freeze_mode,
			"physics": body.is_physics_processing()})
		body.set_physics_process(false)
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.constant_force = Vector2.ZERO
		body.constant_torque = 0.0
		body.freeze_mode = RigidBody2D.FREEZE_MODE_STATIC
		body.freeze = true

func apply(sample_data: Array, teleport: bool = false) -> void:
	vehicle.call("set_route_visual_steering", float(sample_data[6]) if sample_data.size() >= 7 else 0.0)
	# Starsze trasy (bez kolumny pracy) nie zmieniają stanu narzędzia.
	if sample_data.size() >= 8:
		set_tool_working(float(sample_data[7]) > 0.5)
	var transforms: Array[Transform2D] = poses(sample_data)
	for i in bodies.size():
		var body: RigidBody2D = bodies[i]
		body.global_transform = transforms[i]
		PhysicsServer2D.body_set_state(body.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, transforms[i])
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		if teleport:
			body.reset_physics_interpolation()

func unlock() -> void:
	vehicle.call("clear_route_visual_steering")
	if _saved.is_empty():
		return
	for i in bodies.size():
		var body: RigidBody2D = bodies[i]
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.constant_force = Vector2.ZERO
		body.constant_torque = 0.0
		body.freeze_mode = _saved[i]["mode"]
		body.freeze = _saved[i]["freeze"]
		body.set_physics_process(_saved[i]["physics"])
		body.sleeping = false
	_saved.clear()

func excluded() -> Array[RID]:
	var result: Array[RID] = []
	for body in bodies:
		result.append(body.get_rid())
	return result

func stopped(limit: float) -> bool:
	for body in bodies:
		if body.linear_velocity.length() / units > limit or absf(body.angular_velocity) > 0.1:
			return false
	return true

func _vec(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))
