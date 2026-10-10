extends Node
## Development: performance run. `--bench=<file.csv>` starts the jet in the air on the autopilot, uncapped frame
## rate, and logs once a second: frame rate, worst frame, CPU and GPU render time, draw calls, primitives, video
## memory and the terrain streamer's tiles. Prints a summary and quits at the end.
##   --bench-at=x,z,heading     world position (m) and heading (deg) to start from (default: Srinagar, east)
##   --bench-alt=m              start altitude above sea level (default 6500)
##   --bench-time=s             length of the run (default 90)
##   --bench-view=n             camera view (default 3, the cockpit)
##   --bench-pan                swing the view left and right all the time (stresses culling and streaming)
##   --bench-flight             fly a real sortie instead of straight and level: autopilot turns both ways, a 180,
##                              aileron rolls, a hard banked pull, inverted flight, and the camera cycling through
##                              every view (cockpit looking around, chase, far, orbit swinging round the jet)
##   --bench-speed=m/s          start speed (default 230)
##   --bench-diff=<dir>         watch the picture for flicker: every frame is compared with the one before (small
##                              grey copies); a sudden change much larger than the motion around it is logged as the
##                              "diff" column and both frames are saved to <dir> for a look
##   --bench-frames=<file.csv>  also log every frame (hunting hitches): frame time, render times, terrain and forest
##                              work, tiles loaded and evicted, near-tree rebuilds, floating origin shifts

var aircraft: Node3D
var cam: Node
var world: Node

var _out := ""
var _len := 90.0
var _pan := false
var _mouse := false            # --bench-mouse: drag the view with synthetic mouse motion (as a player does)
var _prev_look := Basis.IDENTITY
var _look_rate := 0.0          # how fast the view turned against the jet this frame (deg/s)
var _flight := false
var _gmax := 0.0
var _aoamax := 0.0
var _vmax := 0.0
var _ctr := 0.0
var _snap_dir := ""
var _snaps: Array[float] = []
var _look = null
var _speed := 230.0
var _diff_dir := ""
var _diff := 0.0
var _diff_hist: Array[float] = []
var _prev_small := PackedByteArray()
var _prev_img: Image
var _saved := 0
const BW := 16
const BH := 12
var _prev_blocks := PackedFloat32Array()
var _prev_blocks2 := PackedFloat32Array()
var _phase := ""
var _held: Array[String] = []
var _t := -1.0
var _sec := 0.0
var _frames := 0
var _worst := 0.0
var _cpu := 0.0
var _gpu := 0.0
var _rows := PackedStringArray()
var _all_dt := PackedFloat32Array()
var _draw_max := 0
var _vp: RID
var _frames_out := ""
var _frame_rows := PackedStringArray()
var _shifts := 0
var _prev := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1000
	var at := Vector3(-151000.0, 6500.0, 58000.0)
	var hdg := 90.0
	var view := 3
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--bench="):
			_out = arg.trim_prefix("--bench=")
		elif arg.begins_with("--bench-at="):
			var v := arg.trim_prefix("--bench-at=").split(",")
			at.x = v[0].to_float()
			at.z = v[1].to_float()
			if v.size() > 2:
				hdg = v[2].to_float()
		elif arg.begins_with("--bench-alt="):
			at.y = arg.trim_prefix("--bench-alt=").to_float()
		elif arg.begins_with("--bench-time="):
			_len = arg.trim_prefix("--bench-time=").to_float()
		elif arg.begins_with("--bench-view="):
			view = arg.trim_prefix("--bench-view=").to_int()
		elif arg == "--bench-pan":
			_pan = true
		elif arg == "--bench-mouse":
			_mouse = true
		elif arg.begins_with("--bench-snap="):     # dir:t1,t2,...  screenshots at those times
			var spec := arg.trim_prefix("--bench-snap=")
			var cut := spec.rfind(":")                  # (the folder may start with a drive letter)
			_snap_dir = spec.substr(0, cut)
			DirAccess.make_dir_recursive_absolute(_snap_dir)
			for v in spec.substr(cut + 1).split(","):
				_snaps.append(v.to_float())
		elif arg.begins_with("--bench-look="):     # fixed camera yaw,pitch (degrees) for the whole run
			var v := arg.trim_prefix("--bench-look=").split(",")
			_look = Vector2(deg_to_rad(v[0].to_float()), deg_to_rad(v[1].to_float()))
		elif arg == "--bench-flight":
			_flight = true
		elif arg.begins_with("--bench-speed="):
			_speed = arg.trim_prefix("--bench-speed=").to_float()
		elif arg.begins_with("--bench-diff="):
			_diff_dir = arg.trim_prefix("--bench-diff=")
			DirAccess.make_dir_recursive_absolute(_diff_dir)
		elif arg.begins_with("--bench-frames="):
			_frames_out = arg.trim_prefix("--bench-frames=")
	WorldData.origin_shifted.connect(func(_d): _shifts += 1)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	await get_tree().create_timer(0.5).timeout
	aircraft.air_start(Transform3D(Basis(Vector3.UP, deg_to_rad(-hdg)), at), _speed)
	cam.view = view
	cam._first = true
	cam._yaw = 0.0
	cam._pitch = 0.0
	cam._idle = -1e9
	await get_tree().create_timer(3.0).timeout      # let the first tiles stream in before measuring
	_rows.append("t,x,z,alt_m,agl_m,ias,fps,worst_ms,cpu_ms,gpu_ms,draws,prims_k,vram_mb,tiles_drawn,tiles_resident,tile_loads,trees,g_max,aoa_max,vortex_max,contrail")
	_t = 0.0


