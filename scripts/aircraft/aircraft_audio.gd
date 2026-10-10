extends Node3D
## Reactive aircraft sound. Every layer is driven by the simulation (core RPM, thrust, afterburner stage,
## dynamic pressure, buffet, wheel speed), positioned on the airframe in 3D (distance, air absorption, Doppler),
## shaped by jet directivity (whine forward, roar aft), and muffled in the cockpit.

const A = preload("res://scripts/core/audio.gd")
const DIR := "res://assets/audio/"
const INTAKE := Vector3(0.0, -0.6, -2.0)       # body frame (forward is -Z)
const NOZZLE := Vector3(0.0, 0.0, 10.0)

var ac: Node3D
var _whine: AudioStreamPlayer3D
var _core: AudioStreamPlayer3D
var _low: AudioStreamPlayer3D
var _ab: AudioStreamPlayer3D
var _ab_body: AudioStreamPlayer3D
var _wind: AudioStreamPlayer3D
var _buffet: AudioStreamPlayer3D
var _roll: AudioStreamPlayer3D
var _motor: AudioStreamPlayer3D
var _hum: AudioStreamPlayer
var _warn: AudioStreamPlayer
var _oneshots: Array[AudioStreamPlayer3D] = []
var _loops: Array[AudioStreamPlayer3D] = []
var _shot_i := 0
var _streams := {}
var _warn_current := ""
var _low_fuel_warned := false
var _gear_target := 1.0
var _gear_moving := false
var _dead := false


func setup(aircraft: Node3D) -> void:
	ac = aircraft


func _ready() -> void:
	_whine = _loop("engine_whine", INTAKE, "Engine")
	_core = _loop("engine_core", NOZZLE, "Engine")
	_low = _loop("engine_low", NOZZLE, "Engine")
	_ab = _loop("afterburner", NOZZLE + Vector3(0, 0, 3), "Engine")
	_ab_body = _loop("ab_body", NOZZLE + Vector3(0, 0, 3), "Engine")
	_wind = _loop("wind", Vector3.ZERO, "Effects")
	_buffet = _loop("buffet", Vector3.ZERO, "Effects")
	_roll = _loop("tyre_roll", Vector3(0, -2, 1.8), "Effects")
	_motor = _loop("gear_motor", Vector3(0, -1.2, 0.5), "Effects")
	if not ac.is_remote:
		# cockpit ambience: our own jet only
		_hum = AudioStreamPlayer.new()
		_hum.stream = A.looped(DIR + "cockpit_hum.wav")
		_hum.bus = "Warnings"
		_hum.volume_db = -80.0
		add_child(_hum)
		_hum.play()
	_warn = AudioStreamPlayer.new()
	_warn.bus = "Warnings"
	add_child(_warn)
	for i in 6:
		var p := AudioStreamPlayer3D.new()
		p.bus = "Effects"
		p.unit_size = 14.0
		p.max_distance = 6000.0
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
		p.area_mask = 0
		add_child(p)
		_oneshots.append(p)
	for n in ["gear_clunk", "touchdown", "tyre_chirp", "ab_light", "explosion", "scrape", "caution", "warn_stall", "warn_pullup", "warn_gear", "warn_overg"]:
		_streams[n] = load(DIR + n + ".wav")
	for n in ["switch_01", "switch_02", "metal_hit_01", "thunder_01"]:
		_streams[n] = load(DIR + n + ".ogg")
	if not ac.is_remote:
		for n in ["warn_stall", "warn_pullup", "warn_gear", "warn_overg"]:
			_streams[n] = A.looped(DIR + n + ".wav")
	ac.sim_event.connect(_on_event)


func _loop(n: String, local: Vector3, bus: String) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.stream = A.looped(DIR + n + (".wav"))
	p.bus = bus
	p.position = local
	p.unit_size = 22.0
	p.max_db = 6.0
	p.max_distance = 9000.0
	p.attenuation_filter_cutoff_hz = 6000.0
	p.attenuation_filter_db = -18.0
	p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_PHYSICS_STEP
	p.area_mask = 0            # no reverb areas in this game: skip the per-mix area lookup
	p.volume_db = -80.0
	add_child(p)
	p.play(randf() * 2.0)
	_loops.append(p)
	return p


