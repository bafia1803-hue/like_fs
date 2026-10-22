extends RefCounted
## Cennik: jedyne miejsce, które określa ceny w grze (warstwa gry, bez UI).
## Dane z files/prices.json. Inne systemy pytają tylko tę klasę, więc później można tu dodać
## np. wahania cen skupu w czasie, rabaty albo zużycie maszyn bez zmian w reszcie kodu.

const PATH: String = "res://files/prices.json"

var last_error: String = ""
var _data: Dictionary = {}


func load_prices(path: String = PATH) -> bool:
	var parser := JSON.new()
	if not FileAccess.file_exists(path) or parser.parse(FileAccess.get_file_as_string(path)) != OK or not parser.data is Dictionary:
		last_error = "Brak lub błędny cennik: " + path
		return false
	_data = parser.data
	for key in ["grain_sell_per_l", "supply_buy_per_l", "machines", "fields"]:
		if not _data.get(key) is Dictionary:
			last_error = "Cennik nie zawiera sekcji: " + key
			return false
	return true


func currency() -> String:
	return str(_data.get("currency", "zł"))


func starting_money() -> float:
	return float(_data.get("starting_money", 0.0))


## Ile skup płaci za litr ziarna (0, gdy skup tego nie przyjmuje).
func grain_sell_price(material_id: String) -> float:
	return float(_data["grain_sell_per_l"].get(material_id, 0.0))


## Cena litra materiału siewnego na stacji nasion (-1, gdy niedostępny).
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