func _process(delta: float) -> void:
	if _t < 0.0:
		return
	_t += delta
	_sec += delta
	_frames += 1
	_worst = maxf(_worst, delta)
	_all_dt.append(delta)
	_cpu += RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu()
	_gpu += RenderingServer.viewport_get_measured_render_time_gpu(_vp)
	var draws := RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	if _diff_dir != "":
		_watch()
	if _frames_out != "":
		_log_frame(delta, draws)
	_draw_max = maxi(_draw_max, draws)
	_gmax = maxf(_gmax, absf(float(aircraft.g_load)))
	_aoamax = maxf(_aoamax, float(aircraft.aoa_deg))
	var tr: Node = aircraft.fx.get_node_or_null("Trails") if aircraft.get("fx") else null
	if tr:
		_vmax = maxf(_vmax, float(tr._vortex()))
		_ctr = float(tr._contrail())
	if not _snaps.is_empty() and _t >= _snaps[0]:
		var at: float = _snaps.pop_front()
		get_viewport().get_texture().get_image().save_png(_snap_dir.path_join("snap_%05.1f.png" % at))
	if _look != null:
		cam._yaw = _look.x
		cam._pitch = _look.y
	# the view's turn rate against the jet, frame by frame (an evenly turning view gives an even rate)
	var tb: Basis = aircraft.get_global_transform_interpolated().basis.orthonormalized()
	var rel: Basis = tb.inverse() * cam.global_transform.basis.orthonormalized()
	_look_rate = rad_to_deg(Quaternion(_prev_look).angle_to(Quaternion(rel))) / maxf(delta, 1e-4)
	_prev_look = rel
	if _flight:
		_fly()
	elif _mouse:
		# hold the right button and drag: a steady 0.5 rad/s swing, reversing every 4 s
		if not cam._dragging:
			var b := InputEventMouseButton.new()
			b.button_index = MOUSE_BUTTON_RIGHT
			b.pressed = true
			Input.parse_input_event(b)
		var mm := InputEventMouseMotion.new()
		var dir := 1.0 if fmod(_t, 8.0) < 4.0 else -1.0
		mm.relative = Vector2(dir * 0.5 * delta / (0.005 * float(Settings.get_value("controls/mouse_sensitivity"))), 0.0)
		Input.parse_input_event(mm)
	elif _pan:
		cam._yaw = sin(_t * 0.9) * 2.0
		cam._pitch = sin(_t * 0.37) * 0.25
	if _sec >= 1.0:
		var w := WorldData.to_world(aircraft.global_position)
		var st: Dictionary = world.streamer.stats if world.streamer else {"drawn": 0, "resident": 0, "loads": 0}
		_rows.append("%.1f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.1f,%.2f,%.2f,%d,%d,%.0f,%d,%d,%d,%d,%.1f,%.1f,%.2f,%.2f" % [
			_t, w.x, w.z, w.y, aircraft.altitude_agl, aircraft.fm.ias, _frames / _sec, _worst * 1000.0, _cpu / _frames, _gpu / _frames,
			draws, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
			st.drawn, st.resident, st.loads, int(world.get_node("CoverForest").planted) if world.has_node("CoverForest") else 0,
			_gmax, _aoamax, _vmax, _ctr])
		_gmax = 0.0
		_aoamax = 0.0
		_vmax = 0.0
		_sec = 0.0
		_frames = 0
		_worst = 0.0
		_cpu = 0.0
		_gpu = 0.0
	if _t >= _len:
		_finish()


