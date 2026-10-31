extends RefCounted
## Polecenia gracza – jedyna droga, którą interfejs zmienia stan gry.
## Każde polecenie zwraca komunikat dla gracza (pusty = nic do pokazania); wołający decyduje,
## gdzie go wyświetlić (dymek, etykieta w oknie).

const Machines = preload("res://scripts/sim/machines/machines.gd")
const FieldWorkScript = preload("res://scripts/sim/systems/field_work_system.gd")

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func _vehicle() -> RigidBody2D:
	return _context.player.controlled


## Klawisz B: praca narzędzia sterowanego zestawu.
func toggle_work() -> String:
	if not is_instance_valid(_vehicle()):
		return ""
	return str(_context.field_work.toggle_work(_vehicle()))


## Klawisz H: pracownik obrabia pole najbliższe sterowanemu zestawowi (albo kończy pracę).
## Pusty komunikat, gdy funkcja pracownika jest wyłączona.
func toggle_worker() -> String:
	if _context.workers == null or not is_instance_valid(_vehicle()):
		return ""
	return str(_context.workers.toggle(_vehicle()))


## Klawisz E: podpięcie/odpięcie (wołać poza krokiem fizyki – call_deferred).
func toggle_attachment() -> String:
	if not is_instance_valid(_vehicle()):
		return ""
	return str(_context.hitches.toggle_for(_vehicle()))


## TAB: następny/poprzedni pojazd.
func switch_vehicle(direction: int = 1) -> String:
	return _context.player.switch_vehicle(direction)


func buy_machine(model_id: String) -> String:
	return _context.shop.buy_machine(model_id)


func sell_machine(instance_id: String) -> String:
	return _context.shop.sell_machine(instance_id)


func buy_field(field_id: String) -> String:
	return _context.shop.buy_field(field_id)


## Przycisk z kłosem: następny gatunek siewnika gracza.
func cycle_seed_crop() -> String:
	var seeder: Node2D = _context.player.controlled_seeder()
	return "" if seeder == null else FieldWorkScript.cycle_seed_crop(seeder)


## Punkty farmy.
func request_fill(point_id: String, machine_id: String, material: String) -> String:
	return _context.services.request_fill(point_id, machine_id, material)


func start_purchase(offer: Dictionary) -> String:
	return _context.services.start_purchase(offer)


func cancel_fill(machine_id: String) -> String:
	_context.services.cancel_fill(machine_id)
	return "Przerwano napełnianie."


## Sen: rośliny rosną o jedną fazę. Zwraca liczbę komórek, które urosły.
func grow_crops() -> int:
	return _context.field_work.grow_crops()


# ---------------------------------------------------------------------------
# Trasy
# ---------------------------------------------------------------------------

## Okno tras: „Uruchom trasę”. Zestaw na miejscu i gotowy – start od razu; inaczej zestaw widmo
## i podpowiedź, co zrobić.
func request_route_start(route: Dictionary) -> String:
	if not is_instance_valid(_vehicle()):
		return ""
	var routes: Node = _context.routes
	routes.arm(_vehicle(), route)
	var status: Dictionary = routes.armed_status()
	if bool(status.get("at_start", false)) and bool(status.get("tool_ok", false)) and bool(status.get("slow", false)):
		return start_armed_route()
	if not bool(status.get("at_start", false)):
		return "Podjedź na miejsce startu"
	if not bool(status.get("tool_ok", false)):
		return routes.tool_hint(str(status["tool_needed"]))
	return "Zwolnij i naciśnij „Uruchom trasę”."


func start_armed_route() -> String:
	var text: String = _context.routes.start_armed()
	return text if not text.is_empty() else "Uruchomiono trasę."


## „Odwołaj przejazd”: przed startem odwołuje przejazd, w trakcie jazdy płynnie go przerywa.
func cancel_route() -> String:
	var routes: Node = _context.routes
	if not routes.armed.is_empty():
		routes.disarm()
		return "Przejazd odwołany."
	if is_instance_valid(_vehicle()) and routes.tasks.has(_vehicle()):
		routes.request_stop(_vehicle(), "Przejazd odwołany.")
	return ""


## Odwołany przejazd, którego pojazd zniknął (np. sprzedany). Zwraca komunikat albo pusty.
func drop_invalid_armed_route() -> String:
	var routes: Node = _context.routes
	if not routes.armed.is_empty() and not bool(routes.armed_status().get("valid", false)):
		routes.disarm()
		return "Przejazd odwołany – brak pojazdu."
	return ""


func stop_route(vehicle: RigidBody2D) -> void:
	_context.routes.stop(vehicle)


func begin_recording() -> void:
	_context.routes.begin_recording(_vehicle(), "")


func recording_stop_problem() -> String:
	return _context.routes.recording_stop_problem()


func finish_recording(title: String) -> void:
	_context.routes.finish_recording(title)


func cancel_recording() -> void:
	_context.routes.cancel_recording()


func rename_route(id: String, title: String) -> void:
	_context.routes.rename_route(id, title)


func delete_route(id: String) -> void:
	_context.routes.delete_route(id)
