extends Node3D
## Niebo, słońce i ustawienia obrazu: ciepłe, jasne, matowe kolory w stylu low-poly.

var sun: DirectionalLight3D
var environment: Environment


func _ready() -> void:
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("#4f9be8")
	sky_material.sky_horizon_color = Color("#cfe5f5")
	sky_material.sky_curve = 0.12
	sky_material.ground_bottom_color = Color("#7aa65a")
	sky_material.ground_horizon_color = Color("#cfe5f5")
	sky_material.sun_angle_max = 20.0
	sky_material.sun_curve = 0.1
	var sky := Sky.new()
	sky.sky_material = sky_material

	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.62
	environment.ambient_light_sky_contribution = 0.7
	environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.tonemap_exposure = 0.95
	environment.tonemap_white = 6.0
	environment.adjustment_enabled = true
	environment.adjustment_saturation = 1.04
	environment.adjustment_contrast = 1.04
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_light_color = Color("#cfe3f3")
	environment.fog_depth_begin = 180.0
	environment.fog_depth_end = 1100.0
	environment.fog_depth_curve = 1.6
	environment.fog_density = 0.85
	environment.fog_sky_affect = 0.0
	# Działa tylko w rendererze Forward+; w Compatibility jest ignorowane.
	environment.ssao_enabled = true
	environment.ssao_radius = 1.4
	environment.ssao_intensity = 1.6
	environment.ssao_power = 1.3
	environment.glow_enabled = true
	environment.glow_intensity = 0.35
	environment.glow_bloom = 0.04
	environment.glow_hdr_threshold = 1.2

	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	add_child(world_environment)

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color("#fff0d4")
	sun.light_energy = 1.12
	sun.rotation_degrees = Vector3(-52.0, -38.0, 0.0)
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	sun.shadow_blur = 1.5
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 160.0
	sun.directional_shadow_fade_start = 0.85
	add_child(sun)


## Jakość grafiki (files/graphics.json): cienie słońca, SSAO, poświata.
func apply_quality(preset: Dictionary) -> void:
	var splits: int = int(preset.get("shadow_splits", 4))
	sun.shadow_enabled = splits > 0
	match splits:
		1:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		2:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
		_:
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = maxf(10.0, float(preset.get("shadow_distance_m", 160.0)))
	environment.ssao_enabled = bool(preset.get("ssao", true))
	environment.glow_enabled = bool(preset.get("glow", true))
