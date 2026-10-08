extends Node3D
## Main menu backdrop: the Su-27 in afterburner over a sunset cloud deck, filmed with slow camera moves.
## Light on purpose: only the jet, a sky, a cloud layer and the ocean shader. No world, no physics.

const OCEAN_SHADER := preload("res://shaders/ocean.gdshader")
const CLOUD_SHADER := preload("res://shaders/menu_clouds.gdshader")
const FLAME_SHADER := preload("res://shaders/afterburner_flame.gdshader")
const SPEED := 260.0          # apparent airspeed, m/s
const SHOT_TIME := 9.0

# camera shots in the jet's frame (-Z forward, +X right, +Y up): [start offset, end offset, look offset, fov]
const SHOTS := [
	[Vector3(-25.0, 3.0, 33.0), Vector3(-19.0, 2.0, 27.0), Vector3(0.0, 0.4, -2.0), 34.0],
	[Vector3(-44.0, -3.0, 5.0), Vector3(-42.0, -5.0, -9.0), Vector3(0.0, 0.0, 0.0), 30.0],
	[Vector3(-9.0, 14.0, 52.0), Vector3(3.0, 10.0, 44.0), Vector3(0.0, 0.0, -4.0), 28.0],
	[Vector3(-21.0, 4.0, -48.0), Vector3(-14.0, 2.0, -38.0), Vector3(0.0, 0.3, 2.0), 30.0],
]

var _jet: Node3D
var _model: Node3D
var _cam: Camera3D
var _ocean_mat: ShaderMaterial
var _cloud_mat: ShaderMaterial
var _t := 0.0
var _dist := 0.0
var _surfaces := {}
var _beacons: Array[StandardMaterial3D] = []
var _strobes: Array[StandardMaterial3D] = []
var _layer: CanvasLayer
var _views: Array[SubViewport] = []
var _cams: Array[Camera3D] = []
var _rects: Array[TextureRect] = []
const CROSSFADE := 1.6       # seconds the outgoing and incoming shots overlap
const PREROLL := 0.2         # seconds the incoming view renders invisibly before its dissolve begins
var _snd := {}


func _ready() -> void:
	_build_environment()
	_build_jet()
	_build_audio()
	# Two identical views (ping-pong). Shot k plays on view k % 2. The next shot pre-rolls invisibly on the other
	# view, dissolves in on top, and then simply keeps playing: nothing ever hands over, so nothing can flicker.
	get_viewport().disable_3d = true
	var attrs := CameraAttributesPractical.new()
	attrs.dof_blur_far_enabled = true
	attrs.dof_blur_far_distance = 90.0
	attrs.dof_blur_far_transition = 400.0
	attrs.dof_blur_amount = 0.06
	_layer = CanvasLayer.new()
	_layer.layer = -5                     # under the menu
	add_child(_layer)
	for i in 2:
		var v := SubViewport.new()
		v.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(v)
		var c := Camera3D.new()
		c.far = 40000.0
		c.attributes = attrs
		v.add_child(c)
		c.current = true
		var r := TextureRect.new()
		r.set_anchors_preset(Control.PRESET_FULL_RECT)
		r.mouse_filter = Control.MOUSE_FILTER_IGNORE
		r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		r.stretch_mode = TextureRect.STRETCH_SCALE
		r.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		r.texture = v.get_texture()
		r.modulate.a = 0.0
		r.visible = false
		_layer.add_child(r)
		_views.append(v)
		_cams.append(c)
		_rects.append(r)
	_cam = _cams[0]


func _build_audio() -> void:
	const A = preload("res://scripts/core/audio.gd")
	for pair in [["afterburner", -15.0, 0.92], ["ab_body", -17.0, 0.95], ["engine_whine", -26.0, 0.95], ["engine_low", -15.0, 0.9], ["wind", -20.0, 0.85]]:
		var p := AudioStreamPlayer.new()
		p.stream = A.looped("res://assets/audio/" + pair[0] + ".wav")
		p.bus = "Engine"
		p.volume_db = -80.0
		p.pitch_scale = pair[2]
		add_child(p)
		p.play(randf() * 3.0)
		_snd[pair[0]] = [p, pair[1]]


