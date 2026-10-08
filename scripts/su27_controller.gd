extends Node3D
## Su-27 flight model for Flightout.
## Single-body aerodynamic model in the style of vazgriz/FlightSim:
## real velocity vector, angle of attack / sideslip, lift + induced drag + wave drag,
## thrust with afterburner and altitude lapse, gravity, ISA-style air density,
## and fly-by-wire style rate commands with an AoA / G limiter.
## Units: SI (m, kg, s, N). Godot forward is -Z, right is +X, up is +Y.

# ---------------- aircraft data (Su-27S, approximate) ----------------
const MASS := 23000.0              # kg, typical combat weight
const WING_AREA := 62.0            # m^2
const ASPECT_RATIO := 3.5
const OSWALD := 0.80
const CL_ALPHA := 3.6              # lift slope, per radian
const CL0 := 0.05
const ALPHA_STALL := deg_to_rad(26.0)
const CD0 := 0.024                 # clean parasite drag
const THRUST_DRY := 2.0 * 79400.0  # N, two AL-31F at military power
const THRUST_AB := 2.0 * 122600.0  # N, full afterburner
const THRUST_IDLE := 2.0 * 2500.0
const AB_THRESHOLD := 0.85         # throttle above this lights the afterburner
const SPOOL_RATE := 0.45           # engine response, fraction per second
const G_MAX := 9.0
const G_MIN := -3.0
const ALPHA_LIMIT := deg_to_rad(24.0)   # FBW AoA limit
const MAX_RATES := Vector3(0.65, 0.35, 3.8)  # pitch, yaw, roll  (rad/s)
const ANG_ACCEL := Vector3(2.5, 1.5, 9.0)    # rad/s^2
const Q_REF := 9000.0               # dynamic pressure for full control authority
const Q_REF_ROLL := 14000.0         # roll needs more airspeed for full rate (calmer on approach)

# ---------------- ground / gear ----------------
const GEAR_HEIGHT := 2.0            # origin height above ground, level, gear down
const NOSE_CONTACT := Vector3(0.0, -2.0, -5.2)
const MAIN_CONTACT := Vector3(0.0, -2.0, 1.7)
const TAIL_PROBE := Vector3(0.0, 0.0, 10.9)
const ROLL_FRICTION := 0.025
const WHEELBASE := 6.9             # m, nose wheel to main wheels
const MAX_STEER := deg_to_rad(55.0) # nose wheel angle at taxi speed
const BRAKE_FRICTION := 0.45
# suspension: one spring-damper per wheel; contact points are at full oleo extension (aircraft frame)
const STATIC_STROKE := 0.12          # oleo compression sitting on the ground
const MAX_STROKE := 0.32             # beyond this the gear bottoms out
const GEAR_CONTACTS := [Vector3(0.0, -2.12, -5.2), Vector3(-2.42, -2.12, 1.7), Vector3(2.42, -2.12, 1.7)]
const GEAR_K := [280000.0, 800000.0, 800000.0]    # N/m
const GEAR_C := [40000.0, 110000.0, 110000.0]     # N/(m/s)
const SINK_SMOOTH := 1.5            # m/s touchdown grades
const SINK_GOOD := 3.0
const SINK_FIRM := 4.5
const SINK_HARD := 7.0              # above this the gear collapses
const PRACTICE_DISTANCE := 7000.0   # m from the touchdown aim point
const GLIDESLOPE := deg_to_rad(3.0)
const GROUND_CLEARANCE := GEAR_HEIGHT
const MAX_GROUND_PITCH := deg_to_rad(13.0)   # tail touches the runway beyond this
const CRASH_PROBES := [Vector3(0.0, -0.2, -11.0), Vector3(7.4, -0.3, 1.0), Vector3(-7.4, -0.3, 1.0),
		Vector3(2.15, 3.9, 3.9), Vector3(-2.15, 3.9, 3.9), Vector3(0.0, 0.0, 10.9)]

const GRAVITY := 9.81
const RHO0 := 1.225

var spawn: Transform3D
var model: Node3D
var gear_player: AnimationPlayer
var canopy_player: AnimationPlayer
var brake_player: AnimationPlayer
var radar_player: AnimationPlayer
var radome_player: AnimationPlayer
var radar_clip := "radar_scan"

