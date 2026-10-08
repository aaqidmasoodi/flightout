extends RefCounted
## FlightModel: 6-DOF rigid-body simulation of one aircraft. Pure data (no nodes, no rendering, seeded RNG),
## stepped on a fixed tick, so the same code can run on a client (prediction) and a server (authority).
##
## Frames: world is Godot's (north -Z, east +X, up +Y). Body: +X right, +Y up, +Z aft (nose is -Z).
## Body rates omega: x = pitch rate (nose up +), y = yaw (nose LEFT +), z = roll (right wing UP +).
## Aero conventions used in the coefficients: q = omega.x (nose up +), r = -omega.y (nose right +),
## p = -omega.z (right wing down +). Cm + nose up, Cn + nose right, Cl + right wing down.
## Controls: elevator + = trailing edge up (nose up), aileron + = roll right, rudder + = yaw right.

const Atmosphere = preload("res://scripts/sim/atmosphere.gd")
const JetEngine = preload("res://scripts/sim/jet_engine.gd")
const AircraftSpec = preload("res://scripts/aircraft/aircraft_spec.gd")
const G := 9.80665

var spec: AircraftSpec
var atmo: Atmosphere
## ground_height(x, z) -> float and is_water(x, z) -> bool, provided by the world (server or client).
var ground_height: Callable
var is_water: Callable

# ---------------- state ----------------
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var rot := Basis.IDENTITY
var omega := Vector3.ZERO
var fuel := 0.0
var engines: Array = []
var time := 0.0
var rng := RandomNumberGenerator.new()

# systems
var gear_down := true
var gear_pos := 1.0           # 0 up and locked .. 1 down and locked
var flaps := false
var flap_pos := 0.0
var airbrake := false
var airbrake_pos := 0.0
var limiter := true
var elev := 0.0               # actual surface positions (rad), after actuator limits
var ail := 0.0
var rud := 0.0
var steer := 0.0              # nose-wheel angle (rad, + right)

# inputs (set by the pilot, the network, or an AI)
var in_pitch := 0.0           # -1..1, + pull
var in_roll := 0.0            # -1..1, + right
var in_yaw := 0.0             # -1..1, + right
var in_throttle := 0.0        # 0..1 (AB above spec.ab_threshold)
var in_brake := 0.0           # 0..1

# outputs / telemetry
var mass := 0.0
var tas := 0.0
var ias := 0.0
var mach := 0.0
var qbar := 0.0
var alpha := 0.0
var beta := 0.0
var nz := 1.0
var stall_frac := 0.0
var buffet := 0.0
var thrust := 0.0
var fuel_flow := 0.0
var wind := Vector3.ZERO
var wow := false
var gear_comp := [0.0, 0.0, 0.0]
var wheel_speed := 0.0        # m/s rolling speed of the main wheels
var tail_scrape := false
var crashed := false
var crash_reason := ""
var events: Array = []        # [type, text, value] for UI/audio: "touchdown", "crash", "tailstrike", "gear_bottom"
var alpha_crit_deg := 30.0
var _air_time := 0.0
var _rock_t := 0.0
var _drop := 0.0
var _prev_comp := [0.0, 0.0, 0.0]


func setup(p_spec: AircraftSpec, p_atmo: Atmosphere, p_ground: Callable, p_water: Callable, p_seed: int = 1) -> void:
	spec = p_spec
	atmo = p_atmo
	ground_height = p_ground
	is_water = p_water
	rng.seed = p_seed
	engines.clear()
	for i in spec.engine_count:
		var e := JetEngine.new()
		e.configure(spec)
		engines.append(e)
	fuel = spec.fuel_default
	_update_mass()


func reset(xform: Transform3D, speed: float = 0.0, on_ground: bool = true) -> void:
	pos = xform.origin
	rot = xform.basis.orthonormalized()
	vel = -rot.z * speed
	omega = Vector3.ZERO
	crashed = false
	crash_reason = ""
	tail_scrape = false
	elev = 0.0; ail = 0.0; rud = 0.0; steer = 0.0
	gear_down = on_ground or gear_down
	gear_pos = 1.0 if gear_down else 0.0
	wow = on_ground
	_air_time = 0.0 if on_ground else 10.0
	_prev_comp = [0.0, 0.0, 0.0]
	fuel = spec.fuel_default
	for e in engines:
		e.n2 = e.idle_n2
		e.ab = 0.0
		e.ab_lit = false
	events.clear()


