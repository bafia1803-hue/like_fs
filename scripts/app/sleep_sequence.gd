extends Node
## Sen: ekran ciemnieje do czerni, w pełnej ciemności rośliny przechodzą do kolejnej fazy,
## potem ekran się rozjaśnia. Razem SLEEP_*_SECONDS (ok. 4 s).
##
## Blokada sterowania: na czas snu pauzujemy całe drzewo gry (get_tree().paused).
## Wszystkie skrypty świata są PAUSABLE, więc same przestają dostawać klawisze, kliknięcia
## i kroki fizyki. Działa tylko to, co ma PROCESS_MODE_ALWAYS: zasłona z animacją oraz
## odświeżanie stanu pól (żeby po rozjaśnieniu były już widoczne nowe rośliny).

signal finished(message: String)

const DARKEN_SECONDS: float = 1.6
const HOLD_SECONDS: float = 0.5
const BRIGHTEN_SECONDS: float = 1.9

var sleeping: bool = false
var _curtain: ColorRect
var _actions: RefCounted
var _message: String = ""


func setup(curtain: ColorRect, actions: RefCounted) -> void:
	name = "SleepSequence"
	_curtain = curtain
	_actions = actions


func start() -> void:
	if sleeping or _curtain == null:
		return
	sleeping = true
	get_tree().paused = true
	_curtain.color.a = 0.0
	_curtain.visible = true
	var tween: Tween = _curtain.create_tween()
	# Zapadanie zmroku: szybko na początku, wolniej pod koniec.
	tween.tween_property(_curtain, "color:a", 1.0, DARKEN_SECONDS).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_callback(_pass_night)
	tween.tween_interval(HOLD_SECONDS)
	# Świt: wolno na początku, szybciej pod koniec.
	tween.tween_property(_curtain, "color:a", 0.0, BRIGHTEN_SECONDS).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.tween_callback(_wake_up)


func _pass_night() -> void:
	var grown: int = _actions.grow_crops()
	_message = "Noc minęła — rośliny urosły." if grown > 0 else "Noc minęła — na polu nic nie rośnie."


func _wake_up() -> void:
	_curtain.visible = false
	get_tree().paused = false
	sleeping = false
	finished.emit(_message)
