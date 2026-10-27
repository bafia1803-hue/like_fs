shader_type spatial;
// Łan: zwarta, niska pokrywa zboża – siatka co 0,5 m, którą shader podnosi do wysokości roślin
// odczytanej z tekstury stanu pola (ta sama co dla kępek i gleby). Zastępuje tysiące dalekich
// kępek kilkoma tysiącami dużych trójkątów: z daleka pole wygląda jak gęsty łan z wysokością
// (krawędzie pola i pasy po kombajnie mają ściany), a karta nie rasteryzuje trójkątów mniejszych
// niż piksel. Blisko punktu skupienia łan jest niski (kępki nad nim są dobrze widoczne),
// a dalej rośnie do far_factor wysokości roślin – tam, gdzie kępki wsiąkają.
// Ściernisko, gleba i siew: łan chowa się pod powierzchnię pola.
//
// Atrybuty siatki: UV = położenie w polu [m], COLOR.r = 1 dolna krawędź ściany (przy ziemi),
// COLOR.g = 1 górna krawędź ściany (normalna z siatki, pozioma).
render_mode cull_back, specular_disabled;

uniform sampler2D stage_tex : filter_nearest;
uniform vec2 grid_size = vec2(240.0, 320.0);   // kolumny, wiersze
uniform float cell_m = 0.25;
uniform vec3 color_light : source_color = vec3(0.663, 0.851, 0.341);
uniform vec3 color_dark : source_color = vec3(0.157, 0.42, 0.208);
uniform vec3 color_ready : source_color = vec3(0.902, 0.702, 0.243);
uniform float height_light = 0.22;
uniform float height_dark = 0.55;
uniform float height_ready = 0.95;
uniform vec3 barley_ready_tint = vec3(0.8, 0.74, 0.66);
uniform vec3 oats_ready_tint = vec3(1.08, 1.16, 1.5);
uniform vec3 focus = vec3(0.0);
uniform float detail_end = 40.0;
uniform float fade_m = 12.0;
uniform float visible_end = 110.0;
uniform float near_factor = 0.42;
uniform float far_factor = 0.8;
uniform float step_m = 0.5;
uniform float ground_y = 0.03;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;
uniform float noise_cells = 16.0;

varying vec3 v_color;
varying vec2 v_field;

// Wysokość roślin w komórce pod punktem p (metry w polu) i ich kolor.
float plant_height(vec2 p, out vec3 color) {
	ivec2 cell = ivec2(clamp(floor(p / cell_m), vec2(0.0), grid_size - 1.0));
	vec3 state = texelFetch(stage_tex, cell, 0).rgb * 255.0;
	int stage = int(state.r + 0.5);
	int crop = int(state.g + 0.5);
	float fert = clamp(state.b, 0.0, 2.0);
	color = color_light;
	float height = 0.0;
	if (stage == 2) {
		height = height_light;
	} else if (stage == 3) {
		height = height_dark;
		color = mix(color_dark, color_light, 0.35);
	} else if (stage == 4) {
		height = height_ready;
		color = crop == 2 ? color_ready * barley_ready_tint : (crop == 3 ? min(color_ready * oats_ready_tint, vec3(1.0)) : color_ready);
	}
	if (stage >= 2 && stage <= 3) {
		color = mix(color, color * vec3(0.85, 1.0, 0.85), fert * 0.5);
	}
	return height;
}

float height_at(vec2 p) {
	vec3 unused;
	return plant_height(p, unused);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	vec2 p = UV;
	// Wierzchołek leży w narożniku komórek: średnia z 4 sąsiednich (łagodna krawędź łanu).
	float q = cell_m * 0.5;
	vec3 c0; vec3 c1; vec3 c2; vec3 c3;
	float h0 = plant_height(p + vec2(-q, -q), c0);
	float h1 = plant_height(p + vec2(q, -q), c1);
	float h2 = plant_height(p + vec2(-q, q), c2);
	float h3 = plant_height(p + vec2(q, q), c3);
	float sum = h0 + h1 + h2 + h3;
	float height = sum * 0.25;
	vec3 color = (c0 * h0 + c1 * h1 + c2 * h2 + c3 * h3) / max(sum, 0.0001);
	if (sum <= 0.0) {
		// Wierzchołek bez roślin (schowany pod ziemią), ale może być dolnym końcem pochyłej
		// krawędzi łanu: kolor z sąsiednich wierzchołków z roślinami, żeby krawędź nie zmieniała barwy.
		vec3 weighted = vec3(0.0);
		float weights = 0.0;
		for (int dz = -1; dz <= 1; dz++) {
			for (int dx = -1; dx <= 1; dx++) {
				vec2 n = p + vec2(float(dx), float(dz)) * step_m;
				vec3 cn;
				for (int k = 0; k < 4; k++) {
					vec2 offset = vec2(k % 2 == 0 ? -q : q, k < 2 ? -q : q);
					float hn = plant_height(n + offset, cn);
					weighted += cn * hn;
					weights += hn;
				}
			}
		}
		color = weights > 0.0 ? weighted / weights : color_ready;
	}
	vec3 origin = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float d = distance(origin.xz, focus.xz);
	float factor = mix(near_factor, far_factor, smoothstep(detail_end - fade_m, visible_end, d));
	float top = height * factor;
	bool bottom_edge = COLOR.r > 0.5;
	if (height < 0.01) {
		VERTEX.y = ground_y - 0.04;                 // pod powierzchnią pola – niewidoczny
	} else if (bottom_edge) {
		VERTEX.y = ground_y - 0.02;
	} else {
		VERTEX.y = ground_y + top;
	}
	if (COLOR.g < 0.5 && !bottom_edge) {
		// Normalna z nachylenia łanu (pochyłe krawędzie pasów są ciemniejsze od góry).
		float hl = height_at(p - vec2(step_m, 0.0));
		float hr = height_at(p + vec2(step_m, 0.0));
		float hd = height_at(p - vec2(0.0, step_m));
		float hu = height_at(p + vec2(0.0, step_m));
		NORMAL = normalize(vec3((hl - hr) * factor, 2.0 * step_m, (hd - hu) * factor));
	}
	float shade = bottom_edge ? 0.66 : (COLOR.g > 0.5 ? 0.82 : 0.87);
	v_color = color * shade * (0.95 + 0.08 * hash(floor(p / step_m)));
	v_field = p;
}

void fragment() {
	// Drobna faktura łanu (gotowa tekstura szumu z mipmapami – bez migotania w oddali).
	// Jeden odczyt na piksel; większe plamy daje już kolor wierzchołków (co 0,5 m).
	float grain = texture(noise_tex, v_field * (1.6 / noise_cells)).r;
	ALBEDO = v_color * (0.88 + 0.16 * grain);
	ROUGHNESS = 1.0;
}
