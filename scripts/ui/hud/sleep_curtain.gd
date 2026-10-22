extends CanvasLayer
## Zasłona snu: czarny prostokąt nad całym interfejsem, łapie mysz. Działa także w pauzie.

var curtain: ColorRect


func _init() -> void:
	name = "SleepCurtain"
	layer = 100                       # nad całym interfejsem
	process_mode = Node.PROCESS_MODE_ALWAYS
	curtain = ColorRect.new()
	curtain.color = Color(0.0, 0.0, 0.0, 0.0)
	curtain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	curtain.mouse_filter = Control.MOUSE_FILTER_STOP
	curtain.process_mode = Node.PROCESS_MODE_ALWAYS
	curtain.visible = false
	add_child(curtain)
