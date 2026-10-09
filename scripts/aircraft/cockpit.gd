extends Node3D
## The Su-27S cockpit of the pilot's own jet. Loads the interior built by blender/build_cockpit.py, gives every
## part its game material by name, and drives instruments, lamps and controls from the simulation every frame.
##
## Naming contract with the Blender builder (glTF converts Blender Z-up to Godot Y-up):
##   GAU_<g>        gauge pivot; its local +Y is the face normal, toward the pilot
##   NDL_<g>_<n>    needles, rest pointing to 12 o'clock; they spin about their local Y
##   LMP_<id>       lamps (instance uniform `lit`), SCR_<id> screens, ANIM_<part> moving controls
##   CNP_Root       everything that rides on the canopy; reparented under the airframe's Canopy node
## Remote jets never load this: they keep the airframe's light placeholder interior.

const SCENE := "res://assets/aircraft/su27_cockpit/su27_cockpit.glb"
const TEX := "res://assets/aircraft/su27_cockpit/"
const Avionics = preload("res://scripts/sim/avionics.gd")
const PAINT_SHADER := preload("res://shaders/cockpit/cockpit_paint.gdshader")
const GLASS_SHADER := preload("res://shaders/cockpit/cockpit_glass.gdshader")
const LAMP_SHADER := preload("res://shaders/cockpit/cockpit_lamp.gdshader")
const HUD_SHADER := preload("res://shaders/cockpit/hud_combiner.gdshader")
const STD_SHADER := preload("res://shaders/cockpit/cockpit_std.gdshader")
const AP_FACE_SHADER := preload("res://shaders/cockpit/ap_face.gdshader")
const ApPanel = preload("res://scripts/avionics/ap_panel.gd")
const Mfd = preload("res://scripts/avionics/mfd.gd")
const Sensors = preload("res://scripts/avionics/sensors.gd")
const MFD_SHADER := preload("res://shaders/cockpit/mfd_screen.gdshader")
## MFD screens from the builder: id -> [width m, height m, side buttons, top/bottom keys, start page, page list]
const MFDS := {"MFD_L": [0.2, 0.15, 6, 5, "RDR", ["RDR", "SA", "SYS", "WPN", "EW"]],
	"MFD_C": [0.1, 0.15, 6, 3, "SYS", ["SYS", "EW", "WPN"]],
	"MFD_R": [0.2, 0.15, 6, 5, "SA", ["RDR", "SA", "SYS", "WPN", "EW"]]}
const SCREEN_Z := 0.0065               # the screen quad's height above its bezel frame (builder uv_quad z)
const HudDisplay = preload("res://scripts/avionics/hud_display.gd")
const NEEDLE_RATE := 14.0             # 1/s: needle damping, real instruments lag a little
const LAMP_RATE := 22.0               # 1/s: filament warm-up and fade
const LAMP_HOLD := 0.6                # s: a lamp that came on stays on at least this long (no flicker at a threshold)

var ac: Node3D
var _needles := {}                    # "IAS_0" -> [node, rest basis, shown angle (deg clockwise)]
var _lamps := {}                      # "WARN_3" -> [MeshInstance3D, ...]
var _lamp_lit := {}                   # MeshInstance3D -> shown brightness
var _lamp_hold := {}                  # lamp id -> seconds it must stay lit
var _movers := {}                     # "Stick" -> [node, rest transform]
var _ball: Node3D
var _ball_rest: Basis
var _card: Node3D
var _card_rest: Basis
var _fuel: Array = []                 # [node, rest position] x2
var _mats := {}
var _gear_lever := 1.0                # 1 down, 0 up (lever travel, smoothed)
var _shown_pitch := 0.0
var _shown_bank := 0.0
var ready_ok := false
# pilot: limb segments aimed by two-bone IK every frame (hands ride the stick and throttle, boots the pedals)
var _plt := {}                        # "ShoulderL", "WristL", "UpperArmL", ... -> Node3D
var _plt_all: Array = []              # every pilot part, [base name, node] (names can repeat)
var _head: Node3D
var _seat: Node3D
var _seat_rest := Vector3.ZERO
const LIMBS := {"UpperArm": 0.29, "Forearm": 0.25, "Thigh": 0.45, "Shin": 0.43}
## In the cockpit view you see your legs and nothing else of yourself (as in DCS): these parts stay visible.
const SEEN_FROM_INSIDE := ["Thigh", "Shin", "Boot", "Sole", "Ankle", "Hip", "Pelvis", "Root"]
# rear-view mirrors: one small camera looking aft from the canopy bow, its image split across both mirrors
var _mirrors := {}                   # "L"/"R" -> MeshInstance3D
var _mirror_vp: SubViewport
var _mirror_cam: Camera3D
const MIRROR_SIZE := Vector2i(448, 176)
# cockpit shadows: a tight first shadow cascade while inside, so small parts get crisp, steady shadows
var _sun: DirectionalLight3D
var _sun_splits := Vector3.ZERO
const COCKPIT_LAYER := 1 << 19          # visual layer 20, see aircraft_effects.gd
var _ck_meshes: Array[MeshInstance3D] = []   # meshes drawn with the precise cockpit transform
var _ck_sent := {}                      # MeshInstance3D -> last model-to-eye transform sent
var _precise_on := false
var _inside := false
# HUD: symbology drawn into a texture, shown collimated on the combiner glass
var _hud_vp: SubViewport
var _hud: Control
var _hud_mat: ShaderMaterial
var _hud_timer := 0.0
# autopilot panel under the HUD: a live face texture, knobs that turn, clicks and the mouse wheel
var _ap_face: MeshInstance3D
var _ap_mat: ShaderMaterial
var _ap_vp: SubViewport
var _ap_panel: Control
var _ap_knobs := {}                   # "SPD" -> [[node, rest basis], ...]
var _ap_wheel_t := {}                 # knob id -> time of the last wheel step (fast spins take bigger steps)
var _mfd_scr := {}                     # "MFD_L" -> screen MeshInstance3D
var _mfds := {}                        # "MFD_L" -> Mfd control
var _osb := {}                         # OSB node -> [mfd name, slot, rest position]
var _osb_down := {}                    # OSB node -> seconds it stays pressed in
var _shade := 0.0                      # HUD sun shade: 0 stowed .. 1 deployed
var _cabin := 0.0                      # cabin lighting shown: 0 off .. 1 on (fades)
var _glow_mats: Array[ShaderMaterial] = []   # instrument faces, needles, legends: integral lighting


func setup(aircraft: Node3D, model: Node3D) -> void:
	ac = aircraft
	process_priority = 100     # after the camera (priority 0) has placed the eye for this frame
	if not ResourceLoader.exists(SCENE):
		push_warning("Cockpit: %s not found, keeping the placeholder interior" % SCENE)
		return
	var root := (load(SCENE) as PackedScene).instantiate() as Node3D
	root.name = "Interior"
	add_child(root)
	_apply_materials(root)
	_index(root)
	var canopy := model.find_child("Canopy", true, false) as Node3D
	var cnp := root.find_child("CNP_Root", true, false) as Node3D
	if canopy and cnp:
		cnp.reparent(canopy, true)
	var old := model.find_child("Cockpit", true, false) as Node3D
	if old:
		old.visible = false
	_hide_airframe_glass(model)
	_setup_mirrors()
	_setup_hud(root)
	_setup_ap()
	_setup_mfds()
	_setup_cabin_lights(root)
	ready_ok = true


