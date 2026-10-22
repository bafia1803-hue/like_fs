extends Node
## Sklep i nieruchomości (warstwa gry): kupno i sprzedaż maszyn, zakup pól.
## Miejsce na placu: core/shop/lot_planner.gd; stan nowej maszyny: core/shop/instance_factory.gd.

const Machines = preload("res://scripts/sim/machines/machines.gd")
const Footprint = preload("res://scripts/core/shop/machine_footprint.gd")
const LotPlanner = preload("res://scripts/core/shop/lot_planner.gd")
const InstanceFactory = preload("res://scripts/core/shop/instance_factory.gd")
const Vec = preload("res://scripts/core/util/vec.gd")

var _context: RefCounted


func setup(context: RefCounted) -> void:
	name = "Shop"
	_context = context


func shop_data() -> Dictionary:
	return _context.map_data().get("shop", {})


## Kupuje maszynę i stawia ją na placu sklepu. Zwraca komunikat dla gracza.
func buy_machine(model_id: String) -> String:
	var models: Dictionary = _context.models()
	if not models.has(model_id):
		return "Nieznana maszyna."
	var model: Dictionary = models[model_id]
	var economy: RefCounted = _context.economy
	var price: float = float(economy.prices.machine_price(model_id))
	if price < 0.0:
		return "Tej maszyny nie ma w sklepie."
	if not economy.can_afford(price):
		return "Za mało pieniędzy: %s kosztuje %s." % [str(model["name"]), economy.format(price)]
	var shop: Dictionary = shop_data()
	var rotation: float = deg_to_rad(float(shop.get("spawn_rotation_deg", 0.0)))
	# Obrys w orientacji, w jakiej maszyna stanie na placu.
	var footprint: Rect2 = Footprint.world_aabb(Footprint.local_rect(model), Vector2.ZERO, rotation)
	var lot := Rect2(Vec.v2(shop["lot"]["origin_m"]), Vec.v2(shop["lot"]["size_m"]))
	var spot: Variant = LotPlanner.find_spot(lot, footprint, occupied_rects(), float(shop.get("spacing_m", 1.5)))
	if spot == null:
		return "Brak miejsca na placu sklepu. Odjedź którąś maszyną i spróbuj ponownie."
	if not economy.spend(price, "Zakup: " + str(model["name"])):
		return "Za mało pieniędzy."
	var instance_id: String = InstanceFactory.next_id(InstanceFactory.prefix_for(model), _context.machines.by_id)
	var state: Dictionary = InstanceFactory.new_state(model, instance_id, spot, rotation)
	var machine: Node2D = _context.factory.create(state)
	_context.machines.add(machine)
	return "Kupiono: %s. Czeka na placu sklepu." % str(model["name"])


## Sprzedaje maszynę. Zwraca komunikat dla gracza.
func sell_machine(instance_id: String) -> String:
	var reason: String = sell_block_reason(instance_id)
	if not reason.is_empty():
		return reason
	var machine: Node2D = _context.machines.get_machine(instance_id)
	var model: Dictionary = Machines.model(machine)
	var value: float = float(_context.economy.prices.machine_resale_price(str(model["id"])))
	if machine == _context.player.controlled:
		_context.player.switch_vehicle()
	_context.hitches.detach_all(machine)
	_context.machines.remove(machine)
	_context.economy.earn(value, "Sprzedaż: " + str(model["name"]))
	return "Sprzedano: %s za %s." % [str(model["name"]), _context.economy.format(value)]


## Dlaczego maszyny nie można teraz sprzedać (pusty tekst = można).
func sell_block_reason(instance_id: String) -> String:
	var machine: Node2D = _context.machines.get_machine(instance_id)
	if machine == null:
		return "Nie ma takiej maszyny."
	var vehicles: Array[RigidBody2D] = _context.machines.vehicles
	# Przypięta maszyna może być sprzedana (połączenie znika), ale nie w trakcie trasy zestawu.
	for vehicle in vehicles:
		if vehicle != machine and _context.hitches.get_attached_machine(vehicle) != machine:
			continue
		if Machines.route_mode(vehicle) == "playing" or Machines.is_recording(vehicle):
			return "Zestaw wykonuje trasę."
	if machine is RigidBody2D and vehicles.has(machine as RigidBody2D) and vehicles.size() <= 1:
		return "To twój ostatni pojazd."
	return ""


## Prostokąty zajęte przez maszyny i przeszkody (metry, świat) – dla placu sklepu.
func occupied_rects() -> Array:
	var result: Array = []
	for machine in _context.machines.all():
		var pose: Transform2D = Machines.pose_m(machine, _context.units)
		result.append(Footprint.world_aabb(Footprint.local_rect(Machines.model(machine)), pose.origin, pose.get_rotation()))
	for obstacle in _context.map_data().get("static_obstacles", []):
		var center: Vector2 = Vec.v2(obstacle["center_m"])
		var half: Vector2 = Vector2.ONE * float(obstacle.get("radius_m", 0.0))
		if str(obstacle.get("shape", "")) == "rectangle":
			half = Vector2(float(obstacle["width_m"]), float(obstacle["length_m"])) * 0.5
		result.append(Rect2(center - half, half * 2.0))
	return result


## Cena pola (zł) albo -1, gdy nie jest na sprzedaż.
func field_price(field_id: String) -> float:
	return float(_context.economy.prices.field_price(field_id))


## Pole pod pojazdem, które można kupić: {"id", "name", "price"} albo pusty słownik.
func field_offer_for(vehicle: Node2D) -> Dictionary:
	if not is_instance_valid(vehicle):
		return {}
	var field: Node2D = _context.field_work.field_at(vehicle.global_position)
	if field == null or bool(field.owned):
		return {}
	var price: float = field_price(str(field.field_id))
	if price < 0.0:
		return {}
	return {"id": str(field.field_id), "name": str(field.field_name), "price": price}


func buy_field(field_id: String) -> String:
	var price: float = field_price(field_id)
	if price < 0.0:
		return "To pole nie jest na sprzedaż."
	if not _context.economy.spend(price, "Zakup pola"):
		return "Za mało pieniędzy na pole (%s)." % _context.economy.format(price)
	_context.field_work.set_owned(field_id)
	return "Kupiono pole! Możesz na nim pracować."