func set_engines_n2(n2: float) -> void:
	for e in engines:
		e.n2 = n2


func _update_mass() -> void:
	mass = spec.empty_mass + spec.misc_mass + fuel


func inertia() -> Vector3:
	return spec.inertia * (mass / spec.inertia_ref_mass)


# ======================================================================================
func step(dt: float) -> void:
	if crashed:
		vel = vel.move_toward(Vector3.ZERO, 30.0 * dt)
		omega = omega.move_toward(Vector3.ZERO, 3.0 * dt)
		pos += vel * dt
		return
	time += dt
	_update_systems(dt)
	_update_mass()
	var I := inertia()

	# ---- air data ----
	var gh: float = ground_height.call(pos.x, pos.z)
	wind = atmo.wind_at(pos, time, gh)
	var air := vel - wind
	var rho := Atmosphere.density(pos.y)
	var vb := rot.transposed() * air
	tas = air.length()
	var v := maxf(tas, 0.5)
	mach = tas / Atmosphere.speed_of_sound(pos.y)
	qbar = 0.5 * rho * tas * tas
	ias = sqrt(2.0 * qbar / Atmosphere.RHO0)
	alpha = atan2(-vb.y, -vb.z) if tas > 1.0 else 0.0
	beta = asin(clampf(vb.x / v, -1.0, 1.0)) if tas > 1.0 else 0.0
	var pr := -omega.z        # roll rate (right wing down +)
	var qr := omega.x         # pitch rate (nose up +)
	var rr := -omega.y        # yaw rate (nose right +)

	# ---- engines ----
	thrust = 0.0
	fuel_flow = 0.0
	for e in engines:
		e.step(dt, in_throttle, fuel > 0.0, rho / Atmosphere.RHO0, mach)
		thrust += e.thrust
		fuel_flow += e.fuel_flow
	fuel = maxf(fuel - fuel_flow * dt, 0.0)

	# ---- aerodynamic state ----
	var S: float = spec.wing_area
	var b: float = spec.wing_span
	var c: float = spec.mac
	var slats := maxf(flap_pos, clampf((rad_to_deg(alpha) - 8.0) / 10.0, 0.0, 1.0))
	alpha_crit_deg = spec.alpha_crit_deg * _crit_scale(mach) + slats * spec.slat_crit_bonus_deg
	var a_abs := absf(alpha)
	var crit := deg_to_rad(alpha_crit_deg)
	stall_frac = clampf((a_abs - crit * spec.alpha_buffet_frac) / (crit * (1.0 - spec.alpha_buffet_frac)), 0.0, 1.0)
	buffet = clampf(stall_frac * 1.3, 0.0, 1.0) * clampf(tas / 40.0, 0.0, 1.0)
	var phat := pr * b / (2.0 * v)
	var qhat := qr * c / (2.0 * v)
	var rhat := rr * b / (2.0 * v)
	var e_eff := clampf(cos(alpha) * 1.15, 0.35, 1.0)          # tailplane loses bite at very high AoA
	var a_eff := 1.0 - 0.75 * stall_frac                      # roll control fades in the stall
	var cnb := spec.cn_beta * (1.0 - 1.1 * stall_frac)          # weathercock stability collapses deep in the stall

	# base moments without control deflection (used by the fly-by-wire inversion and the real moments)
	var cm0: float = _table(spec.cm_table, rad_to_deg(alpha)) + spec.cm_q * qhat + spec.flap_cm * flap_pos
	var cl0: float = spec.cl_beta * beta + spec.cl_p * phat + spec.cl_r * rhat
	var cn0: float = cnb * beta + spec.cn_r * rhat

	# ---- fly-by-wire: compute surface demands, then move the actuators ----
	_fly_by_wire(dt, I, S, b, c, cm0, cl0, cn0, e_eff, a_eff, pr, qr, rr, v)

	# ---- aerodynamic coefficients with the actual surfaces ----
	var cl_lift := _cl(alpha, mach, slats) + spec.flap_cl * flap_pos + spec.cl_de * elev * e_eff
	var hgt := pos.y - spec.wing_height_offset - gh
	var ge := _ground_effect(hgt, b)
	cl_lift *= 1.0 + 0.10 * (1.0 - ge)
	var k := 1.0 / (PI * spec.aspect_ratio * spec.oswald)
	var cd: float = spec.cd0 + k * cl_lift * cl_lift * ge + _wave_drag(mach) + 1.1 * pow(sin(alpha), 2.0)
	cd += spec.flap_cd * flap_pos + spec.airbrake_cd * airbrake_pos + spec.gear_cd * gear_pos
	cd += 0.04 * (absf(elev) + absf(rud) * 0.5)
	var cy: float = spec.cy_beta * beta + spec.cy_dr * rud
	var cm := cm0 + spec.cm_de * elev * e_eff
	# post-stall: wing rock and an occasional wing drop (seeded, deterministic)
	var rock := 0.0
	# progression: early buffet is a warning (shake, mild rock); departure tendencies only past mid-stall
	if stall_frac > 0.0:
		_rock_t += dt
		var deep := clampf((stall_frac - 0.3) / 0.7, 0.0, 1.0)
		rock = sin(_rock_t * TAU * 0.5) * 0.018 * deep * deep
		if stall_frac > 0.5 and rng.randf() < 0.004 * (stall_frac - 0.5) * 2.0:
			_drop = rng.randf_range(-1.0, 1.0) * 0.025 * stall_frac
	_drop = move_toward(_drop, 0.0, 0.02 * dt)
	var cl_roll := cl0 + spec.cl_da * ail * a_eff + spec.cl_dr * rud + rock + _drop
	var cn_yaw := cn0 + spec.cn_dr * rud + spec.cn_da * ail + (rock + _drop) * 0.3

	# ---- forces (world) ----
	var force := Vector3(0.0, -mass * G, 0.0)
	var torque := Vector3.ZERO     # body frame
	if tas > 0.5:
		var vdir := air / tas
		var right := rot.x
		var lift_dir := right.cross(vdir)
		if lift_dir.length_squared() < 1e-6:
			lift_dir = rot.y
		lift_dir = lift_dir.normalized()
		var side_dir := vdir.cross(lift_dir).normalized()
		force += lift_dir * qbar * S * cl_lift - vdir * qbar * S * cd + side_dir * qbar * S * cy
		torque += Vector3(qbar * S * c * cm, -qbar * S * b * cn_yaw, -qbar * S * b * cl_roll)
	force += -rot.z * thrust

	# ---- landing gear and airframe contacts ----
	var g_res := _ground_contacts(dt, gh)
	force += g_res[0]
	torque += g_res[1]

	# ---- integrate (semi-implicit Euler) ----
	var acc := force / mass
	nz = (acc + Vector3(0.0, G, 0.0)).dot(rot.y) / G
	vel += acc * dt
	pos += vel * dt
	var Iw := Vector3(I.x * omega.x, I.y * omega.y, I.z * omega.z)
	var gyro := omega.cross(Iw)
	var wdot := Vector3((torque.x - gyro.x) / I.x, (torque.y - gyro.y) / I.y, (torque.z - gyro.z) / I.z)
	omega += wdot * dt
	var ang := omega.length() * dt
	if ang > 1e-9:
		rot = (rot * Basis(omega.normalized(), ang)).orthonormalized()

	if wow:
		_air_time = 0.0
	else:
		_air_time += dt