# state
var velocity := Vector3.ZERO
var omega := Vector3.ZERO           # body rates (local axes)
var throttle := 0.0
var engine := 0.0                   # spooled engine setting
var on_ground := true
var crashed := false
var crash_reason := ""
var gear_down := true
var canopy_open := false
var airbrake := false
var flaps := false
var radar_on := false
var radome_open := false
var wheel_brakes := false
var wow := true                     # weight on wheels
var nose_steer_deg := 0.0           # nose-wheel deflection, + = right
var gear_comp := [0.0, 0.0, 0.0]    # current oleo compression per wheel (nose, main L, main R)
var landing_event := ""             # last touchdown grade for the HUD
var landing_event_time := -100.0
var touchdown_sink := 0.0
var autothrottle := false
var at_target := 0.0
var _airborne_time := 0.0

# telemetry for HUD
var speed := 0.0
var mach := 0.0
var aoa_deg := 0.0
var g_load := 1.0
var vertical_speed := 0.0
var altitude_agl := 0.0
var thrust_now := 0.0

# smoothed pilot inputs (also drive control surface visuals)
var pitch_in := 0.0
var roll_in := 0.0
var yaw_in := 0.0
var flap_pos := 0.0
var brake_pos := 0.0

var fx: Node
var _surfaces := {}
var _tires: Array[Node3D] = []
var _nose_gear: Node3D
var _nose_rest: Basis
var _oleos: Array[Node3D] = []
var _oleo_rest: Array[Vector3] = []


func _ready() -> void:
	model = load("res://assets/su27.glb").instantiate()
	model.rotation.y = PI  # glTF model front is +Z, Godot forward is -Z
	add_child(model)

	gear_player = model.find_child("AnimationPlayer", true, false)
	canopy_player = _clone_player("CanopyPlayer")
	brake_player = _clone_player("AirbrakePlayer")
	radar_player = _clone_player("RadarPlayer")
	radome_player = _clone_player("RadomePlayer")
	for clip in gear_player.get_animation_list():
		if clip.begins_with("radar_scan"):
			radar_clip = clip
			gear_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR

	for n in ["Stabilator_L", "Stabilator_R", "Flaperon_L", "Flaperon_R",
			"Slat_L", "Slat_R", "Rudder_L", "Rudder_R"]:
		var node := model.find_child(n, true, false) as Node3D
		if node:
			_surfaces[n] = [node, node.transform.basis]
	fx = preload("res://scripts/aircraft/su27_effects.gd").new()
	fx.name = "Effects"
	add_child(fx)
	fx.setup(self, model)

	add_to_group("player_aircraft")
	# steering turns only the lower fork (oleo), the upper strut stays fixed
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


func _clone_player(player_name: String) -> AnimationPlayer:
	var p := AnimationPlayer.new()
	p.name = player_name
	gear_player.get_parent().add_child(p)
	p.root_node = gear_player.root_node
	for lib in gear_player.get_animation_library_list():
		p.add_animation_library(lib, gear_player.get_animation_library(lib))
	return p


# ---------------- atmosphere ----------------
func _air_density(h: float) -> float:
	return RHO0 * exp(-maxf(h, 0.0) / 8500.0)


func _speed_of_sound(h: float) -> float:
	return clampf(340.3 - 0.0039 * h, 295.0, 340.3)


# ---------------- aerodynamic coefficients ----------------
func _cl(alpha: float) -> float:
	var a := absf(alpha)
	var s := signf(alpha) if alpha != 0.0 else 1.0
	var linear := CL0 + CL_ALPHA * alpha
	if a <= ALPHA_STALL:
		return linear
	# post-stall: blend from peak toward flat-plate lift
	var peak := CL0 + CL_ALPHA * ALPHA_STALL * s
	var plate := 1.1 * sin(2.0 * alpha)
	var t := clampf((a - ALPHA_STALL) / deg_to_rad(15.0), 0.0, 1.0)
	return lerpf(peak, plate, t)


func _wave_drag(m: float) -> float:
	# transonic drag rise, peaks just above Mach 1 then eases off
	if m < 0.82:
		return 0.0
	if m < 1.1:
		return 0.032 * smoothstep(0.82, 1.1, m)
	return 0.032 - 0.010 * clampf((m - 1.1) / 1.0, 0.0, 1.0)


