extends RefCounted
## Próbka trasy: [czas, x, y, obrót pojazdu, kąt narzędzia, kąt dyszla, skręt kół, praca narzędzia,
## rozłożenie narzędzia] (metry, radiany). Starsze wersje mają mniej kolumn (route_data.gd).

const TIME: int = 0
const X: int = 1
const Y: int = 2
const VEHICLE_ROTATION: int = 3
const TOOL_ANGLE: int = 4
const DRAWBAR_ANGLE: int = 5
const STEERING: int = 6
const TOOL_WORKING: int = 7
const TOOL_UNFOLDED: int = 8
const COLUMN_NAMES: Array[String] = ["time_s", "x_m", "y_m", "vehicle_rad", "tool_relative_rad",
	"drawbar_relative_rad", "visual_steering_normalized", "tool_working", "tool_unfolded"]


## Próbka pomiędzy a i b w chwili time. Praca narzędzia się nie interpoluje: obowiązuje stan
## z początku odcinka (aż do samego końca odcinka).
static func interpolate(a: Array, b: Array, time: float) -> Array:
	var weight: float = clampf((time - float(a[0])) / maxf(0.000001, float(b[0]) - float(a[0])), 0.0, 1.0)
	var result: Array = [time, lerpf(a[1], b[1], weight), lerpf(a[2], b[2], weight),
		lerp_angle(a[3], b[3], weight), lerp_angle(a[4], b[4], weight), lerp_angle(a[5], b[5], weight)]
	if a.size() >= 7 and b.size() >= 7:
		result.append(lerpf(float(a[6]), float(b[6]), weight))
	if a.size() >= 8 and b.size() >= 8:
		result.append(float(b[7]) if weight >= 1.0 else float(a[7]))
	if a.size() >= 9 and b.size() >= 9:
		result.append(lerpf(float(a[8]), float(b[8]), weight))
	return result
