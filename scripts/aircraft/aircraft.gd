extends Node3D
## Player aircraft node: a thin wrapper around the pure-data FlightModel (scripts/sim/flight_model.gd).
## It reads the pilot's controls, steps the simulation on the fixed physics tick, and drives everything you
## see from the simulation state: actuator positions move the surfaces, gear transit drives the animation,
## strut compression moves the oleos. Events (touchdown, crash, gear, afterburner) are emitted for audio and HUD.

signal sim_event(type: String, value: float)

const FlightModel = preload("res://scripts/sim/flight_model.gd")
const AircraftSpec = preload("res://scripts/aircraft/aircraft_spec.gd")
const P = preload("res://scripts/net/protocol.gd")
const Layout = preload("res://scripts/world/spawn_layout.gd")
const SUBSTEPS := P.SUBSTEPS         # 2 substeps per 120 Hz tick = 240 Hz simulation
const CORRECTION_RATE := 10.0        # 1/s: how fast a network correction is blended out of the view
const TOGGLES := {"toggle_gear": FlightModel.T_GEAR, "toggle_flaps": FlightModel.T_FLAPS,
	"toggle_airbrake": FlightModel.T_AIRBRAKE, "toggle_limiter": FlightModel.T_LIMITER,
	"toggle_canopy": FlightModel.T_CANOPY, "toggle_radar": FlightModel.T_RADAR, "toggle_radome": FlightModel.T_RADOME,
	"toggle_lights": FlightModel.T_LIGHTS, "reset": FlightModel.T_RESPAWN,
	"mode_nav": FlightModel.T_MODE_NAV, "mode_bvr": FlightModel.T_MODE_BVR, "mode_wvr": FlightModel.T_MODE_WVR,
	"mode_gnd": FlightModel.T_MODE_GND}

## OFFLINE: single player. PREDICTED: your jet online (simulated here at once, corrected by the server).
## REMOTE: someone else's jet, drawn from interpolated server snapshots.
enum NetMode { OFFLINE, PREDICTED, REMOTE }
var net_mode := NetMode.OFFLINE
var slot := 0                        # shelter index online
var callsign := ""
var input_blocked := false           # menus open online: the jet keeps flying, hands off the stick
var is_remote: bool:
	get: return net_mode == NetMode.REMOTE
const PRACTICE_DISTANCE := 7000.0
const GLIDESLOPE := deg_to_rad(3.0)

@export var spec: AircraftSpec
var fm: FlightModel
var spawn: Transform3D

var model: Node3D
var gear_player: AnimationPlayer
var canopy_player: AnimationPlayer
var brake_player: AnimationPlayer
var radar_player: AnimationPlayer
var radome_player: AnimationPlayer
var radar_clip := "radar_scan"
var fx: Node
var cockpit: Node3D                  # full interior, own jet only (scripts/aircraft/cockpit.gd)

# pilot / systems state that lives on the client
var throttle := 0.0
var canopy_open: bool:
	get: return fm.canopy_open
var radar_on: bool:
	get: return fm.radar_on
var radome_open: bool:
	get: return fm.radome_open
## Avionics master mode (scripts/sim/avionics.gd Mode): drives HUD symbology, weapon release and warning inhibits.
var master_mode: int:
	get: return fm.master_mode
var wheel_brakes := false
var autothrottle := false
var at_target := 0.0
## onboard autopilot (scripts/sim/autopilot.gd): altitude, heading and level-flight modes, plus the take-off tail guard
var autopilot = preload("res://scripts/sim/autopilot.gd").new()
var stores = null                      # external stores on the stations (scripts/sim/stores.gd), null if none
var sensors = null                     # radar and datalink picture for the displays (scripts/avionics/sensors.gd)
var hud_shade := false                 # HUD sun shade deployed (cockpit only, not simulated)
var mirrors_folded := false            # rear-view mirrors folded up out of use (cockpit only, not simulated)
var fpm_caged := false                 # HUD flight path marker caged to the centre line (cockpit only, not simulated)
var pilot_out := false                 # G-LOC: the pilot has passed out, the stick goes limp (scripts/aircraft/pilot_g.gd)
var pilot_g: Node                      # the pilot's body under G (own jet only)
var cabin_lights := false              # cockpit night lighting: instrument backlighting and floodlights
var torch := false                     # the pilot's handheld flashlight (cockpit only, follows the view)
var _man_pitch := 0.0                  # the pilot's own (smoothed) stick, before the autopilot and tail guard
var _man_roll := 0.0
var _ap_hold := {}                     # autopilot target keys held: action -> seconds
var _at_by_ap := false                 # the auto-throttle is currently driven by the autopilot's SPD mode
var landing_event := ""
var landing_event_time := -100.0
var pitch_in := 0.0
var roll_in := 0.0
var yaw_in := 0.0

# read-only views of the simulation (HUD, camera, effects, audio)
var velocity: Vector3:
	get: return fm.vel
var speed: float:
	get: return fm.tas
var ias: float:
	get: return fm.ias
var mach: float:
	get: return fm.mach
var ground_speed: float:
	get: return Vector2(fm.vel.x, fm.vel.z).length()
var heading_deg: float:
	get:
		var f := -fm.rot.z
		return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)
var aoa_deg: float:
	get: return rad_to_deg(fm.alpha)
var g_load: float:
	get: return fm.nz
var vertical_speed: float:
	get: return fm.vel.y
