extends RefCounted
## Kontener zależności symulacji (wstrzykiwanie zależności).
## Wypełnia go SimulationBuilder; systemy, WorldQuery i GameActions dostają go w setup().
## Testy mogą zbudować go częściowo – każdy system używa tylko pól, których potrzebuje.

var units: float = 40.0
## Sesja: save_data, map_data, catalog_data, models_by_id, instances_by_id.
var session: Dictionary = {}
var config: RefCounted          # data/game_config.gd
var events: RefCounted          # sim/event_bus.gd
var economy: RefCounted         # core/economy/economy.gd
var machines: RefCounted        # sim/machines/machine_registry.gd
var factory: RefCounted         # sim/machines/machine_factory.gd
var hitches: Node2D             # sim/systems/hitch_system.gd
var field_work: Node2D          # sim/systems/field_work_system.gd
var transfer: Node2D            # sim/systems/grain_transfer_system.gd
var services: Node2D            # sim/systems/farm_services.gd
var routes: Node2D              # sim/routes/route_system.gd
var player: Node                # sim/player_control.gd
var shop: Node                  # sim/systems/shop_service.gd
## Pracownik (sim/worker/worker_system.gd) – null, gdy funkcja wyłączona (files/workers.json).
var workers: Node2D
## Korzeń symulacji ("Simulation", Node2D) – wszystkie węzły gry są jego dziećmi.
var root: Node2D
## Granice świata w metrach (map.json → world_bounds).
var world_rect_m := Rect2()


func save_data() -> Dictionary:
	return session["save_data"]


func map_data() -> Dictionary:
	return session["map_data"]


func catalog() -> Dictionary:
	return session["catalog_data"]


func models() -> Dictionary:
	return session["models_by_id"]


func materials() -> Array:
	return session["catalog_data"]["materials"]


## Gęstość materiału [kg/l] (0 dla nieznanego).
func density(material_id: String) -> float:
	if _densities.is_empty():
		for material in materials():
			_densities[str(material["id"])] = float(material.get("bulk_density_kg_per_l", 0.0))
	return float(_densities.get(material_id, 0.0))


## Nazwa materiału z katalogu (id, gdy nieznany).
func material_name(material_id: String) -> String:
	for material in materials():
		if str(material["id"]) == material_id:
			return str(material.get("name", material_id))
	return material_id


var _densities: Dictionary = {}
