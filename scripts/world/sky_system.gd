extends Node3D
## Sky, sun, moon, ambient light, fog, exposure and rain, driven by WorldData.time_of_day and conditions.
## Weather changes ease in smoothly. Lighting is keyed to the sun's elevation so every hour looks right.

const Look = preload("res://scripts/core/look.gd")
const SKY_SHADER := preload("res://shaders/sky.gdshader")
const LATITUDE := 34.0        # degrees north (a Kashmir-like latitude)
const DECLINATION := 10.0     # spring sun
# conditions: cloud coverage, overcast grey, haze, fog density, light dimming, rain
# per condition: cirrus/sky (cov, over, haze), fog density, light dimming, rain, and the volumetric cloud layer
# (base and top altitude, coverage, density, stratus shape 0..1, darkness)
const CONDITIONS := [
	{"cov": 0.04, "over": 0.0, "haze": 0.0, "fog": 0.000022, "dim": 1.0, "rain": 0.0, "base": 1400.0, "top": 2900.0, "ccov": 0.0, "cdens": 1.0, "strat": 0.0, "cdark": 0.0},
	{"cov": 0.34, "over": 0.0, "haze": 0.0, "fog": 0.000026, "dim": 0.96, "rain": 0.0, "base": 1400.0, "top": 2900.0, "ccov": 0.42, "cdens": 1.0, "strat": 0.0, "cdark": 0.0},
	{"cov": 0.62, "over": 0.25, "haze": 0.05, "fog": 0.00003, "dim": 0.72, "rain": 0.0, "base": 1300.0, "top": 3200.0, "ccov": 0.62, "cdens": 1.1, "strat": 0.15, "cdark": 0.1},
	{"cov": 0.93, "over": 0.82, "haze": 0.2, "fog": 0.00005, "dim": 0.32, "rain": 0.0, "base": 900.0, "top": 2400.0, "ccov": 0.82, "cdens": 1.0, "strat": 0.55, "cdark": 0.25},
	{"cov": 0.7, "over": 0.55, "haze": 0.85, "fog": 0.00042, "dim": 0.45, "rain": 0.0, "base": 120.0, "top": 900.0, "ccov": 0.85, "cdens": 0.55, "strat": 1.0, "cdark": 0.1},
	{"cov": 1.0, "over": 0.95, "haze": 0.45, "fog": 0.00016, "dim": 0.22, "rain": 1.0, "base": 600.0, "top": 3800.0, "ccov": 1.0, "cdens": 1.35, "strat": 0.6, "cdark": 0.55},
]

var env: Environment
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var sky_mat: ShaderMaterial
var draw_fog := 0.000035
var sun_elevation := 45.0
var _w := {}
var _rain: GPUParticles3D
var _rain_snd: AudioStreamPlayer
var _drift := Vector2.ZERO
var clouds                      # VolumetricClouds compositor effect
var _cloud_drift := Vector2.ZERO
var _volumes := {}
var _volumes_ready := false
var _sky_timer := 1.0
var _glow_on := true
var _sky_sent := Vector4(INF, 0, 0, 0)
var _drift_sent := Vector2(INF, INF)


func _ready() -> void:
	physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = SKY_SHADER
	sky_mat.set_shader_parameter("cloud_tex", preload("res://scripts/world/surface_materials.gd").sky_clouds())
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.glow_enabled = true
	env.glow_hdr_threshold = 1.1
	env.fog_enabled = true
	env.fog_aerial_perspective = 0.55
	var we := WorldEnvironment.new()
	we.environment = env
	clouds = preload("res://scripts/world/volumetric_clouds.gd").new()
	var comp := Compositor.new()
	comp.compositor_effects = [clouds]
	we.compositor = comp
	add_child(we)
	_volumes = preload("res://scripts/world/surface_materials.gd").cloud_volumes()
	_apply_quality()
	Settings.changed.connect(func(key, _v):
		if key in ["graphics/clouds", "graphics/shadow_quality", "graphics/ssao", "graphics/glow"]:
			_apply_quality())
	Look.apply(env)
	Settings.changed.connect(func(k, _v):
		if String(k).begins_with("display/"):
			Look.apply(env))

	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	add_child(sun)
	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = Color(0.62, 0.72, 1.0)
	moon.shadow_enabled = false
	add_child(moon)
	_build_rain()
	var c: Dictionary = CONDITIONS[WorldData.conditions]
	_w = c.duplicate()
	_apply_quality()


