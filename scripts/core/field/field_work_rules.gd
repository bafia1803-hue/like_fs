extends RefCounted
## Zasady pracy narzędzi na polu – czysta logika (bez węzłów).
## FieldWorkSystem liczy geometrię (które komórki) i woła te funkcje dla każdej komórki.
##
## Wynik sprawdzenia: {"ok": bool, "message": String} (+ ilości), message = komunikat dla gracza
## (pusty, gdy komórkę po prostu się pomija).

const FieldCells = preload("res://scripts/core/field/field_cells.gd")
const Stage = FieldCells.Stage


## Czy narzędzie pracuje (opuszczone i włączone) – work_state ze stanu maszyny.
static func is_working(state: Dictionary) -> bool:
	var work_state: Variant = state.get("work_state")
	return work_state is Dictionary and bool(work_state.get("enabled", false)) and bool(work_state.get("lowered", false))


## Limit prędkości pojazdu od pracującego narzędzia (INF = brak limitu).
static func speed_cap_kmh(model: Dictionary, working: bool) -> float:
	if not working:
		return INF
	var work: Variant = model.get("work")
	if work is Dictionary and work.has("max_working_speed_kmh"):
		return float(work["max_working_speed_kmh"])
	return INF


## Czy przy tej prędkości [m/s] narzędzie pracuje. Siewnik działa też na wstecznym.
static func work_allowed(operation: String, speed: float, minimum: float) -> bool:
	var limit: float = maxf(0.001, minimum)
	return absf(speed) >= limit if operation == "sow" else speed >= limit


## Komunikat po przełączeniu pracy klawiszem B.
static func toggle_message(model: Dictionary, active: bool) -> String:
	var work: Dictionary = model["work"]
	var limit: String = ""
	if active and work.has("max_working_speed_kmh"):
		limit = " (max %d km/h)" % roundi(float(work["max_working_speed_kmh"]))
	match str(work["operation"]):
		"harvest":
			return ("Heder opuszczony — koszenie" + limit) if active else "Heder podniesiony"
		"cultivate":
			return ("Kultywator opuszczony" + limit) if active else "Kultywator podniesiony"
		"sow":
			return ("Siewnik włączony" + limit) if active else "Siewnik wyłączony"
	return (str(model["name"]) + ": praca" + limit) if active else (str(model["name"]) + ": stop")


## Gatunek, który sieje siewnik (stan "seed_crop_id"; domyślnie pierwszy z sowable_crop_ids).
static func seed_crop(model: Dictionary, state: Dictionary) -> String:
	var work: Dictionary = model.get("work", {}) if model.get("work") is Dictionary else {}
	var crops: Array = work.get("sowable_crop_ids", [])
	if crops.is_empty():
		return ""
	var chosen: String = str(state.get("seed_crop_id", ""))
	return chosen if crops.has(chosen) else str(crops[0])


## Następny gatunek z listy (pszenica → jęczmień → owies → …). Pusty, gdy maszyna nie sieje.
static func next_seed_crop(model: Dictionary, state: Dictionary) -> String:
	var work: Dictionary = model.get("work", {}) if model.get("work") is Dictionary else {}
	var crops: Array = work.get("sowable_crop_ids", [])
	if crops.is_empty():
		return ""
	return str(crops[(crops.find(seed_crop(model, state)) + 1) % crops.size()])


## Czy operacja może coś zrobić z komórką (albo ma o niej coś powiedzieć) – szybkie sito przed
## pełnymi zasadami. fertilized_bits – bity nawożenia komórki (FieldCells.fertilized).
static func cell_needs_work(operation: String, stage: int, fertilized_bits: int) -> bool:
	match operation:
		"cultivate":
			return stage != Stage.PLAIN
		"sow":
			return stage == Stage.PLAIN or stage == Stage.READY or stage == Stage.HARVESTED
		"fertilize":
			var bit: int = FieldCells.fertilize_bit(stage)
			return bit != 0 and (fertilized_bits & bit) == 0
		"harvest":
			return stage == Stage.READY
	return true