var altitude_agl: float:
	get: return global_position.y - spec.gear_height - WorldData.scene_ground_height(global_position.x, global_position.z)
var thrust_now: float:
	get: return fm.thrust
var stall_frac: float:
	get: return fm.stall_frac
var buffet: float:
	get: return fm.buffet
var wow: bool:
	get: return fm.wow
var on_ground: bool:
	get: return fm.wow
var crashed: bool:
	get: return fm.crashed
var crash_reason: String:
	get: return fm.crash_reason
var gear_down: bool:
	get: return fm.gear_down
var gear_comp: Array:
	get: return fm.gear_comp
var flaps: bool:
	get: return fm.flaps
var airbrake: bool:
	get: return fm.airbrake
var aoa_limiter: bool:
	get: return fm.limiter
var nose_steer_deg: float:
	get: return rad_to_deg(fm.steer) if fm.wow else 0.0
var fuel_kg: float:
	get: return fm.fuel
var fuel_flow: float:
	get: return fm.fuel_flow
var rpm: float:
	get: return (fm.engines[0].n2 if fm.engines.size() > 0 else 0.0)
var ab_stage: float:
	get: return (fm.engines[0].ab if fm.engines.size() > 0 else 0.0)
var wind: Vector3:
	get: return fm.wind
## 0..1 engine setting for the effects (afterburner glow above spec.ab_threshold)
var engine: float:
	get:
		if ab_stage > 0.001:
			return spec.ab_threshold + ab_stage * (1.0 - spec.ab_threshold)
		return clampf((rpm - spec.engine_idle_n2) / (100.0 - spec.engine_idle_n2), 0.0, 1.0) * spec.ab_threshold
var AB_THRESHOLD: float:
	get: return spec.ab_threshold

var _surfaces := {}
var _tires: Array[Node3D] = []
var _nose_gear: Node3D
var _nose_rest: Basis
var _oleos: Array[Node3D] = []
var _oleo_rest: Array[Vector3] = []
var _was_ab := false
var _was_wow := true
var _prev_ias := 0.0
var _ias_rate := 0.0
var _tog := 0                        # local switch counters, 2 bits each (see FlightModel.apply_input)
var _shown := {}                     # switch states the visuals currently show
var _shown_bits := -1                # the same states packed (a quick check before building the dictionary)
var _gear_moving_visual := true
var _vis_pos := Vector3.ZERO         # network correction still being blended out (view only)
var _vis_rot := Quaternion.IDENTITY
var _remote_crashed := false
const SLAT_RATE := 30.0                # degrees per second (slat actuators)
var _slat_deg := 0.0
const REMOTE_DETAIL_FAR := 2500.0     # m: beyond this a remote jet's surfaces and gear are updated less often
var _lod_dt := 0.0
var _lod_n := 0
var dev_pilot: Object = null     # development: a scripted pilot (scripts/dev/formation.gd) flies instead of the keys
var _dev_fly := "--dev-fly" in OS.get_cmdline_user_args()   # development: a simple autopilot for netcode tests
var _dev_gear_done := false
var _dev_ap_done := false
var _dev_thr := 1.0


func _ready() -> void:
	if spec == null:
		spec = load("res://data/aircraft/su27.tres")
	fm = FlightModel.new()
	fm.setup(spec, WorldData.atmosphere, WorldData.ground_height, WorldData.is_water, 7)
	model = _scene(spec.model_scene).instantiate()
	model.rotation.y = PI  # glTF model front is +Z, Godot forward is -Z
	add_child(model)
	# cockpit lights start on at night (they can be switched any time)
	var hour: float = float(WorldData.get("time_of_day")) if WorldData.get("time_of_day") != null else 12.0
	cabin_lights = hour < 7.0 or hour > 19.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--cabin="):           # dev: force the cockpit lights for screenshots
			cabin_lights = a.get_slice("=", 1) == "1"
		elif a == "--torch":                     # dev: flashlight on for screenshots
			torch = true
	# pylons, launch rails and the loaded missiles (or tanks, bombs ... on aircraft that carry them)
	var st = preload("res://scripts/sim/stores.gd").new()
	if st.load_for(String(spec.id)):
		st.attach(model)
		stores = st

	# One AnimationPlayer per system, each with ONLY its own clips. A player that knows other systems'
	# tracks writes them too (e.g. the airbrake would snap the gear down), so libraries are never shared.
	var source: AnimationPlayer = model.find_child("AnimationPlayer", true, false)
	var clips := {}
	for lib_name in source.get_animation_library_list():
		var lib := source.get_animation_library(lib_name)
		for clip in lib.get_animation_list():
			clips[String(clip)] = lib.get_animation(clip)
	for clip in clips:
		if String(clip).begins_with("radar_scan"):
			radar_clip = clip
			(clips[clip] as Animation).loop_mode = Animation.LOOP_LINEAR
	_clip_prefix = String(spec.id) + ":"
	canopy_player = _system_player("CanopyPlayer", source, clips, ["canopy_open"])
	brake_player = _system_player("AirbrakePlayer", source, clips, ["airbrake_open"])
	radar_player = _system_player("RadarPlayer", source, clips, [radar_clip])
	radome_player = _system_player("RadomePlayer", source, clips, ["radome_open"])
	gear_player = _system_player("GearPlayer", source, clips, ["gear_extend", "gear_retract"])
	source.stop()
	source.queue_free()
	for n in ["Stabilator_L", "Stabilator_R", "Flaperon_L", "Flaperon_R", "Slat_L", "Slat_R", "Rudder_L", "Rudder_R"]:
		var node := model.find_child(n, true, false) as Node3D
		if node:
			_surfaces[n] = [node, node.transform.basis]
	fx = preload("res://scripts/aircraft/aircraft_effects.gd").new()
	fx.name = "Effects"
	add_child(fx)
	fx.setup(self, model)
	if not is_remote and Game.get("is_server") != true:
		cockpit = preload("res://scripts/aircraft/cockpit.gd").new()
		cockpit.name = "CockpitInterior"
		model.add_child(cockpit)
		cockpit.setup(self, model)
		pilot_g = preload("res://scripts/aircraft/pilot_g.gd").new()
		pilot_g.name = "PilotG"
		pilot_g.ac = self
		add_child(pilot_g)
	if is_remote:
		add_to_group("remote_aircraft")
		# placed every simulation tick from the snapshots (net/client.gd) and drawn between ticks by physics
		# interpolation, exactly like our own jet, so the two never move out of step on screen
		_add_callsign()
	else:
		add_to_group("player_aircraft")
	var snd: Node3D = preload("res://scripts/aircraft/aircraft_audio.gd").new()
	snd.name = "Audio"
	snd.setup(self)
	add_child(snd)
	_nose_gear = model.find_child("NoseGear_Oleo", true, false) as Node3D
	if _nose_gear:
		_nose_rest = _nose_gear.transform.basis
	for n in ["NoseGear_Oleo", "MainGear_Oleo_L", "MainGear_Oleo_R"]:
		var o := model.find_child(n, true, false) as Node3D
		_oleos.append(o)
		_oleo_rest.append(o.position if o else Vector3.ZERO)
	for n in ["NoseGear_Tire", "MainGear_Tire_L", "MainGear_Tire_R"]:
		var t := model.find_child(n, true, false) as Node3D
		if t:
			_tires.append(t)
	fm.respawn(Transform3D(global_transform.basis, WorldData.to_world(global_position)))
	_shown = _switches()


