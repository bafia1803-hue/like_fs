extends RefCounted
const VERSION: int = 2

static func valid(route: Variant) -> bool:
	if not route is Dictionary:
		return false
	if (route.get("version") != 1 and route.get("version") != VERSION) or not route.get("name") is String or not route.get("signature") is Dictionary:
		return false
	if not route.get("id") is String or not route.get("map_id") is String or not route.get("samples") is Array:
		return false
	var samples: Array = route["samples"]
	if samples.size() < 2 or samples.size() > 150000:
		return false
	var previous: float = -1.0
	for sample in samples:
		if not sample is Array or sample.size() != (7 if int(route["version"]) == 2 else 6):
			return false
		for value in sample:
			if not (value is float or value is int) or not is_finite(float(value)):
				return false
		if float(sample[0]) <= previous or float(sample[0]) > 86400.0:
			return false
		if sample.size() == 7 and absf(float(sample[6])) > 1.0:
			return false
		previous = float(sample[0])
	return float(samples[0][0]) == 0.0

static func at(route: Dictionary, time: float, hint: int = 0) -> Dictionary:
	var samples: Array = route["samples"]
	var index: int = clampi(hint, 0, samples.size() - 2)
	while index < samples.size() - 2 and float(samples[index + 1][0]) < time:
		index += 1
	while index > 0 and float(samples[index][0]) > time:
		index -= 1
	var point: Array = preload("res://scripts/route_rig.gd").interpolate(samples[index], samples[index + 1], time)
	return {"point": point, "index": index}

static func between(route: Dictionary, start: float, finish: float, hint: int) -> Array:
	var first: Dictionary = at(route, start, hint)
	var result: Array = [first["point"]]
	var samples: Array = route["samples"]
	var index: int = int(first["index"]) + 1
	while index < samples.size() and float(samples[index][0]) < finish:
		if float(samples[index][0]) > start:
			result.append(samples[index])
		index += 1
	result.append(at(route, finish, int(first["index"]))["point"])
	return result
