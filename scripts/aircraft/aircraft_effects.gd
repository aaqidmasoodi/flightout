extends Node
## Presentation-only effects for any aircraft following the FlightOut model naming contract: exterior lights and afterburner.
## Reads state from the flight controller and never touches the physics,
## so a dedicated server can skip this node entirely.

const AB_THRESHOLD := 0.85
const COCKPIT_LAYER := 1 << 19          # the cockpit interior's visual layer (scripts/aircraft/cockpit.gd)
const FLAME_SHADER := preload("res://shaders/afterburner_flame.gdshader")

var aircraft: Node3D
var model: Node3D
var lights_on := true

var _t := 0.0
var _lamps := {}
var _glow_mats: Array[StandardMaterial3D] = []
var _flames: Array[MeshInstance3D] = []
var _flame_mat: ShaderMaterial
var _landing: Array[SpotLight3D] = []
var _halos := {}                        # lamp name -> billboard glow (the point of light seen from a distance)
var _set := {}
var _lamp_on := {}                      # lamp name -> state last applied (lights are only touched when they change)
var _night_set := -1.0
var _eng_set := -1.0
var _ab_light: OmniLight3D
const AB_LIGHT_ENERGY := 2.2
const AB_LIGHT_RANGE := 11.0

## Which exterior lights each type really has (anything not listed: the full set). The Su-27S carries steady
## navigation lights (red left, green right, white tail), no anti-collision beacons, no strobes and no formation
## lights; its landing and taxi lights sit on the nose-gear leg and only work with the gear down.
const LIGHT_SETS := {"su27": {"beacons": false, "strobes": false}}


func setup(ac: Node3D, mdl: Node3D) -> void:
	aircraft = ac
	model = mdl
	var id := ""
	if ac.get("spec") != null and ac.spec != null:
		id = String(ac.spec.id)
	_set = LIGHT_SETS.get(id, {})
	# aviation colours: red and green are deep, the white is slightly warm (incandescent)
	var red := Color(1.0, 0.07, 0.04)
	var green := Color(0.1, 1.0, 0.45)
	var white := Color(1.0, 0.95, 0.85)
	# name, colour, lamp emission, light energy, light range, halo size
	# navigation lights are small steady lamps: bright points with a faint wash on the nearby skin, nothing more
	_add_lamp("Light_Nav_L", red, 6.0, 0.3, 2.5, 0.022)
	_add_lamp("Light_Nav_R", green, 6.0, 0.3, 2.5, 0.022)
	_add_lamp("Light_Tail_L", white, 5.0, 0.2, 2.0, 0.018)
	_add_lamp("Light_Tail_R", white, 5.0, 0.2, 2.0, 0.018)
	if _set.get("beacons", true):
		_add_lamp("Light_Beacon_Top", red, 10.0, 1.6, 6.0, 0.03)
		_add_lamp("Light_Beacon_Bottom", red, 10.0, 1.6, 6.0, 0.03)
	else:
		_remove_lamp("Light_Beacon_Top")
		_remove_lamp("Light_Beacon_Bottom")
	if _set.get("strobes", true):
		_add_lamp("Light_Strobe_L", white, 16.0, 3.0, 8.0, 0.045)
		_add_lamp("Light_Strobe_R", white, 16.0, 3.0, 8.0, 0.045)
	else:
		_remove_lamp("Light_Strobe_L")
		_remove_lamp("Light_Strobe_R")
	# (no halo on the nose-gear lamps: they sit right under the cockpit, and their spot lights show them)
	_add_lamp("Light_Landing_L", white, 10.0, 0.0, 0.0)
	_add_lamp("Light_Landing_R", white, 10.0, 0.0, 0.0)
	# nose-gear lamps: L is the landing light (long, narrow beam, a few degrees down), R the taxi light (wide,
	# short, aimed lower just ahead of the jet). Model nose is +Z, a light shines down its -Z: turn it around.
	for e in [["Light_Landing_L", 12.0, -5.0, 1500.0, 8.0], ["Light_Landing_R", 28.0, -11.0, 220.0, 4.0]]:
		var lamp := model.find_child(e[0], true, false) as Node3D
		if lamp:
			var spot := SpotLight3D.new()
			spot.basis = Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, deg_to_rad(float(e[2])))
			spot.spot_range = float(e[3])
			spot.spot_angle = float(e[1])
			spot.spot_angle_attenuation = 0.6
			spot.light_color = Color(1.0, 0.93, 0.8)
			spot.light_energy = 0.0
			spot.set_meta("on_energy", float(e[4]))
			spot.light_cull_mask = ~COCKPIT_LAYER & 0xFFFFF
			spot.visible = false
			# a jet far away lights nothing you can see: its spot drops out of the light lists
			spot.distance_fade_enabled = true
			spot.distance_fade_begin = float(e[3]) + 500.0
			spot.distance_fade_length = 300.0
			lamp.add_child(spot)
			_landing.append(spot)

	for n in ["Afterburner_L", "Afterburner_R"]:
		var g := model.find_child(n, true, false) as MeshInstance3D
		if g:
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.02, 0.02, 0.02)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.45, 0.12)
			g.material_override = m
			_glow_mats.append(m)
	# condensation: wingtip vortices, vapour over the wing roots, contrails (scripts/fx/aircraft_trails.gd)
	if DisplayServer.get_name() != "headless" and not "--no-trails" in OS.get_cmdline_user_args():
		var trails: Node = preload("res://scripts/fx/aircraft_trails.gd").new()
		trails.name = "Trails"
		add_child(trails)
		trails.setup(ac, mdl)
	# the afterburner's light on the jet's own tail and fins, and on the runway or ground below: one small light
	# between the nozzles, no shadows, short reach, off unless the burner is lit (and faded out with distance)
	var nz: Array = []
	for n in ["AfterburnerFlame_L", "AfterburnerFlame_R", "Afterburner_L", "Afterburner_R"]:
		var a := model.find_child(n, true, false) as Node3D
		if a:
			nz.append(ac.to_local(a.global_position) if a.is_inside_tree() else (model.transform * a.position))
	if not nz.is_empty():
		var c := Vector3.ZERO
		for p in nz:
			c += p
		c /= nz.size()
		_ab_light = OmniLight3D.new()
		_ab_light.name = "AfterburnerLight"
		_ab_light.light_color = Color(1.0, 0.55, 0.24)
		_ab_light.omni_range = AB_LIGHT_RANGE
		_ab_light.omni_attenuation = 1.4
		_ab_light.light_energy = 0.0
		_ab_light.light_specular = 0.3
		_ab_light.shadow_enabled = false
		_ab_light.light_cull_mask = ~COCKPIT_LAYER & 0xFFFFF
		_ab_light.distance_fade_enabled = true
		_ab_light.distance_fade_begin = 300.0
		_ab_light.distance_fade_length = 100.0
		_ab_light.position = c + Vector3(0.0, 0.0, 2.5)        # a little behind the nozzles, in the flame
		_ab_light.visible = false
		ac.add_child(_ab_light)
	_flame_mat = ShaderMaterial.new()
	_flame_mat.shader = FLAME_SHADER
	for n in ["AfterburnerFlame_L", "AfterburnerFlame_R"]:
		var f := model.find_child(n, true, false) as MeshInstance3D
		if f:
			f.material_override = _flame_mat
			f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			f.visible = false
			_flames.append(f)


