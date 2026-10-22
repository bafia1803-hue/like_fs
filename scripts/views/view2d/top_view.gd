extends RefCounted
## Wygląd maszyny z góry (widok 2D, minimapa, podglądy): z konfiguracji, bez kodu dla każdej maszyny.
##
## machines.json → visual.top_view: lista prostokątów (lokalnie, metry, przód w −y):
##   {"center_m": [x, y], "size_m": [szerokość, długość], "color": "body" | "body_dark" | "#rrggbb",
##    "rotation_deg": 0 (opcjonalnie)}
## "body" = visual.body_color, "body_dark" = ten kolor przyciemniony. Bez visual.top_view maszyna
## jest jednym prostokątem o wymiarach z dimensions (dotychczasowy wygląd).


## [{"center": Vector2, "size": Vector2, "rotation": float, "color": Color}] w metrach.
static func parts(model: Dictionary) -> Array:
	var visual: Dictionary = model.get("visual", {}) if model.get("visual") is Dictionary else {}
	var body := Color.from_string(str(visual.get("body_color", "#888888")), Color.GRAY)
	var result: Array = []
	if visual.get("top_view") is Array:
		for part in visual["top_view"]:
			var color_name: String = str(part.get("color", "body"))
			var color: Color = body
			if color_name == "body_dark":
				color = body.darkened(0.25)
			elif color_name != "body":
				color = Color.from_string(color_name, body)
			result.append({"center": Vector2(float(part["center_m"][0]), float(part["center_m"][1])),
				"size": Vector2(float(part["size_m"][0]), float(part["size_m"][1])),
				"rotation": deg_to_rad(float(part.get("rotation_deg", 0.0))), "color": color})
		return result
	var dims: Dictionary = model["dimensions"]
	result.append({"center": Vector2.ZERO, "size": Vector2(float(dims["width_m"]), float(dims["length_m"])),
		"rotation": 0.0, "color": body})
	return result


## Czy model ma własny wygląd z góry.
static func custom(model: Dictionary) -> bool:
	return model.get("visual") is Dictionary and model["visual"].get("top_view") is Array