## Siew jednej komórki. cost_l – zużycie ziarna na komórkę.
static func sow_check(stage: int, storage: Dictionary, crop: String, cost_l: float) -> Dictionary:
	if stage == Stage.READY:
		return {"ok": false, "message": "Najpierw zbierz albo skultywuj dojrzałe zboże."}
	if stage == Stage.HARVESTED:
		return {"ok": false, "message": "Przed siewem skultywuj ściernisko."}
	if stage != Stage.PLAIN:
		return {"ok": false, "message": ""}
	if crop.is_empty() or float(storage.get("amount_l", 0.0)) + 0.000001 < cost_l:
		return {"ok": false, "message": "Siewnik nie ma ziarna — kup je na stacji nasion."}
	return {"ok": true, "message": ""}


## Nawożenie jednej komórki: czy w zbiorniku jest dawka.
static func fertilize_check(storage: Dictionary, dose_l: float) -> Dictionary:
	if float(storage.get("amount_l", 0.0)) + 0.000001 < dose_l:
		return {"ok": false, "message": "Rozsiewacz jest pusty — kup nawóz w magazynie przy wiacie."}
	return {"ok": true, "message": ""}


## Zużycie materiału ze zbiornika (zbiornik pusty = bez materiału, gdy clear_material).
static func consume(storage: Dictionary, amount_l: float, clear_material: bool) -> void:
	storage["amount_l"] = maxf(0.0, float(storage["amount_l"]) - amount_l)
	if clear_material and float(storage["amount_l"]) <= 0.000001:
		storage["material_id"] = null


## Plon komórki [l]: plon z farming.json × powierzchnia × premia nawożenia.
static func harvest_yield(settings: Dictionary, crop: String, fertilizer_level: int, area_m2: float) -> float:
	var amount: float = float(settings["yield_l_per_m2"].get(crop, 0.0)) * area_m2
	var bonus: Array = settings.get("fertilizer_yield_bonus", [0.0, 0.0, 0.0])
	return amount * (1.0 + float(bonus[clampi(fertilizer_level, 0, bonus.size() - 1)]))


## Zbiór jednej komórki: {"ok", "message", "material", "amount"}.
## storage/storage_def – zbiornik pojazdu (kombajnu) z definicją; amount – plon komórki.
static func harvest_check(stage: int, crop: String, work: Dictionary, storage: Dictionary,
		storage_def: Dictionary, settings: Dictionary, fertilizer_level: int, area_m2: float) -> Dictionary:
	if stage != Stage.READY:
		return {"ok": false, "message": ""}
	if not work["allowed_crop_ids"].has(crop):
		return {"ok": false, "message": "Ten heder nie zbiera tej rośliny."}
	var material: String = str(work["crop_to_material_id"].get(crop, ""))
	if storage.is_empty() or storage_def.is_empty():
		return {"ok": false, "message": "Pojazd nie ma zbiornika na ziarno."}
	if not storage_def["accepted_material_ids"].has(material):
		return {"ok": false, "message": ""}
	if float(storage["amount_l"]) > 0.000001 and str(storage["material_id"]) != material:
		return {"ok": false, "message": "Opróżnij zbiornik przed zmianą rodzaju ziarna."}
	var amount: float = harvest_yield(settings, crop, fertilizer_level, area_m2)
	if amount <= 0.0:
		return {"ok": false, "message": "Brak przelicznika plonu dla: " + crop}
	if float(storage["amount_l"]) + amount > float(storage_def["capacity_l"]) + 0.000001:
		return {"ok": false, "message": "Zbiornik kombajnu pełny — zbiór wstrzymany."}
	return {"ok": true, "message": "", "material": material, "amount": amount}


## Dodanie plonu do zbiornika (po udanym harvest_check).
static func store_harvest(storage: Dictionary, storage_def: Dictionary, material: String, amount: float) -> void:
	storage["amount_l"] = minf(float(storage_def["capacity_l"]), float(storage["amount_l"]) + amount)
	storage["material_id"] = material
