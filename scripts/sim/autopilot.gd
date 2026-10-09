extends RefCounted
## Onboard autopilot, aircraft-agnostic: it only reads the flight model state and the aircraft spec and produces
## pilot-style inputs (pitch and roll stick; the speed hold drives the jet's auto-throttle). It never touches the
## physics, so it works for every jet that uses the FlightOut flight model, offline and online alike (the server
## just sees ordinary stick and throttle commands).
##
## Worked like a real mode control panel (Boeing MCP / Airbus FCU), the panel under the HUD:
##   - each window (SPD, HDG, ALT, V/S) shows a SELECTED value; its knob (or typing into it) only changes the
##     window, the jet does not react yet
##   - the button under a window ENTERS that value: the autopilot starts flying it (SPD speed, HDG turn to and hold,
##     ALT climb or descend to and hold, V/S climb or descend at that rate to the ALT window, then hold it)
##   - AP engages or disengages the whole autopilot. Engaging takes note of the speed, heading and altitude you
##     are flying and holds all three at once; one autopilot, no separate auto-throttle or altitude-hold switches
##   - LVL is horizon recovery: wings level, stop climbing or descending, then hold what it levelled at
## While disengaged the windows follow the jet unless you have turned a knob (preselected). A window that differs
## from what the autopilot is flying blinks its button: press it to enter the value.
## Moving the stick while engaged is control wheel steering: you fly, and when you let go it holds the heading
## and altitude you left it at. It disconnects on the ground, in a stall or a crash.
##
## Also here, always on: the take-off TAIL GUARD. Near the ground it limits how fast the nose can come up so the
## tail never touches the runway, however hard the pilot pulls.

const G := 9.80665
const BANK_MAX := 30.0          # deg
const VS_MAX := 15.0            # m/s climb or descent while changing altitude in ALT (about 3000 ft/min)
const TAIL_CLEAR := 0.45        # m the tail guard keeps between the tail and the runway
const ALT_DATUM := 2.0          # m: altitudes are shown as position height minus this (same as the flight data panel)
const KT := 1.94384
const FT := 3.28084

var engaged := false
var spd_on := false             # speed hold (drops out if the pilot moves the throttle)
var vert := "ALT"               # vertical mode while engaged: "ALT" (go to and hold alt_tgt) or "VS"
var level := false              # horizon recovery in progress

# panel windows (selected)
var spd_sel := 150.0            # m/s indicated
var hdg_sel := 0.0              # degrees
var alt_sel := 1000.0           # m above sea level (position height)
var vs_sel := 0.0               # m/s
# what the autopilot is flying (entered)
var spd_tgt := 150.0
var hdg_tgt := 0.0
var alt_tgt := 1000.0
var vs_tgt := 0.0
var _pre := {}                  # "SPD"/"HDG"/"ALT"/"VS" -> true when the pilot turned that knob (window stays put)

var status := ""                # reason after a disconnect, for the HUD ("OFF", "GROUND", "STALL")
var status_time := -100.0       # seconds (Time ticks) when status was set

var _pitch := 0.0
var _roll := 0.0
var _override := false
var _level_t := 0.0
var _vs_i := 0.0                # integral of vertical speed error: trims out the last few metres


# ------------------------------------------------------------------ state helpers
static func bank_deg(fm) -> float:
	var b: Basis = fm.rot
	return rad_to_deg(atan2(-b.x.y, b.y.y))


static func heading_deg(fm) -> float:
	var f: Vector3 = -fm.rot.z
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


static func gamma(fm) -> float:
	var v: Vector3 = fm.vel
	return asin(clampf(v.y / maxf(v.length(), 1.0), -1.0, 1.0))


## Converts a wanted change in load factor into pitch stick, the inverse of the fly-by-wire's G command.
static func stick_for_dn(spec, dn: float) -> float:
	return dn / (spec.g_max - 1.0) if dn > 0.0 else dn / (1.0 - spec.g_min)


func _stamp(reason: String) -> void:
	status = reason
	status_time = Time.get_ticks_msec() / 1000.0


## True when a window shows a value different from what the autopilot is flying: its button blinks.
func pending(id: String) -> bool:
	if not engaged:
		return false
	match id:
		"SPD": return absf(spd_sel - spd_tgt) > 0.3 or not spd_on
		"HDG": return absf(wrapf(hdg_sel - hdg_tgt, -180.0, 180.0)) > 0.5
		"ALT": return absf(alt_sel - alt_tgt) > 1.0
		"VS": return absf(vs_sel - (vs_tgt if vert == "VS" else 0.0)) > 0.05
	return false


## Mode lamp under a window: lit while the autopilot is flying that value.
func active(id: String) -> bool:
	if not engaged or level:
		return false
	match id:
		"SPD": return spd_on
		"HDG": return true
		"ALT": return true               # held, or being climbed / descended to
		"VS": return vert == "VS"
	return false


