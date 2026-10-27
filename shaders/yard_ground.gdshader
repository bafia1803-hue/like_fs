shader_type spatial;
// Plac farmy: utwardzony żwir/beton z delikatnymi plamami. Szum z gotowej tekstury (noise_texture.gd).
render_mode specular_disabled;

uniform vec3 base_color : source_color = vec3(0.8, 0.75, 0.65);
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float noise_cells = 16.0;

varying vec2 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 p = v_world;
	float large = texture(noise_tex, p * (0.08 / noise_cells)).r;
	float small = texture(noise_tex, p * (1.7 / noise_cells) + 0.31).r;
	// płyty betonowe 4 x 4 m
	vec2 tile = abs(fract(p / 4.0) - 0.5) * 2.0;
	float seam = smoothstep(0.96, 0.99, max(tile.x, tile.y));
	vec3 color = base_color * 0.8 * (0.92 + 0.1 * large + 0.05 * small);
	color *= 1.0 - seam * 0.12;
	ALBEDO = color;
	ROUGHNESS = 1.0;
}
