shader_type spatial;
// Powierzchnia pola: kolor komórki zależy od jej fazy (gleba, siew, wzrost, dojrzałe, ściernisko).
render_mode specular_disabled;

uniform sampler2D stage_tex : filter_nearest;
uniform vec2 grid_size = vec2(400.0, 800.0);   // kolumny, wiersze
uniform float cell_m = 0.25;
uniform vec3 color_soil : source_color = vec3(0.475, 0.318, 0.216);
uniform vec3 color_sown : source_color = vec3(0.314, 0.2, 0.137);
uniform vec3 color_light : source_color = vec3(0.663, 0.851, 0.341);
uniform vec3 color_dark : source_color = vec3(0.157, 0.42, 0.208);
uniform vec3 color_ready : source_color = vec3(0.902, 0.702, 0.243);
uniform vec3 color_harvested : source_color = vec3(0.608, 0.475, 0.267);

varying vec2 v_local;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	v_local = VERTEX.xz;   // siatka zaczyna się w lewym górnym rogu pola
}

void fragment() {
	vec2 local = v_local;
	vec2 grid_m = grid_size * cell_m;
	ivec2 cell = ivec2(clamp(floor(local / cell_m), vec2(0.0), grid_size - 1.0));
	vec3 state = texelFetch(stage_tex, cell, 0).rgb * 255.0;
	float fert = clamp(state.b, 0.0, 2.0);   // poziom nawożenia 0–2
	int stage = int(state.r + 0.5);
	float n = hash(vec2(cell));

	// Bruzdy co 0,5 m wzdłuż długości pola
	float furrow = abs(fract(local.x / 0.5) - 0.5) * 2.0;
	float rows = 0.9 + 0.1 * smoothstep(0.2, 0.8, furrow);
	vec3 soil = color_soil * vec3(1.05, 1.02, 1.0);
	vec3 color = soil * rows;
	if (stage == 1) {
		float seed_rows = abs(fract(local.x / 0.25) - 0.5) * 2.0;
		color = color_sown * (0.86 + 0.14 * smoothstep(0.3, 0.9, seed_rows));
	} else if (stage == 2) {
		color = mix(color_sown, color_light, 0.18) * rows;
	} else if (stage == 3) {
		color = mix(color_sown, color_dark, 0.45) * rows;
	} else if (stage == 4) {
		color = mix(soil, color_ready, 0.55) * 0.9;
		if (int(state.g + 0.5) == 2) {
			color *= vec3(0.8, 0.74, 0.66);   // jęczmień: ciemniejszy niż pszenica
		} else if (int(state.g + 0.5) == 3) {
			color = min(color * vec3(1.08, 1.16, 1.5), vec3(1.0));   // owies: jaśniejszy
		}
	} else if (stage == 5) {
		float swath = abs(fract(local.x / 1.6) - 0.5) * 2.0;
		color = mix(color_harvested, vec3(0.93, 0.8, 0.52), 0.35 + 0.15 * smoothstep(0.5, 1.0, swath));
	}
	// Nawożenie: gleba (i młode rośliny) lekko ciemniejsze i bardziej nasycone.
	if (stage != 4) {
		color = mix(color, color * vec3(0.84, 0.86, 0.8), fert * 0.5);
	}
	color *= 0.95 + 0.08 * n;
	// Ciemniejsza krawędź pola
	float edge = min(min(local.x, local.y), min(grid_m.x - local.x, grid_m.y - local.y));
	color *= mix(0.78, 1.0, smoothstep(0.0, 0.6, edge));
	ALBEDO = color;
	ROUGHNESS = 1.0;
}
