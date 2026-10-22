extends RefCounted
## Zamiana tablic z JSON ([x, y] w metrach) na wektory i proste sprawdzenia liczb.


static func v2(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))


static func to_array(value: Vector2) -> Array:
	return [value.x, value.y]


static func is_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))


static func is_pair(value: Variant) -> bool:
	return value is Array and (value as Array).size() == 2 and is_number(value[0]) and is_number(value[1])
