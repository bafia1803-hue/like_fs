shader_type spatial;
// Rdzeń strumienia ziarna: pasy jaśniejszego i ciemniejszego ziarna przesuwają się w dół.
render_mode specular_disabled, cull_disabled;

uniform vec3 color_light : source_color = vec3(0.96, 0.8, 0.4);
uniform vec3 color_dark : source_color = vec3(0.84, 0.64, 0.27);
uniform float speed = 3.0;
uniform float length_m = 3.0;

void fragment() {
	// UV.y biegnie wzdłuż walca (0 u góry).
	float y = UV.y * length_m;
	float bands = fract(y * 1.6 - TIME * speed + UV.x * 2.0);
	float flicker = step(0.55, bands);
	ALBEDO = mix(color_dark, color_light, flicker);
	ROUGHNESS = 1.0;
}