## Layers turned all the way down are paused (they keep their place in the loop), so silent layers of every jet in
## the game are not mixed at all; they carry on when their volume comes back up.
func _pause_silent() -> void:
	for p in _loops:
		var quiet := p.volume_db <= -70.0
		if p.stream_paused != quiet:
			p.stream_paused = quiet


static func _db(lin: float) -> float:
	return linear_to_db(maxf(lin, 0.00001))


func _process(delta: float) -> void:
	if ac == null:
		return
	var cam := get_viewport().get_camera_3d()
	var local: bool = not ac.is_remote       # other pilots' jets: positional sound only, no cockpit or warnings
	if not local:
		_dead = ac.crashed
	var cockpit: bool = local and cam != null and "view_name" in cam and String(cam.view_name) == "COCKPIT"
	var canopy_open: bool = ac.canopy_open
	if local:
		Audio.set_cockpit_muffle(1.0 if (cockpit and not canopy_open) else (0.35 if cockpit else 0.0))
	if _dead:
		for p in [_whine, _core, _low, _ab, _ab_body, _wind, _buffet, _roll, _motor]:
			p.volume_db = move_toward(p.volume_db, -80.0, 60.0 * delta)
		_set_warning("")
		_pause_silent()
		return

	# ---- engine ----
	var n2: float = ac.rpm
	var nf := clampf((n2 - 55.0) / 45.0, 0.0, 1.0)
	var ab: float = ac.ab_stage
	var thrust_frac: float = clampf(ac.thrust_now / (ac.spec.engine_count * ac.spec.thrust_ab_n), 0.0, 1.0)
	# jet directivity: fan whine radiates forward, exhaust roar aft
	var front := 0.5
	var aft := 0.5
	if cam:
		var rel: Vector3 = (ac.global_transform.affine_inverse() * cam.global_position)
		var d := rel.normalized() if rel.length() > 0.1 else Vector3(0, 0, 1)
		front = clampf(-d.z, 0.0, 1.0)
		aft = clampf(d.z, 0.0, 1.0)
	if cockpit:
		front = 0.6; aft = 0.15
	var spool := clampf(n2 / 100.0, 0.0, 1.1)
	_whine.pitch_scale = 0.42 + 0.68 * spool
	_whine.volume_db = _db((0.12 + 0.55 * nf) * (0.55 + 0.7 * front)) + (2.0 if cockpit else 0.0)
	_core.pitch_scale = 0.72 + 0.45 * nf
	_core.volume_db = _db((0.08 + 0.85 * pow(nf, 1.4)) * (0.45 + 0.8 * aft))
	_low.pitch_scale = 0.8 + 0.35 * nf
	_low.volume_db = _db((0.1 + 0.9 * thrust_frac) * (0.5 + 0.7 * aft)) + (3.0 if cockpit else 0.0)
	_ab.pitch_scale = 0.88 + 0.18 * ab
	_ab.volume_db = _db(ab * (0.35 + 0.9 * aft))
	_ab_body.pitch_scale = 0.9 + 0.25 * ab
	_ab_body.volume_db = _db(ab * 0.9 * (0.4 + 0.8 * aft))

	# ---- airflow ----
	var q := 0.5 * 1.225 * pow(float(ac.ias), 2.0)
	var flow := pow(clampf(q / 26000.0, 0.0, 1.4), 0.75)
	var wind_gain := flow * (0.55 if (cockpit and not canopy_open) else 1.0) + (0.35 * flow + 0.12 if canopy_open and float(ac.speed) > 5.0 else 0.0)
	_wind.pitch_scale = 0.62 + clampf(float(ac.speed) / 330.0, 0.0, 1.2)
	_wind.volume_db = _db(wind_gain * 0.8)
	var buf: float = ac.buffet
	_buffet.volume_db = _db(buf * (1.3 if cockpit else 0.8))
	_buffet.pitch_scale = 0.85 + 0.3 * buf

	# ---- ground roll ----
	var gs: float = ac.ground_speed
	var rolling: bool = ac.wow and ac.gear_down
	_roll.volume_db = _db((clampf(gs / 55.0, 0.0, 1.0) * 0.9) if rolling else 0.0)
	_roll.pitch_scale = 0.55 + clampf(gs / 70.0, 0.0, 1.0) * 0.8

	# ---- gear / hydraulics ----
	var gear_pos: float = ac.fm.gear_pos
	var moving := absf(gear_pos - (1.0 if ac.gear_down else 0.0)) > 0.002
	if _gear_moving and not moving:
		_shot("gear_clunk", Vector3(0, -1.5, 0), 0.0, 0.95 + randf() * 0.1)   # up-lock / down-lock
		_shot("metal_hit_01", Vector3(0, -1.5, 0), -10.0, 0.8)
	_gear_moving = moving
	var hyd: bool = moving or ac.canopy_player.is_playing() or ac.brake_player.is_playing()
	_motor.volume_db = move_toward(_motor.volume_db, -14.0 if hyd else -80.0, (120.0 if hyd else 50.0) * delta)
	_motor.pitch_scale = 0.95 + 0.05 * sin(Time.get_ticks_msec() * 0.003)

	# ---- cockpit ambience ----
	if _hum:
		_hum.volume_db = move_toward(_hum.volume_db, -30.0 if cockpit else -80.0, 80.0 * delta)
		var hq := _hum.volume_db <= -70.0
		if _hum.stream_paused != hq:
			_hum.stream_paused = hq
	_pause_silent()

	# ---- warnings ----
	if local:
		_update_warnings()


