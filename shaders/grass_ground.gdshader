shader_type spatial;
// Łąka: łagodne plamy kolorów. Szum z gotowej tekstury (noise_texture.gd) zamiast liczenia
// w każdym pikselu – łąka zajmuje dużą część ekranu, więc jej shader musi być bardzo tani.
// Bez `discard`: pola i plac leżą trochę wyżej i po prostu zasłaniają łąkę (test głębi).
// Shader z `discard` wyłącza na karcie wczesny test głębi i jest droższy w każdym pikselu.
render_mode specular_disabled;

uniform vec3 color_a : source_color = vec3(0.42, 0.66, 0.27);
uniform vec3 color_b : source_color = vec3(0.5, 0.71, 0.3);
uniform vec3 color_c : source_color = vec3(0.35, 0.58, 0.25);
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float noise_cells = 16.0;

varying vec2 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 p = v_world / noise_cells;
	float large = texture(noise_tex, p * 0.018).r;
	float medium = texture(noise_tex, p * 0.07 + 0.37).r;
	float small = texture(noise_tex, p * 0.6 + 0.71).r;
	vec3 color = mix(color_a, color_b, smoothstep(0.35, 0.75, large));
	color = mix(color, color_c, smoothstep(0.55, 0.85, medium) * 0.55);
	color *= 0.95 + 0.07 * small;
	ALBEDO = color;
	ROUGHNESS = 1.0;
}