# ------------------------------------------------------------------ materials
func _apply_materials(root: Node) -> void:
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var lamp := m.name.begins_with("LMP_")
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			var mname := src.resource_name if src else ""
			# the windscreen is raked so steeply that canopy-grade reflections turn it milky: it gets its own, clearer glass
			if mname == "CP_CanopyGlass" and m.name.begins_with("WS_Glass"):
				mname = "CP_WindscreenGlass"
			var mat := _material(mname)
			if mat:
				m.set_surface_override_material(i, mat)
		if lamp:
			# round lamps carry no legend UVs
			var round := m.name.begins_with("LMP_C_") or m.name.begins_with("LMP_RWR") or m.name.begins_with("LMP_GEAR") or m.name.begins_with("LMP_HUD")
			m.set_instance_shader_parameter("use_legend", 0.0 if round else 1.0)
			m.set_instance_shader_parameter("lit", 0.0)
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if _is_glass(m) else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		# own render layer: the jet's exterior lights (beacons, strobes) cull it, so they never flash the cockpit
		m.layers = COCKPIT_LAYER
		var ours := true
		for i in m.mesh.get_surface_count():
			var sm := m.get_surface_override_material(i) as ShaderMaterial
			if sm == null or not sm.shader in [PAINT_SHADER, GLASS_SHADER, LAMP_SHADER, STD_SHADER, HUD_SHADER, AP_FACE_SHADER]:
				ours = false
		if ours:
			_ck_meshes.append(m)


func _is_glass(m: MeshInstance3D) -> bool:
	return m.name.begins_with("CNP_Glass") or m.name.begins_with("WS_Glass") or m.name.ends_with("Glass")


func _material(n: String) -> Material:
	if _mats.has(n):
		return _mats[n]
	var m: Material = null
	match n:
		# finishes (shaders/cockpit/cockpit_paint.gdshader): 0 enamel, 1 crinkle, 2 grained vinyl / leather,
		# 3 ribbed matting, 4 brushed metal, 5 moulded rubber / plastic, 6 woven fabric
		"CP_Paint": m = _paint(Color(0.34, 0.58, 0.57), Color(0.58, 0.58, 0.55), 0.5, 0.0, 0.7, 0)
		"CP_PaintDark": m = _paint(Color(0.085, 0.09, 0.095), Color(0.48, 0.48, 0.47), 0.62, 0.0, 0.7, 1)
		"CP_Metal": m = _paint(Color(0.62, 0.63, 0.64), Color(0.8, 0.8, 0.8), 0.34, 0.85, 0.95, 4)
		"CP_SteelDark": m = _paint(Color(0.2, 0.2, 0.21), Color(0.6, 0.6, 0.6), 0.42, 0.75, 0.9, 4)
		"CP_Rubber": m = _paint(Color(0.06, 0.06, 0.062), Color(0.16, 0.16, 0.15), 0.82, 0.0, 0.0, 5)
		"CP_Leather": m = _paint(Color(0.25, 0.185, 0.13), Color(0.38, 0.31, 0.24), 0.55, 0.0, 0.0, 2)
		"CP_Fabric": m = _paint(Color(0.38, 0.39, 0.29), Color(0.5, 0.5, 0.42), 0.92, 0.0, 0.0, 6)
		"CP_Pad": m = _paint(Color(0.13, 0.105, 0.085), Color(0.25, 0.21, 0.17), 0.58, 0.0, 0.0, 2)
		"CP_Glare": m = _paint(Color(0.035, 0.035, 0.037), Color(0.12, 0.12, 0.12), 0.66, 0.0, 0.0, 2)
		"CP_FloorMat": m = _paint(Color(0.05, 0.05, 0.052), Color(0.14, 0.14, 0.14), 0.85, 0.0, 0.0, 3)
		"CP_Yellow": m = _paint(Color(0.92, 0.72, 0.12), Color(0.55, 0.55, 0.52), 0.5, 0.0, 0.7)
		"CP_Red": m = _paint(Color(0.70, 0.11, 0.07), Color(0.55, 0.55, 0.52), 0.5, 0.0, 0.7)
		"CP_Seal": m = _paint(Color(0.055, 0.055, 0.055), Color(0.12, 0.12, 0.12), 0.85, 0.0, 0.0, 5)
		"CP_Gauge":
			# faces, the ADI ball and the HSI card; the ADI bezel and HSI overlay have clear centres
			var s := _standard(Color.WHITE, 0.55, 0.0)
			s.set_shader_parameter("albedo_tex", load(TEX + "instruments.png"))
			s.set_shader_parameter("scissor", 0.5)
			m = s
		"CP_Label":
			var s := _standard(Color(0.95, 0.95, 0.92), 0.7, 0.0)
			s.set_shader_parameter("albedo_tex", load(TEX + "labels.png"))
			s.set_shader_parameter("scissor", 0.45)
			m = s
		"CP_Needle":
			m = _standard(Color(0.93, 0.92, 0.85), 0.5, 0.0)
			(m as ShaderMaterial).set_shader_parameter("glow_threshold", 0.3)
		"CP_Orange": m = _standard(Color(0.98, 0.52, 0.08), 0.5, 0.0)
		"CP_Screen":
			var s := _standard(Color(0.02, 0.035, 0.03), 0.15, 0.0)
			s.set_shader_parameter("emission_c", Color(0.05, 0.12, 0.08))
			s.set_shader_parameter("emission_e", 0.15)
			m = s
		"CP_Mirror": m = _standard(Color(0.9, 0.9, 0.9), 0.03, 1.0)
		"CP_CanopyGlass": m = _glass(Color(0.88, 0.95, 0.93), 0.05, 0.6, 0.02, 1.0, 0.35)
		"CP_WindscreenGlass":
			m = _glass(Color(0.86, 0.93, 0.91), 0.015, 0.16, 0.02, 0.35, 0.05)
			(m as ShaderMaterial).set_shader_parameter("fresnel_power", 6.0)
		"CP_GlassEdge": m = _glass(Color(0.32, 0.55, 0.47), 0.7, 0.2, 0.05, 0.0, 0.0)
		"CP_GaugeGlass": m = _glass(Color(0.95, 0.95, 0.95), 0.03, 0.3, 0.02, 0.3, 0.0)
		"CP_HUDGlass": m = _glass(Color(0.55, 0.85, 0.65), 0.12, 0.45, 0.02, 0.2, 0.0)
		"CP_HUDShade": m = _glass(Color(0.16, 0.2, 0.15), 0.62, 0.25, 0.03, 0.15, 0.0)
		"CP_MFD": m = _standard(Color(0.01, 0.02, 0.015), 0.15, 0.0)      # replaced per screen in _setup_mfds
		"CP_APFace":
			_ap_mat = ShaderMaterial.new()
			_ap_mat.shader = AP_FACE_SHADER
			m = _ap_mat
		"CP_Frame": m = _paint(Color(0.47, 0.64, 0.67), Color(0.72, 0.73, 0.74), 0.45, 0.25, 0.9)
		"CP_Suit": m = _paint(Color(0.43, 0.44, 0.33), Color(0.47, 0.47, 0.37), 0.88, 0.0, 0.0)
		"CP_GSuit": m = _paint(Color(0.34, 0.36, 0.26), Color(0.38, 0.4, 0.3), 0.85, 0.0, 0.0)
		"CP_Helmet": m = _paint(Color(0.8, 0.81, 0.78), Color(0.55, 0.55, 0.52), 0.32, 0.0, 0.0)
		"CP_Mask": m = _paint(Color(0.26, 0.28, 0.23), Color(0.3, 0.32, 0.27), 0.7, 0.0, 0.0)
		"CP_Glove": m = _paint(Color(0.2, 0.17, 0.14), Color(0.3, 0.26, 0.21), 0.6, 0.0, 0.0)
		"CP_Boot": m = _paint(Color(0.12, 0.12, 0.12), Color(0.22, 0.22, 0.21), 0.5, 0.0, 0.0)
		"CP_Visor": m = _glass(Color(0.25, 0.2, 0.12), 0.55, 0.35, 0.03, 0.2, 0.0)
		"CP_LampRed": m = _lamp(Color(1.0, 0.16, 0.08))
		"CP_LampAmber": m = _lamp(Color(1.0, 0.62, 0.12))
		"CP_LampGreen": m = _lamp(Color(0.35, 1.0, 0.35))
		"CP_LampWhite": m = _lamp(Color(0.95, 0.95, 0.9))
	_mats[n] = m
	return m