func _build_rain() -> void:
	_rain = GPUParticles3D.new()
	_rain.amount = 6000
	_rain.lifetime = 1.4
	_rain.local_coords = false
	_rain.visibility_aabb = AABB(Vector3(-90, -80, -90), Vector3(180, 160, 180))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(70.0, 4.0, 70.0)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 3.0
	pm.initial_velocity_min = 38.0
	pm.initial_velocity_max = 46.0
	pm.gravity = Vector3.ZERO
	pm.particle_flag_align_y = true
	_rain.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.025, 1.1)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.75, 0.8, 0.88, 0.32)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	mat.billboard_keep_scale = true
	q.material = mat
	_rain.draw_pass_1 = q
	_rain.emitting = false
	_rain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_rain)
	_rain_snd = AudioStreamPlayer.new()
	_rain_snd.stream = preload("res://scripts/core/audio.gd").looped("res://assets/audio/rain.wav")
	_rain_snd.bus = "Effects"
	_rain_snd.volume_db = -80.0
	add_child(_rain_snd)
	_rain_snd.play()


## Direction towards a body from its hour angle (degrees) and declination, at our latitude.
static func _body_dir(hour_angle: float, decl: float) -> Vector3:
	var lat := deg_to_rad(LATITUDE)
	var dc := deg_to_rad(decl)
	var ha := deg_to_rad(hour_angle)
	var alt := asin(sin(lat) * sin(dc) + cos(lat) * cos(dc) * cos(ha))
	var az := atan2(-sin(ha), tan(dc) * cos(lat) - sin(lat) * cos(ha))   # from north, clockwise (east positive)
	return Vector3(cos(alt) * sin(az), sin(alt), -cos(alt) * cos(az))


