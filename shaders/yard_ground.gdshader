shader_type spatial;
// Plac farmy: utwardzony żwir/beton z delikatnymi plamami.
render_mode specular_disabled;

uniform vec3 base_color : source_color = vec3(0.8, 0.75, 0.65);

varying vec3 v_world;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = v_world.xz;
	float large = noise(p * 0.08);
	float small = noise(p * 1.7 + 31.0);
	// płyty betonowe 4 x 4 m
	vec2 tile = abs(fract(p / 4.0) - 0.5) * 2.0;
	float seam = smoothstep(0.96, 0.99, max(tile.x, tile.y));
	vec3 color = base_color * 0.8 * (0.92 + 0.1 * large + 0.05 * small);
	color *= 1.0 - seam * 0.12;
	ALBEDO = color;
	ROUGHNESS = 1.0;
}
