extends Node3D
## Świat gry – korzeń kompozycji sceny gry. Składa trzy oddzielne warstwy i nic poza tym:
##
## 1. Symulacja ("Simulation", Node2D): SimulationBuilder → GameContext (fizyka Rapier2D, maszyny,
##    zaczepy, praca na polu, przeładunek, usługi farmy, trasy). Nic nie rysuje.
## 2. Widoki 2D/3D (ViewSwitcher): czytają stan przez WorldQuery, przełączane klawiszem V.
## 3. Interfejs (Hud): czyta WorldQuery, zmienia grę przez GameActions, komunikaty z EventBus.
## Klawisze obsługuje InputRouter, sen – SleepSequence, jakość grafiki (G) – GraphicsSettings. Zapis slotu i menu należą do GameApp.

signal world_ready
signal world_failed(message: String)
signal save_requested
signal menu_requested
signal quit_requested

const SimulationBuilder = preload("res://scripts/sim/simulation_builder.gd")
const WorldQuery = preload("res://scripts/sim/world_query.gd")
const GameActions = preload("res://scripts/sim/game_actions.gd")
const SaveCodec = preload("res://scripts/data/save_codec.gd")
const HudScript = preload("res://scripts/ui/hud/hud.gd")
const ViewSwitcherScript = preload("res://scripts/app/view_switcher.gd")
const InputRouterScript = preload("res://scripts/app/input_router.gd")
const SleepSequenceScript = preload("res://scripts/app/sleep_sequence.gd")
const GraphicsScript = preload("res://scripts/app/graphics_settings.gd")
const FrameProbeScript = preload("res://scripts/app/frame_probe.gd")
const GpuCostScript = preload("res://scripts/app/gpu_cost_probe.gd")

@export_file("*.json") var initial_save_path: String = "res://files/save.json"

var saved_game: Dictionary = {}
var save_slot: int = 0
var managed_by_menu: bool = false

## Po udanym starcie: kontener zależności, odczyt i polecenia (także dla testów).
var context: RefCounted
var query: RefCounted
var actions: RefCounted
var hud: Node
var views: Node
var input: Node
var sleep_sequence: Node
var graphics: Node
var loaded: bool = false


func _ready() -> void:
	var simulation := Node2D.new()
	simulation.name = "Simulation"
	add_child(simulation)
	hud = HudScript.new()
	add_child(hud)
	var physics_engine: String = str(ProjectSettings.get_setting("physics/2d/physics_engine", "DEFAULT"))
	print("Wybrany silnik fizyki 2D: ", physics_engine)
	if not physics_engine.to_lower().contains("rapier"):
		_fail("Ten etap wymaga Rapier2D. Wybierz go w Project Settings → Physics → 2D → Physics Engine i uruchom ponownie edytor.")
		return
	var builder = SimulationBuilder.new()
	builder.save_path = initial_save_path
	context = builder.build(simulation, saved_game)
	if context == null:
		_fail(builder.last_error)
		return
	query = WorldQuery.new(context)
	actions = GameActions.new(context)
	views = ViewSwitcherScript.new()
	add_child(views)
	views.setup(self, query)
	hud.setup(query, actions, managed_by_menu)
	var probe = FrameProbeScript.new()
	add_child(probe)
	hud.perf_report.probe = probe
	graphics = GraphicsScript.new()
	add_child(graphics)
	graphics.changed.connect(hud.set_graphics_quality)
	graphics.setup(views)
	hud.save_requested.connect(save_requested.emit)
	hud.menu_requested.connect(menu_requested.emit)
	sleep_sequence = SleepSequenceScript.new()
	sleep_sequence.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(sleep_sequence)
	sleep_sequence.setup(hud.sleep_curtain.curtain, actions)
	sleep_sequence.finished.connect(hud.notify)
	hud.sleep_requested.connect(sleep_sequence.start)
	input = InputRouterScript.new()
	add_child(input)
	var gpu_test = GpuCostScript.new()
	add_child(gpu_test)
	gpu_test.setup(views)
	gpu_test.progress.connect(hud.perf_report.show_gpu_test_progress)
	gpu_test.finished.connect(hud.perf_report.show_gpu_test)
	input.setup(self, actions, views, hud, sleep_sequence, graphics, gpu_test)
	loaded = true
	print("Wczytano maszyn: ", context.machines.by_id.size())
	world_ready.emit()


func _fail(message: String) -> void:
	hud.show_error(message)
	push_error(message)
	world_failed.emit(message)


## Migawka gry do zapisu slotu (przerywa nagrywanie i odtwarzanie tras).
func capture_save() -> Dictionary:
	if not loaded:
		return {}
	context.routes.before_save()
	return SaveCodec.new().capture(context.session, context.machines.by_id, context.field_work, context.units)


func show_save_message(text: String) -> void:
	hud.notify(text)