func _paint(base: Color, under: Color, rough: float, metal: float, under_metal: float, finish := 0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = PAINT_SHADER
	m.set_shader_parameter("base_color", base)
	m.set_shader_parameter("under_color", under)
	m.set_shader_parameter("roughness_base", rough)
	m.set_shader_parameter("metallic_base", metal)
	m.set_shader_parameter("under_metallic", under_metal)
	m.set_shader_parameter("finish", finish)
	return m


func _standard(c: Color, rough: float, metal: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = STD_SHADER
	m.set_shader_parameter("albedo", c)
	m.set_shader_parameter("roughness_v", rough)
	m.set_shader_parameter("metallic_v", metal)
	return m


func _glass(tint: Color, base_alpha: float, fresnel: float, rough: float, scratches: float, haze: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GLASS_SHADER
	m.set_shader_parameter("tint", tint)
	m.set_shader_parameter("base_alpha", base_alpha)
	m.set_shader_parameter("fresnel_alpha", fresnel)
	m.set_shader_parameter("roughness_base", rough)
	m.set_shader_parameter("scratches", scratches)
	m.set_shader_parameter("haze", haze)
	m.render_priority = 1
	return m


func _lamp(tint: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = LAMP_SHADER
	m.set_shader_parameter("legend", load(TEX + "labels.png"))
	m.set_shader_parameter("tint", tint)
	return m


## The airframe's thin single-surface glass is replaced by the cockpit's thick glass (seen from inside and out).
func _hide_airframe_glass(model: Node) -> void:
	var hidden := StandardMaterial3D.new()
	hidden.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	hidden.albedo_color = Color(0, 0, 0, 0)
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null or is_ancestor_of(m):
			continue
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			if src and src.resource_name.begins_with("M_Su27_Glass"):
				m.set_surface_override_material(i, hidden)


# ------------------------------------------------------------------ indexing
static func _base_name(n: String) -> String:
	# Blender's .001 duplicates arrive as _001 (or keep the dot): strip either
	var r := RegEx.create_from_string("([._]\\d{3})+$")
	return r.sub(n, "")


func _index(root: Node) -> void:
	for n in root.find_children("*", "", true, false):
		var node := n as Node3D
		if node == null:
			continue
		var nm := _base_name(String(node.name))
		if nm.begins_with("NDL_"):
			var key := nm.substr(4)
			if key.begins_with("FUEL_"):
				_fuel.append([node, node.position])
			else:
				_needles[key] = [node, node.basis, 0.0]
		elif nm.begins_with("LMP_"):
			var id := nm.substr(4)
			if not _lamps.has(id):
				_lamps[id] = []
			_lamps[id].append(node)
			_lamp_lit[node] = 0.0
		elif nm == "ANIM_ADI_Ball":
			_ball = node
			_ball_rest = node.basis
		elif nm == "ANIM_HSI_Card":
			_card = node
			_card_rest = node.basis
		elif nm == "ANIM_Seat":
			_seat = node
			_seat_rest = node.position
		elif nm.begins_with("ANIM_") and not (node is MeshInstance3D) and nm.find("_CP_") < 0:
			_movers[nm.substr(5)] = [node, node.transform]
		elif nm.begins_with("OSB_"):
			# OSB_MFD_L_T3 -> MFD_L, T3
			var parts := nm.substr(4).split("_")
			if parts.size() >= 3:
				_osb[node] = [parts[0] + "_" + parts[1], parts[2], node.position]
		elif nm.begins_with("SCR_MFD_"):
			_mfd_scr[nm.substr(4)] = node
		elif nm == "AP_Face":
			_ap_face = node as MeshInstance3D
		elif nm.begins_with("AP_KNOB_"):
			var kid := nm.substr(8).get_slice("_", 0)
			if not _ap_knobs.has(kid):
				_ap_knobs[kid] = []
			_ap_knobs[kid].append([node, node.basis])
		elif nm == "CNP_MirrorL" or nm == "CNP_MirrorR":
			_mirrors[nm.right(1)] = node
		elif nm == "PLT_Head":
			_head = node
		elif nm.begins_with("PLT_"):
			_plt[nm.substr(4)] = node
			_plt_all.append([nm.substr(4), node])
	_fuel.sort_custom(func(a, b): return String(a[0].name) < String(b[0].name))


# ------------------------------------------------------------------ per frame
func _process(delta: float) -> void:
	if not ready_ok or ac == null or ac.fm == null:
		return
	var fm = ac.fm
	var k := 1.0 - exp(-NEEDLE_RATE * delta)
	var agl: float = ac.altitude_agl
	var ias_kmh: float = ac.ias * 3.6
	var rpm: float = ac.rpm
	var rpm2: float = fm.engines[1].n2 if fm.engines.size() > 1 else rpm
	var egt := func(n2: float, ab: float) -> float: return 300.0 + clampf((n2 - 20.0) / 80.0, 0.0, 1.0) * 480.0 + ab * 140.0
	var ab2: float = fm.engines[1].ab if fm.engines.size() > 1 else ac.ab_stage
	var t := Time.get_time_dict_from_system()
	var sec: float = t.second + (Time.get_ticks_msec() % 1000) / 1000.0
	var running := rpm > 50.0
	var hyd := clampf((rpm - 15.0) / 45.0, 0.0, 1.0) * 215.0
	var brake: float = 10.0 * fm.in_brake if running or fm.in_brake > 0.0 else 0.0

	_needle("AOA_G_0", lerpf(205.0, 335.0, (clampf(ac.aoa_deg, -10.0, 35.0) + 10.0) / 45.0), k)
	_needle("AOA_G_1", lerpf(155.0, 25.0, (clampf(ac.g_load, -2.0, 10.0) + 2.0) / 12.0), k)
	_needle("IAS_0", -150.0 + clampf(ias_kmh, 0.0, 1600.0) / 1600.0 * 300.0, k)
	_needle("IAS_1", -135.0 + (clampf(ac.mach, 0.6, 3.0) - 0.6) / 2.4 * 270.0, k)
	_needle("RADALT_0", _radalt_angle(agl), k)
	var alt: float = ac.global_position.y - WorldData.sea_level if "sea_level" in WorldData else ac.global_position.y
	_needle("BARO_0", fposmod(alt, 1000.0) / 1000.0 * 360.0, k, true)
	_needle("BARO_1", fposmod(alt, 10000.0) / 10000.0 * 360.0, k, true)
	_needle("VVI_0", _vvi_angle(ac.vertical_speed), k)
	_needle("CLOCK_0", fmod(t.hour + t.minute / 60.0, 12.0) / 12.0 * 360.0, 1.0, true)
	_needle("CLOCK_1", (t.minute + sec / 60.0) / 60.0 * 360.0, 1.0, true)
	_needle("CLOCK_2", floorf(sec) / 60.0 * 360.0, 1.0, true)
	_needle("FLAPS_0", -90.0 + fm.flap_pos * 30.0 / 30.0 * 180.0, k)
	_needle("BRAKE_0", -135.0 + brake / 16.0 * 270.0, k)
	_needle("BRAKE_1", -135.0 + brake / 16.0 * 270.0, k)
	_needle("HYD_0", -135.0 + hyd / 300.0 * 270.0, k)
	_needle("HYD_1", -135.0 + hyd * 0.98 / 300.0 * 270.0, k)
	_needle("OXY_0", -135.0 + 118.0 / 150.0 * 270.0, k)
	_needle("OXY2_0", -135.0 + 118.0 / 150.0 * 270.0, k)
	var cabin_km := clampf(alt / 1000.0 * 0.45, 0.0, 20.0) if alt > 2000.0 else alt / 1000.0
	_needle("CABIN_0", -80.0 + clampf(cabin_km, 0.0, 20.0) / 20.0 * 160.0, k)
	_needle("CABIN_1", 260.0 - (clampf((alt - cabin_km * 1000.0) / 25000.0 * 0.4, 0.0, 0.6) + 0.1) / 0.7 * 160.0, k)
	_needle("RPM_0", -135.0 + clampf(rpm, 0.0, 110.0) / 110.0 * 270.0, k)
	_needle("RPM_1", -135.0 + clampf(rpm2, 0.0, 110.0) / 110.0 * 270.0, k)
	_needle("EGT_0", -135.0 + (egt.call(rpm, ac.ab_stage) - 300.0) / 800.0 * 270.0, k)
	_needle("EGT_1", -135.0 + (egt.call(rpm2, ab2) - 300.0) / 800.0 * 270.0, k)

	# attitude ball, compass card, bearing to home
	var b: Basis = fm.rot
	var fwd := -b.z
	var pitch := asin(clampf(fwd.y, -1.0, 1.0))
	var bank := atan2(-b.x.y, b.y.y)
	_shown_pitch = lerpf(_shown_pitch, pitch, k)
	_shown_bank = lerp_angle(_shown_bank, bank, k)
	if _ball:
		_ball.basis = _ball_rest * Basis(Vector3.UP, _shown_bank) * Basis(Vector3.RIGHT, _shown_pitch)
	var hdg := deg_to_rad(ac.heading_deg)
	if _card:
		_card.basis = _card_rest * Basis(Vector3.UP, hdg)
	var d: Vector3 = WorldData.home_position() - ac.global_position     # the HSI needle points home
	var brg := rad_to_deg(atan2(d.x, -d.z))
	_needle("HSI_0", brg - ac.heading_deg, k, true)

	# fuel tape pointers: TOTAL (left, 0..9 t) and FEED tank (right, 0..1.5 t)
	var fuel: float = ac.fuel_kg
	if _fuel.size() >= 2:
		_slide(_fuel[0], -0.0504 + clampf(fuel / 9000.0, 0.0, 1.0) * 0.1064)
		_slide(_fuel[1], -0.0504 + clampf(minf(fuel, 1300.0) / 1500.0, 0.0, 1.0) * 0.1064)

	_update_lamps(delta, agl, running, rpm)
	_update_controls(delta)
	_update_pilot()
	_update_hud(delta)
	_update_ap(delta)
	_update_mfds(delta)
	_update_shade(delta)
	_update_cabin_lights(delta)
	_update_precise()
	_update_torch(delta)


## Model -> eye transform for every cockpit mesh, built only from aircraft-relative numbers (see
## shaders/include/cockpit_precise.gdshaderinc). Runs after the camera has placed itself this frame
## (process_priority), so the eye used here is exactly the one being rendered.
func _update_precise() -> void:
	var cam := get_viewport().get_camera_3d()
	var on: bool = _inside and cam != null and cam.get("target") == ac and int(cam.get("view")) == 3
	if not on:
		if _precise_on:
			_precise_on = false
			_ck_sent.clear()
			for m in _ck_meshes:
				if is_instance_valid(m):
					m.set_instance_shader_parameter("ck_on", 0.0)
		return
	var eye := Transform3D(cam.get("_ck_look") as Basis, cam.get("_ck_eye") as Vector3).affine_inverse()
	for m in _ck_meshes:
		if not is_instance_valid(m) or m.material_override != null or not m.is_visible_in_tree():
			continue
		var p := eye * _aircraft_space(m)
		var last = _ck_sent.get(m)
		if last != null and (last as Transform3D).is_equal_approx(p):
			continue
		_ck_sent[m] = p
		var b := p.basis
		m.set_instance_shader_parameter("ck_r0", Vector4(b.x.x, b.y.x, b.z.x, p.origin.x))
		m.set_instance_shader_parameter("ck_r1", Vector4(b.x.y, b.y.y, b.z.y, p.origin.y))
		m.set_instance_shader_parameter("ck_r2", Vector4(b.x.z, b.y.z, b.z.z, p.origin.z))
		if last == null:
			m.set_instance_shader_parameter("ck_on", 1.0)
	_precise_on = true


## A node's transform relative to the aircraft root: the product of local transforms up the tree, so no
## world-sized number ever enters it.
func _aircraft_space(n: Node3D) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p != null and p != ac:
		var p3 := p as Node3D
		if p3:
			t = p3.transform * t
		p = p.get_parent()
	return t


func _needle(key: String, deg: float, k: float, wrap := false) -> void:
	if not _needles.has(key):
		return
	var e: Array = _needles[key]
	var shown: float = e[2]
	if wrap:
		shown = rad_to_deg(lerp_angle(deg_to_rad(shown), deg_to_rad(deg), k))
	else:
		shown = lerpf(shown, deg, k)
	e[2] = shown
	(e[0] as Node3D).basis = (e[1] as Basis) * Basis(Vector3.UP, -deg_to_rad(shown))


func _slide(e: Array, y: float) -> void:
	var n := e[0] as Node3D
	var target: Vector3 = (e[1] as Vector3) + Vector3(0.0, 0.0, -y)
	n.position = n.position.lerp(target, 0.15)


static func _radalt_angle(v: float) -> float:
	v = clampf(v, 0.0, 1000.0)
	if v <= 100.0:
		return -150.0 + v / 100.0 * 180.0
	return 30.0 + log(v / 100.0) / log(10.0) * 120.0


static func _vvi_angle(v: float) -> float:
	var av := absf(v)
	var d := 0.0
	if av <= 10.0:
		d = av / 10.0 * 60.0
	elif av <= 50.0:
		d = 60.0 + (av - 10.0) / 40.0 * 60.0
	else:
		d = 120.0 + (minf(av, 150.0) - 50.0) / 100.0 * 40.0
	return 270.0 + d * signf(v)


func _update_lamps(delta: float, agl: float, running: bool, rpm: float) -> void:
	var fm = ac.fm
	var on := {}
	on["WARN_2"] = ac.fuel_kg < Avionics.LOW_FUEL_KG + 200.0
	on["WARN_3"] = rpm < 55.0
	on["WARN_4"] = rpm < 45.0
	on["WARN_5"] = rpm < 45.0
	on["WARN_6"] = rpm < 45.0
	on["WARN_7"] = not ac.aoa_limiter
	on["WARN_9"] = ac.stall_frac > 0.5
	on["WARN_10"] = ac.canopy_open
	var mode := int(ac.master_mode)
	for i in 4:
		on["MODE_%d" % i] = mode == i
	var locked: bool = fm.gear_down and fm.gear_pos > 0.98
	on["GEAR_N"] = locked
	on["GEAR_L"] = locked
	on["GEAR_R"] = locked
	on["GEAR_UNSAFE"] = (fm.gear_pos > 0.01 and fm.gear_pos < 0.99) or (not fm.gear_down and agl < 300.0 and ac.vertical_speed < -1.5 and ac.ias < 110.0)
	on["C_FLAPS"] = fm.flap_pos > 0.5
	on["C_CHAFF"] = 0.45
	on["C_FLARE"] = 0.45
	on["PL_AUTO"] = ac.autothrottle
	on["PL_START"] = not running and ac.throttle > 0.05
	var kk := 1.0 - exp(-LAMP_RATE * delta)
	for id in _lamps:
		var want: float = 0.0
		if on.has(id):
			var v = on[id]
			want = (1.0 if v else 0.0) if typeof(v) == TYPE_BOOL else float(v)
		var hold: float = _lamp_hold.get(id, 0.0)
		hold = LAMP_HOLD if want >= 0.5 else maxf(hold - delta, 0.0)
		_lamp_hold[id] = hold
		if hold > 0.0:
			want = maxf(want, 1.0)
		for m in _lamps[id]:
			var cur: float = _lamp_lit[m]
			var nxt := lerpf(cur, want, kk)
			if absf(nxt - cur) > 0.002 or (want == 0.0 and cur != 0.0 and nxt < 0.002):
				if nxt < 0.002:
					nxt = 0.0
				_lamp_lit[m] = nxt
				(m as GeometryInstance3D).set_instance_shader_parameter("lit", nxt)


func _update_controls(delta: float) -> void:
	var k := 1.0 - exp(-18.0 * delta)
	if _movers.has("Stick"):
		var e: Array = _movers["Stick"]
		var rest: Transform3D = e[1]
		var want := rest.basis * Basis(Vector3(0, 0, 1), deg_to_rad(12.0) * ac.roll_in) * Basis(Vector3.RIGHT, -deg_to_rad(14.0) * ac.pitch_in)
		(e[0] as Node3D).basis = (e[0] as Node3D).basis.slerp(want.orthonormalized(), k)
	if _movers.has("Throttle"):
		var e: Array = _movers["Throttle"]
		var thr: float = ac.throttle
		var mil: float = ac.spec.ab_threshold
		# slides along the quadrant slot (not a pivot): IDLE at the back, MIL detent, afterburner up to MAX
		var slide := lerpf(-0.19, 0.02, thr / mil) if thr <= mil else lerpf(0.02, 0.18, (thr - mil) / maxf(1.0 - mil, 0.01))
		var rest: Transform3D = e[1]
		var want := rest.origin + rest.basis * Vector3(0.0, 0.0, -slide)
		var node := e[0] as Node3D
		node.basis = rest.basis
		node.position = node.position.lerp(want, k)
	for side in [["PedalL", -1.0], ["PedalR", 1.0]]:
		if _movers.has(side[0]):
			var e: Array = _movers[side[0]]
			var rest: Transform3D = e[1]
			(e[0] as Node3D).position = rest.origin + Vector3(0.0, 0.0, 0.06 * ac.yaw_in * float(side[1]))
	if _movers.has("GearLever"):
		# a real lever: it pivots in its housing, handle down for gear down, up for gear up
		var e: Array = _movers["GearLever"]
		var rest: Transform3D = e[1]
		_gear_lever = move_toward(_gear_lever, 1.0 if ac.gear_down else 0.0, delta * 5.0)
		var ang := deg_to_rad(lerpf(-32.0, 32.0, _gear_lever))
		(e[0] as Node3D).basis = rest.basis * Basis(Vector3.RIGHT, ang)


# ------------------------------------------------------------------ pilot
func _update_pilot() -> void:
	if _seat:
		_seat.position = _seat_rest + Vector3(0.0, clampf(float(Settings.get_value("cockpit/seat_height")), -0.06, 0.06), 0.0)
	# inside: only the legs are yours to see; outside: the whole pilot
	var cam := get_viewport().get_camera_3d()
	var inside: bool = cam != null and "view_name" in cam and String(cam.view_name) == "COCKPIT" and cam.get("target") == ac
	if inside != _inside:
		_inside = inside
		if _head:
			_head.visible = not inside
		for e in _plt_all:
			var key: String = e[0]
			var keep := false
			for k in SEEN_FROM_INSIDE:
				if key.contains(k):
					keep = true
			(e[1] as Node3D).visible = keep or not inside
		_set_cockpit_shadows(inside)
		if _mirror_vp:
			_mirror_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if inside else SubViewport.UPDATE_DISABLED
	if inside:
		_update_mirror_camera()
	var b: Basis = global_basis
	for side in [["L", 1.0], ["R", -1.0]]:
		var sd: String = side[0]
		var sx: float = side[1]
		# arms: elbows out, down and a little back; legs: knees up and forward, slightly apart
		_limb("Shoulder" + sd, "Wrist" + sd, "UpperArm" + sd, "Forearm" + sd, b * Vector3(0.3 * sx, -0.35, -0.1))
		_limb("Hip" + sd, "Ankle" + sd, "Thigh" + sd, "Shin" + sd, b * Vector3(0.12 * sx, 0.5, 0.4))


func _limb(root_key: String, end_key: String, upper_key: String, lower_key: String, pole_dir: Vector3) -> void:
	var r: Node3D = _plt.get(root_key)
	var e: Node3D = _plt.get(end_key)
	var u: Node3D = _plt.get(upper_key)
	var l: Node3D = _plt.get(lower_key)
	if r == null or e == null or u == null or l == null:
		return
	var l1: float = LIMBS[upper_key.left(upper_key.length() - 1)]
	var l2: float = LIMBS[lower_key.left(lower_key.length() - 1)]
	var a := r.global_position
	var t := e.global_position
	var d := t - a
	var dist := clampf(d.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var dir := d.normalized()
	var x := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - x * x, 0.0))
	var side := pole_dir - dir * pole_dir.dot(dir)
	if side.length_squared() < 1e-6:
		side = global_basis.y
	side = side.normalized()
	var elbow := a + dir * x + side * h
	_aim(u, a, elbow, side)
	_aim(l, elbow, a + dir * dist, side)


## A limb segment runs along its local -Y (Blender -Z) from its origin; point it from `from` to `to`.
func _aim(n: Node3D, from: Vector3, to: Vector3, side: Vector3) -> void:
	var y := (from - to).normalized()
	var x := side.cross(y).normalized()
	var z := x.cross(y)
	n.global_transform = Transform3D(Basis(x, y, z), from)


# ------------------------------------------------------------------ mirrors
func _setup_mirrors() -> void:
	if _mirrors.is_empty():
		return
	_mirror_vp = SubViewport.new()
	_mirror_vp.name = "MirrorView"
	_mirror_vp.size = MIRROR_SIZE
	_mirror_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_mirror_vp.msaa_3d = Viewport.MSAA_DISABLED
	_mirror_vp.positional_shadow_atlas_size = 0
	add_child(_mirror_vp)
	_mirror_cam = Camera3D.new()
	_mirror_cam.fov = 62.0
	_mirror_cam.near = 0.05
	_mirror_cam.far = 20000.0
	_mirror_cam.compositor = Compositor.new()     # no volumetric clouds in the mirrors: they cost a full pass
	_mirror_vp.add_child(_mirror_cam)
	_mirror_cam.current = true
	var tex := _mirror_vp.get_texture()
	# the camera looks aft; a mirror shows that image flipped, left half on the left mirror
	for side in _mirrors:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_texture = tex
		m.albedo_color = Color(0.86, 0.88, 0.9)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
		m.uv1_scale = Vector3(-0.5, 1.0, 1.0)
		m.uv1_offset = Vector3(1.0 if side == "L" else 0.5, 0.0, 0.0)
		(_mirrors[side] as MeshInstance3D).material_override = m


func _update_mirror_camera() -> void:
	if _mirror_cam == null or not _mirrors.has("L") or not _mirrors.has("R"):
		return
	var a: Vector3 = (_mirrors["L"] as Node3D).global_transform * (_mirrors["L"] as MeshInstance3D).get_aabb().get_center()
	var b: Vector3 = (_mirrors["R"] as Node3D).global_transform * (_mirrors["R"] as MeshInstance3D).get_aabb().get_center()
	var basis := ac.global_basis
	var pos := (a + b) * 0.5 + basis.y * 0.06
	# aircraft forward is -Z: look along +Z (aft), slightly down over the seat
	var back := (basis.z - basis.y * 0.08).normalized()
	_mirror_cam.global_transform = Transform3D(Basis.looking_at(back, basis.y), pos)


# ------------------------------------------------------------------ shadows
func _set_cockpit_shadows(inside: bool) -> void:
	if _sun == null:
		for l in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
			if (l as DirectionalLight3D).shadow_enabled:
				_sun = l
				_sun_splits = Vector3(_sun.directional_shadow_split_1, _sun.directional_shadow_split_2, _sun.directional_shadow_split_3)
				break
	if _sun == null:
		return
	if inside:
		var far := maxf(_sun.directional_shadow_max_distance, 10.0)
		_sun.directional_shadow_split_1 = clampf(2.5 / far, 0.002, _sun_splits.x)
		_sun.directional_shadow_split_2 = clampf(30.0 / far, _sun.directional_shadow_split_1 + 0.01, _sun_splits.y)
	else:
		_sun.directional_shadow_split_1 = _sun_splits.x
		_sun.directional_shadow_split_2 = _sun_splits.y
		_sun.directional_shadow_split_3 = _sun_splits.z


func _exit_tree() -> void:
	if _inside:
		_set_cockpit_shadows(false)


# ------------------------------------------------------------------ HUD
func _setup_hud(root: Node) -> void:
	var targets: Array = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for i in m.mesh.get_surface_count():
			var src := m.mesh.surface_get_material(i)
			if src and src.resource_name == "CP_HUDGlass":
				targets.append([m, i])
	if targets.is_empty():
		return
	_hud_vp = SubViewport.new()
	_hud_vp.name = "HudView"
	_hud_vp.size = Vector2i(HudDisplay.SIZE, HudDisplay.SIZE)
	_hud_vp.transparent_bg = true
	_hud_vp.disable_3d = true
	_hud_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_hud_vp)
	_hud = HudDisplay.new()
	_hud.ac = ac
	_hud_vp.add_child(_hud)
	_hud_mat = ShaderMaterial.new()
	_hud_mat.shader = HUD_SHADER
	_hud_mat.set_shader_parameter("hud_tex", _hud_vp.get_texture())
	_hud_mat.set_shader_parameter("fov_deg", HudDisplay.HUD_FOV)
	_hud_mat.set_shader_parameter("el0", HudDisplay.TEX_EL0)
	_hud_mat.set_shader_parameter("window", Vector4(-HudDisplay.WIN_AZ - 0.35, HudDisplay.WIN_AZ + 0.35, HudDisplay.WIN_BOT - 0.35, HudDisplay.WIN_TOP + 0.35))
	_hud_mat.render_priority = 2
	for t in targets:
		(t[0] as MeshInstance3D).set_surface_override_material(t[1], _hud_mat)


# ------------------------------------------------------------------ multifunction displays
func _setup_mfds() -> void:
	if ac.get("sensors") == null:
		var sn = Sensors.new()
		sn.ac = ac
		ac.set("sensors", sn)
	for name in _mfd_scr:
		if not MFDS.has(name):
			continue
		var cfg: Array = MFDS[name]
		var vp := SubViewport.new()
		vp.size = Vector2i(1024, 768) if float(cfg[0]) > 0.15 else Vector2i(512, 768)
		vp.disable_3d = true
		vp.transparent_bg = false
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var page := Mfd.new()
		page.ac = ac
		page.size = Vector2(vp.size)
		page.setup(name.substr(4), cfg[0], cfg[1], cfg[2], cfg[3], cfg[4], cfg[5])
		if name == "MFD_R" and "--dev-wpn" in OS.get_cmdline_user_args():
			page.page = "WPN"          # development: show the stores page
		vp.add_child(page)
		_mfds[name] = page
		var mat := ShaderMaterial.new()
		mat.shader = MFD_SHADER
		mat.set_shader_parameter("screen_tex", vp.get_texture())
		var mi := _mfd_scr[name] as MeshInstance3D
		for i in mi.mesh.get_surface_count():
			mi.set_surface_override_material(i, mat)


func _update_mfds(delta: float) -> void:
	var sn = ac.get("sensors")
	if sn:
		sn.update(delta)
	for name in _mfds:
		(_mfds[name] as Control).call("tick", delta)
	# pressed bezel buttons sit 2 mm in for a moment
	for node in _osb:
		var n := node as Node3D
		var rest: Vector3 = _osb[node][2]
		var down: float = _osb_down.get(node, 0.0)
		if down > 0.0:
			_osb_down[node] = down - delta
			n.position = rest + n.basis * Vector3(0.0, -0.0022, 0.0)
		elif n.position != rest:
			n.position = rest


# ------------------------------------------------------------------ cabin lighting
## Night lighting, kept extremely subtle (separate from the exterior lights, L):
##   integral lighting   instrument markings, needles and panel legends are faintly backlit
##   floodlighting       baked into the cockpit model (blender/build_cockpit.py CABIN_LAMPS: lamps under the
##                       glareshield and along the canopy sills, with soft shadows) and shown as a faint lift of
##                       the surfaces: it reads as light, but nothing is lit in real time, so nothing glares or
##                       reflects in the canopy and HUD glass
## Switched with the cockpit lights key (ac.cabin_lights); fades in and out like a dimmer.
const CABIN_GLOW := 0.12          # instrument backlighting
var CABIN_LIFT := 0.08            # painted surfaces: lift where the baked floodlight is full (fades in its shadows)
const CABIN_LIFT_PLAIN := 0.006   # other surfaces (no baked light): a trace only

var _backlit: Array[ShaderMaterial] = []      # instrument faces and legends (not frames that share needle white)

func _setup_cabin_lights(_root: Node3D) -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cabin-lift="):      # dev: tune the floodlight strength
			CABIN_LIFT = a.get_slice("=", 1).to_float()
	for n in _mats:
		var m = _mats[n]
		if m is ShaderMaterial and (m.shader == PAINT_SHADER or m.shader == STD_SHADER):
			_glow_mats.append(m)
			if n in ["CP_Gauge", "CP_Label"]:
				_backlit.append(m)


func _update_cabin_lights(delta: float) -> void:
	var want := 1.0 if bool(ac.get("cabin_lights")) else 0.0
	if is_equal_approx(_cabin, want):
		return
	_cabin = move_toward(_cabin, want, delta * 2.5)
	for m in _glow_mats:
		m.set_shader_parameter("cabin", (CABIN_LIFT if m.shader == PAINT_SHADER else CABIN_LIFT_PLAIN) * _cabin)
		if m in _backlit:
			m.set_shader_parameter("glow", CABIN_GLOW * _cabin)


# ------------------------------------------------------------------ flashlight
## The pilot's handheld torch (ac.torch): a small spot held just below and right of the eyes, aimed where the
## pilot looks, with a little hand lag so it sweeps rather than snaps. A tight bright centre that falls off to
## a soft edge, a short throw (it is a cockpit torch, not a searchlight) and soft shadows. It lights only the
## cockpit layer and has almost no specular, so it does not flare in the canopy or HUD glass.
const TORCH_HAND := Vector3(0.07, -0.09, -0.02)   # from the eye, in the view's frame
const TORCH_ANGLE := 20.0                         # deg, half angle of the cone (most of it is the soft fall-off)
const TORCH_RANGE := 1.6                          # m
var TORCH_ENERGY := 0.4
const TORCH_LAG := 14.0                           # how quickly the beam follows the view (1/s)
var _torch: SpotLight3D
var _torch_aim := Basis()
var _torch_k := 0.0

var _dev_t := 0.0
var _dev_press := -1.0

## dev: press the torch key after N seconds (--press-torch-at=N), to test the switch the way a player uses it
func _physics_process(delta: float) -> void:
	_dev_t += delta
	if _dev_press == -1.0 and _dev_t < 0.05:
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--press-torch-at="):
				_dev_press = arg.get_slice("=", 1).to_float()
	if _dev_press > 0.0 and _dev_t >= _dev_press:
		_dev_press = -2.0
		var ev := InputEventAction.new()
		ev.action = "toggle_torch"
		ev.pressed = true
		Input.parse_input_event(ev)
	elif _dev_press == -2.0:
		_dev_press = -3.0
		var ev := InputEventAction.new()
		ev.action = "toggle_torch"
		ev.pressed = false
		Input.parse_input_event(ev)

func _update_torch(delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	var want: bool = bool(ac.get("torch")) and _inside and cam != null
	_torch_k = move_toward(_torch_k, 1.0 if want else 0.0, delta * 8.0)
	if _torch == null:
		if _torch_k <= 0.0:
			return
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--torch-energy="):    # dev: tune the beam
				TORCH_ENERGY = arg.get_slice("=", 1).to_float()
		_torch = SpotLight3D.new()
		_torch.name = "Torch"
		_torch.top_level = true
		_torch.light_color = Color(1.0, 0.94, 0.84)
		_torch.light_cull_mask = COCKPIT_LAYER
		_torch.light_specular = 0.05
		_torch.spot_range = TORCH_RANGE
		_torch.spot_attenuation = 1.2
		_torch.spot_angle = TORCH_ANGLE
		_torch.spot_angle_attenuation = 0.55       # < 1: bright only at the centre, fading gently to the edge
		_torch.shadow_enabled = true
		_torch.shadow_blur = 2.0
		_torch.shadow_bias = 0.02
		_torch.shadow_normal_bias = 1.0
		add_child(_torch)
		_torch_aim = cam.get("_ck_look") if cam.get("_ck_look") != null else Basis()
	_torch.visible = _torch_k > 0.0 and cam != null
	if not _torch.visible:
		return
	# the eye adapts: at night (high exposure) the base energy reads well; in daylight it needs more to show at all
	var exposure := 2.0
	var env: Environment = get_viewport().find_world_3d().environment if get_viewport().find_world_3d() else null
	if env == null and cam.environment:
		env = cam.environment
	if env:
		exposure = maxf(env.tonemap_exposure, 0.3)
	_torch.light_energy = TORCH_ENERGY * _torch_k * clampf(pow(2.0 / exposure, 2.0), 1.0, 6.0)
	# lag in the jet's frame (the view's look basis relative to the airframe), so manoeuvring never swings the beam
	var look := cam.global_basis.orthonormalized()
	var rel: Basis = cam.get("_ck_look") if cam.get("_ck_look") != null else Basis()
	_torch_aim = _torch_aim.slerp(rel, clampf(delta * TORCH_LAG, 0.0, 1.0)).orthonormalized()
	var frame := look * rel.inverse()               # the airframe's world basis as the camera sees it
	_torch.global_transform = Transform3D(frame * _torch_aim, cam.global_position + look * TORCH_HAND)


## HUD sun shade: swings down behind the combiner (and its lever with it) when ac.hud_shade is on.
func _update_shade(delta: float) -> void:
	var want := 1.0 if bool(ac.get("hud_shade")) else 0.0
	_shade = move_toward(_shade, want, delta * 2.2)
	var e := smoothstep(0.0, 1.0, _shade)
	if _movers.has("HUDShade"):
		var m: Array = _movers["HUDShade"]
		(m[0] as Node3D).transform = (m[1] as Transform3D) * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(lerpf(-88.0, 0.0, e))), Vector3.ZERO)
	if _movers.has("HUDShadeLever"):
		var m: Array = _movers["HUDShadeLever"]
		(m[0] as Node3D).transform = (m[1] as Transform3D) * Transform3D(Basis(Vector3.RIGHT, deg_to_rad(lerpf(30.0, -30.0, e))), Vector3.ZERO)


## A left click in the cockpit that is not on the autopilot panel: bezel buttons, the shade lever, MFD screens.
func _click_other(screen_pos: Vector2) -> bool:
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.get("target") != ac or int(cam.get("view")) != 3:
		return false
	var focal := get_viewport().get_visible_rect().size.y * 0.5 / tan(deg_to_rad(cam.fov) * 0.5)
	var best := INF
	var best_node: Node3D = null
	var cands := []
	for node in _osb:
		cands.append([node, 0.0085, Vector3(0.0, 0.007, 0.0)])
	if _movers.has("HUDShadeLever"):
		cands.append([_movers["HUDShadeLever"][0], 0.012, Vector3(0.0, 0.0, 0.016)])
	for c in cands:
		var n := c[0] as Node3D
		var wp: Vector3 = n.global_transform * (c[2] as Vector3)
		if cam.is_position_behind(wp):
			continue
		var depth := (wp - cam.global_position).dot(-cam.global_basis.z)
		var r_px: float = float(c[1]) * focal / maxf(depth, 0.05)
		var d := cam.unproject_position(wp).distance_to(screen_pos)
		if d < r_px and d < best:
			best = d
			best_node = n
	if best_node != null:
		if _osb.has(best_node):
			var e: Array = _osb[best_node]
			_osb_down[best_node] = 0.15
			if _mfds.has(e[0]):
				(_mfds[e[0]] as Control).call("press", e[1])
			ac.sim_event.emit("switch", 0.0)
		else:
			ac.set("hud_shade", not bool(ac.get("hud_shade")))
			ac.sim_event.emit("switch", 0.0)
		return true
	# the screens themselves: a click on the radar picture locks the contact under it
	var o := cam.project_ray_origin(screen_pos)
	var dir := cam.project_ray_normal(screen_pos)
	for name in _mfd_scr:
		if not _mfds.has(name):
			continue
		var mi := _mfd_scr[name] as Node3D
		var inv := mi.global_transform.affine_inverse()
		var lo := inv * o
		var ld := inv.basis * dir
		if absf(ld.y) < 1e-6:
			continue
		var t := (SCREEN_Z - lo.y) / ld.y
		if t <= 0.0:
			continue
		var p := lo + ld * t
		var cfg: Array = MFDS[name]
		var u := p.x / float(cfg[0]) + 0.5
		var v := 0.5 - (-p.z) / float(cfg[1])
		if u < 0.0 or u > 1.0 or v < 0.0 or v > 1.0:
			continue
		var page := _mfds[name] as Control
		return bool(page.call("click", Vector2(u, v) * page.size))
	return false


# ------------------------------------------------------------------ autopilot panel
func _setup_ap() -> void:
	if _ap_mat == null:
		return
	_ap_vp = SubViewport.new()
	_ap_vp.size = ApPanel.TEX
	_ap_vp.disable_3d = true
	_ap_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_ap_vp)
	_ap_panel = ApPanel.new()
	_ap_panel.ac = ac
	_ap_vp.add_child(_ap_panel)
	_ap_mat.set_shader_parameter("face", _ap_vp.get_texture())


