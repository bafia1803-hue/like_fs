shader_type spatial;
// Kępki trawy i kwiatków na łące (MultiMesh, kolor z instancji). Statyczne, bez wiatru.
// Wokół punktu skupienia (pojazd gracza / miejsce, na które patrzy kamera) trawa jest pełna,
// a w paśmie fade_m przed visible_end kępki po kolei (każda przy swojej odległości, wg r z kanału
// alfa koloru) wsiąkają w ziemię – bez widocznej granicy kawałków. CPU (terrain_3d.gd) wysyła do
// karty tylko kępki, które mogą być widoczne (posortowane wg r). Dalsze kępki są szersze, żeby
// źdźbła nie były cieńsze niż piksel.
render_mode cull_disabled, specular_disabled;

uniform vec3 focus = vec3(0.0);
uniform float visible_end = 75.0;
uniform float fade_m = 20.0;
uniform float wide_from_m = 16.0;
uniform float max_widen = 2.5;

varying vec3 v_color;

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = distance(origin.xz, focus.xz);
	float keep = 1.0 - smoothstep(visible_end - fade_m, visible_end, d);
	float rnd = COLOR.a;
	float grow = smoothstep(rnd * 0.92, rnd * 0.92 + 0.08, keep);
	float widen = clamp(d / wide_from_m, 1.0, max_widen);
	float y = VERTEX.y;
	v_color = COLOR.rgb * mix(0.72, 1.08, clamp(y * 3.0, 0.0, 1.0));
	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), 0.8));
	if (grow <= 0.002) {
		VERTEX = vec3(0.0);
	} else {
		VERTEX.y *= grow;
		VERTEX.xz *= widen;
	}
}

void fragment() {
	// Obie strony karty używają tej samej, skierowanej w górę normalnej.
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	ALBEDO = v_color;
	ROUGHNESS = 1.0;
}