func _build_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.07, 0.13, 0.27)
	sky_mat.sky_horizon_color = Color(0.93, 0.60, 0.38)
	sky_mat.sky_curve = 0.12
	sky_mat.ground_horizon_color = Color(0.70, 0.48, 0.36)
	sky_mat.ground_bottom_color = Color(0.05, 0.06, 0.09)
	sky_mat.sun_angle_max = 18.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.glow_enabled = true
	env.glow_intensity = 0.7
	env.glow_bloom = 0.08
	env.fog_enabled = true
	env.fog_light_color = Color(0.86, 0.64, 0.50)
	env.fog_density = 0.00004
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.08
	env.adjustment_contrast = 1.04
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-11.0, -38.0, 0.0)   # low sun behind the cameras: lights the jet, warm sky ahead
	sun.light_color = Color(1.0, 0.80, 0.62)
	sun.light_energy = 1.7
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)

	var ocean := MeshInstance3D.new()
	var pm := PlaneMesh.new(); pm.size = Vector2(90000.0, 90000.0)
	ocean.mesh = pm
	_ocean_mat = preload("res://scripts/world/surface_materials.gd").ocean()
	ocean.material_override = _ocean_mat
	ocean.position.y = -1600.0
	add_child(ocean)

	var clouds := MeshInstance3D.new()
	var cm := PlaneMesh.new(); cm.size = Vector2(70000.0, 70000.0)
	clouds.mesh = cm
	_cloud_mat = preload("res://scripts/world/surface_materials.gd").clouds()
	clouds.material_override = _cloud_mat
	clouds.position.y = -420.0
	clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(clouds)


func _build_jet() -> void:
	_jet = Node3D.new()
	add_child(_jet)
	_model = load(load("res://data/aircraft/su27.tres").model_scene).instantiate()
	_model.rotation.y = PI
	_jet.add_child(_model)
	var ap := _model.find_child("AnimationPlayer", true, false) as AnimationPlayer
	if ap and ap.has_animation("gear_retract"):
		ap.play("gear_retract")
		ap.seek(ap.get_animation("gear_retract").length, true)
		ap.pause()
	var flame := ShaderMaterial.new(); flame.shader = FLAME_SHADER
	flame.set_shader_parameter("intensity", 0.75)
	for n in ["AfterburnerFlame_L", "AfterburnerFlame_R"]:
		var f := _model.find_child(n, true, false) as MeshInstance3D
		if f:
			f.material_override = flame
			f.visible = true
			f.scale = Vector3(0.95, 0.95, 0.8)
	for n in ["Afterburner_L", "Afterburner_R"]:
		var g := _model.find_child(n, true, false) as MeshInstance3D
		if g:
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.02, 0.02, 0.02)
			m.emission_enabled = true; m.emission = Color(1.0, 0.45, 0.12); m.emission_energy_multiplier = 5.0
			g.material_override = m
	_lamp("Light_Nav_L", Color(1.0, 0.1, 0.06), 5.0)
	_lamp("Light_Nav_R", Color(0.15, 1.0, 0.35), 5.0)
	_lamp("Light_Tail_L", Color(1, 0.97, 0.9), 4.0)
	_lamp("Light_Tail_R", Color(1, 0.97, 0.9), 4.0)
	_beacons.append(_lamp("Light_Beacon_Top", Color(1.0, 0.1, 0.06), 0.0))
	_beacons.append(_lamp("Light_Beacon_Bottom", Color(1.0, 0.1, 0.06), 0.0))
	_strobes.append(_lamp("Light_Strobe_L", Color(1, 1, 1), 0.0))
	_strobes.append(_lamp("Light_Strobe_R", Color(1, 1, 1), 0.0))
	for n in ["Flaperon_L", "Flaperon_R", "Stabilator_L", "Stabilator_R", "Rudder_L", "Rudder_R"]:
		var node := _model.find_child(n, true, false) as Node3D
		if node:
			_surfaces[n] = [node, node.transform.basis]


