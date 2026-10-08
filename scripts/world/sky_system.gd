extends Node3D
## Sky, sun, moon, ambient light, fog, exposure and rain, driven by WorldData.time_of_day and conditions.
## Weather changes ease in smoothly. Lighting is keyed to the sun's elevation so every hour looks right.

const Look = preload("res://scripts/core/look.gd")
const SKY_SHADER := preload("res://shaders/sky.gdshader")
const DECK_ALT := 1900.0      # overcast stratus deck altitude
const LATITUDE := 34.0        # degrees north (a Kashmir-like latitude)
const DECLINATION := 10.0     # spring sun
# conditions: cloud coverage, overcast grey, haze, fog density, light dimming, rain
const CONDITIONS := [
	{"cov": 0.04, "over": 0.0, "haze": 0.0, "fog": 0.000016, "dim": 1.0, "rain": 0.0},
	{"cov": 0.34, "over": 0.0, "haze": 0.0, "fog": 0.000022, "dim": 0.96, "rain": 0.0},
	{"cov": 0.62, "over": 0.25, "haze": 0.05, "fog": 0.00003, "dim": 0.72, "rain": 0.0},
	{"cov": 0.93, "over": 0.82, "haze": 0.2, "fog": 0.00005, "dim": 0.32, "rain": 0.0},
	{"cov": 0.7, "over": 0.55, "haze": 0.85, "fog": 0.00042, "dim": 0.45, "rain": 0.0},
	{"cov": 1.0, "over": 0.95, "haze": 0.45, "fog": 0.00016, "dim": 0.22, "rain": 1.0},
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
var clouds: Node3D
var _cloud_drift := Vector2.ZERO


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
	add_child(we)
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
	clouds = preload("res://scripts/world/cloud_field.gd").new()
	clouds.name = "Clouds"
	add_child(clouds)
	var c: Dictionary = CONDITIONS[WorldData.conditions]
	_w = c.duplicate()


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
	var below := 1.0 - smoothstep(DECK_ALT - 80.0, DECK_ALT + 250.0, cam_y) * clampf((float(_w.over) - 0.5) * 2.0, 0.0, 1.0)
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

	# ---- 3D clouds ----
	var wind_hi: Vector3 = WorldData.atmosphere.wind_at(Vector3(0.0, 2500.0, 0.0), 0.0, 0.0)
	var flow := Vector2(wind_hi.x, wind_hi.z)
	if flow.length() < 3.0:
		flow = Vector2(3.0, 1.2)
	_cloud_drift += flow * delta
	var cam0 := get_viewport().get_camera_3d()
	var inside := 0.0
	if cam0:
		inside = clouds.inside_amount(cam0.global_position, float(_w.cov), _cloud_drift)
	var light_dir := sd if e > -4.0 else md
	var key_col := Color(1, 1, 1).lerp(warm, 0.55 + 0.45 * golden).lerp(Color(0.6, 0.68, 0.85), night)
	var lit_c := Color(0.06, 0.07, 0.1).lerp(Color(0.95, 0.96, 0.98), day)
	lit_c = lit_c.lerp(Color(1.0, 0.86, 0.66), golden * 0.55)
	var shade_c := Color(0.03, 0.035, 0.05).lerp(Color(0.46, 0.5, 0.58), day)
	shade_c = shade_c.lerp(Color(0.3, 0.29, 0.38), golden * 0.75).lerp(Color(0.24, 0.26, 0.3), float(_w.rain) * day)
	var pm: ShaderMaterial = clouds.puff_mat
	pm.set_shader_parameter("sun_dir", light_dir)
	pm.set_shader_parameter("sun_color", key_col)
	pm.set_shader_parameter("lit_color", lit_c * lerpf(1.0, 0.75, over))
	pm.set_shader_parameter("shade_color", shade_c)
	pm.set_shader_parameter("darkness", clampf(over * 0.55 + float(_w.rain) * 0.3, 0.0, 0.85))
	pm.set_shader_parameter("drift", _cloud_drift)
	pm.set_shader_parameter("coverage", _w.cov)
	pm.set_shader_parameter("far_fade", lerpf(30000.0, 9000.0, float(_w.haze)))
	var dm: ShaderMaterial = clouds.deck_mat
	dm.set_shader_parameter("amount", clampf((float(_w.over) - 0.3) * 2.6, 0.0, 1.0))
	dm.set_shader_parameter("top_color", lit_c * key_col * 0.85)
	dm.set_shader_parameter("bottom_color", shade_c * lerpf(1.0, 0.7, float(_w.rain)))
	dm.set_shader_parameter("drift", _cloud_drift)
	# inside a cloud: whiteout
	env.fog_density = maxf(env.fog_density, inside * 0.02)
	env.fog_light_color = env.fog_light_color.lerp(Color(lit_c.r, lit_c.g, lit_c.b) * 0.9, inside)

	# ---- sky shader (high cirrus and the sky itself) ----
	_drift += Vector2(0.004, 0.0025) * delta * (1.0 + WorldData.atmosphere.wind_speed * 0.1)
	sky_mat.set_shader_parameter("sun_dir", sd)
	sky_mat.set_shader_parameter("moon_dir", md)
	sky_mat.set_shader_parameter("sun_elev", e)
	sky_mat.set_shader_parameter("cloud_coverage", clampf(float(_w.cov) * 0.55 + over * 0.45, 0.0, 1.0))
	sky_mat.set_shader_parameter("overcast", over)
	sky_mat.set_shader_parameter("haze", float(_w.haze) * below)
	sky_mat.set_shader_parameter("cloud_drift", _drift)

	# ---- rain: particles around the camera, slanted by the wind, plus its sound ----
	var rain: float = _w.rain
	var cam := cam0
	if cam:
		_rain.global_position = cam.global_position + Vector3(0.0, 30.0, 0.0)
	rain *= 1.0 - smoothstep(DECK_ALT - 200.0, DECK_ALT, cam_y)     # no rain above the cloud base
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
