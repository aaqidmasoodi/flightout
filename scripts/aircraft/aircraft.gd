extends Node3D
## Player aircraft node: a thin wrapper around the pure-data FlightModel (scripts/sim/flight_model.gd).
## It reads the pilot's controls, steps the simulation on the fixed physics tick, and drives everything you
## see from the simulation state: actuator positions move the surfaces, gear transit drives the animation,
## strut compression moves the oleos. Events (touchdown, crash, gear, afterburner) are emitted for audio and HUD.

signal sim_event(type: String, value: float)

const FlightModel = preload("res://scripts/sim/flight_model.gd")
const AircraftSpec = preload("res://scripts/aircraft/aircraft_spec.gd")
const SUBSTEPS := 2                  # 2 x 120 Hz physics ticks = 240 Hz simulation
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

# pilot / systems state that lives on the client
var throttle := 0.0
var canopy_open := false
var radar_on := false
var radome_open := false
var wheel_brakes := false
var autothrottle := false
var at_target := 0.0
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
	get: return global_position.y - spec.gear_height - WorldData.ground_height(global_position.x, global_position.z)
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


func _ready() -> void:
	if spec == null:
		spec = load("res://data/aircraft/su27.tres")
	fm = FlightModel.new()
	fm.setup(spec, WorldData.atmosphere, WorldData.ground_height, WorldData.is_water, 7)
	model = load(spec.model_scene).instantiate()
	model.rotation.y = PI  # glTF model front is +Z, Godot forward is -Z
	add_child(model)

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
	fm.reset(global_transform, 0.0, true)


func _system_player(player_name: String, source: AnimationPlayer, clips: Dictionary, names: Array) -> AnimationPlayer:
	var p := AnimationPlayer.new()
	p.name = player_name
	source.get_parent().add_child(p)
	p.root_node = source.root_node
	var lib := AnimationLibrary.new()
	for n in names:
		if clips.has(n):
			lib.add_animation(n, _only_moving_tracks(clips[n]))
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
	_handle_toggles()
	_read_inputs(delta)
	fm.in_pitch = pitch_in
	fm.in_roll = roll_in
	fm.in_yaw = yaw_in
	fm.in_throttle = throttle
	fm.in_brake = 1.0 if wheel_brakes else 0.0
	var dt := delta / SUBSTEPS
	for i in SUBSTEPS:
		fm.step(dt)
	global_transform = Transform3D(fm.rot, fm.pos)
	_process_events()
	_update_surfaces()
	_update_gear_visuals(delta)


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
	var pitch_axis := Input.get_axis("pitch_down", "pitch_up")
	if bool(Settings.get_value("controls/invert_pitch")):
		pitch_axis = -pitch_axis
	pitch_in = move_toward(pitch_in, pitch_axis, delta * 4.0)
	roll_in = move_toward(roll_in, Input.get_axis("roll_left", "roll_right"), delta * 5.0)
	yaw_in = move_toward(yaw_in, Input.get_axis("yaw_left", "yaw_right"), delta * 3.0)
	if Input.is_action_pressed("throttle_up"):
		throttle = minf(throttle + delta * 0.4, 1.0)
		autothrottle = false
	if Input.is_action_pressed("throttle_down"):
		throttle = maxf(throttle - delta * 0.4, 0.0)
		autothrottle = false
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


func _event(text: String) -> void:
	landing_event = text
	landing_event_time = Time.get_ticks_msec() / 1000.0


# ---------------- visuals from simulation state ----------------
func _set_surface(n: String, deg: float) -> void:
	if _surfaces.has(n):
		var e: Array = _surfaces[n]
		(e[0] as Node3D).transform.basis = (e[1] as Basis) * Basis(Vector3.RIGHT, deg_to_rad(deg))


func _update_surfaces() -> void:
	# the surfaces show the real actuator positions the fly-by-wire is commanding
	var e := rad_to_deg(fm.elev)
	var a := rad_to_deg(fm.ail)
	var r := rad_to_deg(fm.rud)
	_set_surface("Stabilator_L", e - a * 0.4)
	_set_surface("Stabilator_R", e + a * 0.4)
	_set_surface("Flaperon_L", -a - fm.flap_pos * 30.0)
	_set_surface("Flaperon_R", a - fm.flap_pos * 30.0)
	var slat := maxf(fm.flap_pos, clampf((aoa_deg - 8.0) / 10.0, 0.0, 1.0)) * 28.0
	_set_surface("Slat_L", slat)
	_set_surface("Slat_R", slat)
	_set_surface("Rudder_L", r)
	_set_surface("Rudder_R", r)