# ---------------- systems ----------------
func _update_systems(dt: float) -> void:
	var g_target := 1.0 if gear_down else 0.0
	gear_pos = move_toward(gear_pos, g_target, dt / spec.gear_transit_time)
	flap_pos = move_toward(flap_pos, 1.0 if flaps else 0.0, dt / 2.5)
	airbrake_pos = move_toward(airbrake_pos, 1.0 if airbrake else 0.0, dt / 1.5)


# ---------------- fly-by-wire (nonlinear dynamic inversion) ----------------
func _fly_by_wire(dt: float, I: Vector3, S: float, b: float, c: float, cm0: float, cl0: float, cn0: float,
		e_eff: float, a_eff: float, pr: float, qr: float, rr: float, v: float) -> void:
	var up := Vector3.UP
	var fwd := -rot.z
	var phi := atan2(rot.x.y, rot.y.y)            # bank angle
	var theta := asin(clampf(fwd.y, -1.0, 1.0))
	var vs := maxf(v, 40.0)

	# pitch: g-command with flight-path hold at neutral stick, AoA and G protection
	var n_extra := in_pitch * ((spec.g_max - 1.0) if in_pitch > 0.0 else (1.0 - spec.g_min))
	# neutral stick: hold the flight path, including the extra pull a coordinated level turn needs
	var bank_c := clampf(phi, -deg_to_rad(70.0), deg_to_rad(70.0))
	var q_cmd := G * n_extra / vs + G * sin(bank_c) * tan(bank_c) / vs * (0.0 if wow else 1.0)
	q_cmd = clampf(q_cmd, -spec.max_rates.x, spec.max_rates.x)
	# The override only lasts while the pilot holds aft stick (as on the Su-27): relax the pull and the
	# protections come back and fly the nose down out of the post-stall regime.
	var protect := limiter or in_pitch < 0.35
	if protect:
		var a_lim := minf(deg_to_rad(spec.alpha_limit_deg), deg_to_rad(alpha_crit_deg - 3.0))
		q_cmd = minf(q_cmd, 3.0 * (a_lim - alpha))
		q_cmd = maxf(q_cmd, 3.0 * (deg_to_rad(-10.0) - alpha))
		var n_up := spec.g_max - nz
		if n_up < 1.0:
			q_cmd = minf(q_cmd, n_up * G / vs)
		var n_dn := nz - spec.g_min
		if n_dn < 1.0:
			q_cmd = maxf(q_cmd, -n_dn * G / vs)
	else:
		# limiter override with aft stick held: the elevator goes to the stop (Cobra territory)
		q_cmd = maxf(q_cmd, in_pitch * spec.max_rates.x * 3.5)

	# roll: rate command about the VELOCITY vector (stability axis), as real fighter fly-by-wire does.
	# Rolling about the body axis at high AoA would turn AoA into sideslip and depart the jet.
	var p_stab := in_roll * spec.max_rates.z
	var ca := cos(clampf(alpha, -1.2, 1.2))
	var sa := sin(clampf(alpha, -1.2, 1.2))
	var p_cmd := p_stab * ca
	# yaw: stability-axis roll coupling + turn coordination + pedal + sideslip suppression
	var r_cmd := 0.0
	if not wow:
		r_cmd = p_stab * sa + G * sin(phi) * cos(theta) / vs + in_yaw * spec.max_rates.y + 1.5 * beta
	else:
		r_cmd = in_yaw * spec.max_rates.y

	# inversion: surface deflection that produces the wanted angular acceleration
	var qd := spec.fbw_gains.x * (q_cmd - qr)
	var pd := spec.fbw_gains.z * (p_cmd - pr)
	var rd := spec.fbw_gains.y * (r_cmd - rr)
	var e_cmd := 0.0
	var a_cmd := 0.0
	var r_dem := 0.0
	var qs := qbar * S
	if qs * c > 1500.0:
		e_cmd = (I.x * qd / (qs * c) - cm0) / (spec.cm_de * e_eff)
		a_cmd = (I.z * pd / (qs * b) - cl0) / (spec.cl_da * a_eff)
		r_dem = (I.y * rd / (qs * b) - cn0 - spec.cn_da * ail) / spec.cn_dr
	# at very low airspeed the inversion is meaningless: surfaces just follow the stick
	var direct := clampf(1.0 - (qs * c - 1500.0) / 6000.0, 0.0, 1.0)
	var e_max := deg_to_rad(spec.elevator_up_deg)
	var e_min := -deg_to_rad(spec.elevator_down_deg)
	var a_max := deg_to_rad(spec.aileron_deg)
	var r_max := deg_to_rad(spec.rudder_deg)
	e_cmd = lerpf(e_cmd, (in_pitch * e_max) if in_pitch > 0.0 else (-in_pitch * e_min), direct)
	a_cmd = lerpf(a_cmd, in_roll * a_max, direct)
	r_dem = lerpf(r_dem, in_yaw * r_max, direct)
	e_cmd = clampf(e_cmd, e_min, e_max)
	a_cmd = clampf(a_cmd, -a_max, a_max)
	r_dem = clampf(r_dem, -r_max, r_max)
	# actuators: finite rate
	elev = move_toward(elev, e_cmd, deg_to_rad(spec.actuator_rates.x) * dt)
	ail = move_toward(ail, a_cmd, deg_to_rad(spec.actuator_rates.z) * dt)
	rud = move_toward(rud, r_dem, deg_to_rad(spec.actuator_rates.y) * dt)


