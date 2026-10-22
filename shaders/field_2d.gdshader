shader_type canvas_item;
// Pole w widoku 2D: kolor komórki wg fazy z tekstury stanu (R = faza).
uniform sampler2D stage_tex : filter_nearest;
uniform vec4 colors[6];

void fragment() {
	vec2 state = texture(stage_tex, UV).rg * 255.0;
	int stage = int(state.r + 0.5);
	COLOR = colors[clamp(stage, 0, 5)];
	if (stage == 4 && int(state.g + 0.5) == 2) {
		COLOR.rgb *= vec3(0.8, 0.74, 0.66);   // dojrzały jęczmień ciemniejszy
	} else if (stage == 4 && int(state.g + 0.5) == 3) {
		COLOR.rgb = min(COLOR.rgb * vec3(1.08, 1.16, 1.5), vec3(1.0));   // dojrzały owies jaśniejszy
	}
}
