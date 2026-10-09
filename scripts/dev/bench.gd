extends Node
## Development: performance run. `--bench=<file.csv>` starts the jet in the air on the autopilot, uncapped frame
## rate, and logs once a second: frame rate, worst frame, CPU and GPU render time, draw calls, primitives, video
## memory and the terrain streamer's tiles. Prints a summary and quits at the end.
##   --bench-at=x,z,heading     world position (m) and heading (deg) to start from (default: Srinagar, east)
##   --bench-alt=m              start altitude above sea level (default 6500)
##   --bench-time=s             length of the run (default 90)
##   --bench-view=n             camera view (default 3, the cockpit)
##   --bench-pan                swing the view left and right all the time (stresses culling and streaming)

var aircraft: Node3D
var cam: Node
var world: Node

var _out := ""
var _len := 90.0
var _pan := false
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
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_vp = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_vp, true)
	await get_tree().create_timer(0.5).timeout
	aircraft.air_start(Transform3D(Basis(Vector3.UP, deg_to_rad(-hdg)), at), 230.0)
	cam.view = view
	cam._first = true
	cam._yaw = 0.0
	cam._pitch = 0.0
	cam._idle = -1e9
	await get_tree().create_timer(3.0).timeout      # let the first tiles stream in before measuring
	_rows.append("t,x,z,alt_m,agl_m,ias,fps,worst_ms,cpu_ms,gpu_ms,draws,prims_k,vram_mb,tiles_drawn,tiles_resident,tile_loads,trees")
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
	_draw_max = maxi(_draw_max, draws)
	if _pan:
		cam._yaw = sin(_t * 0.9) * 2.0
		cam._pitch = sin(_t * 0.37) * 0.25
	if _sec >= 1.0:
		var w := WorldData.to_world(aircraft.global_position)
		var st: Dictionary = world.streamer.stats if world.streamer else {"drawn": 0, "resident": 0, "loads": 0}
		_rows.append("%.1f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f,%.1f,%.2f,%.2f,%d,%d,%.0f,%d,%d,%d,%d" % [
			_t, w.x, w.z, w.y, aircraft.altitude_agl, aircraft.fm.ias, _frames / _sec, _worst * 1000.0, _cpu / _frames, _gpu / _frames,
			draws, RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
			RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
			st.drawn, st.resident, st.loads, int(world.get_node("CoverForest").planted) if world.has_node("CoverForest") else 0])
		_sec = 0.0
		_frames = 0
		_worst = 0.0
		_cpu = 0.0
		_gpu = 0.0
	if _t >= _len:
		_finish()


func _finish() -> void:
	_t = -1.0
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
	if _out != "":
		var f := FileAccess.open(_out, FileAccess.WRITE)
		if f:
			f.store_string("\n".join(_rows) + "\n# " + summary + "\n")
	get_tree().quit()