func _thrust(h: float, m: float) -> float:
	var lapse := pow(_air_density(h) / RHO0, 0.7) * (1.0 + 0.12 * clampf(m, 0.0, 1.5))
	var t: float
	if engine <= AB_THRESHOLD:
		t = lerpf(THRUST_IDLE, THRUST_DRY, engine / AB_THRESHOLD)
	else:
		t = lerpf(THRUST_DRY, THRUST_AB, (engine - AB_THRESHOLD) / (1.0 - AB_THRESHOLD))
	return t * lapse


# ---------------- main loop ----------------
func _physics_process(delta: float) -> void:
	_handle_toggles()
	if crashed:
		return
	_read_inputs(delta)
	var steps := 2
	var dt := delta / steps
	for i in steps:
		_simulate(dt)
		if crashed:
			break
	_update_surfaces()
	_update_nose_wheel(delta)
	if on_ground and gear_down and not gear_player.is_playing():
		for t in _tires:
			t.rotate_object_local(Vector3.RIGHT, speed / 0.45 * delta)


func _read_inputs(delta: float) -> void:
	pitch_in = move_toward(pitch_in, Input.get_axis("pitch_down", "pitch_up"), delta * 4.0)
	roll_in = move_toward(roll_in, Input.get_axis("roll_left", "roll_right"), delta * 5.0)
	yaw_in = move_toward(yaw_in, Input.get_axis("yaw_left", "yaw_right"), delta * 3.0)
	if Input.is_action_pressed("throttle_up"):
		throttle = minf(throttle + delta * 0.4, 1.0)
		autothrottle = false
	if Input.is_action_pressed("throttle_down"):
		throttle = maxf(throttle - delta * 0.4, 0.0)
		autothrottle = false
	if autothrottle:
		if wow:
			autothrottle = false
		else:
			# hold the captured airspeed without lighting the afterburner
			var err := at_target - speed
			throttle = clampf(throttle + clampf(err * 0.03, -0.4, 0.4) * delta, 0.0, AB_THRESHOLD)
	wheel_brakes = Input.is_action_pressed("wheel_brake")
	flap_pos = move_toward(flap_pos, 1.0 if flaps else 0.0, delta * 0.5)
	brake_pos = move_toward(brake_pos, 1.0 if airbrake else 0.0, delta * 1.5)
	engine = move_toward(engine, throttle, delta * SPOOL_RATE)