func _process(delta: float) -> void:
	var target: Dictionary = CONDITIONS[WorldData.conditions]
	var k := clampf(delta * 0.6, 0.0, 1.0)
	for key in target:
		_w[key] = lerpf(float(_w[key]), float(target[key]), k)
	var hour: float = WorldData.time_of_day
	var sd := _body_dir((hour - 12.0) * 15.0, DECLINATION)
	var md := _body_dir((hour - 0.5) * 15.0 + 180.0, -DECLINATION * 0.5)
	sun_elevation = rad_to_deg(asin(clampf(sd.y, -1.0, 1.0)))
	var e := sun_elevation
	var day := smoothstep(-6.0, 10.0, e)
	var golden := (1.0 - smoothstep(3.0, 20.0, e)) * smoothstep(-10.0, 0.0, e)
	var night := 1.0 - smoothstep(-12.0, -2.0, e)
	# above the overcast deck the sky is clear and the sun is full strength; the deck becomes a floor below
	var cam_y := 0.0
	var cam_now := get_viewport().get_camera_3d()
	if cam_now:
		cam_y = cam_now.global_position.y
	var deck_top := float(_w.top)
	var below := 1.0 - smoothstep(deck_top - 50.0, deck_top + 300.0, cam_y) * clampf((float(_w.over) - 0.5) * 2.0, 0.0, 1.0)
	var over: float = float(_w.over) * below
	var dim: float = lerpf(1.0, float(_w.dim), below)

	# ---- sun ----
	var up := Vector3.UP if absf(sd.y) < 0.99 else Vector3.FORWARD
	sun.look_at_from_position(Vector3.ZERO, -sd, up)
	sun.visible = e > -4.0
	var warm := _gradient(e, [[-4.0, Color(1.0, 0.32, 0.12)], [2.0, Color(1.0, 0.5, 0.26)], [8.0, Color(1.0, 0.7, 0.46)],
			[20.0, Color(1.0, 0.88, 0.74)], [45.0, Color(1.0, 0.96, 0.91)], [90.0, Color(1.0, 0.98, 0.95)]])
	sun.light_color = warm.lerp(Color(0.85, 0.88, 0.92), over * 0.7)
	sun.light_energy = (0.4 + 0.78 * smoothstep(0.0, 35.0, e)) * smoothstep(-4.0, 6.0, e) * dim
	sun.shadow_opacity = clampf(1.0 - over * 0.85, 0.1, 1.0)

	# ---- moon ----
	var mup := Vector3.UP if absf(md.y) < 0.99 else Vector3.FORWARD
	moon.look_at_from_position(Vector3.ZERO, -md, mup)
	moon.visible = night > 0.02 and md.y > -0.05
	moon.light_energy = 0.26 * night * (1.0 - 0.75 * over) * smoothstep(-0.05, 0.25, md.y)

	# ---- ambient, exposure, glow ----
	var storm := float(_w.rain)
	env.ambient_light_color = Color(0.06, 0.08, 0.14).lerp(Color(0.5, 0.55, 0.62), day).lerp(Color(0.32, 0.35, 0.4), storm * day)
	env.ambient_light_sky_contribution = lerpf(0.3, 0.85, day)
	env.ambient_light_energy = lerpf(0.9, 0.5, day) * (1.0 - 0.25 * storm)
	env.tonemap_exposure = lerpf(2.0, 0.85, day) * lerpf(1.0, 1.12, golden) * (1.0 - 0.1 * over)
	env.glow_intensity = lerpf(0.9, 0.55, day)
	env.glow_bloom = lerpf(0.12, 0.03, day)

	# ---- fog / visibility ----
	var horizon := Color(0.012, 0.02, 0.04).lerp(Color(0.62, 0.72, 0.84), day)
	horizon = horizon.lerp(Color(0.95, 0.55, 0.32), golden * 0.55)
	var grey := Color(0.02, 0.022, 0.03).lerp(Color(0.42, 0.45, 0.5), day).lerp(Color(0.27, 0.3, 0.34) * day, float(_w.rain))
	env.fog_light_color = horizon.lerp(grey, maxf(over, float(_w.haze)))
	env.fog_density = maxf(lerpf(0.000016, float(_w.fog), below), draw_fog)
	env.fog_sky_affect = lerpf(0.12, 0.6, float(_w.haze))
	env.fog_height = 260.0
	env.fog_height_density = 0.004 * float(_w.haze) * (1.0 if WorldData.conditions == 4 else 0.3)

	# ---- volumetric clouds ----
	if not _volumes_ready:
		_volumes_ready = true
		for vk in _volumes:
			var tx = _volumes[vk]
			if tx is NoiseTexture3D and (tx as NoiseTexture3D).get_data().is_empty():
				_volumes_ready = false
			elif tx is NoiseTexture2D and (tx as NoiseTexture2D).get_image() == null:
				_volumes_ready = false
		if _volumes_ready:
			clouds.set_noise_textures(_volumes)
	var wind_hi: Vector3 = WorldData.atmosphere.wind_at(Vector3(0.0, 2500.0, 0.0), 0.0, 0.0)
	var flow := Vector2(wind_hi.x, wind_hi.z)
	if flow.length() < 3.0:
		flow = Vector2(3.0, 1.2)
	_cloud_drift -= flow * delta          # noise space moves against the wind, so the clouds travel with it
	var use_sun := e > -4.0
	clouds.sun_dir = sd if use_sun else md
	clouds.light_intensity = (sun.light_energy if use_sun else moon.light_energy * 1.6) * 2.9
	clouds.sun_color = sun.light_color if use_sun else moon.light_color
	clouds.ambient = 0.62
	var sky_top := Color(0.012, 0.016, 0.03).lerp(Color(0.42, 0.52, 0.68), day).lerp(Color(0.4, 0.38, 0.48), golden * 0.5)
	clouds.amb_top = sky_top.lerp(Color(0.36, 0.38, 0.42) * maxf(day, 0.05), over)
	clouds.amb_bottom = Color(0.01, 0.012, 0.015).lerp(Color(0.2, 0.22, 0.2), day).lerp(Color(0.32, 0.22, 0.16), golden * 0.4)
	clouds.fog_color = env.fog_light_color
	clouds.fog_density = env.fog_density
	clouds.base = float(_w.base)
	clouds.top = float(_w.top)
	clouds.coverage = float(_w.ccov)
	clouds.density = float(_w.cdens)
	clouds.stratus = float(_w.strat)
	clouds.darkness = float(_w.cdark)
	clouds.wind = _cloud_drift

	# ---- water haze ----
	for om in preload("res://scripts/world/surface_materials.gd").ocean_materials:
		(om as ShaderMaterial).set_shader_parameter("haze_color", env.fog_light_color)
		(om as ShaderMaterial).set_shader_parameter("haze_density", maxf(env.fog_density * 1.9, 0.00003))

	# ---- sky shader (high cirrus and the sky itself) ----
	# Changing any sky uniform re-renders the sky's lighting cubemap, so update a few times a second at most, and
	# only when something actually changed (Godot's recommended practice for dynamic skies).
	_drift += Vector2(0.004, 0.0025) * delta * (1.0 + WorldData.atmosphere.wind_speed * 0.1)
	_sky_timer += delta
	var sky_state := Vector4(e, over, float(_w.haze) * below, float(_w.cov))
	if _sky_timer >= 0.25 and (sky_state.distance_to(_sky_sent) > 0.002 or _drift.distance_to(_drift_sent) > 0.0005):
		_sky_timer = 0.0
		_sky_sent = sky_state
		_drift_sent = _drift
		sky_mat.set_shader_parameter("sun_dir", sd)
		sky_mat.set_shader_parameter("moon_dir", md)
		sky_mat.set_shader_parameter("sun_elev", e)
		sky_mat.set_shader_parameter("cloud_coverage", clampf(float(_w.cov) * 0.3 + over * 0.2, 0.0, 1.0))   # high cirrus only
		sky_mat.set_shader_parameter("overcast", over)
		sky_mat.set_shader_parameter("haze", float(_w.haze) * below)
		sky_mat.set_shader_parameter("cloud_drift", _drift)

	# ---- rain: particles around the camera, slanted by the wind, plus its sound ----
	var rain: float = _w.rain
	var cam: Camera3D = cam_now
	if cam:
		_rain.global_position = cam.global_position + Vector3(0.0, 30.0, 0.0)
	rain *= 1.0 - smoothstep(float(_w.base), float(_w.base) + 300.0, cam_y)     # no rain above the cloud base
	_rain.emitting = rain > 0.05
	_rain.amount_ratio = clampf(rain, 0.0, 1.0)
	var wv: Vector3 = WorldData.atmosphere.wind_at(_rain.global_position, 0.0, 0.0) if WorldData.atmosphere else Vector3.ZERO
	(_rain.process_material as ParticleProcessMaterial).direction = (Vector3(0, -40, 0) + wv).normalized()
	_rain_snd.volume_db = linear_to_db(maxf(rain * 0.8, 0.0001))


