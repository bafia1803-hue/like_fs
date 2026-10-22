extends RefCounted
## Obrys maszyny z góry (metry, układ maszyny: x w prawo, y do tyłu, środek nadwozia w 0,0)
## – w pozycji postojowej (maszyna składana: złożona). Obejmuje nadwozie, koła, zaczepy i dyszel.
## Używa go plac sklepu do ustawiania kupionych maszyn bez nachodzenia na siebie.


static func local_rect(model: Dictionary) -> Rect2:
	var dims: Dictionary = model["dimensions"]
	var width: float = float(dims["width_m"])
	var length: float = float(dims["length_m"])
	var half_width: float = width * 0.5
	# Maszyna składana stoi złożona: szerokość z profilu kolizji "złożony".
	var folding: Variant = model.get("folding")
	var profiles: Variant = model.get("physics", {}).get("collision_profiles")
	if folding is Dictionary and profiles is Dictionary:
		var folded: Array = profiles.get(str(folding.get("folded_profile", "folded")), [])
		if not folded.is_empty():
			half_width = 0.0
			for rect in folded:
				half_width = maxf(half_width, absf(float(rect["center_m"][0])) + float(rect["width_m"]) * 0.5)
	var result := Rect2(-half_width, -length * 0.5, half_width * 2.0, length)
	for axle in model.get("axles", []):
		var y: float = -length * 0.5 + float(axle["distance_from_front_m"])
		var radius: float = float(axle["tire_length_m"]) * 0.5
		var x: float = float(axle["track_m"]) * 0.5 + float(axle["tire_width_m"]) * 0.5
		result = result.expand(Vector2(-x, y - radius)).expand(Vector2(x, y + radius))
	var carriage_pivot := Vector2.ZERO
	if model.get("front_carriage") is Dictionary:
		var pivot: Array = model["front_carriage"]["pivot_in_body_m"]
		carriage_pivot = Vector2(float(pivot[0]), float(pivot[1]))
	for port in model.get("hitch_ports", []):
		var point := Vector2(float(port["position_m"][0]), float(port["position_m"][1]))
		if str(port.get("member", "body")) == "front_carriage":
			point += carriage_pivot
		result = result.expand(point)
	if model.get("drawbar") is Dictionary:
		result = result.expand(Vector2(0.0, -length * 0.5 - float(model["drawbar"]["length_m"])))
	return result


## Prostokąt (AABB) zajmowany w świecie przez obrys obrócony o rotation (radiany), w metrach.
static func world_aabb(local: Rect2, position_m: Vector2, rotation: float) -> Rect2:
	var transform := Transform2D(rotation, position_m)
	var corners: Array[Vector2] = [local.position, Vector2(local.end.x, local.position.y), local.end, Vector2(local.position.x, local.end.y)]
	var result := Rect2(transform * corners[0], Vector2.ZERO)
	for corner in corners:
		result = result.expand(transform * corner)
	return result