static var _scene_cache := {}       # model path -> PackedScene, kept loaded for every later jet (joins cost no disk read)
static var _clip_cache := {}        # "type:clip" -> animation with only its own moving tracks
var _clip_prefix := ""


static func _scene(path: String) -> PackedScene:
	if not _scene_cache.has(path):
		_scene_cache[path] = load(path)
	return _scene_cache[path]


func _system_player(player_name: String, source: AnimationPlayer, clips: Dictionary, names: Array) -> AnimationPlayer:
	var p := AnimationPlayer.new()
	p.name = player_name
	source.get_parent().add_child(p)
	p.root_node = source.root_node
	var lib := AnimationLibrary.new()
	for n in names:
		if clips.has(n):
			# stripped once per aircraft type and shared (read-only) by every jet of that type: a player joining
			# then costs no animation copying
			var key := _clip_prefix + String(n)
			if not _clip_cache.has(key):
				_clip_cache[key] = _only_moving_tracks(clips[n])
			lib.add_animation(n, _clip_cache[key])
	p.add_animation_library("", lib)
	return p


## The exporter samples every animated part into every clip, so e.g. "airbrake_open" also carries the gear
## frozen at its rest (down) pose. A track whose value never changes inside a clip belongs to another system:
## drop it, so each clip only moves what it really animates.
static func _only_moving_tracks(src: Animation) -> Animation:
	var anim := src.duplicate(true) as Animation
	for t in range(anim.get_track_count() - 1, -1, -1):
		var n := anim.track_get_key_count(t)
		if n < 2:
			anim.remove_track(t)
			continue
		var first = anim.track_get_key_value(t, 0)
		var moving := false
		for k in range(1, n):
			var v = anim.track_get_key_value(t, k)
			if typeof(v) == TYPE_QUATERNION:
				if absf((v as Quaternion).dot(first as Quaternion)) < 0.99999:
					moving = true
			elif typeof(v) == TYPE_VECTOR3:
				if ((v as Vector3) - (first as Vector3)).length() > 1e-4:
					moving = true
			elif v != first:
				moving = true
			if moving:
				break
		if not moving:
			anim.remove_track(t)
	return anim


func _physics_process(delta: float) -> void:
	if is_remote:
		return
	var t := 0
	if net_mode == NetMode.PREDICTED:
		t = Game.client.next_tick()
	_read_inputs(delta)
	var cmd := P.make_cmd(t, pitch_in, roll_in, yaw_in, throttle, 1.0 if wheel_brakes else 0.0, _tog)
	apply_cmd(cmd, false)
	step_sim()
	if Engine.get_physics_frames() % 30 == 0:
		WorldData.prefetch_ahead(fm.world_pos(), fm.vel)
	if net_mode == NetMode.PREDICTED:
		Game.client.record(cmd, fm.get_state())
	var k := exp(-CORRECTION_RATE * delta)
	_vis_pos *= k
	_vis_rot = Quaternion.IDENTITY.slerp(_vis_rot, k)
	var shifted := _follow_origin()
	global_transform = Transform3D(Basis(_vis_rot) * fm.rot, _scene_pos() + _vis_pos)
	if shifted:
		reset_physics_interpolation()
	_process_events()
	_sync_switches()
	_update_surfaces()
	_update_gear_visuals(delta)