## The sortie: [start s, phase]. Each phase sets the controls and the camera for its stretch of time.
const SORTIE := [[0.0, "cruise_cockpit"], [8.0, "turn_right_orbit"], [22.0, "turn_left_chase"], [34.0, "reverse_far"],
	[46.0, "rolls_cockpit"], [51.0, "banked_pull_orbit"], [55.0, "recover_cockpit_look"], [63.0, "inverted_close"],
	[67.0, "recover_cockpit_look"], [78.0, "turn_right_orbit_low"], [92.0, "cruise_cockpit"]]


func _hold(actions: Array) -> void:
	for a in _held:
		if not a in actions:
			Input.action_release(a)
	for a in actions:
		if not a in _held:
			Input.action_press(a)
	_held.assign(actions)


func _fly() -> void:
	var phase := ""
	for p in SORTIE:
		if _t >= float(p[0]):
			phase = p[1]
	var ap = aircraft.autopilot
	var fm = aircraft.fm
	var start := phase != _phase
	_phase = phase
	var hdg: float = aircraft.heading_deg
	match phase:
		"cruise_cockpit":
			if start:
				_hold([])
				cam.view = 3
				_ap_heading(ap, fm, hdg)
			cam._yaw = sin(_t * 0.7) * 1.2
			cam._pitch = -0.1
		"turn_right_orbit", "turn_right_orbit_low":
			if start:
				_hold([])
				cam.view = 2
				_ap_heading(ap, fm, hdg + 150.0)
			cam._yaw += get_process_delta_time() * 0.9          # swing round the jet
			cam._pitch = -0.35 if phase.ends_with("low") else -0.15
		"turn_left_chase":
			if start:
				_hold([])
				cam.view = 0
				_ap_heading(ap, fm, hdg - 170.0)
			cam._yaw = sin(_t * 0.5) * 0.8
		"reverse_far":
			if start:
				_hold([])
				cam.view = 1
				_ap_heading(ap, fm, hdg + 180.0)
			cam._yaw = sin(_t * 0.4) * 1.5
		"rolls_cockpit":
			if start:
				ap.disengage("")
				cam.view = 3
				cam._yaw = 0.0
				cam._pitch = 0.0
				_hold(["roll_right"])
		"banked_pull_orbit":
			# rolled to about 80 degrees of bank, pulling: a hard turn with the horizon on its side
			if start:
				cam.view = 2
			var bank := rad_to_deg(asin(clampf(fm.rot.x.y, -1.0, 1.0)))
			_hold(["pitch_up"] + (["roll_right"] if absf(bank) < 65.0 else []))
			cam._yaw += get_process_delta_time() * 1.4
		"inverted_close":
			if start:
				cam.view = 0
				ap.disengage("")
			# roll until upside down, then hold it there with a little push
			var up: float = fm.rot.y.y
			_hold(["roll_left"] if up > -0.9 else ["pitch_down"])
			cam._yaw = sin(_t * 1.1) * 2.0
		"recover_cockpit_look":
			if start:
				_hold([])
				cam.view = 3
				ap.press("LVL", fm)                             # horizon recovery, then hold
			# look over the shoulders and down at the ground, like checking six
			cam._yaw = sin(_t * 0.6) * 2.4
			cam._pitch = -0.3 + sin(_t * 0.9) * 0.25
	if start:
		cam._first = true
		print("BENCH phase %s at %.1f s  alt %.0f m  hdg %.0f" % [phase, _t, fm.world_pos().y, hdg])


## Compares the last rendered frame with the one before it (192 x 108 grey). Saves both when the change jumps.
func _watch() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	var mid := img.duplicate() as Image
	mid.resize(480, 270, Image.INTERPOLATE_BILINEAR)
	var small := mid.duplicate() as Image
	small.resize(192, 108, Image.INTERPOLATE_BILINEAR)
	small.convert(Image.FORMAT_L8)
	var data := small.get_data()
	_diff = 0.0
	if _prev_small.size() == data.size():
		# per block (16 x 12 blocks of 12 x 9 px): a pop is a block that suddenly changes much more than it did in
		# the frames before, while smooth motion changes every block steadily
		var blocks := PackedFloat32Array()
		blocks.resize(BW * BH)
		var s := 0
		for y in 108:
			var row := y * 192
			var brow := (y / 9) * BW
			for x in 192:
				var dd := absi(data[row + x] - _prev_small[row + x])
				s += dd
				blocks[brow + x / 12] += dd
		_diff = float(s) / data.size()
		var worst := 0.0
		var worst_b := -1
		if _prev_blocks.size() == blocks.size() and _prev_blocks2.size() == blocks.size():
			for k in blocks.size():
				var now := blocks[k] / 108.0
				var before := maxf(_prev_blocks[k], _prev_blocks2[k]) / 108.0
				var r := now - (before * 2.0 + 1.5)
				if r > worst:
					worst = r
					worst_b = k
		if worst_b >= 0 and _saved < 60:
			_saved += 1
			_prev_img.save_png(_diff_dir.path_join("pop_%06.2f_a.png" % _t))
			mid.save_png(_diff_dir.path_join("pop_%06.2f_b.png" % _t))
			print("BENCH pop at %.2f s: block %d,%d changed %.1f (before %.1f)" % [_t, worst_b % BW, worst_b / BW,
				blocks[worst_b] / 108.0, maxf(_prev_blocks[worst_b], _prev_blocks2[worst_b]) / 108.0])
		_prev_blocks2 = _prev_blocks
		_prev_blocks = blocks
	_prev_small = data
	_prev_img = mid


