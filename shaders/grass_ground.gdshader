shader_type spatial;
// Łąka: łagodne plamy kolorów, bez tekstur. Wewnątrz pól nic nie rysuje (tam jest gleba).
render_mode specular_disabled;

uniform vec3 color_a : source_color = vec3(0.42, 0.66, 0.27);
uniform vec3 color_b : source_color = vec3(0.5, 0.71, 0.3);
uniform vec3 color_c : source_color = vec3(0.35, 0.58, 0.25);
uniform vec4 holes[8];
uniform int hole_count = 0;

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
	for (int i = 0; i < hole_count; i++) {
		vec4 h = holes[i];
		if (p.x > h.x && p.x < h.z && p.y > h.y && p.y < h.w) {
			discard;
		}
	}
	float large = noise(p * 0.018);
	float medium = noise(p * 0.07 + 13.0);
	float small = noise(p * 0.6 + 71.0);
	vec3 color = mix(color_a, color_b, smoothstep(0.35, 0.75, large));
	color = mix(color, color_c, smoothstep(0.55, 0.85, medium) * 0.55);
	color *= 0.95 + 0.07 * small;
	ALBEDO = color;
	ROUGHNESS = 1.0;
}