## One tick of input into the simulation. `replay` is true while re-simulating after a server correction:
## then nothing audible or visible may fire.
func apply_cmd(cmd: Array, replay: bool) -> void:
	var fired: int = fm.apply_input(cmd[1], cmd[2], cmd[3], cmd[4], cmd[5], cmd[6])
	if fired & (1 << FlightModel.T_RESPAWN):
		fm.respawn(_spawn_point())
		if not replay:
			_after_respawn()


func step_sim() -> void:
	var dt := P.TICK_DT / SUBSTEPS
	for i in SUBSTEPS:
		fm.step(dt)


## Server correction: restore its state for tick `ack`, replay our inputs since, and blend the difference out of
## the view over a few frames, so the jet never visibly jumps.
func rewind(state: Array, ack: int, cmds: Dictionary, states: Dictionary, now: int) -> void:
	var old_pos := fm.world_pos()
	var old_rot := Quaternion(fm.rot.orthonormalized())
	fm.set_state(state)
	for t in range(ack + 1, now + 1):
		if cmds.has(t):
			apply_cmd(cmds[t], true)
			step_sim()
			states[t] = fm.get_state()
	fm.events.clear()
	var new_rot := Quaternion(fm.rot.orthonormalized())
	_vis_pos += old_pos - fm.world_pos()        # (world terms: the frames may differ by whole cells)
	_vis_rot = ((_vis_rot * old_rot) * new_rot.inverse()).normalized()
	if _vis_pos.length() > 40.0:          # a respawn or a big desync: cut, don't glide across the map
		_vis_pos = Vector3.ZERO
		_vis_rot = Quaternion.IDENTITY
		reset_physics_interpolation()


## The scene origin follows our own jet's simulation frame (floating origin, see scripts/world/world_data.gd).
## Moves the scene origin with our jet. True when it moved: the caller must place the jet in the new frame and only
## then reset its physics interpolation (resetting first would keep the old-frame position as the "previous" one,
## and the next rendered frame would draw the jet, and the camera following it, part way back across the shift
## while the terrain is already in the new frame: a one-frame jump of the whole world every 2 km).
func _follow_origin() -> bool:
	if is_remote or not is_in_group("player_aircraft"):
		return false
	if fm.ox != WorldData.origin_x or fm.oz != WorldData.origin_z:
		WorldData.set_origin(fm.ox, fm.oz)
		return true
	return false


## Where the simulation puts the jet in the scene (equal to fm.pos while the scene follows this jet).
func _scene_pos() -> Vector3:
	return fm.pos + Vector3(fm.ox - WorldData.origin_x, 0.0, fm.oz - WorldData.origin_z)


## Puts the jet at a spawn point, parked and configured (no input involved: used when the flight starts).
func place(xform: Transform3D) -> void:
	fm.respawn(xform)
	_after_respawn()


func _spawn_point() -> Transform3D:
	return Layout.parking_slot(slot) if net_mode == NetMode.PREDICTED else spawn


func _after_respawn() -> void:
	throttle = 0.0
	autothrottle = false
	autopilot.disengage("")
	_man_pitch = 0.0
	_man_roll = 0.0
	_vis_pos = Vector3.ZERO
	_vis_rot = Quaternion.IDENTITY
	_snap_gear_down()
	_shown = _switches()
	sim_event.emit("reset", 0.0)
	_follow_origin()
	global_transform = Transform3D(fm.rot, _scene_pos())
	reset_physics_interpolation()


func _process_events() -> void:
	for e in fm.events:
		var type: String = e[0]
		match type:
			"touchdown":
				_event(e[1])
			"crash":
				_event("CRASHED  ·  " + String(e[1]))
			"tailstrike":
				_event("TAIL STRIKE")
		sim_event.emit(type, float(e[2]))
	fm.events.clear()
	var ab_now := ab_stage > 0.01
	if ab_now and not _was_ab:
		sim_event.emit("ab_light", 0.0)
	_was_ab = ab_now
	if fm.wow != _was_wow:
		sim_event.emit("wheels_down" if fm.wow else "wheels_up", 0.0)
	_was_wow = fm.wow