func _simulate(dt: float) -> void:
	var b := global_transform.basis
	var h := global_position.y - GEAR_HEIGHT
	var rho := _air_density(h)
	speed = velocity.length()
	mach = speed / _speed_of_sound(h)
	var q := 0.5 * rho * speed * speed

	# --- angles of attack / sideslip from velocity in body axes ---
	var vl := b.inverse() * velocity
	var alpha := 0.0
	var beta := 0.0
	if speed > 1.0:
		alpha = atan2(-vl.y, -vl.z)
		beta = atan2(vl.x, -vl.z)
	aoa_deg = rad_to_deg(alpha)

	# --- coefficients ---
	var cl := _cl(alpha) + flap_pos * 0.30
	var k := 1.0 / (PI * ASPECT_RATIO * OSWALD)
	var cd := CD0 + k * cl * cl + _wave_drag(mach) + 1.0 * pow(sin(alpha), 2)
	cd += flap_pos * 0.03 + brake_pos * 0.07
	if gear_down or gear_player.is_playing():
		cd += 0.02
	var cy := -0.6 * beta

	# --- forces (world) ---
	var force := Vector3(0.0, -MASS * GRAVITY, 0.0)
	var aero := Vector3.ZERO
	if speed > 1.0:
		var vdir := velocity / speed
		var right := b.x
		var lift_dir := right.cross(vdir).normalized()
		aero += lift_dir * q * WING_AREA * cl
		aero += -vdir * q * WING_AREA * cd
		aero += right * q * WING_AREA * cy * 0.5
	thrust_now = _thrust(h, mach)
	force += aero + (-b.z) * thrust_now
	g_load = aero.dot(b.y) / (MASS * GRAVITY)

	# --- landing gear: spring-damper per wheel (only when the gear is down and locked) ---
	var touching := false
	var gear_force := 0.0
	var locked := gear_down and not gear_player.is_playing()
	if locked:
		for i in 3:
			var cp: Vector3 = global_transform * GEAR_CONTACTS[i]
			var comp := maxf(-_height_above_ground(cp), 0.0)
			var rate := (comp - float(gear_comp[i])) / dt
			gear_comp[i] = comp
			if comp > 0.0:
				touching = true
				gear_force += maxf(GEAR_K[i] * minf(comp, MAX_STROKE) + GEAR_C[i] * rate, 0.0)
	else:
		gear_comp = [0.0, 0.0, 0.0]
	if touching and not wow:
		_on_touchdown()
	wow = touching
	if touching:
		force.y += gear_force
		var flat_v := Vector3(velocity.x, 0.0, velocity.z)
		var mu := BRAKE_FRICTION if wheel_brakes else ROLL_FRICTION
		if flat_v.length() > 0.05:
			force += -flat_v.normalized() * mu * gear_force
		elif thrust_now < mu * gear_force:
			velocity.x = 0.0
			velocity.z = 0.0
			force.x = 0.0
			force.z = 0.0

	var accel := force / MASS
	velocity += accel * dt

	# --- rotation: fly-by-wire rate command ---
	var eff := clampf(q / Q_REF, 0.05, 1.0)
	var eff_roll := clampf(q / Q_REF_ROLL, 0.05, 1.0)
	var cmd := Vector3(pitch_in * MAX_RATES.x * eff, -yaw_in * MAX_RATES.y * eff, -roll_in * MAX_RATES.z * eff_roll)
	# AoA / G limiter (pitch)
	var cl_slope_q := maxf(q * WING_AREA * CL_ALPHA, 1.0)
	var alpha_hi := minf(ALPHA_LIMIT, (G_MAX * MASS * GRAVITY) / cl_slope_q)
	var alpha_lo := maxf(-deg_to_rad(10.0), (G_MIN * MASS * GRAVITY) / cl_slope_q)
	if alpha > alpha_hi:
		cmd.x = minf(cmd.x, (alpha_hi - alpha) * 3.0)
	elif alpha < alpha_lo:
		cmd.x = maxf(cmd.x, (alpha_lo - alpha) * 3.0)
	# directional stability: nose weathervanes into the airflow
	cmd.y += -beta * 2.5 * eff
	if absf(alpha) > ALPHA_STALL:
		cmd.x += -(alpha - signf(alpha) * ALPHA_STALL) * 2.0
	# rate limits by angular acceleration
	omega.x = move_toward(omega.x, cmd.x, ANG_ACCEL.x * dt)
	omega.y = move_toward(omega.y, cmd.y, ANG_ACCEL.y * dt)
	omega.z = move_toward(omega.z, cmd.z, ANG_ACCEL.z * dt)

	if touching:
		# on the wheels: nose-wheel steering, wings held level by the gear, nose can't go below level
		omega.z = 0.0
		var fwd_speed := velocity.dot(-b.z)
		var steer_angle := yaw_in * MAX_STEER * clampf(1.0 - absf(fwd_speed) / 60.0, 0.12, 1.0)
		omega.y = -fwd_speed * tan(steer_angle) / WHEELBASE

	var w := omega.length()
	if w > 1e-6:
		b = b * Basis(omega / w, w * dt)
	b = b.orthonormalized()

	if touching:
		var e := b.get_euler()
		e.z = lerp_angle(e.z, 0.0, clampf(dt * 8.0, 0.0, 1.0))
		if e.x < 0.0:
			e.x = 0.0
			omega.x = maxf(omega.x, 0.0)
		if e.x > MAX_GROUND_PITCH:
			e.x = MAX_GROUND_PITCH
			omega.x = minf(omega.x, 0.0)
		b = Basis.from_euler(e)
		var side := b.x
		velocity -= side * velocity.dot(side) * clampf(dt * 12.0, 0.0, 1.0)

	global_transform.basis = b
	global_position += velocity * dt
	vertical_speed = velocity.y

	# --- hard limits: gear bottoming, tail bumper, belly / sea / terrain ---
	if locked:
		var worst := 0.0
		for i in 3:
			var cp2: Vector3 = global_transform * GEAR_CONTACTS[i]
			worst = maxf(worst, -_height_above_ground(cp2) - MAX_STROKE)
		if worst > 0.0:
			global_position.y += worst
			if velocity.y < -SINK_HARD:
				_crash("Landing gear collapsed (%.1f m/s)" % -velocity.y)
			velocity.y = maxf(velocity.y, 0.0)
		var mp := global_transform * MAIN_CONTACT
		if not crashed and touching and WorldData.is_water(mp.x, mp.z):
			_crash("Ditched in the sea")
	else:
		var belly := _height_above_ground(global_transform * Vector3(0.0, -1.3, 0.0))
		if belly < 0.0:
			var bp := global_transform * Vector3(0.0, -1.3, 0.0)
			_crash("Ditched in the sea" if WorldData.is_water(bp.x, bp.z) else "Belly landing, gear was up")
	# tail stinger: scrapes and rests on the runway instead of digging in
	var tail_h := _height_above_ground(global_transform * TAIL_PROBE)
	if tail_h < 0.0 and not crashed:
		if velocity.y < -5.0:
			_crash("Tail strike")
		else:
			global_position.y -= tail_h
			velocity.y = maxf(velocity.y, 0.0)
			if Time.get_ticks_msec() / 1000.0 - landing_event_time > 2.0:
				_event("TAIL STRIKE")
	on_ground = touching
	if on_ground:
		_airborne_time = 0.0
	else:
		_airborne_time += dt
	if not crashed and _airframe_hit_terrain():
		_crash("Hit the terrain")
	altitude_agl = maxf(_height_above_ground(global_position) - GEAR_HEIGHT, 0.0)