func _update_ap(delta: float) -> void:
	if _ap_panel == null or ac.get("autopilot") == null:
		return
	_ap_panel.tick(delta)
	# knobs turn with their values: one detent (15 degrees) per step
	var ap = ac.autopilot
	var imp := int(Settings.get_value("hud/unit_system")) == 1
	var det := {
		"SPD": ap.spd_sel * (1.94384 if imp else 3.6) / (5.0 if imp else 10.0),
		"HDG": ap.hdg_sel,
		"ALT": (ap.alt_sel - 2.0) * (3.28084 if imp else 1.0) / (100.0 if imp else 50.0),
		"VS": ap.vs_sel * (196.85 if imp else 1.0) / (100.0 if imp else 1.0),
	}
	for id in _ap_knobs:
		var ang := deg_to_rad(fposmod(float(det.get(id, 0.0)) * 15.0, 360.0))
		for e in _ap_knobs[id]:
			(e[0] as Node3D).basis = (e[1] as Basis) * Basis(Vector3.UP, -ang)


## The autopilot panel control under a screen point (cockpit view only): see ApPanel.hit().
func _ap_pick(screen_pos: Vector2) -> Dictionary:
	if _ap_face == null or not _inside or Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		return {}
	var cam := get_viewport().get_camera_3d()
	if cam == null or cam.get("target") != ac or int(cam.get("view")) != 3:
		return {}
	# the ray in aircraft space, from the eye: small numbers only, exact like the precise cockpit drawing
	var tb: Basis = ac.get_global_transform_interpolated().basis if ac.is_physics_interpolated_and_enabled() else ac.global_basis
	var d_a := tb.orthonormalized().inverse() * cam.project_ray_normal(screen_pos)
	var o_a: Vector3 = cam.get("_ck_eye")
	var inv := _aircraft_space(_ap_face).affine_inverse()
	var o := inv * o_a
	var d := inv.basis * d_a
	if absf(d.y) < 1e-6:
		return {}
	var t := (0.004 - o.y) / d.y          # the face's top plane (Blender z 0.004 -> Godot local y)
	if t <= 0.0:
		return {}
	var p := o + d * t
	return ApPanel.hit(p.x, -p.z)


