extends Node2D
## Nieruchome przeszkody z map.json (static_obstacles): silosy, wiaty, słupy.
## Warstwa gry: tworzy wyłącznie kolizje. Klucz "visual" czytają widoki 2D/3D.

var last_error: String = ""


func configure(map_data: Dictionary, units: float) -> bool:
	name = "StaticObstacles"
	for entry in map_data.get("static_obstacles", []):
		if not entry is Dictionary:
			return _fail("Niepoprawny wpis przeszkody.")
		var data: Dictionary = entry
		var center: Array = data.get("center_m", [])
		if center.size() != 2:
			return _fail("Przeszkoda bez center_m: " + str(data.get("id", "?")))
		var body := StaticBody2D.new()
		body.name = "Obstacle_" + str(data.get("id", "?"))
		body.collision_layer = 1
		body.collision_mask = 1
		body.position = Vector2(float(center[0]), float(center[1])) * units
		body.rotation = deg_to_rad(float(data.get("rotation_deg", 0.0)))
		var collider := CollisionShape2D.new()
		match str(data.get("shape", "")):
			"circle":
				var circle := CircleShape2D.new()
				circle.radius = float(data["radius_m"]) * units
				collider.shape = circle
			"rectangle":
				var rectangle := RectangleShape2D.new()
				rectangle.size = Vector2(float(data["width_m"]), float(data["length_m"])) * units
				collider.shape = rectangle
			_:
				body.free()
				return _fail("Nieznany kształt przeszkody: " + str(data.get("id", "?")))
		body.add_child(collider)
		add_child(body)
	return true


func _fail(message: String) -> bool:
	last_error = message
	push_error(message)
	return false
