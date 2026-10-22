extends RefCounted
## Kolizje na dwóch poziomach wysokości (fizyka jest 2D, z góry).
##
## Każda bryła kolizji maszyny może mieć klucz "levels": ["low"], ["high"] albo oba (domyślnie).
##   low  – nisko nad ziemią: rama ciągnika siodłowego za kabiną, nogi naczepy, osie
##   high – wysoko: przód naczepy wisi nad siodłem (tir może pod niego wjechać)
## Dwie bryły zderzają się tylko wtedy, gdy mają wspólny poziom.
## Budynki, przeszkody i maszyny bez kluczy "levels" są na obu poziomach (zachowanie jak dawniej).
##
## Godot przypisuje warstwy kolizji do całego ciała, nie do pojedynczej bryły. Dlatego bryły
## tylko-niskie i tylko-wysokie trafiają na osobne, lekkie ciała „poziomów” zespawane z głównym
## nadwoziem stawem stałym (Rapier: joint_make_fixed). Główne ciało ma bryły obu poziomów,
## dostaje siły opon i napędu; ciała poziomów tylko przenoszą kontakt.
##
## Format bryły (machines.json, physics.collision_shapes):
##   {"center_m": [x, y], "width_m": w, "length_m": l, "rotation_deg": 0, "levels": ["low"]}
## Opcjonalnie "group": nazwa – bryły tej samej grupy można włączać/wyłączać razem
## (np. nogi naczepy: "legs" – kolizja tylko po odpięciu).

const LOW: int = 1
const HIGH: int = 2
const ALL: int = LOW | HIGH
## Masa ciała poziomu względem głównego nadwozia (mała: nie zmienia jazdy, ale przenosi kontakt).
const SUB_MASS_RATIO: float = 0.04
static var _units: float = 40.0


static func bits(levels: Variant) -> int:
	if not levels is Array or (levels as Array).is_empty():
		return ALL
	var result: int = 0
	for level in levels:
		match str(level):
			"low":
				result |= LOW
			"high":
				result |= HIGH
	return result if result != 0 else ALL


## Dodaje bryły do głównego ciała i tworzy ciała poziomów (dzieci głównego ciała).
## Zwraca {"groups": {nazwa: [CollisionShape2D]}, "sub_bodies": [RigidBody2D]}.
## Główne ciało musi mieć już ustawioną masę i pozę; ciała poziomów są spawane przy wejściu do drzewa.
static func build(main: RigidBody2D, shapes: Array, units: float) -> Dictionary:
	_units = units
	main.collision_layer = ALL
	main.collision_mask = ALL
	var subs: Dictionary = {}          # bity -> RigidBody2D
	var groups: Dictionary = {}
	for value in shapes:
		var rect: Dictionary = value
		var level_bits: int = bits(rect.get("levels"))
		var target: RigidBody2D = main
		if level_bits != ALL:
			if not subs.has(level_bits):
				subs[level_bits] = _make_sub(main, level_bits)
			target = subs[level_bits]
		var shape := RectangleShape2D.new()
		shape.size = Vector2(float(rect["width_m"]), float(rect["length_m"])) * units
		var collider := CollisionShape2D.new()
		collider.shape = shape
		collider.position = Vector2(float(rect["center_m"][0]), float(rect["center_m"][1])) * units
		collider.rotation = deg_to_rad(float(rect.get("rotation_deg", 0.0)))
		target.add_child(collider)
		var group: String = str(rect.get("group", ""))
		if not group.is_empty():
			if not groups.has(group):
				groups[group] = []
			groups[group].append(collider)
	var list: Array[RigidBody2D] = []
	for sub in subs.values():
		list.append(sub)
		main.add_child(sub)
		main.add_collision_exception_with(sub)
	main.set_meta("level_bodies", list)
	if not list.is_empty():
		main.tree_entered.connect(func(): weld.call_deferred(main), CONNECT_ONE_SHOT)
	return {"groups": groups, "sub_bodies": list}


static func _make_sub(main: RigidBody2D, level_bits: int) -> RigidBody2D:
	var sub := RigidBody2D.new()
	sub.name = "Level_" + ("low" if level_bits == LOW else "high")
	sub.collision_layer = level_bits
	sub.collision_mask = level_bits
	sub.gravity_scale = 0.0
	sub.linear_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	sub.angular_damp_mode = RigidBody2D.DAMP_MODE_REPLACE
	sub.mass = maxf(1.0, main.mass * SUB_MASS_RATIO)
	# Stały moment bezwładności: ciało poziomu może chwilowo nie mieć żadnej bryły (np. nogi
	# po podpięciu), a Rapier traktuje zerową bezwładność jak zablokowany obrót – to
	# zablokowałoby obrót całego nadwozia przez staw stały.
	sub.inertia = sub.mass * pow(2.0 * _units, 2.0)
	sub.center_of_mass_mode = RigidBody2D.CENTER_OF_MASS_MODE_CUSTOM
	sub.center_of_mass = Vector2.ZERO
	sub.can_sleep = false
	sub.continuous_cd = RigidBody2D.CCD_MODE_CAST_SHAPE
	sub.physics_material_override = main.physics_material_override
	sub.set_meta("level_main", main)
	# Ruch rodzica nie przesuwa ciała poziomu – pozę daje fizyka (staw stały).
	sub.top_level = true
	sub.transform = main.transform
	return sub


## Ciała poziomów danego nadwozia (puste dla zwykłych maszyn).
static func sub_bodies(main: Node) -> Array:
	return main.get_meta("level_bodies", []) if main != null else []


## Spawanie ciał poziomów z głównym nadwoziem (staw stały w miejscu nadwozia).
static func weld(main: RigidBody2D) -> void:
	if not is_instance_valid(main):
		return
	sync(main)
	var joints: Array = []
	for sub in sub_bodies(main):
		var joint: RID = PhysicsServer2D.joint_create()
		PhysicsServer2D.call("joint_make_fixed", joint, main.global_position, main.get_rid(), (sub as RigidBody2D).get_rid())
		PhysicsServer2D.joint_disable_collisions_between_bodies(joint, true)
		joints.append(joint)
	main.set_meta("level_joints", joints)
	main.tree_exiting.connect(func():
		for joint in main.get_meta("level_joints", []):
			PhysicsServer2D.free_rid(joint)
		main.set_meta("level_joints", []), CONNECT_ONE_SHOT)


## Po teleporcie nadwozia (podpięcie, start trasy): ciała poziomów w tym samym miejscu.
static func sync(main: RigidBody2D) -> void:
	for value in sub_bodies(main):
		var sub: RigidBody2D = value
		sub.global_transform = main.global_transform
		PhysicsServer2D.body_set_state(sub.get_rid(), PhysicsServer2D.BODY_STATE_TRANSFORM, main.global_transform)
		sub.linear_velocity = main.linear_velocity
		sub.angular_velocity = main.angular_velocity
		sub.sleeping = false


## Zwykła bryła maszyny bez podziału na poziomy (nadwozie z body_collision).
static func single_rect(collision: Dictionary) -> Array:
	return [{"center_m": collision["center_m"], "width_m": collision["width_m"], "length_m": collision["length_m"],
		"rotation_deg": collision.get("rotation_deg", 0.0)}]