func _lamp(n: String, c: Color, e: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c.darkened(0.5); m.emission_enabled = true; m.emission = c; m.emission_energy_multiplier = e
	var mi := _model.find_child(n, true, false) as MeshInstance3D
	if mi:
		mi.material_override = m
	return m


func _surface(n: String, deg: float) -> void:
	if _surfaces.has(n):
		var e: Array = _surfaces[n]
		(e[0] as Node3D).transform.basis = (e[1] as Basis) * Basis(Vector3.RIGHT, deg_to_rad(deg))


func _process(delta: float) -> void:
	_t += delta
	_dist += SPEED * delta
	for k in _snd:
		var e: Array = _snd[k]
		var breathe := 1.5 * sin(_t * 0.23 + float(k.length()))
		(e[0] as AudioStreamPlayer).volume_db = move_toward((e[0] as AudioStreamPlayer).volume_db, float(e[1]) + breathe, 20.0 * delta)
	var scroll := Vector2(0.0, -_dist)
	_ocean_mat.set_shader_parameter("scroll", scroll * 1.0)
	_cloud_mat.set_shader_parameter("scroll", scroll)

	# gentle flight: slow banks and small pitch changes, with matching control surface motion
	var bank := sin(_t * 0.23) * 0.22 + sin(_t * 0.61) * 0.04
	var roll_rate := cos(_t * 0.23) * 0.23 * 0.22
	var pitch := sin(_t * 0.17) * 0.035
	_jet.basis = Basis.from_euler(Vector3(pitch, sin(_t * 0.11) * 0.05, -bank))
	_jet.position = Vector3(0.0, sin(_t * 0.5) * 0.4, 0.0)
	_surface("Flaperon_L", -roll_rate * 300.0)
	_surface("Flaperon_R", roll_rate * 300.0)
	_surface("Stabilator_L", pitch * 120.0 - roll_rate * 120.0)
	_surface("Stabilator_R", pitch * 120.0 + roll_rate * 120.0)
	_surface("Rudder_L", sin(_t * 0.3) * 2.0)
	_surface("Rudder_R", sin(_t * 0.3) * 2.0)

	var bp := fmod(_t, 1.0)
	_beacons[0].emission_energy_multiplier = 10.0 if bp < 0.12 else 0.0
	_beacons[1].emission_energy_multiplier = 10.0 if fmod(_t + 0.5, 1.0) < 0.12 else 0.0
	var sp := fmod(_t, 1.3)
	for s in _strobes:
		s.emission_energy_multiplier = 18.0 if (sp < 0.05 or (sp > 0.14 and sp < 0.19)) else 0.0

	# cinematic shots with crossfades: shot k starts every (SHOT_TIME - CROSSFADE) seconds on view k % 2
	var period := SHOT_TIME - CROSSFADE
	var k := int(_t / period)
	var tau := _t - k * period
	var cur := k % 2
	var other := 1 - cur
	_sync_views()
	if tau < CROSSFADE and k > 0:
		# outgoing shot underneath, incoming shot on top dissolving in
		_apply_shot(_cams[other], k - 1, tau + period)
		_apply_shot(_cams[cur], k, tau)
		_show(other, 1.0, false)
		var a := tau / CROSSFADE
		_show(cur, a * a * (3.0 - 2.0 * a), true)
	elif period - tau < PREROLL:
		# the next shot starts rendering, invisible, on top: its first visible frame is already live
		_apply_shot(_cams[cur], k, tau)
		_apply_shot(_cams[other], k + 1, 0.0)
		_show(cur, 1.0, false)
		_show(other, 0.0, true)
	else:
		_apply_shot(_cams[cur], k, tau)
		_show(cur, 1.0, true)
		_hide(other)
	_cam = _cams[cur]


func _show(i: int, alpha: float, on_top: bool) -> void:
	var r := _rects[i]
	if on_top and r.get_index() != _layer.get_child_count() - 1:
		_layer.move_child(r, -1)
	r.modulate.a = alpha
	r.visible = true
	_views[i].render_target_update_mode = SubViewport.UPDATE_ALWAYS


func _hide(i: int) -> void:
	if _rects[i].visible:
		_rects[i].visible = false
		_rects[i].modulate.a = 0.0
		_views[i].render_target_update_mode = SubViewport.UPDATE_DISABLED


## Both views render at the window's real pixel size with the game's render settings.
func _sync_views() -> void:
	var main_vp := get_viewport()
	var px: Vector2i = get_window().size
	for v in _views:
		if v.size != px:
			v.size = px
		v.msaa_3d = main_vp.msaa_3d
		v.screen_space_aa = main_vp.screen_space_aa
		v.use_taa = main_vp.use_taa
		v.use_debanding = main_vp.use_debanding
		v.scaling_3d_scale = main_vp.scaling_3d_scale


## Places a camera on shot `idx` at `local` seconds into it: a steady dolly between the shot's two offsets.
func _apply_shot(cam: Camera3D, idx: int, local: float) -> void:
	var shot: Array = SHOTS[idx % SHOTS.size()]
	var u := clampf(local / SHOT_TIME, 0.0, 1.0)
	var e := lerpf(u, u * u * (3.0 - 2.0 * u), 0.25)     # near-constant motion, so dissolves never stall
	var off: Vector3 = (shot[0] as Vector3).lerp(shot[1], e)
	cam.fov = shot[3]
	cam.global_position = _jet.position + off
	cam.look_at(_jet.position + (shot[2] as Vector3), Vector3.UP)
	cam.h_offset = -off.length() * 0.085     # keep the jet to the right of the menu panel
