extends Node
## The pilot's body under G (own jet only): how much G he can take before his vision goes, his straining against it
## and the breathing you hear through the oxygen mask, and G-LOC. Modelled on how fighter pilots actually tolerate G
## (and how DCS plays it), not a simple threshold:
##
## * Tolerance: about 4.7 G relaxed, +1 G from the G-suit, and up to +2.4 G more while straining (the anti-G
##   straining manoeuvre: tensing the legs and body and breathing in short, forced cycles every few seconds). The
##   straining tires him: holding high G for long wears its benefit down, and it comes back with rest. A push to
##   negative G just before a pull lowers his tolerance for a while (the "push-pull" effect).
## * Onset takes time: the eye has a few seconds of oxygen in reserve, so a quick spike past the limit greys the
##   picture a little, while holding it too long goes grey (the colour drains), then tunnel vision (the edges close
##   in), then black. Easing off brings the vision back over a few seconds.
## * G-LOC (Realistic only): blacked out for more than a second and a half, he passes out: the controls go limp
##   (the stick centres) until a few seconds after the G has come off, then he wakes, gasping, as vision returns.
## * Negative G past about -1.5 G reddens the view (red-out).
## * Sound: the straining "hick" every three seconds while he fights the G, and heavy breathing afterwards that
##   eases as he recovers. Heard only in the cockpit.
##
## Setting cockpit/g_effects: 0 off, 1 reduced (more tolerance, no G-LOC), 2 realistic.

const VISION_SHADER := preload("res://shaders/g_vision.gdshader")
const SND := "res://assets/audio/pilot/"
const RELAXED := 4.7
const SUIT := 1.0
const STRAIN := 2.4
const BLACKOUT_SPAN := 1.8          # G beyond the limit for full blackout
const ONSET_TAU := 1.8              # s: how quickly vision goes (the oxygen reserve)
const RECOVER_TAU := 2.4            # s: how quickly it comes back
const LOC_AFTER := 1.5              # s blacked out before G-LOC
const LOC_WAKE := 7.0               # s after the G comes off before he wakes

var ac: Node3D
var mode := 2
var loss := 0.0                     # 0 clear .. 1 black
var red := 0.0
var effort := 0.0                   # straining 0..1
var stamina := 1.0
var unconscious := false
var _black_t := 0.0
var _wake_t := 0.0
var _pushpull := 0.0
var _work := 0.0                    # how hard he has been working (breathing after)
var _layer: CanvasLayer
var _rect: ColorRect
var _mat: ShaderMaterial
var _breath: AudioStreamPlayer
var _strain: AudioStreamPlayer
var _ins: Array = []
var _outs: Array = []
var _strains: Array = []
var _strain_t := 0.0
var _breath_t := 0.0
var _breath_in := true
var _pick := 0


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 4                  # over the 3D view and the instruments, under menus
	add_child(_layer)
	_rect = ColorRect.new()
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	_mat.shader = VISION_SHADER
	_rect.material = _mat
	_rect.visible = false
	_layer.add_child(_rect)
	for k in 3:
		_ins.append(load(SND + "mask_in_%d.wav" % k))
		_outs.append(load(SND + "mask_out_%d.wav" % k))
		_strains.append(load(SND + "mask_strain_%d.wav" % k))
	_breath = AudioStreamPlayer.new()
	_breath.bus = "Pilot"
	add_child(_breath)
	_strain = AudioStreamPlayer.new()
	_strain.bus = "Pilot"
	add_child(_strain)
	_apply_setting()
	Settings.changed.connect(func(k, _v):
		if k == "cockpit/g_effects":
			_apply_setting())


func _apply_setting() -> void:
	mode = clampi(int(Settings.get_value("cockpit/g_effects")), 0, 2)
	if mode == 0:
		loss = 0.0
		red = 0.0
		effort = 0.0
		unconscious = false
		_work = 0.0