func _read_inputs(delta: float) -> void:
	if dev_pilot != null:
		dev_pilot.fly(self, delta)
		return
	if _dev_fly:
		_dev_autopilot()
		if "--dev-ap" in OS.get_cmdline_user_args():
			# development: hand over to the real autopilot once airborne, then change altitude and heading
			if not _dev_ap_done and altitude_agl > 250.0:
				_dev_ap_done = true
				autopilot.follow(fm)
				autopilot.engage(fm)
				autopilot.level = false
				autopilot.turn("ALT", 16, true)
				autopilot.turn("HDG", 90, true)
				autopilot.set_value("SPD", 310.0, true)
				autopilot.press("ALT", fm)
				autopilot.press("HDG", fm)
				autopilot.press("SPD", fm)
				autopilot.turn("ALT", 5, true)            # a selected value left waiting for ENTER
			if autopilot.engaged:
				var ap: Array = autopilot.update(fm, spec, delta, 0.0, 0.0)
				pitch_in = float(ap[0])
				roll_in = float(ap[1])
				_dev_thr = move_toward(_dev_thr, clampf(0.62 + (autopilot.spd_tgt - fm.ias) * 0.05, 0.0, spec.ab_threshold - 0.01), 0.6 * delta)
				throttle = _dev_thr
		pitch_in = autopilot.tail_guard(fm, spec, pitch_in)
		return
	if input_blocked:
		# hands off the stick; an engaged autopilot keeps flying the jet
		_man_pitch = 0.0
		_man_roll = 0.0
		var ap: Array = autopilot.update(fm, spec, delta, 0.0, 0.0)
		pitch_in = move_toward(pitch_in, float(ap[0]), delta * 4.0)
		roll_in = move_toward(roll_in, float(ap[1]), delta * 5.0)
		yaw_in = move_toward(yaw_in, 0.0, delta * 3.0)
		wheel_brakes = false
		return
	# typing a value into the autopilot panel: the keys belong to the panel, not to the jet's switches
	var typing: bool = cockpit != null and cockpit.has_method("ap_editing") and cockpit.ap_editing()
	for action in TOGGLES:
		if not typing and Input.is_action_just_pressed(action):
			var sh: int = TOGGLES[action] * 2
			_tog = (_tog & ~(3 << sh)) | ((((_tog >> sh) & 3) + 1) & 3) << sh
	if not typing and Input.is_action_just_pressed("toggle_cabin_lights"):
		cabin_lights = not cabin_lights
		sim_event.emit("switch", 0.0)
	if not typing and Input.is_action_just_pressed("toggle_torch"):
		torch = not torch
		sim_event.emit("switch", 0.0)
	if not typing and Input.is_action_just_pressed("toggle_hud_shade"):
		hud_shade = not hud_shade
		sim_event.emit("switch", 0.0)
	if not typing and Input.is_action_just_pressed("toggle_fpm_cage"):
		fpm_caged = not fpm_caged
		sim_event.emit("switch", 0.0)
	if not typing and Input.is_action_just_pressed("toggle_mirrors"):
		mirrors_folded = not mirrors_folded
		sim_event.emit("switch", 0.0)
	if not typing and Input.is_action_just_pressed("practice_approach") and net_mode == NetMode.OFFLINE:
		practice_approach()
	var pitch_axis := Input.get_axis("pitch_down", "pitch_up")
	if bool(Settings.get_value("controls/invert_pitch")):
		pitch_axis = -pitch_axis
	var roll_axis := Input.get_axis("roll_left", "roll_right")
	var yaw_axis := Input.get_axis("yaw_left", "yaw_right")
	if pilot_out:
		# G-LOC: his hands fall away, the stick and pedals centre
		pitch_axis = 0.0
		roll_axis = 0.0
		yaw_axis = 0.0
	_man_pitch = move_toward(_man_pitch, pitch_axis, delta * 4.0)
	_man_roll = move_toward(_man_roll, roll_axis, delta * 5.0)
	if not typing:
		_autopilot_keys(delta)
	var ap: Array = autopilot.update(fm, spec, delta, _man_pitch, _man_roll)
	# the tail-strike guard only protects the autopilot's own pitch commands: hand flying, you rotate when you like
	pitch_in = autopilot.tail_guard(fm, spec, float(ap[0])) if autopilot.engaged else float(ap[0])
	roll_in = float(ap[1])
	yaw_in = move_toward(yaw_in, yaw_axis, delta * 3.0)
	var hand_on_throttle := Input.is_action_pressed("throttle_up") or Input.is_action_pressed("throttle_down")
	if Input.is_action_pressed("throttle_up"):
		throttle = minf(throttle + delta * 0.4, 1.0)
	if Input.is_action_pressed("throttle_down"):
		throttle = maxf(throttle - delta * 0.4, 0.0)
	if hand_on_throttle:
		# moving the throttle takes the speed back from the autopilot (its SPD mode drops out)
		autothrottle = false
		if autopilot.spd_on:
			autopilot.spd_on = false
	# the autopilot's speed mode drives the auto-throttle (also used on its own by the practice approach)
	if autopilot.engaged and autopilot.spd_on:
		autothrottle = true
		at_target = autopilot.spd_tgt
		_at_by_ap = true
	elif _at_by_ap:
		autothrottle = false
		_at_by_ap = false
	_ias_rate = lerpf(_ias_rate, (fm.ias - _prev_ias) / maxf(delta, 1e-3), clampf(delta * 3.0, 0.0, 1.0))
	_prev_ias = fm.ias
	if autothrottle:
		if fm.wow:
			autothrottle = false
		else:
			# speed hold that anticipates engine spool lag: proportional on error, damped by acceleration
			var err := at_target - fm.ias
			var want := clampf(0.62 + err * 0.05 - _ias_rate * 0.35, 0.0, spec.ab_threshold - 0.01)
			throttle = move_toward(throttle, want, 0.6 * delta)
	wheel_brakes = Input.is_action_pressed("wheel_brake")


## Flips one of the simulated switches (a TOGGLES action such as "toggle_radar") as if its key were pressed:
## used by cockpit buttons, so they go through the same path as the keys (and the network).
func press_switch(action: String) -> void:
	if is_remote or not TOGGLES.has(action):
		return
	var sh: int = TOGGLES[action] * 2
	_tog = (_tog & ~(3 << sh)) | ((((_tog >> sh) & 3) + 1) & 3) << sh


## Autopilot panel value typed into a window, in display units (see Autopilot.set_value).
func ap_set(id: String, shown: float) -> void:
	if is_remote:
		return
	autopilot.set_value(id, shown, int(Settings.get_value("hud/unit_system")) == 1)
	sim_event.emit("switch", 0.0)


