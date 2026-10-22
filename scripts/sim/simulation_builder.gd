extends RefCounted
## Buduje symulację (korzeń kompozycji warstwy gry): sesja → konfiguracja → ekonomia →
## przeszkody → maszyny → gracz → systemy → zdarzenia. Zwraca GameContext albo null
## (wtedy last_error opisuje problem). Nie tworzy widoków ani interfejsu.

const GameContext = preload("res://scripts/sim/game_context.gd")
const EventBus = preload("res://scripts/sim/event_bus.gd")
const SessionLoader = preload("res://scripts/data/session_loader.gd")
const SaveCodec = preload("res://scripts/data/save_codec.gd")
const GameConfig = preload("res://scripts/data/game_config.gd")
const Economy = preload("res://scripts/core/economy/economy.gd")
const Vec = preload("res://scripts/core/util/vec.gd")
const MachineFactory = preload("res://scripts/sim/machines/machine_factory.gd")
const MachineRegistry = preload("res://scripts/sim/machines/machine_registry.gd")
const ObstaclesScript = preload("res://scripts/sim/systems/static_obstacles.gd")
const HitchSystemScript = preload("res://scripts/sim/systems/hitch_system.gd")
const FieldWorkScript = preload("res://scripts/sim/systems/field_work_system.gd")
const GrainTransferScript = preload("res://scripts/sim/systems/grain_transfer_system.gd")
const FarmServicesScript = preload("res://scripts/sim/systems/farm_services.gd")
const RouteSystemScript = preload("res://scripts/sim/routes/route_system.gd")
const PlayerControlScript = preload("res://scripts/sim/player_control.gd")
const ShopServiceScript = preload("res://scripts/sim/systems/shop_service.gd")

const UNITS_PER_METER: float = 40.0
const DEFAULT_SAVE_PATH: String = "res://files/save.json"

var last_error: String = ""
## Ścieżki danych (do podmiany w testach).
var save_path: String = DEFAULT_SAVE_PATH
var config_directory: String = GameConfig.DEFAULT_DIRECTORY


## root – pusty węzeł "Simulation" (już w drzewie albo dodany później), saved_game – zapis gracza
## (pusty: nowa gra z szablonu save.json).
func build(root: Node2D, saved_game: Dictionary = {}) -> RefCounted:
	last_error = ""
	var context = GameContext.new()
	context.units = UNITS_PER_METER
	context.root = root
	context.events = EventBus.new()
	if not _load_session(context, saved_game):
		return null
	var bounds: Dictionary = context.map_data().get("world_bounds", {})
	if not Vec.is_pair(bounds.get("origin_m")) or not Vec.is_pair(bounds.get("size_m")):
		return _fail("Mapa nie zawiera poprawnego world_bounds.")
	context.world_rect_m = Rect2(Vec.v2(bounds["origin_m"]), Vec.v2(bounds["size_m"]))
	var config = GameConfig.new()
	if not config.load_from(config_directory):
		return _fail(config.last_error)
	context.config = config
	context.economy = Economy.new()
	context.economy.configure(context.save_data(), config.prices)
	context.economy.money_changed.connect(context.events.money_changed.emit)
	var obstacles = ObstaclesScript.new()
	root.add_child(obstacles)
	if not obstacles.configure(context.map_data(), context.units):
		return _fail(obstacles.last_error)
	if not _create_machines(context):
		return null
	if not _create_systems(context):
		return null
	return context


func _load_session(context: RefCounted, saved_game: Dictionary) -> bool:
	var loader = SessionLoader.new()
	var session: Dictionary = loader.load_session(save_path)
	if session.is_empty():
		_fail(loader.last_error)
		return false
	var codec = SaveCodec.new()
	var source: Dictionary = session["save_data"] if saved_game.is_empty() else saved_game
	session = codec.prepare_session(session, source)
	if session.is_empty():
		_fail(codec.last_error)
		return false
	context.session = session
	return true


func _create_machines(context: RefCounted) -> bool:
	var machines_root := Node2D.new()
	machines_root.name = "Machines"
	context.root.add_child(machines_root)
	context.factory = MachineFactory.new()
	context.factory.setup(context.models(), context.materials(), context.units)
	context.machines = MachineRegistry.new()
	context.machines.setup(machines_root, context.events)
	var instances: Dictionary = context.session["instances_by_id"]
	for instance_id in instances:
		var saved_state: Dictionary = instances[instance_id]
		# Maszyny wczytujemy w zapisanej pozie, ale zatrzymane.
		saved_state["motion"]["linear_velocity_m_per_s"] = [0.0, 0.0]
		saved_state["motion"]["angular_velocity_deg_per_s"] = 0.0
		saved_state["parking_brake_engaged"] = true
		var machine: Node2D = context.factory.create(saved_state)
		if machine == null:
			_fail(context.factory.last_error)
			return false
		context.machines.add(machine)
	var player = PlayerControlScript.new()
	context.root.add_child(player)
	context.player = player
	if not player.setup(context):
		_fail("Sterowana maszyna nie jest pojazdem fizycznym.")
		return false
	return true


func _create_systems(context: RefCounted) -> bool:
	var hitches = HitchSystemScript.new()
	hitches.setup(context)
	context.root.add_child(hitches)
	context.hitches = hitches
	if not hitches.restore_connections():
		_fail("Nie udało się odtworzyć połączeń. Szczegóły w Output.")
		return false
	var field_work = FieldWorkScript.new()
	context.root.add_child(field_work)
	context.field_work = field_work
	if not field_work.setup(context):
		_fail(field_work.last_error)
		return false
	var transfer = GrainTransferScript.new()
	context.root.add_child(transfer)
	context.transfer = transfer
	if not transfer.setup(context):
		_fail(transfer.last_error)
		return false
	var services = FarmServicesScript.new()
	context.root.add_child(services)
	context.services = services
	if not services.setup(context):
		_fail(services.last_error)
		return false
	var routes = RouteSystemScript.new()
	context.root.add_child(routes)
	context.routes = routes
	if not routes.setup(context):
		_fail(routes.last_error)
		return false
	context.player.connect_routes(routes)
	var shop = ShopServiceScript.new()
	context.root.add_child(shop)
	shop.setup(context)
	context.shop = shop
	# Komunikaty systemów → zdarzenia (PlayerControl filtruje te o zestawie gracza).
	# (Bez lambd przechwytujących kontekst – nie tworzą cykli referencji.)
	field_work.work_message.connect(context.player.on_vehicle_message)
	services.service_message.connect(context.events.machine_message.emit)
	routes.message.connect(context.events.notice.emit)
	return true


func _fail(message: String) -> RefCounted:
	if last_error.is_empty():
		last_error = message
	push_error(message)
	return null
