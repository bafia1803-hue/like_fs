shader_type spatial;
// Kępki trawy i kwiatków na łące (MultiMesh, kolor z instancji).
render_mode cull_disabled, specular_disabled;

uniform float wind_strength = 0.05;

varying vec3 v_color;

void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float y = VERTEX.y;
	float sway = sin(TIME * 1.9 + world.x * 0.4 + world.z * 0.3);
	VERTEX.x += sway * y * y * wind_strength * 4.0;
	v_color = COLOR.rgb * mix(0.72, 1.08, clamp(y * 3.0, 0.0, 1.0));
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), 0.8));
}

void fragment() {
	// Obie strony karty używają tej samej, skierowanej w górę normalnej.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = v_color;
	ROUGHNESS = 1.0;
}