## Autopilot panel button: "AP", "LVL", or a window's enter button "SPD", "HDG", "ALT", "VS" (panel and keys).
func ap_press(id: String) -> void:
	if is_remote:
		return
	autopilot.press(id, fm)
	sim_event.emit("switch", 0.0)


## Autopilot panel knob: "SPD", "HDG", "ALT", "VS", turned by `steps` detents.
func ap_turn(id: String, steps: int) -> void:
	if is_remote:
		return
	autopilot.turn(id, steps, int(Settings.get_value("hud/unit_system")) == 1)


## Autopilot keys: the same buttons and knobs as the panel. Knob keys step per press and repeat while held.
func _autopilot_keys(delta: float) -> void:
	if Input.is_action_just_pressed("ap_master"):
		ap_press("AP")
	if Input.is_action_just_pressed("ap_level"):
		ap_press("LVL")
	ap_turn("ALT", _ap_steps("ap_alt_up", delta) - _ap_steps("ap_alt_down", delta))
	ap_turn("HDG", _ap_steps("ap_hdg_right", delta) - _ap_steps("ap_hdg_left", delta))
	ap_turn("SPD", _ap_steps("ap_spd_up", delta) - _ap_steps("ap_spd_down", delta))


func _ap_steps(action: String, delta: float) -> int:
	if Input.is_action_just_pressed(action):
		_ap_hold[action] = 0.0
		return 1
	if not Input.is_action_pressed(action):
		_ap_hold.erase(action)
		return 0
	# held: after a short pause, repeat ten times a second
	var t: float = _ap_hold.get(action, 0.0)
	var before := floori(maxf(t - 0.4, 0.0) * 10.0)
	t += delta
	_ap_hold[action] = t
	return floori(maxf(t - 0.4, 0.0) * 10.0) - before


## Development autopilot: full power, rotate at 150 kt, gear up, climb to about 900 m and weave gently.
func _dev_autopilot() -> void:
	var t := fm.time
	throttle = 1.0 if t > 1.0 else 0.0
	var agl := altitude_agl
	var climb := 0.0 if fm.ias < 78.0 else (0.45 if fm.pos.y < 900.0 else clampf(-fm.vel.y * 0.05, -0.3, 0.3))
	pitch_in = climb
	roll_in = 0.0 if agl < 300.0 else 0.6 * sin(t * 0.25)
	if agl > 40.0 and not _dev_gear_done:
		_dev_gear_done = true
		var sh := FlightModel.T_GEAR * 2
		_tog = (_tog & ~(3 << sh)) | ((((_tog >> sh) & 3) + 1) & 3) << sh


func _event(text: String) -> void:
	landing_event = text
	landing_event_time = Time.get_ticks_msec() / 1000.0


# ---------------- visuals from simulation state ----------------
func _set_surface(n: String, deg: float) -> void:
	if _surfaces.has(n):
		var e: Array = _surfaces[n]
		# only when it moved (most ticks the surfaces hold still): every write re-transforms the part and its children
		if e.size() > 2 and absf(float(e[2]) - deg) < 0.005:
			return
		(e[0] as Node3D).transform.basis = (e[1] as Basis) * Basis(Vector3.RIGHT, deg_to_rad(deg))
		if e.size() > 2:
			e[2] = deg
		else:
			e.append(deg)


func _update_surfaces() -> void:
	# the surfaces show the real actuator positions the fly-by-wire is commanding
	var e := rad_to_deg(fm.elev)
	var a := rad_to_deg(fm.ail)
	var r := rad_to_deg(fm.rud)
	_set_surface("Stabilator_L", e - a * 0.4)
	_set_surface("Stabilator_R", e + a * 0.4)
	_set_surface("Flaperon_L", -a - fm.flap_pos * 30.0)
	_set_surface("Flaperon_R", a - fm.flap_pos * 30.0)
	# leading-edge slats: scheduled on angle of attack by the flight control system, as on the real jet. Below about
	# 30 kt the angle of attack means nothing (a breeze or a gust over a parked jet swings it wildly), so the schedule
	# only takes effect with real airflow, and the slats move at an actuator's pace instead of jumping with every
	# gust. (Before, parked in a wind they flapped up and down endlessly.)
	var airflow := clampf((fm.ias - 15.0) / 10.0, 0.0, 1.0)
	var slat_want := maxf(fm.flap_pos, clampf((aoa_deg - 8.0) / 10.0, 0.0, 1.0) * airflow) * 28.0
	_slat_deg = move_toward(_slat_deg, slat_want, SLAT_RATE * get_physics_process_delta_time())
	_set_surface("Slat_L", _slat_deg)
	_set_surface("Slat_R", _slat_deg)
	_set_surface("Rudder_L", r)
	_set_surface("Rudder_R", r)


