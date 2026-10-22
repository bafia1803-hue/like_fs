extends StaticBody2D
## Maszyna bez fizyki jazdy (nieznany physics_kind): nieruchoma bryła z body_collision.

const Vec = preload("res://scripts/core/util/vec.gd")

var definition: Dictionary = {}
var instance_state: Dictionary = {}


func configure(model: Dictionary, saved_state: Dictionary, _materials: Array, units: float) -> void:
	definition = model
	instance_state = saved_state
	name = str(saved_state["instance_id"])
	collision_layer = 3
	collision_mask = 3
	var saved_pose: Dictionary = saved_state["transform"]
	position = Vec.v2(saved_pose["position_m"]) * units
	rotation = deg_to_rad(float(saved_pose["rotation_deg"]))
	var collision_data: Dictionary = model["physics"]["body_collision"]
	var shape := RectangleShape2D.new()
	shape.size = Vector2(float(collision_data["width_m"]), float(collision_data["length_m"])) * units
	var collider := CollisionShape2D.new()
	collider.name = "BodyCollision"
	collider.shape = shape
	collider.position = Vec.v2(collision_data["center_m"]) * units
	collider.rotation = deg_to_rad(float(collision_data["rotation_deg"]))
	add_child(collider)


func pose_body() -> Node2D:
	return self


func motion_body() -> RigidBody2D:
	return null


func cargo_body() -> RigidBody2D:
	return null


func is_attached() -> bool:
	return false


func change_cargo_mass(_delta_kg: float) -> void:
	pass
