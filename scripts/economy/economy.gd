extends Node
## Pieniądze gracza (warstwa gry). Stan siedzi w save_data["economy"], więc zapis gry
## przenosi go bez dodatkowego kodu. Każda zmiana przechodzi przez earn/spend.

signal money_changed(money: float, change: float, reason: String)

const PriceListScript = preload("res://scripts/economy/price_list.gd")

var prices = PriceListScript.new()
var last_error: String = ""
var _state: Dictionary = {}


func configure(save_data: Dictionary) -> bool:
	name = "Economy"
	if not prices.load_prices():
		last_error = prices.last_error
		return false
	if not save_data.get("economy") is Dictionary:
		save_data["economy"] = {"money": prices.starting_money()}
	_state = save_data["economy"]
	if not (_state.get("money") is float or _state.get("money") is int):
		_state["money"] = prices.starting_money()
	return true


func get_money() -> float:
	return float(_state["money"])


func can_afford(amount: float) -> bool:
	return get_money() + 0.0001 >= amount


func earn(amount: float, reason: String = "") -> void:
	if amount <= 0.0:
		return
	_state["money"] = get_money() + amount
	money_changed.emit(get_money(), amount, reason)


## Pobiera pieniądze. Zwraca false (i nic nie zmienia), gdy brakuje środków.
func spend(amount: float, reason: String = "") -> bool:
	if amount <= 0.0:
		return true
	if not can_afford(amount):
		return false
	_state["money"] = get_money() - amount
	money_changed.emit(get_money(), -amount, reason)
	return true


func format(amount: float) -> String:
	return prices.format(amount)
