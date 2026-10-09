extends Node
## Development: `--jitter-log=<file.csv>` logs, every rendered frame, the jet's interpolated pose, the camera's
## pose relative to it and frame timing, then quits. Used to hunt view vibration without a human in the loop.

var path := ""
var delay := 12.0
var length := 15.0
var ac: Node3D
var cam: Camera3D
var _t := 0.0
var _lines := PackedStringArray()


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--probe-delay="):
			delay = arg.trim_prefix("--probe-delay=").to_float()
		elif arg.begins_with("--probe-length="):
			length = arg.trim_prefix("--probe-length=").to_float()
	process_priority = 1000
	process_physics_priority = 1000


var _caps: Array[Image] = []
var _cap_n := 0
var _cap_dir := ""


func _process(delta: float) -> void:
	_t += delta
	if _cap_n == 0:
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--capture="):
				var v := arg.trim_prefix("--capture=").split(",")
				_cap_n = v[0].to_int()
				_cap_dir = v[1]
	if _cap_n > 0 and _t > delay and _caps.size() < _cap_n:
		# development: real-time consecutive frames (kept in memory, saved at the end) to judge motion smoothness
		_caps.append(get_viewport().get_texture().get_image())
		if _caps.size() == _cap_n:
			for i in _caps.size():
				_caps[i].save_png(_cap_dir.path_join("cap_%02d.png" % i))
	if cam != null and cam.view != 3 and "--jitter-cockpit" in OS.get_cmdline_user_args():
		cam.view = 3
	if _t < delay or ac == null or cam == null:
		return
	if _lines.is_empty():
		_lines.append("# jitter_fix=%s vsync=%d max_fps=%d tps=%d interp=%s" % [str(Engine.physics_jitter_fix), DisplayServer.window_get_vsync_mode(), Engine.max_fps, Engine.physics_ticks_per_second, str(get_tree().physics_interpolation)])
		_lines.append("t,dt,frac,ax,ay,az,ap,ar,ah,cx,cy,cz,cp,ch,rx,ry,rz,rawx,rawy,rawz,vx,vy,vz,hdg,ias,ap_on,ap_alt,ap_hdg,tail,pitch_in,roll_in")
	var ai: Transform3D = ac.get_global_transform_interpolated()
	var raw: Transform3D = ac.global_transform
	var rel := ai.affine_inverse() * cam.global_transform
	var e := ai.basis.get_euler()
	var ce := rel.basis.get_euler()
	var v: Vector3 = ac.velocity
	_lines.append("%.5f,%.5f,%.4f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f,%.6f,%.6f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.3f,%.3f" % [
		_t, delta, Engine.get_physics_interpolation_fraction(), ai.origin.x, ai.origin.y, ai.origin.z,
		rad_to_deg(e.x), rad_to_deg(e.z), rad_to_deg(e.y), rel.origin.x, rel.origin.y, rel.origin.z,
		rad_to_deg(ce.x), rad_to_deg(ce.y), cam.global_position.x, cam.global_position.y, cam.global_position.z,
		raw.origin.x, raw.origin.y, raw.origin.z, v.x, v.y, v.z] + ",%.2f,%.2f,%d,%.1f,%.1f,%d,%.3f,%.3f" % [ac.heading_deg, ac.ias,
		int(ac.autopilot.engaged), ac.autopilot.alt_sel, ac.autopilot.hdg_sel, int(ac.fm.tail_scrape), ac.pitch_in, ac.roll_in])
	if _t > delay + length:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string("\n".join(_lines))
		f.close()
		get_tree().quit()
