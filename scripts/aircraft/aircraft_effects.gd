extends Node
## Presentation-only effects for any aircraft following the FlightOut model naming contract: exterior lights and afterburner.
## Reads state from the flight controller and never touches the physics,
## so a dedicated server can skip this node entirely.

const AB_THRESHOLD := 0.85
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


func setup(ac: Node3D, mdl: Node3D) -> void:
	aircraft = ac
	model = mdl
	var red := Color(1.0, 0.10, 0.06)
	var green := Color(0.15, 1.0, 0.35)
	var white := Color(1.0, 0.98, 0.92)
	# name, colour, lamp emission, light energy, light range
	_add_lamp("Light_Nav_L", red, 5.0, 0.8, 4.0)
	_add_lamp("Light_Nav_R", green, 5.0, 0.8, 4.0)
	_add_lamp("Light_Tail_L", white, 4.0, 0.5, 3.0)
	_add_lamp("Light_Tail_R", white, 4.0, 0.5, 3.0)
	_add_lamp("Light_Beacon_Top", red, 10.0, 2.5, 8.0)
	_add_lamp("Light_Beacon_Bottom", red, 10.0, 2.5, 8.0)
	_add_lamp("Light_Strobe_L", white, 16.0, 4.0, 10.0)
	_add_lamp("Light_Strobe_R", white, 16.0, 4.0, 10.0)
	_add_lamp("Light_Landing_L", white, 8.0, 0.0, 0.0)
	_add_lamp("Light_Landing_R", white, 8.0, 0.0, 0.0)
	for n in ["Light_Landing_L", "Light_Landing_R"]:
		var lamp := model.find_child(n, true, false) as Node3D
		if lamp:
			var spot := SpotLight3D.new()
			# model nose is +Z, a light shines down its -Z: turn it around and tip it 6 degrees down
			spot.basis = Basis(Vector3.UP, PI) * Basis(Vector3.RIGHT, deg_to_rad(-6.0))
			spot.spot_range = 450.0
			spot.spot_angle = 14.0
			spot.light_color = Color(1.0, 0.96, 0.85)
			spot.light_energy = 0.0
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
	_flame_mat = ShaderMaterial.new()
	_flame_mat.shader = FLAME_SHADER
	for n in ["AfterburnerFlame_L", "AfterburnerFlame_R"]:
		var f := model.find_child(n, true, false) as MeshInstance3D
		if f:
			f.material_override = _flame_mat
			f.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			f.visible = false
			_flames.append(f)


func _add_lamp(n: String, color: Color, emission: float, energy: float, light_range: float) -> void:
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
		mi.add_child(light)
	_lamps[n] = {"mat": m, "light": light, "emission": emission, "energy": energy}


func _set_lamp(n: String, on: bool) -> void:
	if not _lamps.has(n):
		return
	var e: Dictionary = _lamps[n]
	var m: StandardMaterial3D = e.mat
	m.emission_energy_multiplier = e.emission if on else 0.0
	var l: OmniLight3D = e.light
	if l:
		l.light_energy = e.energy if on else 0.0


func _process(delta: float) -> void:
	if aircraft == null:
		return
	_t += delta
	if Input.is_action_just_pressed("toggle_lights"):
		lights_on = not lights_on
	var on: bool = lights_on and not aircraft.crashed

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
	for s in _landing:
		s.light_energy = 6.0 if land else 0.0

	# afterburner: glow inside the nozzle follows the engine, flame appears in reheat
	var eng: float = aircraft.engine
	var ab := clampf((eng - AB_THRESHOLD) / (1.0 - AB_THRESHOLD), 0.0, 1.0)
	for m in _glow_mats:
		m.emission_energy_multiplier = 0.15 + eng * 0.8 + ab * 6.0
	for f in _flames:
		f.visible = ab > 0.02
		f.scale = Vector3(0.85 + 0.15 * ab, 0.85 + 0.15 * ab, 0.35 + 0.65 * ab)
	_flame_mat.set_shader_parameter("intensity", ab)