# ------------------------------------------------------------------ panel and keys
## While disengaged the windows follow the jet, except values the pilot preselected.
func follow(fm) -> void:
	if engaged:
		return
	if not _pre.get("SPD", false):
		spd_sel = fm.ias
	if not _pre.get("HDG", false):
		hdg_sel = heading_deg(fm)
	if not _pre.get("ALT", false):
		alt_sel = fm.pos.y
	if not _pre.get("VS", false):
		vs_sel = 0.0


## Hold what the jet is doing right now: speed, heading, altitude (led a little by the climb so it does not
## bounce back). Windows that were not preselected show the same values.
func _hold_current(fm) -> void:
	spd_tgt = fm.ias
	hdg_tgt = heading_deg(fm)
	alt_tgt = fm.pos.y + fm.vel.y * 2.0
	vs_tgt = 0.0
	vert = "ALT"
	_vs_i = 0.0
	for id in ["SPD", "HDG", "ALT", "VS"]:
		if not _pre.get(id, false):
			_sync(id)


func _sync(id: String) -> void:
	match id:
		"SPD": spd_sel = spd_tgt
		"HDG": hdg_sel = hdg_tgt
		"ALT": alt_sel = alt_tgt
		"VS": vs_sel = vs_tgt


func engage(fm) -> bool:
	if fm.wow or fm.crashed:
		_stamp("GROUND" if fm.wow else "OFF")
		return false
	engaged = true
	spd_on = true
	status = ""
	_hold_current(fm)
	# in a big bank or a steep climb or dive: level off first, then hold where it ends up
	level = absf(bank_deg(fm)) > 10.0 or absf(rad_to_deg(gamma(fm))) > 5.0
	_level_t = 0.0
	return true


func disengage(reason := "OFF") -> void:
	if engaged and reason != "":
		_stamp(reason)
	engaged = false
	spd_on = false
	level = false
	_pre.clear()


## A panel button (or its key): "AP", "LVL", or the enter button under a window: "SPD", "HDG", "ALT", "VS".
func press(id: String, fm) -> void:
	match id:
		"AP":
			if engaged:
				disengage("OFF")
			else:
				engage(fm)
		"LVL":
			if not engaged and not engage(fm):
				return
			level = true
			_level_t = 0.0
		"SPD", "HDG", "ALT", "VS":
			if not engaged and not engage(fm):
				return
			level = false
			match id:
				"SPD":
					spd_tgt = spd_sel
					spd_on = true
				"HDG":
					hdg_tgt = hdg_sel
				"ALT":
					alt_tgt = alt_sel
					vert = "ALT"
					_vs_i = 0.0
				"VS":
					if absf(vs_sel) < 0.05:
						# no rate set: a moderate 1000 ft/min toward the ALT window
						vs_sel = (1000.0 if alt_sel > fm.pos.y else -1000.0) / (FT * 60.0)
					vs_tgt = vs_sel
					alt_tgt = alt_sel          # V/S climbs or descends to the ALT window, then holds it
					vert = "VS"
			_pre.erase(id)


## A value typed into a panel window, in display units (kt or km/h, degrees, ft or m, ft/min or m/s).
## Like turning the knob: it sets the window; the button under it enters it.
func set_value(id: String, shown: float, imperial: bool) -> void:
	match id:
		"SPD":
			spd_sel = clampf(shown / (KT if imperial else 3.6), 60.0, 700.0)
		"HDG":
			hdg_sel = fposmod(round(shown), 360.0)
		"ALT":
			alt_sel = ALT_DATUM + clampf(shown / (FT if imperial else 1.0), 0.0, 20000.0)
		"VS":
			vs_sel = clampf(shown / (FT * 60.0 if imperial else 1.0), -60.0, 60.0)
	_pre[id] = true


## A panel knob (or its keys) turned by `steps` detents: changes the window only. Steps follow the display units.
func turn(id: String, steps: int, imperial: bool) -> void:
	if steps == 0:
		return
	match id:
		"SPD":
			spd_sel = clampf(spd_sel + steps * (5.0 / KT if imperial else 10.0 / 3.6), 60.0, 700.0)
		"HDG":
			hdg_sel = fposmod(round(hdg_sel) + steps, 360.0)
		"ALT":
			var step := 100.0 / FT if imperial else 50.0
			var shown := alt_sel - ALT_DATUM
			alt_sel = ALT_DATUM + clampf(round(shown / step + steps) * step, 0.0, 20000.0)
		"VS":
			var step := 100.0 / (FT * 60.0) if imperial else 1.0
			vs_sel = clampf(round(vs_sel / step + steps) * step, -60.0, 60.0)
	_pre[id] = true


func _capture(fm) -> void:
	hdg_tgt = heading_deg(fm)
	alt_tgt = fm.pos.y + fm.vel.y * 2.0
	vert = "ALT"
	_vs_i = 0.0
	_sync("HDG")
	_sync("ALT")
	_pre.erase("HDG")
	_pre.erase("ALT")


