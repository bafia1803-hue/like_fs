shader_type spatial;
// Kępki zboża sterowane z GPU: faza każdej komórki pochodzi z tekstury stanu pola.
// Ta sama siatka kępki pokazuje młode, rosnące, dojrzałe zboże i ściernisko.
render_mode cull_disabled, specular_disabled;

// R = faza (0 gleba, 1 zasiane, 2 młode, 3 rosnące, 4 dojrzałe, 5 ściernisko), G = gatunek
uniform sampler2D stage_tex : filter_nearest;
uniform vec3 color_light : source_color = vec3(0.663, 0.851, 0.341);
uniform vec3 color_dark : source_color = vec3(0.157, 0.42, 0.208);
uniform vec3 color_ready : source_color = vec3(0.902, 0.702, 0.243);
uniform vec3 color_stubble : source_color = vec3(0.85, 0.7, 0.42);
uniform float height_light = 0.2;
uniform float height_dark = 0.6;
uniform float height_ready = 0.98;
uniform float height_stubble = 0.14;
uniform float ear_start = 0.68;
uniform float stem_to_ear_width = 0.42;
uniform float wind_strength = 0.06;

varying vec3 v_color;

void vertex() {
	ivec2 cell = ivec2(INSTANCE_CUSTOM.xy + vec2(0.5));
	vec2 state = texelFetch(stage_tex, cell, 0).rg * 255.0;
	int stage = int(state.r + 0.5);
	int crop = int(state.g + 0.5);
	float rnd = INSTANCE_CUSTOM.z;
	float part = UV2.x;       // 0 źdźbło, 1 kłos, 2 liść
	float along = UV2.y;      // 0..1 wzdłuż części

	float height = 0.0;
	bool ears = false;
	bool leaves = false;
	vec3 base = color_light;
	if (stage == 2) {
		height = height_light;
		leaves = true;
		base = color_light;
	} else if (stage == 3) {
		height = height_dark;
		leaves = true;
		base = mix(color_dark, color_light, 0.38) * vec3(1.04, 1.02, 0.9);
	} else if (stage == 4) {
		height = height_ready * (crop == 2 ? 0.88 : 1.0);
		ears = true;
		leaves = true;
		base = crop == 2 ? mix(color_ready, vec3(0.95, 0.87, 0.6), 0.35) : color_ready;
	} else if (stage == 5) {
		height = height_stubble;
		base = color_stubble;
	}
	height *= 0.82 + 0.3 * rnd;

	bool hidden = height <= 0.0 || (part > 1.5 && !leaves) || (stage == 5 && part > 0.5);
	if (hidden) {
		VERTEX = vec3(0.0);
	} else {
		vec2 stalk = UV;   // środek źdźbła w kępce
		if (part > 0.5 && part < 1.5 && !ears) {
			VERTEX.xz = stalk + (VERTEX.xz - stalk) * stem_to_ear_width;
		}
		float y = VERTEX.y;
		VERTEX.y = y * height;
		vec3 world = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
		float sway = sin(TIME * 1.7 + world.x * 0.31 + world.z * 0.23 + rnd * 2.0);
		float bend = y * y * wind_strength * (stage == 4 ? 1.0 : 0.6) * (stage == 5 ? 0.0 : 1.0);
		VERTEX.x += sway * bend;
		VERTEX.z += sway * bend * 0.6;

		vec3 color = base;
		if (part > 0.5 && part < 1.5) {
			color = stage == 4 ? base * vec3(1.04, 0.98, 0.86) : base;
		} else if (part > 1.5) {
			color = stage == 4 ? base * vec3(0.92, 0.86, 0.72) : base * 0.9;
		} else {
			color = stage == 4 ? base * vec3(0.93, 0.88, 0.78) : base;
		}
		float shade = mix(0.68, 1.06, clamp(y, 0.0, 1.0));
		v_color = color * shade * (0.92 + 0.16 * rnd);
		NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), 0.75));
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
