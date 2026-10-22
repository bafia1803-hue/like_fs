extends RefCounted
## Cennik: jedyne miejsce, które określa ceny w grze (czysta logika, dane podaje GameConfig).
## Inne systemy pytają tylko tę klasę, więc później można tu dodać np. wahania cen skupu,
## rabaty albo zużycie maszyn bez zmian w reszcie kodu.

const REQUIRED_SECTIONS: Array[String] = ["grain_sell_per_l", "supply_buy_per_l", "machines", "fields"]

var last_error: String = ""
var _data: Dictionary = {}


## Dane z prices.json. Zwraca false (i last_error), gdy brakuje sekcji.
func setup(data: Dictionary) -> bool:
	last_error = ""
	for key in REQUIRED_SECTIONS:
		if not data.get(key) is Dictionary:
			last_error = "Cennik nie zawiera sekcji: " + key
			return false
	_data = data
	return true


func currency() -> String:
	return str(_data.get("currency", "zł"))


func starting_money() -> float:
	return float(_data.get("starting_money", 0.0))


## Ile skup płaci za litr ziarna (0, gdy skup tego nie przyjmuje).
func grain_sell_price(material_id: String) -> float:
	return float(_data["grain_sell_per_l"].get(material_id, 0.0))


## Cena zakupu w magazynie przy wiacie (ziarno siewne, nawóz) za litr; −1 = nie sprzedaje.
func supply_buy_price(material_id: String) -> float:
	return float(_data["supply_buy_per_l"].get(material_id, -1.0))


func machine_price(model_id: String) -> float:
	return float(_data["machines"].get(model_id, -1.0))


## Ile dostaniesz za sprzedaż posiadanej maszyny.
func machine_resale_price(model_id: String) -> float:
	var price: float = machine_price(model_id)
	return 0.0 if price <= 0.0 else roundf(price * float(_data.get("machine_resale_ratio", 0.6)))


## Cena pola (-1, gdy pola nie da się kupić).
func field_price(field_id: String) -> float:
	return float(_data["fields"].get(field_id, -1.0))


## Modele dostępne w sklepie (w kolejności z cennika).
func shop_models() -> Array:
	return _data["machines"].keys()


## 150000 -> "150 000 zł"
func format(amount: float) -> String:
	return format_money(amount, currency())


static func format_money(amount: float, unit: String = "zł") -> String:
	var value: int = roundi(absf(amount))
	var digits: String = str(value)
	var grouped: String = ""
	while digits.length() > 3:
		grouped = " " + digits.right(3) + grouped
		digits = digits.left(digits.length() - 3)
	return ("-" if amount < -0.5 else "") + digits + grouped + " " + unit
