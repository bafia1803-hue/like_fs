extends RefCounted
## Odczyt stanu gry dla widoków i interfejsu (zapytania, bez zmian stanu).
## Widoki dostają tylko ten obiekt (i EventBus), więc nie mogą zmienić gry.

const Machines = preload("res://scripts/sim/machines/machines.gd")
const FieldWorkRules = preload("res://scripts/core/field/field_work_rules.gd")

var _context: RefCounted


func _init(context: RefCounted) -> void:
	_context = context


func events() -> RefCounted:
	return _context.events


func units() -> float:
	return _context.units


func world_rect_m() -> Rect2:
	return _context.world_rect_m


func map_data() -> Dictionary:
	return _context.map_data()


func catalog() -> Dictionary:
	return _context.catalog()


func models() -> Dictionary:
	return _context.models()


func materials() -> Array:
	return _context.materials()


func machines() -> Dictionary:
	return _context.machines.by_id


func controlled_vehicle() -> RigidBody2D:
	return _context.player.controlled


func attached_machine(vehicle: Node) -> Node2D:
	return _context.hitches.get_attached_machine(vehicle)


func field_grids() -> Array:
	return _context.field_work.fields


func farming_settings() -> Dictionary:
	return _context.config.farming


func route_system() -> Node2D:
	return _context.routes


func silos() -> Array:
	return _context.transfer.get_silos()


func farm_points() -> Array:
	return _context.services.get_points()


func sell_points() -> Array:
	return _context.transfer.get_sell_points()


func economy() -> RefCounted:
	return _context.economy


func money() -> float:
	return _context.economy.get_money()


func format_money(amount: float) -> String:
	return _context.economy.format(amount)


## Cena pola (zł) albo -1, gdy nie jest na sprzedaż.
func field_price(field_id: String) -> float:
	return _context.shop.field_price(field_id)


func shop_data() -> Dictionary:
	return _context.shop.shop_data()


func shop_models() -> Array:
	return _context.economy.prices.shop_models()


func machine_price(model_id: String) -> float:
	return _context.economy.prices.machine_price(model_id)


func machine_resale_price(model_id: String) -> float:
	return _context.economy.prices.machine_resale_price(model_id)


func sell_block_reason(instance_id: String) -> String:
	return _context.shop.sell_block_reason(instance_id)


## Dane mapy dla minimapy tras: mapa, granice świata i pola (tekstury stanu jak w widoku 2D).
func route_map_data() -> Dictionary:
	var colors: Dictionary = farming_settings().get("colors", {})
	var fields: Array = []
	var definitions: Dictionary = {}
	for field_data in map_data()["fields"]:
		definitions[str(field_data["id"])] = field_data
	for grid in field_grids():
		var palette: Array[Color] = [Color(str(definitions.get(str(grid.field_id), {}).get("soil_surface", {}).get("color", "#795137")))]
		for key in ["sown", "light", "dark", "ready", "harvested"]:
			palette.append(Color(str(colors.get(key, "#888888"))))
		fields.append({"origin": grid.position / units(), "size": Vector2(grid.columns, grid.rows) * float(grid.cell_m),
			"rotation": grid.rotation, "texture": grid.stage_texture, "palette": palette})
	return {"map": map_data(), "world_rect": world_rect_m(), "fields": fields}


## Obecne pozy wszystkich maszyn (metry) dla minimapy: [{"model", "transforms", "unfolded"}].
func machine_shapes() -> Array:
	var result: Array = []
	for machine in machines().values():
		var transforms: Dictionary = {"body": Machines.pose_m(machine, units())}
		var carriage: Variant = machine.get("carriage")
		if carriage is Node2D:
			var xf: Transform2D = (carriage as Node2D).global_transform
			transforms["front_carriage"] = Transform2D(xf.get_rotation(), xf.origin / units())
		result.append({"model": Machines.model(machine), "transforms": transforms, "unfolded": Machines.fold_progress(machine)})
	return result


## Komunikaty przeładunku i usług farmy dotyczące danej maszyny.
func machine_statuses(machine: Node) -> PackedStringArray:
	var result := PackedStringArray()
	var id: String = Machines.id(machine)
	for text in [_context.transfer.get_status(id), _context.services.get_status(id)]:
		if not str(text).is_empty():
			result.append(str(text))
	return result


## Maszyny gracza: sterowany pojazd i jego narzędzie.
func player_machines() -> Array:
	return _context.player.player_machines()


## Oferta punktu farmy dla zestawu gracza (silos, magazyn) albo pusty słownik.
func service_offer() -> Dictionary:
	for machine in player_machines():
		var offer: Dictionary = _context.services.offer_for(machine)
		if not offer.is_empty():
			return offer
	return {}


func purchase_label(offer: Dictionary) -> String:
	return _context.services.purchase_label(offer)


## Pole pod sterowanym pojazdem na sprzedaż: {"id", "name", "price"} albo pusty słownik.
func field_offer() -> Dictionary:
	return _context.shop.field_offer_for(controlled_vehicle())


## Podpięty siewnik sterowanego zestawu (albo null).
func controlled_seeder() -> Node2D:
	return _context.player.controlled_seeder()


## Gatunek wysiewany przez siewnik.
func seed_crop(seeder: Node) -> String:
	return FieldWorkRules.seed_crop(Machines.model(seeder), Machines.state(seeder))


## Trasy pasujące do zestawu pojazdu.
func compatible_routes(vehicle: RigidBody2D) -> Array:
	return _context.routes.compatible(vehicle) if vehicle != null else []


## Linie panelu diagnostycznego (F3).
func diagnostics() -> PackedStringArray:
	var vehicle: RigidBody2D = controlled_vehicle()
	var lines := PackedStringArray()
	if not is_instance_valid(vehicle):
		return lines
	lines.append("%s | %.1f km/h | masa: %.0f kg" % [Machines.display_name(vehicle), Machines.display_speed_kmh(vehicle), vehicle.mass])
	lines.append(str(_context.hitches.get_diagnostics(vehicle)))
	var implement: Node2D = attached_machine(vehicle)
	if implement != null and implement.has_method("get_diagnostics"):
		lines.append(str(implement.call("get_diagnostics")))
	lines.append(str(_context.field_work.get_diagnostics(vehicle)))
	lines.append(str(_context.transfer.get_diagnostics(vehicle, implement)))
	return lines
