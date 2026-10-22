shader_type spatial;
// Kępki zboża sterowane z GPU: faza każdej komórki pochodzi z tekstury stanu pola.
// Ta sama siatka kępki (4 wykałaczki) pokazuje młode, rosnące, dojrzałe zboże i ściernisko.
// Statyczne: bez wiatru i bez animacji, żeby karta graficzna liczyła jak najmniej.
render_mode cull_back, specular_disabled;

// R = faza (0 gleba, 1 zasiane, 2 młode, 3 rosnące, 4 dojrzałe, 5 ściernisko), G = gatunek
uniform sampler2D stage_tex : filter_nearest;
uniform vec3 color_light : source_color = vec3(0.663, 0.851, 0.341);
uniform vec3 color_dark : source_color = vec3(0.157, 0.42, 0.208);
uniform vec3 color_ready : source_color = vec3(0.902, 0.702, 0.243);
uniform vec3 color_stubble : source_color = vec3(0.85, 0.7, 0.42);
uniform float height_light = 0.22;
uniform float height_dark = 0.55;
uniform float height_ready = 0.95;
uniform float height_stubble = 0.13;
// Dojrzałe zboże: pierścień kłosa poszerzony (wrzecionowaty kłos).
uniform float ear_width = 1.9;
uniform vec3 barley_ready_tint = vec3(0.8, 0.74, 0.66);
// Dojrzały owies: jaśniejszy, bardziej słomkowy niż pszenica.
uniform vec3 oats_ready_tint = vec3(1.08, 1.16, 1.5);

varying vec3 v_color;

void vertex() {
	ivec2 cell = ivec2(INSTANCE_CUSTOM.xy + vec2(0.5));
	vec3 state = texelFetch(stage_tex, cell, 0).rgb * 255.0;
	float fert = clamp(state.b, 0.0, 2.0);
	int stage = int(state.r + 0.5);
	int crop = int(state.g + 0.5);
	float rnd = INSTANCE_CUSTOM.z;
	float part = UV2.x;       // 0 podstawa, 1 pierścień kłosa, 2 czubek

	float height = 0.0;
	vec3 base = color_light;
	if (stage == 2) {
		height = height_light;
	} else if (stage == 3) {
		height = height_dark;
		base = mix(color_dark, color_light, 0.35);
	} else if (stage == 4) {
		height = height_ready;
		// Dojrzały jęczmień jest trochę ciemniejszy od pszenicy; inne fazy są identyczne.
		base = crop == 2 ? color_ready * barley_ready_tint : (crop == 3 ? min(color_ready * oats_ready_tint, vec3(1.0)) : color_ready);
	} else if (stage == 5) {
		height = height_stubble;
		base = color_stubble;
	}
	// Nawiezione rośliny w trakcie wzrostu: soczystsza zieleń (subtelnie).
	if (stage >= 1 && stage <= 3) {
		base = mix(base, base * vec3(0.85, 1.0, 0.85), fert * 0.5);
	}

	if (height <= 0.0) {
		VERTEX = vec3(0.0);
		v_color = vec3(0.0);
	} else {
		height *= 0.85 + 0.3 * rnd;
		vec2 root = COLOR.rg - 0.5;          // środek podstawy wykałaczki
		vec2 ring = UV;                      // środek wykałaczki na tej wysokości
		float widen = (stage == 4 && part > 0.5 && part < 1.5) ? ear_width : 1.0;
		// Pochylenie skaluje się z wysokością, żeby niskie rośliny nie leżały.
		vec2 center = root + (ring - root) * height;
		VERTEX.xz = center + (VERTEX.xz - ring) * widen;
		float y = VERTEX.y;
		VERTEX.y = y * height;
		vec3 color = base;
		if (stage == 4 && part > 0.5) {
			color = base * vec3(1.06, 1.0, 0.86);
		}
		v_color = color * mix(0.7, 1.05, clamp(y, 0.0, 1.0)) * (0.93 + 0.14 * rnd);
	}
}

void fragment() {
	ALBEDO = v_color;
	ROUGHNESS = 1.0;
}