func _event(text: String) -> void:
	landing_event = text
	landing_event_time = Time.get_ticks_msec() / 1000.0


func _on_touchdown() -> void:
	# grade the landing from the sink rate at first contact (ignore taxi bumps)
	if _airborne_time < 1.0:
		return
	touchdown_sink = -velocity.y
	var bank := rad_to_deg(absf(global_transform.basis.get_euler().z))
	var grade := ""
	if touchdown_sink < SINK_SMOOTH:
		grade = "SMOOTH LANDING"
	elif touchdown_sink < SINK_GOOD:
		grade = "GOOD LANDING"
	elif touchdown_sink < SINK_FIRM:
		grade = "FIRM LANDING"
	elif touchdown_sink < SINK_HARD:
		grade = "HARD LANDING, gear overstressed"
	else:
		grade = "GEAR COLLAPSED"
	if bank > 8.0 and touchdown_sink < SINK_HARD:
		grade += ", one wheel first"
	_event("%s  (%.1f m/s)" % [grade, touchdown_sink])
	if touchdown_sink >= SINK_HARD:
		_crash("Landing gear collapsed (%.1f m/s)" % touchdown_sink)


func _height_above_ground(p: Vector3) -> float:
	return p.y - WorldData.ground_height(p.x, p.z)


func _ground_contact_height() -> float:
	# lowest gear contact point height above the terrain / sea surface
	var t := global_transform
	if not gear_down:
		return _height_above_ground(t * Vector3(0.0, -1.3, 0.0))
	return minf(_height_above_ground(t * NOSE_CONTACT), _height_above_ground(t * MAIN_CONTACT))


func _airframe_hit_terrain() -> bool:
	# nose, wingtips, fin tips and tail: any of them in the ground = crash
	var t := global_transform
	for lp in CRASH_PROBES:
		if lp.z > 9.0:
			continue
		if _height_above_ground(t * lp) < -0.3:
			return true
	return false


func _crash(reason: String) -> void:
	crashed = true
	crash_reason = reason
	velocity = Vector3.ZERO
	omega = Vector3.ZERO


# ---------------- visuals ----------------
func _set_surface(n: String, deg: float) -> void:
	if _surfaces.has(n):
		var e: Array = _surfaces[n]
		var node: Node3D = e[0]
		var rest: Basis = e[1]
		node.transform.basis = rest * Basis(Vector3.RIGHT, deg_to_rad(deg))


func _update_surfaces() -> void:
	# + angle = trailing edge up (stabs, flaperons), leading edge down (slats), trailing edge right (rudders)
	_set_surface("Stabilator_L", pitch_in * 15.0 - roll_in * 8.0)
	_set_surface("Stabilator_R", pitch_in * 15.0 + roll_in * 8.0)
	_set_surface("Flaperon_L", -roll_in * 20.0 - flap_pos * 30.0)
	_set_surface("Flaperon_R", roll_in * 20.0 - flap_pos * 30.0)
	var slat := maxf(flap_pos, clampf((aoa_deg - 8.0) / 10.0, 0.0, 1.0)) * 28.0
	_set_surface("Slat_L", slat)
	_set_surface("Slat_R", slat)
	_set_surface("Rudder_L", yaw_in * 25.0)
	_set_surface("Rudder_R", yaw_in * 25.0)


