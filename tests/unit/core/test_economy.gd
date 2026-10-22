extends "res://tests/framework/test_case.gd"

const PriceList = preload("res://scripts/core/economy/price_list.gd")
const Economy = preload("res://scripts/core/economy/economy.gd")

const DATA := {"currency": "zł", "starting_money": 1000, "machine_resale_ratio": 0.5,
	"grain_sell_per_l": {"wheat_grain": 0.75}, "supply_buy_per_l": {"seed": 2.0},
	"machines": {"tractor_basic": 140000, "trailer_basic": 38003}, "fields": {"field_01": 90000}}


func _prices():
	var prices = PriceList.new()
	assert_true(prices.setup(DATA))
	return prices


func test_price_list_requires_sections() -> void:
	var prices = PriceList.new()
	assert_false(prices.setup({"grain_sell_per_l": {}}))
	assert_has(prices.last_error, "supply_buy_per_l")


func test_prices() -> void:
	var prices = _prices()
	assert_eq(prices.grain_sell_price("wheat_grain"), 0.75)
	assert_eq(prices.grain_sell_price("oats_grain"), 0.0)
	assert_eq(prices.supply_buy_price("fertilizer"), -1.0)
	assert_eq(prices.machine_resale_price("trailer_basic"), 19002.0, "zaokrąglenie 19001,5")
	assert_eq(prices.machine_resale_price("unknown"), 0.0)
	assert_eq(prices.field_price("field_02"), -1.0)
	assert_eq(prices.shop_models(), ["tractor_basic", "trailer_basic"])


func test_format_money() -> void:
	assert_eq(PriceList.format_money(150000.0), "150 000 zł")
	assert_eq(PriceList.format_money(999.4), "999 zł")
	assert_eq(PriceList.format_money(-1234567.0), "-1 234 567 zł")
	assert_eq(PriceList.format_money(0.0, "€"), "0 €")


func test_wallet_creates_state_and_spends() -> void:
	var save := {}
	var economy = Economy.new()
	economy.configure(save, _prices())
	assert_eq(save["economy"]["money"], 1000.0, "pieniądze startowe w zapisie")
	var changes: Array = []
	economy.money_changed.connect(func(money: float, change: float, reason: String): changes.append([money, change, reason]))
	assert_false(economy.spend(1500.0), "za mało")
	assert_true(economy.spend(400.0, "Zakup"))
	economy.earn(50.0, "Skup")
	economy.earn(-5.0)
	assert_eq(economy.get_money(), 650.0)
	assert_eq(changes, [[600.0, -400.0, "Zakup"], [650.0, 50.0, "Skup"]])
	assert_true(economy.can_afford(650.0))


func test_wallet_keeps_saved_money() -> void:
	var save := {"economy": {"money": 12}}
	var economy = Economy.new()
	economy.configure(save, _prices())
	assert_eq(economy.get_money(), 12.0)
	assert_eq(economy.format(12.0), "12 zł")