func _update_gear_visuals(delta: float) -> void:
	if fm.gear_pos < 0.01 and not gear_player.is_playing() and not _gear_moving_visual:
		return                    # gear up and stowed: nothing to move
	_gear_moving_visual = fm.gear_pos >= 0.01 or gear_player.is_playing()
	var locked := fm.gear_pos > 0.98 and not gear_player.is_playing()
	if _nose_gear:
		var st := rad_to_deg(fm.steer) if locked else 0.0
		_nose_gear.transform.basis = _nose_rest * Basis(Vector3.UP, deg_to_rad(-st))
	for i in _oleos.size():
		if _oleos[i] == null:
			continue
		var comp: float = fm.gear_comp[i] if locked else 0.0
		var offset := clampf(comp - spec.static_stroke, -spec.static_stroke, spec.max_stroke - spec.static_stroke)
		_oleos[i].position = _oleos[i].position.lerp(_oleo_rest[i] + Vector3(0.0, offset, 0.0), clampf(delta * 25.0, 0.0, 1.0))
	if fm.wow and locked:
		for t in _tires:
			t.rotate_object_local(Vector3.RIGHT, fm.wheel_speed / 0.45 * delta)


func _toggle_clip(p: AnimationPlayer, clip: String, open: bool) -> void:
	if open:
		p.play(clip)
	else:
		p.play_backwards(clip)


func _switches() -> Dictionary:
	return {"gear": fm.gear_down, "flaps": fm.flaps, "airbrake": fm.airbrake, "limiter": fm.limiter,
		"canopy": fm.canopy_open, "radar": fm.radar_on, "radome": fm.radome_open, "lights": fm.lights_on,
		"mode": fm.master_mode}


## Animations and switch sounds follow the simulation's switch states, whoever changed them (this pilot, a
## replay, or a remote jet's snapshot), so every jet looks the same on every screen.
func _switch_bits() -> int:
	return int(fm.gear_down) | int(fm.flaps) << 1 | int(fm.airbrake) << 2 | int(fm.limiter) << 3 \
		| int(fm.canopy_open) << 4 | int(fm.radar_on) << 5 | int(fm.radome_open) << 6 | int(fm.lights_on) << 7 \
		| int(fm.master_mode) << 8


func _sync_switches() -> void:
	var bits := _switch_bits()
	if bits == _shown_bits:
		return                    # nothing switched since the last tick (almost always)
	_shown_bits = bits
	var now := _switches()
	if now.gear != _shown.gear:
		gear_player.speed_scale = gear_player.get_animation("gear_extend").length / spec.gear_transit_time
		gear_player.play("gear_extend" if now.gear else "gear_retract")
		sim_event.emit("gear_motion", 1.0 if now.gear else 0.0)
	if now.canopy != _shown.canopy:
		_toggle_clip(canopy_player, "canopy_open", now.canopy)
		sim_event.emit("canopy", 1.0 if now.canopy else 0.0)
	if now.airbrake != _shown.airbrake:
		_toggle_clip(brake_player, "airbrake_open", now.airbrake)
		sim_event.emit("airbrake", 1.0 if now.airbrake else 0.0)
	if now.radome != _shown.radome:
		_toggle_clip(radome_player, "radome_open", now.radome)
	if now.flaps != _shown.flaps:
		sim_event.emit("flaps", 1.0 if now.flaps else 0.0)
	if now.radar != _shown.radar:
		if now.radar:
			radar_player.play(radar_clip)
		else:
			radar_player.pause()
		sim_event.emit("switch", 0.0)
	if now.lights != _shown.lights:
		sim_event.emit("switch", 0.0)
	if now.mode != _shown.mode and not is_remote:
		sim_event.emit("switch", 0.0)
	if now.limiter != _shown.limiter and not is_remote:
		_event("AOA LIMITER " + ("ON" if now.limiter else "OFF  ·  CAREFUL"))
		sim_event.emit("switch", 0.0)
	_shown = now


func _snap_gear_down() -> void:
	fm.gear_down = true
	fm.gear_pos = 1.0
	gear_player.speed_scale = 1.0
	gear_player.play("gear_extend")
	gear_player.seek(gear_player.current_animation_length, true)


## Puts the jet on a 3 degree final approach, 7 km out, configured to land, to the runway end nearest to the jet.
## (To be reworked: the player picks the airfield and runway.)
## offset: development only (--dev-approach=right,up in metres), starts off the beam to test the flight director.
func practice_approach(offset := Vector2.ZERO) -> void:
	if WorldData.runways.is_empty():
		return
	var rwy: Dictionary = WorldData.runways[0]
	var me := fm.world_pos()
	var bd := INF
	for r in WorldData.runways:
		var d: float = Vector2(r.threshold.x - me.x, r.threshold.z - me.z).length()
		if d < bd:
			bd = d
			rwy = r
	var dir: Vector3 = rwy.dir
	var aim: Vector3 = rwy.threshold + dir * WorldData.AIM_DISTANCE
	var start := aim - dir * PRACTICE_DISTANCE + Vector3(0.0, PRACTICE_DISTANCE * tan(GLIDESLOPE) + spec.gear_height, 0.0)
	start += dir.cross(Vector3.UP).normalized() * offset.x + Vector3(0.0, offset.y, 0.0)
	var path := dir * cos(GLIDESLOPE) + Vector3(0.0, -sin(GLIDESLOPE), 0.0)
	var yaw := atan2(-dir.x, -dir.z)
	fm.reset(Transform3D(Basis(Vector3.UP, yaw) * Basis.from_euler(Vector3(deg_to_rad(5.0), 0.0, 0.0)), start), 0.0, false)
	sim_event.emit("reset", 0.0)
	fm.vel = path * 78.0
	fm.flaps = true
	fm.flap_pos = 1.0
	fm.airbrake = false
	fm.set_engines_n2(88.0)
	_snap_gear_down()
	_shown = _switches()
	throttle = 0.6
	autothrottle = true
	at_target = 78.0
	_follow_origin()
	global_transform = Transform3D(fm.rot, _scene_pos())
	reset_physics_interpolation()
	_event("PRACTICE APPROACH  RWY " + String(rwy.name))