## True while a value is being typed into an autopilot window: the jet's keys stay quiet meanwhile.
func ap_editing() -> bool:
	return _ap_panel != null and _ap_panel.edit_id != ""


## commit: put the typed value in the selected display; enter: also send it to the autopilot (the Enter key
## does both, like typing a value and pressing the column's ENTER button).
func _ap_edit_end(commit: bool, enter := false) -> void:
	if _ap_panel == null or _ap_panel.edit_id == "":
		return
	var txt: String = _ap_panel.edit_text
	if commit and txt != "" and txt != "-" and txt.is_valid_float():
		ac.ap_set(_ap_panel.edit_id, txt.to_float())
		if enter:
			ac.ap_press(_ap_panel.edit_id)
	_ap_panel.edit_id = ""
	_ap_panel.edit_text = ""


## Typing into a window: digits, minus (V/S), Backspace; Enter sets the value, Escape cancels.
func _ap_edit_key(k: InputEventKey) -> void:
	var code := k.keycode
	var txt: String = _ap_panel.edit_text
	if code >= KEY_0 and code <= KEY_9:
		if txt.length() < 5:
			txt += str(code - KEY_0)
	elif code >= KEY_KP_0 and code <= KEY_KP_9:
		if txt.length() < 5:
			txt += str(code - KEY_KP_0)
	elif (code == KEY_MINUS or code == KEY_KP_SUBTRACT) and txt == "" and _ap_panel.edit_id == "VS":
		txt = "-"
	elif code == KEY_BACKSPACE:
		txt = txt.left(txt.length() - 1)
	elif code == KEY_ENTER or code == KEY_KP_ENTER:
		_ap_edit_end(true, true)
		return
	elif code == KEY_ESCAPE:
		_ap_edit_end(false)
		return
	_ap_panel.edit_text = txt


