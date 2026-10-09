extends Node
## Development: a two-ship formation flight for multiplayer tests, flown by script so it can run for minutes with
## nobody at the keys (`--dev-formation=lead` in one client, `--dev-formation=wing` in another, both online).
##
##   lead   waits for the wingman, takes off, climbs and flies laps between the waypoints (default Srinagar and
##          Awantipora, `--formation-route=ICAO,ICAO,...`) on its autopilot
##   wing   takes off with the lead, joins up and holds echelon right (SPOT metres right and behind the lead), flying
##          on the lead's jet as this client SHOWS it (as a pilot does), through the same autopilot
##
## Every rendered frame is logged to `--formation-log=<file.csv>` (frame time, CPU / GPU render time, physics,
## own and remote jet positions in world coordinates, network numbers) so two clients' logs can be put side by side
## (wall clock), and `--formation-time=<s>` ends the run (default 480 s after take-off roll starts).

const SPOT := Vector2(30.0, 30.0)          # m right of and behind the lead
const CRUISE_ALT := 4300.0                 # m above sea level (raised over high ground ahead, _terrain_guard)
const CRUISE_IAS := 165.0                  # m/s
const ROTATE_IAS := 78.0
const WAYPOINT_R := 2500.0

var aircraft: Node3D
var role := "lead"
var _route: Array[Vector2] = []
var _wp := 0
var _phase := "wait"
var _t := 0.0                               # since the take-off roll started
var _wait := 0.0
var _len := 480.0
var _gear_up := false
var _ias_rate := 0.0
var _prev_ias := 0.0
var _lead_hdg_prev := 0.0
var _lead_turn := 0.0                       # lead's turn rate, deg/s (smoothed)
var _log: FileAccess
var _vp: RID
var _last_phys := 0
var _min_agl := 1e9
var _weapons := "--formation-weapons" in OS.get_cmdline_user_args()   # fire the weapons demo once up and away
var _trim := 0.7                            # wingman throttle trim (integral of the station-keeping error)


func _ready() -> void:
	process_priority = 50                   # after the net client has placed the remote jets
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dev-formation="):
			role = arg.trim_prefix("--dev-formation=")
		elif arg.begins_with("--formation-log="):
			_log = FileAccess.open(arg.trim_prefix("--formation-log="), FileAccess.WRITE)
		elif arg.begins_with("--formation-time="):
			_len = arg.trim_prefix("--formation-time=").to_float()
		elif arg.begins_with("--formation-route="):
			for id in arg.trim_prefix("--formation-route=").split(","):
				_add_wp(id)
	if _route.is_empty():
		_add_wp("VIAW")
		_add_wp("VISR")
	aircraft.dev_pilot = self
	Game.client.log_snaps = _log != null
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	if _log:
		_log.store_line("us,sx,sy,sz,srx,sry,srz,wall,dt,cpu_ms,gpu_ms,phys_ms,proc_ms,phys_steps,phase,x,y,z,hdg,ias,agl,rx,ry,rz,dist,extrap,interp_ticks,rtt_ms,loss,corr,rewind_ms,srv_queue,draws,trip,lead")


func _add_wp(id: String) -> void:
	var a := WorldData.airfield(id)
	if not a.is_empty():
		_route.append(Vector2(float(a.x), float(a.z)))


static func world_pos(ac: Node3D) -> Vector3:
	var fm = ac.fm
	return fm.pos + Vector3(fm.ox, 0.0, fm.oz)


func _lead() -> Node3D:
	var r := get_tree().get_nodes_in_group("remote_aircraft")
	return r[0] if not r.is_empty() else null


