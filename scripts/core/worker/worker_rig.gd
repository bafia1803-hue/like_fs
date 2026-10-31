extends RefCounted
## Model kinematyczny zestawu dla pracownika (czysta logika, metry i radiany).
##
## Pojazd jedzie po ścieżce PUNKTU PROWADZĄCEGO – środka osi bez skrętu (ciągnik: tylna oś,
## kombajn ze skrętną tylną osią: przednia). Ten punkt nie ślizga się na boki, więc po łuku
## o promieniu R jedzie dokładnie po okręgu.
## Narzędzie zawieszane (rigid_mounted) jest sztywno związane z pojazdem. Narzędzie przyczepiane
## (towed_single_axle) ciągnie się za zaczepem: jego oś podąża za punktem zaczepu (traktrysa),
## więc na zakrętach ścina łuk do środka – to liczy follow_tool().
##
## Układy: lokalny maszyny – przód to −y; obrót w grze (rot) – przód = (sin rot, −cos rot).
## Ścieżka (Dubins) – kierunek (cos θ, sin θ), więc rot = θ + π/2.

var pivot_y: float = 0.0            # lokalne y punktu prowadzącego w pojeździe
var wheelbase: float = 2.6
var max_steer: float = deg_to_rad(40.0)
var tool_kind: String = ""          # "" | "rigid_mounted" | "towed_single_axle"
var socket := Vector2.ZERO          # zaczep pojazdu (lokalnie, pojazd)
var plug := Vector2.ZERO            # zaczep narzędzia (lokalnie, narzędzie)
var tool_axle := Vector2.ZERO       # oś narzędzia przyczepianego (lokalnie, narzędzie)
## Środek obszaru roboczego: dla zawieszanego w układzie pojazdu, dla przyczepianego w układzie narzędzia.
var work_center := Vector2.ZERO
var work_width: float = 0.0
var work_length: float = 0.0


static func forward(rot: float) -> Vector2:
	return Vector2(sin(rot), -cos(rot))


static func rot_of(theta: float) -> float:
	return theta + PI * 0.5


static func theta_of(rot: float) -> float:
	return rot - PI * 0.5


func towed() -> bool:
	return tool_kind == "towed_single_axle"


## Długość dyszla narzędzia: od zaczepu do osi [m].
func tool_length() -> float:
	return (tool_axle - plug).length() if towed() else 0.0


## Środek pojazdu (pozycja węzła) dla punktu prowadzącego. Wynik: Vector3(x, y, rot).
func vehicle_pose(path_pose: Vector3) -> Vector3:
	var rot: float = rot_of(path_pose.z)
	var center: Vector2 = Vector2(path_pose.x, path_pose.y) + forward(rot) * pivot_y
	return Vector3(center.x, center.y, rot)


## Punkt prowadzący dla pozy pojazdu (odwrotność vehicle_pose).
func path_pose(vehicle_position: Vector2, vehicle_rot: float) -> Vector3:
	var point: Vector2 = vehicle_position - forward(vehicle_rot) * pivot_y
	return Vector3(point.x, point.y, theta_of(vehicle_rot))


## Zaczep pojazdu w świecie.
func hitch_point(vehicle: Vector3) -> Vector2:
	return Vector2(vehicle.x, vehicle.y) + socket.rotated(vehicle.z)


## Nowy obrót narzędzia przyczepianego po ruchu pojazdu do pozy vehicle (krok traktrysy):
## oś narzędzia zostaje na prostej do nowego zaczepu, w stałej odległości.
func follow_tool(tool_rot: float, previous_vehicle: Vector3, vehicle: Vector3) -> float:
	if not towed():
		return vehicle.z
	var length: float = tool_length()
	var old_hitch: Vector2 = hitch_point(previous_vehicle)
	var axle: Vector2 = old_hitch - forward(tool_rot) * length
	var direction: Vector2 = hitch_point(vehicle) - axle
	if direction.length() < 0.000001:
		return tool_rot
	direction = direction.normalized()
	return atan2(direction.x, -direction.y)


## Środek obszaru roboczego w świecie dla pozy pojazdu i obrotu narzędzia.
func work_point(vehicle: Vector3, tool_rot: float) -> Vector2:
	if towed():
		var tool_origin: Vector2 = hitch_point(vehicle) - plug.rotated(tool_rot)
		return tool_origin + work_center.rotated(tool_rot)
	return Vector2(vehicle.x, vehicle.y) + work_center.rotated(vehicle.z)


## Położenie środka obszaru roboczego przed punktem prowadzącym przy jeździe na wprost
## (dodatnie – przed, ujemne – za) [m].
func work_offset() -> float:
	var vehicle: Vector3 = vehicle_pose(Vector3(0.0, 0.0, -PI * 0.5))
	var point: Vector2 = work_point(vehicle, vehicle.z)
	return -point.y


## Promień zawracania punktu prowadzącego dla maksymalnego skrętu [m].
func minimum_radius() -> float:
	return wheelbase / maxf(tan(max_steer), 0.05)


## Skręt kół (−1 … 1, dodatni w prawo) dla krzywizny ścieżki [1/m] (dodatnia – obrót zgodnie
## z ruchem wskazówek zegara, czyli w prawo w grze).
func steering_for(curvature: float) -> float:
	return clampf(atan(curvature * wheelbase) / maxf(max_steer, 0.01), -1.0, 1.0)