# ------------------------------------------------------------------ per tick
## Returns [pitch, roll] stick. pilot_pitch / pilot_roll are the pilot's own inputs (control wheel steering).
func update(fm, spec, dt: float, pilot_pitch: float, pilot_roll: float) -> Array:
	if engaged:
		if fm.crashed:
			disengage("OFF")
		elif fm.wow:
			disengage("GROUND")
		elif fm.stall_frac > 0.6:
			disengage("STALL")
	follow(fm)
	if not engaged:
		_pitch = pilot_pitch
		_roll = pilot_roll
		return [pilot_pitch, pilot_roll]

	var hands := absf(pilot_pitch) > 0.05 or absf(pilot_roll) > 0.05
	if hands:
		_override = true
		level = false
		_pitch = pilot_pitch
		_roll = pilot_roll
		return [pilot_pitch, pilot_roll]
	if _override:
		# stick released: hold what the pilot left it at
		_override = false
		_capture(fm)

	var v: float = maxf(fm.vel.length(), 40.0)
	var phi := bank_deg(fm)
	var gam := gamma(fm)

	# ---- vertical: flight path angle command -> G command -> pitch stick
	var vs_cmd := 0.0
	if level:
		vs_cmd = 0.0
	elif vert == "VS":
		vs_cmd = vs_tgt
		# reaching the target altitude: capture and hold it (a rate away from it just keeps going, as on real jets)
		var to_go: float = alt_tgt - fm.pos.y
		if (vs_tgt > 0.0 and to_go >= 0.0 and to_go < vs_tgt * 4.0) or (vs_tgt < 0.0 and to_go <= 0.0 and to_go > vs_tgt * 4.0):
			vert = "ALT"
	else:
		vs_cmd = clampf((alt_tgt - fm.pos.y) * 0.18, -VS_MAX, VS_MAX)
	if level or vert != "ALT" or absf(alt_tgt - fm.pos.y) > 150.0:
		_vs_i = 0.0
	else:
		_vs_i = clampf(_vs_i + (vs_cmd - fm.vel.y) * dt, -25.0, 25.0)
	var gam_cmd := asin(clampf(vs_cmd / v, -0.3, 0.3))
	var gam_rate := clampf((gam_cmd - gam) * 0.9, -0.12, 0.12)
	var dn := clampf(v * gam_rate / G + _vs_i * 0.015, -2.0, 2.0)
	var want_p := stick_for_dn(spec, dn)

	# ---- lateral: bank command -> roll rate command -> roll stick (wings level without HDG)
	var bank_cmd := 0.0
	if not level:
		var herr := wrapf(hdg_tgt - heading_deg(fm), -180.0, 180.0)
		bank_cmd = clampf(herr * 2.0, -BANK_MAX, BANK_MAX)
	var p_cmd := clampf(deg_to_rad(bank_cmd - phi) * 1.4, -0.4, 0.4)
	var want_r := p_cmd / maxf(spec.max_rates.z, 0.1)

	# smooth hands
	_pitch = move_toward(_pitch, clampf(want_p, -0.6, 0.3), dt * 1.2)
	_roll = move_toward(_roll, clampf(want_r, -0.4, 0.4), dt * 2.0)

	if level:
		_level_t += dt
		if absf(phi) < 3.0 and absf(rad_to_deg(gam)) < 1.0 and _level_t > 1.0:
			level = false
			_capture(fm)
	return [_pitch, _roll]


## Take-off tail guard: caps pitch stick near the ground so the nose comes up only as fast as the tail
## clearance allows. Uses the airframe's tail probe and main gear from the spec, so it fits any aircraft.
static func tail_guard(fm, spec, pitch_in: float) -> float:
	if pitch_in <= 0.0 or fm.crashed:
		return pitch_in
	var tp: Vector3 = fm.pos + fm.rot * spec.tail_probe
	var th: float = tp.y - float(fm._gh(tp.x, tp.z))
	if th > 6.0:
		return pitch_in
	# lever arm: rotation is about the main wheels on the runway, about the centre of gravity in the air
	var mains_z := 0.0
	for c in spec.gear_contacts:
		mains_z = maxf(mains_z, (c as Vector3).z)
	var arm: float = maxf(spec.tail_probe.z - (mains_z if fm.wow else 0.0), 2.0)
	var climb: float = maxf(fm.vel.y, 0.0)
	# pitch rate that would bring the tail down to the clearance limit in about a second, plus what climbing earns
	var q_max := maxf(th - TAIL_CLEAR, 0.0) / (arm * 1.1) + climb / arm
	var vs: float = maxf(fm.vel.length(), 40.0)
	var cap := stick_for_dn(spec, q_max * vs / G)
	return minf(pitch_in, cap)