static func _gradient(x: float, stops: Array) -> Color:
	if x <= stops[0][0]:
		return stops[0][1]
	for i in stops.size() - 1:
		if x <= stops[i + 1][0]:
			return (stops[i][1] as Color).lerp(stops[i + 1][1], (x - stops[i][0]) / (stops[i + 1][0] - stops[i][0]))
	return stops[-1][1]


func _apply_quality() -> void:
	var cq: Dictionary = Settings.cloud_level()
	clouds.primary_steps = int(cq.steps)
	clouds.light_steps = int(cq.light)
	var rs := {64: Sky.RADIANCE_SIZE_64, 128: Sky.RADIANCE_SIZE_128, 256: Sky.RADIANCE_SIZE_256}
	if env and env.sky and env.sky.radiance_size != rs[int(cq.radiance)]:
		env.sky.radiance_size = rs[int(cq.radiance)]
	if env:
		var ultra := int(Settings.get_value("graphics/shadow_quality")) >= 3
		env.ssao_enabled = bool(Settings.get_value("graphics/ssao"))
		env.ssao_radius = 1.2
		env.ssao_intensity = 1.6
		RenderingServer.environment_set_ssao_quality(RenderingServer.ENV_SSAO_QUALITY_HIGH if ultra else RenderingServer.ENV_SSAO_QUALITY_MEDIUM, not ultra, 0.5, 2, 50.0, 300.0)
		_glow_on = bool(Settings.get_value("graphics/glow"))
		env.glow_enabled = _glow_on
	if sun:
		sun.directional_shadow_max_distance = float(Settings.shadow_level().dist)