var _pipe_prev := -1

## Render pipelines compiled since the last frame (a new shader / state combination being built mid-flight).
func _pipelines() -> int:
	var n := 0
	for m in [Performance.PIPELINE_COMPILATIONS_CANVAS, Performance.PIPELINE_COMPILATIONS_MESH, Performance.PIPELINE_COMPILATIONS_SURFACE,
			Performance.PIPELINE_COMPILATIONS_DRAW, Performance.PIPELINE_COMPILATIONS_SPECIALIZATION]:
		n += int(Performance.get_monitor(m))
	var d := n - _pipe_prev if _pipe_prev >= 0 else 0
	_pipe_prev = n
	return d


func _ap_heading(ap, fm, h: float) -> void:
	if not ap.engaged:
		ap.press("LVL", fm)
	ap.set_value("HDG", fposmod(h, 360.0), true)
	ap.press("HDG", fm)


func _log_frame(delta: float, draws: int) -> void:
	if _frame_rows.is_empty():
		_frame_rows.append("t,dt_ms,cpu_ms,gpu_ms,draws,terrain_us,drawn,loads,evict,evict_split,forest_us,near_us,near_rebuild,cells_planted,origin_shift,cam_yaw,view,bank,process_ms,physics_ms,pipelines,diff,look_rate")
	var st: Dictionary = world.streamer.stats if world.streamer else {}
	var cf: Node = world.get_node_or_null("CoverForest")
	var fs: Dictionary = cf.stats if cf else {}
	var cur := {"loads": int(st.get("loads", 0)), "evict": int(st.get("evict", 0)), "evict_split": int(st.get("evict_split", 0)),
		"near_n": int(fs.get("near_n", 0)), "plant_n": int(fs.get("plant_n", 0)), "shifts": _shifts}
	var d := {}
	for k in cur:
		d[k] = cur[k] - int(_prev.get(k, cur[k]))
	_prev = cur
	_frame_rows.append("%.3f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%.2f,%d,%.0f,%.2f,%.2f,%d,%.2f,%.2f" % [_t, delta * 1000.0,
		RenderingServer.viewport_get_measured_render_time_cpu(_vp) + RenderingServer.get_frame_setup_time_cpu(),
		RenderingServer.viewport_get_measured_render_time_gpu(_vp), draws, int(st.get("proc_us", 0)), int(st.get("drawn", 0)),
		d.loads, d.evict, d.evict_split, int(fs.get("proc_us", 0)), int(fs.get("near_us", 0)), d.near_n, d.plant_n, d.shifts, cam._yaw, cam.view, rad_to_deg(asin(clampf(aircraft.fm.rot.x.y, -1.0, 1.0))),
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0, _pipelines(), _diff, _look_rate])


func _finish() -> void:
	_t = -1.0
	_hold([])
	var sorted := _all_dt.duplicate()
	sorted.sort()
	var n := sorted.size()
	var avg := 0.0
	for d in sorted:
		avg += d
	avg /= maxf(n, 1)
	var p99: float = sorted[int(n * 0.99)] if n > 0 else 0.0
	var summary := "BENCH frames %d  avg %.1f fps (%.2f ms)  1%% low %.1f fps (%.2f ms)  worst %.1f ms  max draws %d  crashed %s  dev overlay %s" % [
		n, 1.0 / avg, avg * 1000.0, 1.0 / p99, p99 * 1000.0, sorted[n - 1] * 1000.0, _draw_max, str(aircraft.fm.crashed), str(Game.dev_hud)]
	print(summary)
	print(RenderingServer.get_video_adapter_name(), " / ", RenderingServer.get_video_adapter_vendor())
	if _frames_out != "":
		var ff := FileAccess.open(_frames_out, FileAccess.WRITE)
		if ff:
			ff.store_string("\n".join(_frame_rows) + "\n")
	if _out != "":
		var f := FileAccess.open(_out, FileAccess.WRITE)
		if f:
			f.store_string("\n".join(_rows) + "\n# " + summary + "\n")
	get_tree().quit()