# ---------------- ground contact ----------------
## Returns [force_world, torque_body]. Spring-damper struts, tyre rolling/braking/side forces,
## nose-wheel steering, tail strikes, and crash detection for the rest of the airframe.
func _ground_contacts(dt: float, gh: float) -> Array:
	var f_total := Vector3.ZERO
	var t_total := Vector3.ZERO
	var touching := false
	var locked := gear_pos > 0.98
	var m_share := mass / 3.0
	# nose-wheel steering: full angle at taxi speed, a few degrees by take-off speed
	var gs := Vector2(vel.x, vel.z).length()
	var steer_lim := lerpf(deg_to_rad(spec.max_steer_deg), deg_to_rad(4.0), clampf(gs / 40.0, 0.0, 1.0))
	steer = move_toward(steer, in_yaw * steer_lim, 1.2 * dt)
	wheel_speed = 0.0
	for i in 3:
		var rb: Vector3 = spec.gear_contacts[i]
		var pw := pos + rot * rb
		var h: float = pw.y - (ground_height.call(pw.x, pw.z) as float)
		var comp := -h
		gear_comp[i] = 0.0
		if not locked or comp <= 0.0:
			_prev_comp[i] = 0.0
			continue
		touching = true
		comp = minf(comp, spec.max_stroke * 1.6)
		var comp_rate := (comp - (_prev_comp[i] as float)) / dt
		_prev_comp[i] = comp
		gear_comp[i] = clampf(comp, 0.0, spec.max_stroke)
		var kspring: float = spec.gear_k[i]
		var cdamp: float = spec.gear_c[i]
		var fn := kspring * comp + cdamp * comp_rate
		if comp > spec.max_stroke:
			fn += kspring * 8.0 * (comp - spec.max_stroke)    # bottomed out
		fn = maxf(fn, 0.0)
		# wheel axes on the ground plane
		var fwd := -rot.z
		if i == 0:
			fwd = (rot * Basis(Vector3.UP, -steer)) * Vector3(0, 0, -1)
		fwd.y = 0.0
		fwd = fwd.normalized() if fwd.length() > 1e-4 else Vector3(0, 0, -1)
		var lat := Vector3(-fwd.z, 0.0, fwd.x)       # right of the wheel
		var vp := vel + rot * omega.cross(rb)
		var v_long := vp.dot(fwd)
		var v_lat := vp.dot(lat)
		if i > 0:
			wheel_speed = v_long
		# rolling resistance and brakes (brakes on the mains)
		var mu_long: float = spec.roll_friction + (spec.brake_friction * in_brake if i > 0 else 0.0)
		var f_long := -signf(v_long) * mu_long * fn
		if absf(v_long) < 0.6:
			f_long = clampf(-v_long * m_share / dt * 0.5, -mu_long * fn, mu_long * fn)
		# tyre side force: grips up to the friction limit
		var f_lat := clampf(-v_lat * m_share / dt * 0.5, -spec.tyre_side_friction * fn, spec.tyre_side_friction * fn)
		var f := Vector3.UP * fn + fwd * f_long + lat * f_lat
		f_total += f
		t_total += rot.transposed() * (pw - pos).cross(f)
	# tail stinger
	tail_scrape = false
	var tp := pos + rot * spec.tail_probe
	var th := tp.y - (ground_height.call(tp.x, tp.z) as float)
	if th < 0.0:
		tail_scrape = true
		var vtp := vel + rot * omega.cross(spec.tail_probe)
		if vtp.y < -5.0:
			_crash("TAIL STRIKE")
		var fn_t := maxf(-th * 2.0e6 - vtp.y * 2.0e5, 0.0)
		var ft := Vector3.UP * fn_t - Vector3(vtp.x, 0.0, vtp.z).normalized() * fn_t * 0.4
		f_total += ft
		t_total += rot.transposed() * (tp - pos).cross(ft)
		_event("tailstrike", "TAIL STRIKE", 0.0)
	# touchdown grading
	if touching and not wow and _air_time > 1.0:
		var sink := -vel.y
		if sink >= spec.sink_hard:
			_crash("GEAR COLLAPSED  (%.1f m/s)" % sink)
		else:
			var grade := "SMOOTH LANDING" if sink < spec.sink_smooth else ("GOOD LANDING" if sink < spec.sink_good else ("FIRM LANDING" if sink < spec.sink_firm else "HARD LANDING"))
			_event("touchdown", "%s  (%.1f m/s)" % [grade, sink], sink)
	wow = touching
	# airframe (nose, wingtips, fins, belly when the gear is up) must not touch
	for p in spec.crash_probes:
		var cp := pos + rot * (p as Vector3)
		if cp.y - (ground_height.call(cp.x, cp.z) as float) < 0.0:
			_crash("WATER" if is_water.call(cp.x, cp.z) else "TERRAIN")
	if not locked:
		var belly := pos + rot * Vector3(0.0, -1.2, 0.0)
		if belly.y - gh < 0.0:
			_crash("WATER" if is_water.call(belly.x, belly.z) else ("BELLY LANDING" if gear_pos < 0.05 else "GEAR NOT LOCKED"))
	if is_water.call(pos.x, pos.z) and pos.y - gh < spec.gear_height:
		_crash("WATER")
	return [f_total, t_total]