## A lamp this type does not have: its lens mesh is hidden (the model's own material for it is emissive).
func _remove_lamp(n: String) -> void:
	var mi := model.find_child(n, true, false) as MeshInstance3D
	if mi:
		mi.visible = false


func _add_lamp(n: String, color: Color, emission: float, energy: float, light_range: float, halo := 0.0) -> void:
	var mi := model.find_child(n, true, false) as MeshInstance3D
	if mi == null:
		return
	var m := StandardMaterial3D.new()
	m.albedo_color = color.darkened(0.55)
	m.roughness = 0.2
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = 0.0
	mi.material_override = m
	var light: OmniLight3D = null
	if energy > 0.0:
		light = OmniLight3D.new()
		light.light_color = color
		light.omni_range = light_range
		light.light_energy = 0.0
		light.shadow_enabled = false
		light.light_cull_mask = ~COCKPIT_LAYER & 0xFFFFF   # never lights the cockpit interior
		light.visible = false
		light.distance_fade_enabled = true                  # a glow on the skin a few metres across: not from afar
		light.distance_fade_begin = 250.0
		light.distance_fade_length = 100.0
		mi.add_child(light)
	if halo > 0.0:
		# the lamp as seen from a distance: a soft glow around it, sized in metres (it shrinks with the jet), at
		# least a couple of pixels (it still reads as a light far away), fading with range and haze
		# (shaders/nav_light.gdshader)
		var q := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2.ONE
		q.mesh = qm
		var hm := ShaderMaterial.new()
		hm.shader = NAV_LIGHT
		hm.set_shader_parameter("glow", _halo_tex())
		hm.set_shader_parameter("color", Color(color.r, color.g, color.b))
		hm.set_shader_parameter("intensity", 2.2)
		hm.set_shader_parameter("size_m", halo * 16.0)     # (the old screen-fixed sizes, as metres around the lamp)
		preload("res://scripts/world/surface_materials.gd").add_haze_material(hm)
		q.material_override = hm
		q.extra_cull_margin = 4.0
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		q.visible = false
		mi.add_child(q)
		_halos[n] = q
	_lamps[n] = {"mat": m, "light": light, "emission": emission, "energy": energy}