## Called by the aircraft every simulation tick instead of reading the keys (scripts/aircraft/aircraft.gd).
func fly(ac: Node3D, delta: float) -> void:
	var fm = ac.fm
	var spec = ac.spec
	ac.yaw_in = 0.0
	_ias_rate = lerpf(_ias_rate, (fm.ias - _prev_ias) / maxf(delta, 1e-3), clampf(delta * 3.0, 0.0, 1.0))
	_prev_ias = fm.ias
	match _phase:
		"wait":
			ac.throttle = 0.0
			ac.wheel_brakes = true
			ac.pitch_in = 0.0
			ac.roll_in = 0.0
			# both jets in the game: give the other client a moment, then roll together
			if _lead() != null:
				_wait += delta
				if _wait > 4.0:
					_phase = "roll"
		"roll":
			_t += delta
			ac.wheel_brakes = false
			ac.throttle = 1.0
			ac.roll_in = 0.0
			ac.pitch_in = 0.0 if fm.ias < ROTATE_IAS else 0.45
			if ac.altitude_agl > 40.0 and not _gear_up:
				_gear_up = true
				ac.press_switch("toggle_gear")
			if ac.altitude_agl > 250.0:
				_phase = "climb"
				ac.autopilot.follow(fm)
				ac.autopilot.engage(fm)
		_:
			_t += delta
			var ap = ac.autopilot
			if not ap.engaged:
				ap.follow(fm)
				ap.engage(fm)
			ap.level = false
			ap.vert = "ALT"
			var spd := CRUISE_IAS
			var thr := -1.0
			if role == "wing" and _lead() != null:
				var r := _formation(ac, delta)
				ap.hdg_tgt = r[0]
				ap.alt_tgt = r[1]
				thr = r[2]
				_phase = "join" if r[3] > 300.0 else "form"
			else:
				var me := world_pos(ac)
				var wp := _route[_wp]
				if Vector2(me.x, me.z).distance_to(wp) < WAYPOINT_R:
					_wp = (_wp + 1) % _route.size()
					wp = _route[_wp]
				var want_hdg := fposmod(rad_to_deg(atan2(wp.x - me.x, -(wp.y - me.z))), 360.0)
				var herr := wrapf(want_hdg - ac.heading_deg, -180.0, 180.0)
				if absf(herr) > 100.0:
					herr = absf(herr)            # big reversals always to the right (the same, predictable way)
				ap.hdg_tgt = fposmod(ac.heading_deg + clampf(herr, -60.0, 60.0), 360.0)
				ap.alt_tgt = maxf(CRUISE_ALT, _terrain_guard(ac))
				_phase = "cruise"
			var out: Array = ap.update(fm, spec, delta, 0.0, 0.0)
			ac.pitch_in = ap.tail_guard(fm, spec, float(out[0]))
			ac.roll_in = float(out[1])
			if thr >= 0.0:
				ac.throttle = move_toward(ac.throttle, thr, 1.5 * delta)
			else:
				var want := clampf(0.62 + (spd - fm.ias) * 0.05 - _ias_rate * 0.35, 0.0, spec.ab_threshold - 0.01)
				ac.throttle = move_toward(ac.throttle, want, 0.8 * delta)
	if _weapons and (_phase == "cruise" or _phase == "form") and ac.get_parent().has_method("set_weapons_demo"):
		_weapons = false
		ac.get_parent().set_weapons_demo(true)
	_min_agl = minf(_min_agl, ac.altitude_agl) if _phase != "wait" and _phase != "roll" else _min_agl


## Highest ground ahead and to the sides over the next few kilometres, plus a margin.
func _terrain_guard(ac: Node3D) -> float:
	var me := world_pos(ac)
	var v: Vector3 = ac.fm.vel
	var f := Vector2(v.x, v.z).normalized()
	var top := -1e9
	for ang in [-0.8, -0.4, 0.0, 0.4, 0.8]:
		var d := f.rotated(ang)
		for km in [1.0, 2.5, 4.0, 6.0, 8.0]:
			var p: Vector2 = Vector2(me.x, me.z) + d * float(km) * 1000.0
			top = maxf(top, WorldData.terrain_height(p.x, p.y))
	return top + 700.0