func _update_gear_visuals(delta: float) -> void:
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


func _set_gear(down: bool) -> void:
	fm.gear_down = down
	gear_player.speed_scale = gear_player.get_animation("gear_extend").length / spec.gear_transit_time
	gear_player.play("gear_extend" if down else "gear_retract")
	sim_event.emit("gear_motion", 1.0 if down else 0.0)


func _handle_toggles() -> void:
	if Input.is_action_just_pressed("reset"):
		reset()
	if fm.crashed:
		return
	if Input.is_action_just_pressed("toggle_gear") and not fm.wow and not gear_player.is_playing():
		_set_gear(not fm.gear_down)
	if Input.is_action_just_pressed("toggle_canopy"):
		canopy_open = not canopy_open
		_toggle_clip(canopy_player, "canopy_open", canopy_open)
		sim_event.emit("canopy", 1.0 if canopy_open else 0.0)
	if Input.is_action_just_pressed("toggle_airbrake"):
		fm.airbrake = not fm.airbrake
		_toggle_clip(brake_player, "airbrake_open", fm.airbrake)
		sim_event.emit("airbrake", 1.0 if fm.airbrake else 0.0)
	if Input.is_action_just_pressed("toggle_radome"):
		radome_open = not radome_open
		_toggle_clip(radome_player, "radome_open", radome_open)
	if Input.is_action_just_pressed("toggle_flaps"):
		fm.flaps = not fm.flaps
		sim_event.emit("flaps", 1.0 if fm.flaps else 0.0)
	if Input.is_action_just_pressed("toggle_autothrottle") and not fm.wow:
		autothrottle = not autothrottle
		at_target = fm.ias
		sim_event.emit("switch", 0.0)
	if Input.is_action_just_pressed("practice_approach"):
		practice_approach()
	if Input.is_action_just_pressed("toggle_limiter"):
		fm.limiter = not fm.limiter
		_event("AOA LIMITER " + ("ON" if fm.limiter else "OFF  ·  CAREFUL"))
		sim_event.emit("switch", 0.0)
	if Input.is_action_just_pressed("toggle_radar"):
		radar_on = not radar_on
		sim_event.emit("switch", 0.0)
		if radar_on:
			radar_player.play(radar_clip)
		else:
			radar_player.pause()
	if Input.is_action_just_pressed("toggle_lights"):
		sim_event.emit("switch", 0.0)


func _snap_gear_down() -> void:
	fm.gear_down = true
	fm.gear_pos = 1.0
	gear_player.speed_scale = 1.0
	gear_player.play("gear_extend")
	gear_player.seek(gear_player.current_animation_length, true)


## Puts the jet on a 3 degree final approach to runway 36, 7 km out, configured to land.
func practice_approach() -> void:
	var aim := Vector3(0.0, 40.0, 7200.0)
	var start := aim + Vector3(0.0, PRACTICE_DISTANCE * tan(GLIDESLOPE) + spec.gear_height, PRACTICE_DISTANCE)
	var path := Vector3(0.0, -sin(GLIDESLOPE), -cos(GLIDESLOPE))
	fm.reset(Transform3D(Basis.from_euler(Vector3(deg_to_rad(5.0), 0.0, 0.0)), start), 0.0, false)
	sim_event.emit("reset", 0.0)
	fm.vel = path * 78.0
	fm.flaps = true
	fm.flap_pos = 1.0
	fm.airbrake = false
	fm.set_engines_n2(88.0)
	_snap_gear_down()
	throttle = 0.6
	autothrottle = true
	at_target = 78.0
	global_transform = Transform3D(fm.rot, fm.pos)
	reset_physics_interpolation()
	_event("PRACTICE APPROACH  RWY 36")


func reset() -> void:
	fm.reset(spawn, 0.0, true)
	sim_event.emit("reset", 0.0)
	throttle = 0.0
	autothrottle = false
	fm.flaps = false
	fm.flap_pos = 0.0
	_snap_gear_down()
	global_transform = spawn
	reset_physics_interpolation()