func _update_warnings() -> void:
	# the highest-priority voiced warning the master mode lets through (scripts/sim/avionics.gd)
	var w := ""
	var av = preload("res://scripts/sim/avionics.gd")
	for wid in av.active(ac):
		var clip: String = av.INFO[wid][3]
		if clip != "":
			w = clip
			break
	_set_warning(w)
	if ac.fuel_kg < 800.0 and not _low_fuel_warned:
		_low_fuel_warned = true
		_warn_oneshot("caution")
	elif ac.fuel_kg > 1000.0:
		_low_fuel_warned = false


func _set_warning(n: String) -> void:
	if n == _warn_current:
		return
	_warn_current = n
	if n == "":
		_warn.stop()
	else:
		_warn.stream = _streams[n]
		_warn.volume_db = -6.0
		_warn.play()


func _warn_oneshot(n: String) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = _streams[n]
	p.bus = "Warnings"
	p.volume_db = -4.0
	add_child(p)
	p.play()
	p.finished.connect(p.queue_free)


func _shot(n: String, local: Vector3, vol_db: float, pitch: float = 1.0) -> void:
	var p := _oneshots[_shot_i]
	_shot_i = (_shot_i + 1) % _oneshots.size()
	p.stream = _streams[n]
	p.position = local
	p.volume_db = vol_db
	p.pitch_scale = pitch
	p.play()


func _on_event(type: String, value: float) -> void:
	match type:
		"touchdown":
			var sink := value
			_shot("touchdown", Vector3(0, -2, 1.8), _db(clampf(0.35 + sink / 4.0, 0.3, 1.6)), 1.0 - clampf(sink / 20.0, 0.0, 0.2))
			if float(ac.ground_speed) > 25.0:
				_shot("tyre_chirp", Vector3(0, -2, 1.8), _db(clampf(0.4 + sink / 5.0, 0.4, 1.0)), 0.95 + randf() * 0.1)
		"crash":
			_dead = true
			_shot("explosion", Vector3.ZERO, 6.0, 1.0)
			_shot("thunder_01", Vector3.ZERO, 0.0, 0.7)
		"tailstrike":
			_shot("scrape", Vector3(0, 0, 10), 0.0, 1.0)
		"ab_light":
			_shot("ab_light", NOZZLE, 0.0, 0.95 + randf() * 0.1)
		"gear_motion":
			_shot("gear_clunk", Vector3(0, -1.5, 0), -6.0, 1.15)
		"switch", "flaps", "airbrake", "canopy":
			_shot("switch_01" if randf() < 0.5 else "switch_02", Vector3(0, 1.0, -5.0), -4.0, 1.0)
		"reset":
			_dead = false
