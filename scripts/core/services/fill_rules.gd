extends RefCounted
## Zasady napełniania maszyn przy punktach farmy (silos, magazyn) – czysta logika.

const StorageRules = preload("res://scripts/core/storage/storage_rules.gd")


## Czy materiał można wlać do zbiornika: {"enabled", "reason"}.
## material_name – nazwa materiału, który już jest w środku (do komunikatu).
static func option_state(storage: Dictionary, storage_def: Dictionary, material: String, inside_name: String) -> Dictionary:
	var amount: float = float(storage.get("amount_l", 0.0))
	if amount > 0.0 and str(storage.get("material_id", "")) != material:
		return {"enabled": false, "reason": "w środku jest " + inside_name.to_lower()}
	if StorageRules.space_for(storage, storage_def, material) <= 0.0:
		return {"enabled": false, "reason": "pełne"}
	return {"enabled": true, "reason": ""}


## Litry kupione w tym kroku: wydajność × czas, nie więcej niż miejsce i nie więcej niż na co
## starcza pieniędzy (z dokładnością do 1 ml).
static func purchase_amount(rate_l_per_s: float, delta: float, room_l: float, money: float, price: float) -> float:
	var moved: float = minf(rate_l_per_s * delta, room_l)
	if price > 0.0:
		moved = minf(moved, floorf(money / price * 1000.0) / 1000.0)
	return moved


## Napis przycisku zakupu w magazynie, np. „Kup nawóz”.
static func purchase_label(material: String) -> String:
	return "Kup nawóz" if material == "fertilizer" else "Kup ziarno"