## Wingman: [heading, altitude, throttle, distance to the spot] to fly echelon right on the lead.
func _formation(ac: Node3D, delta: float) -> Array:
	var lead := _lead()
	var lf = lead.fm
	var fm = ac.fm
	# the lead as this client shows it (predicted to the present, as a pilot sees it)
	var L: Vector3 = world_pos(lead)
	var me := world_pos(ac)
	var lv: Vector3 = lf.vel
	var flat := Vector3(lv.x, 0.0, lv.z)
	var fwd := flat.normalized() if flat.length() > 1.0 else -Vector3(lf.rot.z.x, 0.0, lf.rot.z.z).normalized()
	var right := Vector3(-fwd.z, 0.0, fwd.x)
	var spot: Vector3 = L + right * SPOT.x - fwd * SPOT.y
	var e: Vector3 = spot - me
	var rel: Vector3 = lv - fm.vel
	var lhdg := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var turn := wrapf(lhdg - _lead_hdg_prev, -180.0, 180.0) / maxf(delta, 1e-3)
	_lead_hdg_prev = lhdg
	_lead_turn = lerpf(_lead_turn, clampf(turn, -20.0, 20.0), clampf(delta * 2.0, 0.0, 1.0))
	var cross: float = e.dot(right)
	var cross_rate: float = rel.dot(right)
	var along: float = e.dot(fwd)
	var along_rate: float = rel.dot(fwd)
	var hdg := lhdg + _lead_turn * 1.5 + clampf(cross * 0.5 + cross_rate * 1.5, -35.0, 35.0)
	if e.length() > 400.0:
		# out of position: head for where the spot will be in a few seconds (pursuit), then settle in
		var aim: Vector3 = spot + lv * 4.0
		hdg = rad_to_deg(atan2(aim.x - me.x, -(aim.z - me.z)))
	var alt: float = maxf(spot.y + lv.y * 2.0, _terrain_guard(ac))
	# throttle: trim (integral) plus proportional on the gap along the lead's track and how fast it is closing
	var top: float = 1.0 if along > 300.0 else ac.spec.ab_threshold - 0.01
	_trim = clampf(_trim + (along * 0.0008 + along_rate * 0.01) * delta, 0.25, ac.spec.ab_threshold - 0.01)
	var thr := clampf(_trim + along * 0.006 + along_rate * 0.04, 0.0, top)
	return [fposmod(hdg, 360.0), alt, thr, e.length()]


func _process(delta: float) -> void:
	if _phase != "wait" and _t > _len:
		_finish()
		return
	if _log == null:
		return
	var me := world_pos(aircraft)
	var lead := _lead()
	var r := world_pos(lead) if lead != null else Vector3.ZERO
	var c: Node = Game.client
	var phys := Engine.get_physics_frames()
	var steps := phys - _last_phys
	_last_phys = phys
	var extrap := 0
	for id in c._remotes:
		extrap = 1 if c._remotes[id].stale else 0
	# as drawn this frame (physics interpolation): what the screen shows, own jet and the other one
	var so := WorldData.to_world(aircraft.get_global_transform_interpolated().origin)
	var sr := WorldData.to_world(lead.get_global_transform_interpolated().origin) if lead != null else Vector3.ZERO
	_log.store_line("%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.4f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%s,%.2f,%.2f,%.2f,%.1f,%.1f,%.0f,%.2f,%.2f,%.2f,%.1f,%d,%.1f,%.0f,%.1f,%d,%.1f,%d,%d,%.2f,%.2f" % [
		Time.get_ticks_usec(), so.x, so.y, so.z, sr.x, sr.y, sr.z, Time.get_unix_time_from_system(), delta * 1000.0,
		RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu(),
		RenderingServer.viewport_get_measured_render_time_gpu(_vp),
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, steps, _phase,
		me.x, me.y, me.z, aircraft.heading_deg, aircraft.ias, aircraft.altitude_agl,
		r.x, r.y, r.z, me.distance_to(r) if lead != null else -1.0, extrap, c.interp_delay, c.rtt_ms, c.loss_pct,
		c.corrections, c.rewind_ms, c.server_queue,
		int(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)), c.trip_ticks, c.lead_ticks])


func _finish() -> void:
	if _log:
		_log.flush()
		_log.close()
		_log = null
	if Game.client.log_snaps:
		var path := ""
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--formation-log="):
				path = arg.trim_prefix("--formation-log=").get_basename() + "_snaps.csv"
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_line("wall,id,t,js,offset")
		for l in Game.client.snap_log:
			f.store_line(l)
		f.close()
	print("FORMATION done: %s, %.0f s, lowest %.0f m above ground" % [role, _t, _min_agl])
	get_tree().quit()