func _input(event: InputEvent) -> void:
	if _ap_panel == null or Game.map_open:
		return
	if not _inside:
		_ap_edit_end(false)
		return
	if event is InputEventKey and ap_editing():
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			_ap_edit_key(k)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_ap_panel.hover = _ap_pick((event as InputEventMouseMotion).position)
		return
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	var hit := _ap_pick(mb.position)
	if ap_editing() and (hit.is_empty() or hit.kind != "win" or hit.id != _ap_panel.edit_id):
		_ap_edit_end(true)             # clicking elsewhere sets what was typed
	if hit.is_empty():
		if mb.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and _click_other(mb.position):
			get_viewport().set_input_as_handled()
		return
	var id: String = hit.id
	match mb.button_index:
		MOUSE_BUTTON_LEFT:
			if hit.kind == "btn":
				ac.ap_press(id)
			elif hit.kind == "win":
				# click a window to type a value into it
				_ap_panel.edit_id = id
				_ap_panel.edit_text = ""
			else:
				ac.ap_turn(id, int(hit.side))      # click the right half to increase, the left half to decrease
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if hit.kind == "btn":
				return
			var now := Time.get_ticks_msec() / 1000.0
			var fast: bool = now - float(_ap_wheel_t.get(id, -1.0)) < 0.06
			_ap_wheel_t[id] = now
			var n := (5 if fast else 1) * (1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
			ac.ap_turn(id, n)
		_:
			return
	get_viewport().set_input_as_handled()


func _update_hud(delta: float) -> void:
	if _hud == null:
		return
	# full rate in the cockpit; from outside the HUD is a few pixels, a few updates a second is plenty
	_hud_timer += delta
	if _inside or _hud_timer > 0.25:
		_hud.tick(_hud_timer)
		_hud_timer = 0.0
	# the interpolated basis, the same one the cockpit and the eye are drawn with, so symbols never swim
	var b: Basis = ac.get_global_transform_interpolated().basis if ac.is_physics_interpolated_and_enabled() else ac.global_basis
	_hud_mat.set_shader_parameter("to_aircraft", b.orthonormalized().inverse())