func _crash(reason: String) -> void:
	if crashed:
		return
	crashed = true
	crash_reason = reason
	_event("crash", reason, vel.length())


func _event(type: String, text: String, value: float) -> void:
	for e in events:
		if e[0] == type:
			return
	events.append([type, text, value])


# ---------------- aerodynamic tables ----------------
func _crit_scale(m: float) -> float:
	if m < 0.55:
		return 1.0
	if m < 1.2:
		return lerpf(1.0, 0.5, (m - 0.55) / 0.65)
	return 0.5


func _compressibility(m: float) -> float:
	if m < 0.9:
		return clampf(1.0 / sqrt(maxf(1.0 - m * m, 0.3)), 1.0, 1.3)
	if m < 1.15:
		return lerpf(1.3, 0.8, (m - 0.9) / 0.25)
	return 0.8


## Linear interpolation in an [x, y] table; outside the range it clamps. Negative x mirrors with sign.
func _table(tab: Array, x: float) -> float:
	if tab.is_empty():
		return 0.0
	var first: Array = tab[0]
	if x <= first[0]:
		return first[1]
	for i in tab.size() - 1:
		var p0: Array = tab[i]
		var p1: Array = tab[i + 1]
		if x <= p1[0]:
			return lerpf(p0[1], p1[1], (x - p0[0]) / (p1[0] - p0[0]))
	var last: Array = tab[tab.size() - 1]
	return last[1]


func _cl(a: float, m: float, slats: float) -> float:
	var crit := spec.alpha_crit_deg * _crit_scale(m) + slats * spec.slat_crit_bonus_deg
	var a_deg := rad_to_deg(a)
	var a_eff := absf(a_deg) * spec.alpha_crit_deg / crit
	var v := _table(spec.cl_table, minf(a_eff, 90.0)) if a_eff < 90.0 else 0.0
	if a_deg < 0.0:
		v = -v * 0.85
	return v * _compressibility(m)


func _wave_drag(m: float) -> float:
	if m < 1.1:
		return spec.wave_drag_peak * smoothstep(0.82, 1.1, m)
	return spec.wave_drag_peak * (1.0 - 0.31 * clampf((m - 1.1) / 1.0, 0.0, 1.0))


func _ground_effect(h: float, span: float) -> float:
	var x := 16.0 * maxf(h, 0.05) / span
	return (x * x) / (1.0 + x * x)