func _update_nose_wheel(delta: float) -> void:
	# tiller steering: the nose wheel follows Q/E whenever the wheels are on the ground,
	# even when stopped; it centres itself in the air
	var target := 0.0
	if wow:
		target = yaw_in * rad_to_deg(MAX_STEER) * clampf(1.0 - speed / 60.0, 0.12, 1.0)
	nose_steer_deg = move_toward(nose_steer_deg, target, 90.0 * delta)
	if _nose_gear:
		var steer := nose_steer_deg if (gear_down and not gear_player.is_playing()) else 0.0
		# model nose is +Z and model-left is +X, so a right turn is a negative rotation about +Y
		_nose_gear.transform.basis = _nose_rest * Basis(Vector3.UP, deg_to_rad(-steer))
	# oleo pistons: the model is built at static compression; extend in the air, compress on impact
	for i in _oleos.size():
		if _oleos[i] == null:
			continue
		var comp: float = gear_comp[i] if gear_down else STATIC_STROKE
		var offset := clampf(comp - STATIC_STROKE, -STATIC_STROKE, MAX_STROKE - STATIC_STROKE)
		_oleos[i].position = _oleos[i].position.lerp(_oleo_rest[i] + Vector3(0.0, offset, 0.0), clampf(delta * 25.0, 0.0, 1.0))


func _toggle_clip(p: AnimationPlayer, clip: String, open: bool) -> void:
	if open:
		p.play(clip)
	else:
		p.play_backwards(clip)


func _handle_toggles() -> void:
	if Input.is_action_just_pressed("reset"):
		reset()
	if crashed:
		return
	if Input.is_action_just_pressed("toggle_gear") and not on_ground and not gear_player.is_playing():
		gear_down = not gear_down
		gear_player.play("gear_extend" if gear_down else "gear_retract")
	if Input.is_action_just_pressed("toggle_canopy"):
		canopy_open = not canopy_open
		_toggle_clip(canopy_player, "canopy_open", canopy_open)
	if Input.is_action_just_pressed("toggle_airbrake"):
		airbrake = not airbrake
		_toggle_clip(brake_player, "airbrake_open", airbrake)
	if Input.is_action_just_pressed("toggle_radome"):
		radome_open = not radome_open
		_toggle_clip(radome_player, "radome_open", radome_open)
	if Input.is_action_just_pressed("toggle_flaps"):
		flaps = not flaps
	if Input.is_action_just_pressed("toggle_autothrottle") and not wow:
		autothrottle = not autothrottle
		at_target = speed
	if Input.is_action_just_pressed("practice_approach"):
		practice_approach()
	if Input.is_action_just_pressed("toggle_radar"):
		radar_on = not radar_on
		if radar_on:
			radar_player.play(radar_clip)
		else:
			radar_player.pause()


## Puts the jet on a 3 degree final approach to runway 36, 7 km out, configured to land.
func practice_approach() -> void:
	var aim := Vector3(0.0, 40.0, 7200.0)
	var start := aim + Vector3(0.0, PRACTICE_DISTANCE * tan(GLIDESLOPE) + GEAR_HEIGHT, PRACTICE_DISTANCE)
	var path := Vector3(0.0, -sin(GLIDESLOPE), -cos(GLIDESLOPE))
	global_transform = Transform3D(Basis.from_euler(Vector3(deg_to_rad(6.0), 0.0, 0.0)), start)
	velocity = path * 80.0
	omega = Vector3.ZERO
	crashed = false
	crash_reason = ""
	on_ground = false
	wow = false
	_airborne_time = 10.0
	gear_comp = [0.0, 0.0, 0.0]
	flaps = true
	flap_pos = 1.0
	airbrake = false
	throttle = 0.2
	engine = 0.2
	autothrottle = true
	at_target = 80.0
	if not gear_down or gear_player.is_playing():
		gear_down = true
	gear_player.play("gear_extend")
	gear_player.seek(gear_player.current_animation_length, true)
	_event("PRACTICE APPROACH  RWY 36")


func reset() -> void:
	global_transform = spawn
	velocity = Vector3.ZERO
	omega = Vector3.ZERO
	throttle = 0.0
	engine = 0.0
	on_ground = true
	crashed = false
	crash_reason = ""
	autothrottle = false
	gear_comp = [STATIC_STROKE, STATIC_STROKE, STATIC_STROKE]
	_airborne_time = 0.0
	if not gear_down:
		gear_down = true
		gear_player.play("gear_extend")
		gear_player.seek(gear_player.current_animation_length, true)
