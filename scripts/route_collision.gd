extends RefCounted
## Konserwatywna osłona całego ruchu prostokątnych brył, także przy obrocie.
var last_error: String = ""

func volumes(rig: RefCounted, samples: Array, settings: Dictionary) -> Array:
	last_error = ""
	var vertices: Array = []
	for shape in rig.shapes:
		vertices.append(PackedVector2Array())
	var max_margin: float = float(settings["collision_margin_m"]) * rig.units
	var budget: int = int(settings["max_collision_steps_per_tick"])
	for segment in range(maxi(1, samples.size() - 1)):
		var a: Array = samples[segment]
		var b: Array = samples[mini(segment + 1, samples.size() - 1)]
		var distance: float = Vector2(a[1], a[2]).distance_to(Vector2(b[1], b[2]))
		var turn: float = 0.0
		for index in range(3, 6):
			turn += absf(angle_difference(a[index], b[index]))
		var steps: int = maxi(1, maxi(ceili(distance / float(settings["collision_step_m"])),
			ceili(turn / deg_to_rad(float(settings["collision_step_degrees"])))))
		budget -= steps
		if budget < 0:
			last_error = "Zbyt duży ruch w jednym kroku — zadanie zatrzymane."
			return []
		# Ograniczenie ugięcia łuku pomiędzy próbkami orientacji.
		max_margin = maxf(max_margin, float(settings["collision_margin_m"]) * rig.units + rig.reach * rig.units * pow(turn / steps, 2) / 8.0)
		for step in range(steps + 1):
			var point: Array = rig.interpolate(a, b, lerpf(a[0], b[0], float(step) / steps))
			var poses: Array = rig.poses(point)
			for shape_index in rig.shapes.size():
				var shape: Dictionary = rig.shapes[shape_index]
				for corner in shape["corners"]:
					vertices[shape_index].append(poses[shape["body"]] * corner)
	var result: Array = []
	for index in vertices.size():
		var expanded := PackedVector2Array()
		# Kwadratowa otoczka jest tania i konserwatywna.
		for point in Geometry2D.convex_hull(vertices[index]):
			for offset in [Vector2(-1,-1), Vector2(1,-1), Vector2(1,1), Vector2(-1,1)]:
				expanded.append(point + offset * max_margin)
		var hull: PackedVector2Array = Geometry2D.convex_hull(expanded)
		if hull.size() > 1 and hull[0].is_equal_approx(hull[-1]):
			hull.remove_at(hull.size() - 1)
		var bounds := Rect2(hull[0], Vector2.ZERO)
		for point in hull:
			bounds = bounds.expand(point)
		result.append({"polygon": hull, "bounds": bounds, "mask": rig.shapes[index]["mask"]})
	return result

func blocked(space: PhysicsDirectSpaceState2D, volumes_data: Array, exclude: Array[RID]) -> bool:
	for volume in volumes_data:
		var points: PackedVector2Array = volume["polygon"]
		var origin: Vector2 = points[0]
		var local := PackedVector2Array()
		for point in points:
			local.append(point - origin)
		var shape := ConvexPolygonShape2D.new()
		shape.points = local
		var query := PhysicsShapeQueryParameters2D.new()
		query.shape = shape
		query.transform = Transform2D(0.0, origin)
		query.collision_mask = int(volume["mask"])
		query.collide_with_areas = false
		query.exclude = exclude
		if not space.intersect_shape(query, 1).is_empty():
			return true
	return false

func overlap(first: Array, second: Array) -> bool:
	for a in first:
		for b in second:
			if a["bounds"].intersects(b["bounds"]) and not Geometry2D.intersect_polygons(a["polygon"], b["polygon"]).is_empty():
				return true
	return false
