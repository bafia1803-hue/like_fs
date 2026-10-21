shader_type spatial;
// Kępki trawy i kwiatków na łące (MultiMesh, kolor z instancji). Statyczne, bez wiatru.
render_mode cull_disabled, specular_disabled;

varying vec3 v_color;

void vertex() {
	float y = VERTEX.y;
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