## Development and tests: flying at `speed` (m/s) from a world transform, clean (gear up), autopilot holding it.
func air_start(xform: Transform3D, speed: float) -> void:
	fm.reset(xform, speed, false)
	sim_event.emit("reset", 0.0)
	fm.gear_down = false
	fm.gear_pos = 0.0
	fm.set_engines_n2(92.0)
	gear_player.speed_scale = 1.0
	gear_player.play("gear_retract")
	gear_player.seek(gear_player.current_animation_length, true)
	_shown = _switches()
	throttle = 0.75
	_follow_origin()
	global_transform = Transform3D(fm.rot, _scene_pos())
	reset_physics_interpolation()
	# the autopilot takes the speed and altitude to hold from the flight model's own readings, valid after a step
	await get_tree().physics_frame
	await get_tree().physics_frame
	autopilot.follow(fm)
	autopilot.engage(fm)


## Back to the start: the runway offline, your shelter online. Goes through the input stream (the R switch),
## so online the server respawns you at the same tick.
func reset() -> void:
	var sh := FlightModel.T_RESPAWN * 2
	_tog = (_tog & ~(3 << sh)) | ((((_tog >> sh) & 3) + 1) & 3) << sh


# ---------------- remote jets ----------------
## Places a remote jet from the interpolated snapshot and drives its visuals and sound from it.
## `pos` is a scene position; the remote's model lives in our scene frame.
func apply_remote(pos: Vector3, q: Quaternion, vel: Vector3, omega: Vector3, d: Dictionary, delta: float) -> void:
	fm.ox = WorldData.origin_x
	fm.oz = WorldData.origin_z
	fm.pos = pos
	fm.rot = Basis(q)
	fm.vel = vel
	fm.omega = omega
	fm.elev = d.elev
	fm.ail = d.ail
	fm.rud = d.rud
	fm.steer = d.steer
	fm.gear_pos = d.gear_pos
	fm.flap_pos = d.flap_pos
	fm.airbrake_pos = d.airbrake_pos
	fm.gear_comp = d.comp
	var f: int = d.flags
	fm.gear_down = f & P.FLAG_GEAR != 0
	fm.wow = f & P.FLAG_WOW != 0
	fm.flaps = f & P.FLAG_FLAPS != 0
	fm.airbrake = f & P.FLAG_AIRBRAKE != 0
	fm.crashed = f & P.FLAG_CRASHED != 0
	fm.canopy_open = f & P.FLAG_CANOPY != 0
	fm.lights_on = f & P.FLAG_LIGHTS != 0
	fm.radar_on = f & P.FLAG_RADAR != 0
	fm.radome_open = f & P.FLAG_RADOME != 0
	for e in fm.engines:
		e.n2 = d.n2
		e.ab = d.ab
	# air data the sound and effects use, estimated from the motion
	var vb := fm.rot.inverse() * (vel - WorldData.atmosphere.wind_at(WorldData.to_world(pos), 0.0, 0.0))
	fm.tas = vb.length()
	fm.alpha = atan2(-vb.y, maxf(-vb.z, 1.0))
	var rho_ratio := exp(-maxf(pos.y, 0.0) / 9500.0)
	fm.ias = fm.tas * sqrt(rho_ratio)
	fm.qbar = 0.5 * 1.225 * rho_ratio * fm.tas * fm.tas
	fm.mach = fm.tas / 340.0
	var n := clampf((d.n2 - spec.engine_idle_n2) / (100.0 - spec.engine_idle_n2), 0.0, 1.0)
	fm.thrust = spec.engine_count * (lerpf(2000.0, 79400.0, n * n) + d.ab * 43000.0)
	fm.wheel_speed = Vector2(vel.x, vel.z).length() if fm.wow else 0.0
	if fm.crashed != _remote_crashed:
		_remote_crashed = fm.crashed
		sim_event.emit("crash" if fm.crashed else "reset", 0.0)
	global_transform = Transform3D(fm.rot, fm.pos)
	_sync_switches()
	# the moving surfaces and the gear legs: every frame up close; far away (a few pixels on screen) only every
	# sixth frame, catching up on the time in between. The jet itself is still placed every frame.
	_lod_dt += delta
	var cam := get_viewport().get_camera_3d()
	if cam != null and cam.global_position.distance_squared_to(fm.pos) > REMOTE_DETAIL_FAR * REMOTE_DETAIL_FAR:
		_lod_n += 1
		if _lod_n % 6 != 0:
			return
	_update_surfaces()
	_update_gear_visuals(_lod_dt)
	_lod_dt = 0.0


func _add_callsign() -> void:
	var l := Label3D.new()
	l.name = "Callsign"
	l.text = callsign
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0009
	l.font_size = 30
	l.outline_size = 8
	l.modulate = Color(1.0, 1.0, 1.0, 0.85)
	l.outline_modulate = Color(0.0, 0.0, 0.0, 0.6)
	l.no_depth_test = true
	l.position = Vector3(0.0, 4.5, 0.0)
	l.visibility_range_end = 15000.0
	l.visible = Game.show_names                   # off unless the player turned names on (F9)
	l.add_to_group("callsign_labels")
	add_child(l)
