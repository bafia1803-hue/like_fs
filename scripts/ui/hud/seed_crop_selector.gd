extends HBoxContainer
## Prawy dolny róg: gatunek wysiewany przez podpięty siewnik (przycisk z kłosem + podpis).
## Klik: następny gatunek (pszenica → jęczmień → owies → …).

const IconButtonScript = preload("res://scripts/ui/icon_button.gd")
const SEED_CROPS := {
	"wheat": {"name": "Pszenica", "color": Color("#f2c55c")},
	"barley": {"name": "Jęczmień", "color": Color("#c9a46a")},
	"oats": {"name": "Owies", "color": Color("#fff0bd")},
}

var _query: RefCounted
var _actions: RefCounted
var _button: Button
var _label: Label


func setup(query: RefCounted, actions: RefCounted) -> void:
	_query = query
	_actions = actions
	name = "SeedCropBox"
	add_theme_constant_override("separation", 10)
	alignment = BoxContainer.ALIGNMENT_END
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	offset_left = -260
	offset_top = -72
	offset_right = -16
	offset_bottom = -16
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	visible = false
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color("#fffaf0"))
	_label.add_theme_color_override("font_outline_color", Color(0.12, 0.09, 0.06, 0.85))
	_label.add_theme_constant_override("outline_size", 6)
	_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	add_child(_label)
	_button = IconButtonScript.new("grain", "Siany gatunek – kliknij, aby zmienić")
	_button.pressed.connect(_on_pressed)
	add_child(_button)


func refresh() -> void:
	var seeder: Node2D = _query.controlled_seeder()
	visible = seeder != null
	if seeder == null:
		return
	var crop: String = _query.seed_crop(seeder)
	var info: Dictionary = SEED_CROPS.get(crop, {"name": crop, "color": Color.WHITE})
	_label.text = str(info["name"])
	_button.call("set_icon", "grain", info["color"])


func _on_pressed() -> void:
	_actions.cycle_seed_crop()
	refresh()