func _physics_process(dt: float) -> void:
	if ac == null or ac.fm == null or mode == 0:
		_set_out(false)
		return
	var fm = ac.fm
	if fm.crashed:
		loss = move_toward(loss, 0.0, dt)
		red = move_toward(red, 0.0, dt)
		unconscious = false
		_set_out(false)
		return
	var gz: float = fm.nz
	# straining: he starts as the G builds, and lets go when it eases
	if gz > 4.0 and not unconscious:
		effort = move_toward(effort, 1.0, dt / 0.7)
	elif gz < 3.0 or unconscious:
		effort = move_toward(effort, 0.0, dt / 0.5)
	if effort > 0.5 and gz > 5.0:
		stamina = maxf(stamina - dt * 0.012 * (gz - 5.0), 0.3)
	elif effort < 0.2:
		stamina = minf(stamina + dt * 0.02, 1.0)
	# push-pull: negative G just before lowers tolerance for a while
	if gz < 0.0:
		_pushpull = maxf(_pushpull, clampf(-gz, 0.0, 3.0) / 3.0)
	_pushpull = maxf(_pushpull - dt / 10.0, 0.0)
	var tol := RELAXED + SUIT + STRAIN * effort * stamina - 1.2 * _pushpull
	if mode == 1:
		tol += 1.5
	# vision: towards what this G costs, at the pace the eye's oxygen reserve allows
	var want := clampf((gz - tol) / BLACKOUT_SPAN, 0.0, 1.0)
	if unconscious:
		want = 1.0
	var tau := ONSET_TAU if want > loss else RECOVER_TAU
	loss += (want - loss) * (1.0 - exp(-dt / tau))
	var want_red := clampf((-gz - 1.5) / 2.0, 0.0, 1.0)
	red += (want_red - red) * (1.0 - exp(-dt / (1.0 if want_red > red else 1.5)))
	# G-LOC
	if mode == 2:
		if not unconscious:
			_black_t = _black_t + dt if loss > 0.97 else 0.0
			if _black_t > LOC_AFTER:
				unconscious = true
				_wake_t = 0.0
		else:
			_wake_t = _wake_t + dt if gz < tol - 0.5 else 0.0
			if _wake_t > LOC_WAKE:
				unconscious = false
				_black_t = 0.0
				_work = 1.0                         # wakes gasping
	else:
		unconscious = false
	_set_out(unconscious)
	# how hard he has been working: builds above 3 G, eases off over about ten seconds
	if gz > 3.0:
		_work = minf(_work + dt * (gz - 3.0) * 0.06, 1.0)
	_work = maxf(_work - dt / 12.0 * (1.0 - effort), 0.0)
	_sounds(dt)


func _set_out(v: bool) -> void:
	if ac:
		ac.set("pilot_out", v)


func _inside() -> bool:
	var cam := get_viewport().get_camera_3d()
	return cam != null and "view_name" in cam and String(cam.view_name) == "COCKPIT" and cam.get("target") == ac


func _sounds(dt: float) -> void:
	if not _inside() or unconscious:
		return
	# straining: a forced "hick" every three seconds, then a quick breath in
	if effort > 0.6:
		_strain_t -= dt
		if _strain_t <= 0.0:
			_strain_t = 3.0
			_pick = (_pick + 1) % 3
			_strain.stream = _strains[_pick]
			_strain.volume_db = -4.0
			_strain.play()
			_breath_t = 0.4
			_breath_in = true
		_breath_t -= dt
		if _breath_t <= 0.0 and _breath_in and not _breath.playing:
			_breath.stream = _ins[_pick]
			_breath.pitch_scale = 1.25
			_breath.volume_db = -6.0
			_breath.play()
			_breath_in = false
		return
	_strain_t = 0.4
	# heavy breathing afterwards, slower and quieter as he recovers
	if _work < 0.08:
		return
	_breath_t -= dt
	if _breath_t <= 0.0 and not _breath.playing:
		_pick = (_pick + 1) % 3
		_breath.stream = _ins[_pick] if _breath_in else _outs[_pick]
		_breath.pitch_scale = lerpf(1.0, 1.15, _work)
		_breath.volume_db = lerpf(-22.0, -7.0, _work)
		_breath.play()
		_breath_t = lerpf(1.6, 0.25, _work)
		_breath_in = not _breath_in


func _process(_delta: float) -> void:
	var grey := smoothstep(0.05, 0.5, loss)
	var tunnel := smoothstep(0.3, 0.95, loss)
	var black := maxf(smoothstep(0.85, 1.0, loss), 1.0 if unconscious else 0.0)
	# shown in the cockpit; blacked out (or G-LOC) it covers every view, since the pilot cannot see either way
	var show := (grey > 0.003 or red > 0.003) and (_inside() or black > 0.5)
	_rect.visible = show
	if not show:
		return
	var vs := get_viewport().get_visible_rect().size
	_mat.set_shader_parameter("grey", grey)
	_mat.set_shader_parameter("tunnel", tunnel if _inside() else 0.0)
	_mat.set_shader_parameter("black", black)
	_mat.set_shader_parameter("red", red if _inside() else 0.0)
	_mat.set_shader_parameter("aspect", vs.x / maxf(vs.y, 1.0))
