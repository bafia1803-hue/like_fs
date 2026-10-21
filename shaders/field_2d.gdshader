shader_type canvas_item;
// Pole w widoku 2D: kolor komórki wg fazy z tekstury stanu (R = faza).
uniform sampler2D stage_tex : filter_nearest;
uniform vec4 colors[6];

void fragment() {
	int stage = int(texture(stage_tex, UV).r * 255.0 + 0.5);
	COLOR = colors[clamp(stage, 0, 5)];
}