const NAV_LIGHT := preload("res://shaders/nav_light.gdshader")
static var _halo_texture: Texture2D

## Soft round glow: a bright core with a quickly falling skirt.
static func _halo_tex() -> Texture2D:
	if _halo_texture:
		return _halo_texture
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(1, 1, 1, 1))
	g.add_point(0.12, Color(1, 1, 1, 0.85))
	g.add_point(0.35, Color(1, 1, 1, 0.22))
	g.set_offset(g.get_point_count() - 1, 1.0)
	g.set_color(g.get_point_count() - 1, Color(1, 1, 1, 0))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = 64
	t.height = 64
	_halo_texture = t
	return t


func _set_lamp(n: String, on: bool) -> void:
	if not _lamps.has(n) or _lamp_on.get(n) == on:
		return
	_lamp_on[n] = on
	var e: Dictionary = _lamps[n]
	var m: StandardMaterial3D = e.mat
	m.emission_energy_multiplier = e.emission if on else 0.0
	var l: OmniLight3D = e.light
	if l:
		# lights the airframe and the ground around it (never the cockpit interior: see its cull mask), so from
		# your own cockpit you see the glow on the wings and nose
		l.light_energy = e.energy if on else 0.0
		l.visible = on
	if _halos.has(n):
		(_halos[n] as Node3D).visible = on


func _in_cockpit() -> bool:
	var ck = aircraft.get("cockpit") if aircraft else null
	return ck != null and is_instance_valid(ck) and bool(ck.get("_inside"))


func _process(delta: float) -> void:
	if aircraft == null:
		return
	_t += delta
	lights_on = bool(aircraft.fm.lights_on)     # a switch in the simulation, so remote jets show theirs too
	var on: bool = lights_on and not aircraft.crashed

	# halos read strongly at night and only faintly by day (exposure follows the light level)
	var env: Environment = get_viewport().find_world_3d().environment if get_viewport() and get_viewport().find_world_3d() else null
	var night := 1.0
	if env:
		night = clampf((env.tonemap_exposure - 0.85) / 1.15, 0.12, 1.0)
	if absf(night - _night_set) > 0.005:
		_night_set = night
		for hn in _halos:
			var hq := _halos[hn] as MeshInstance3D
			var hmat := hq.material_override as ShaderMaterial
			hmat.set_shader_parameter("intensity", 2.2 * night)
	# navigation lights: steady
	for n in ["Light_Nav_L", "Light_Nav_R", "Light_Tail_L", "Light_Tail_R"]:
		_set_lamp(n, on)
	# red beacons: one flash per second, top and bottom alternate
	_set_lamp("Light_Beacon_Top", on and fmod(_t, 1.0) < 0.12)
	_set_lamp("Light_Beacon_Bottom", on and fmod(_t + 0.5, 1.0) < 0.12)
	# white strobes: double flash every 1.3 s
	var sp := fmod(_t, 1.3)
	var strobe := sp < 0.05 or (sp > 0.14 and sp < 0.19)
	_set_lamp("Light_Strobe_L", on and strobe)
	_set_lamp("Light_Strobe_R", on and strobe)
	# landing / taxi lights: only with the gear down and locked
	var land: bool = on and aircraft.gear_down and not aircraft.gear_player.is_playing()
	_set_lamp("Light_Landing_L", land)
	_set_lamp("Light_Landing_R", land)
	# the beams themselves only in poor light (by day they light nothing you would notice)
	var beams := land and night > 0.3
	for s in _landing:
		if s.visible != beams:
			s.visible = beams
			s.light_energy = float(s.get_meta("on_energy", 6.0)) if beams else 0.0

	# afterburner light: follows the burner, with the flame's flicker
	if _ab_light:
		var abl := clampf((float(aircraft.engine) - AB_THRESHOLD) / (1.0 - AB_THRESHOLD), 0.0, 1.0)
		_ab_light.visible = abl > 0.02
		if _ab_light.visible:
			var flick := 1.0 + 0.07 * sin(_t * 37.0) + 0.05 * sin(_t * 23.3 + 1.7) + 0.03 * sin(_t * 61.0)
			_ab_light.light_energy = AB_LIGHT_ENERGY * abl * flick
	# afterburner: glow inside the nozzle follows the engine, flame appears in reheat
	var eng: float = aircraft.engine
	if eng == _eng_set:
		return
	_eng_set = eng
	var ab := clampf((eng - AB_THRESHOLD) / (1.0 - AB_THRESHOLD), 0.0, 1.0)
	for m in _glow_mats:
		m.emission_energy_multiplier = 0.15 + eng * 0.8 + ab * 6.0
	for f in _flames:
		f.visible = ab > 0.02
		f.scale = Vector3(0.85 + 0.15 * ab, 0.85 + 0.15 * ab, 0.35 + 0.65 * ab)
	_flame_mat.set_shader_parameter("intensity", ab)
