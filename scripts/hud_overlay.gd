extends Control
## Graphical HUD layer: flight path marker, ILS-style approach guidance, warnings and landing grades.

var aircraft: Node3D
var _t := 0.0
const GREEN := Color(0.35, 1.0, 0.45)
const AMBER := Color(1.0, 0.75, 0.2)
const RED := Color(1.0, 0.25, 0.2)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	_t += delta
	queue_redraw()


func _draw() -> void:
	if aircraft == null:
		return
	var a = aircraft
	var font := get_theme_default_font()
	var vs := get_viewport_rect().size
	var cam := get_viewport().get_camera_3d()

	# --- flight path marker: where the jet is actually going ---
	var vel: Vector3 = a.velocity
	if cam and vel.length() > 15.0:
		var p3: Vector3 = a.global_position + vel.normalized() * 600.0
		if not cam.is_position_behind(p3):
			var c := cam.unproject_position(p3)
			draw_arc(c, 10.0, 0.0, TAU, 24, GREEN, 2.0)
			draw_line(c + Vector2(10, 0), c + Vector2(26, 0), GREEN, 2.0)
			draw_line(c - Vector2(10, 0), c - Vector2(26, 0), GREEN, 2.0)
			draw_line(c - Vector2(0, 10), c - Vector2(0, 20), GREEN, 2.0)

	# --- approach guidance (ILS style) ---
	var g: Dictionary = WorldData.approach_guidance(a.global_position, -a.global_transform.basis.z)
	if not g.is_empty() and not a.wow:
		var box := Rect2(Vector2(vs.x - 250.0, vs.y - 290.0), Vector2(220.0, 220.0))
		draw_rect(box, Color(0, 0, 0, 0.35), true)
		draw_rect(box, Color(1, 1, 1, 0.5), false, 1.0)
		var cc := box.get_center()
		for k in range(-2, 3):
			draw_circle(cc + Vector2(k * 35.0, 0), 3.0, Color(1, 1, 1, 0.7))
			draw_circle(cc + Vector2(0, k * 35.0), 3.0, Color(1, 1, 1, 0.7))
		var lx := clampf(-float(g.loc_dev) / 2.5, -1.0, 1.0) * 80.0
		var gy := clampf(float(g.gs_dev) / 0.7, -1.0, 1.0) * 80.0
		var ok_loc := absf(float(g.loc_dev)) < 0.5
		var ok_gs := absf(float(g.gs_dev)) < 0.2
		draw_line(cc + Vector2(lx, -90), cc + Vector2(lx, 90), GREEN if ok_loc else AMBER, 3.0)
		draw_line(cc + Vector2(-90, gy), cc + Vector2(90, gy), GREEN if ok_gs else AMBER, 3.0)
		draw_rect(Rect2(cc - Vector2(6, 6), Vector2(12, 12)), Color(1, 1, 1, 0.9), false, 2.0)
		var kmh := int(a.speed * 3.6)
		var spd_col := GREEN if (kmh >= 260 and kmh <= 310) else AMBER
		draw_string(font, box.position + Vector2(8, -54), "ILS RWY %s   %.1f km" % [g.name, float(g.dist) / 1000.0], HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
		draw_string(font, box.position + Vector2(8, -34), "Glide %s   Centre %s" % [_dev_text(g.gs_dev, "HIGH", "LOW", 0.2), _dev_text(g.loc_dev, "RIGHT", "LEFT", 0.5)], HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)
		draw_string(font, box.position + Vector2(8, -14), "Speed %d km/h (target 270-300)" % kmh, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, spd_col)

	# --- warnings ---
	var warns: Array[String] = []
	var agl: float = a.altitude_agl
	var vsi: float = a.vertical_speed
	if not a.wow and not a.crashed:
		if agl < 300.0 and vsi < -2.0 and not a.gear_down and a.speed < 120.0:
			warns.append("GEAR")
		if (agl < 400.0 and vsi < -10.0) or (agl < 60.0 and vsi < -5.0):
			warns.append("SINK RATE")
		if vsi < -15.0 and agl / -vsi < 6.0:
			warns.append("PULL UP")
		if a.aoa_deg > 21.0:
			warns.append("STALL")
	if not warns.is_empty() and fmod(_t, 0.8) < 0.55:
		var txt := "   ".join(warns)
		var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 34).x
		draw_string(font, Vector2((vs.x - tw) / 2.0, vs.y * 0.62), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 34, RED)

	# --- landing grade / events ---
	var age: float = Time.get_ticks_msec() / 1000.0 - float(a.landing_event_time)
	if age < 5.0 and a.landing_event != "":
		var e: String = a.landing_event
		var col := GREEN
		if e.begins_with("FIRM") or e.begins_with("TAIL") or e.begins_with("PRACTICE"):
			col = AMBER
		elif e.begins_with("HARD") or e.begins_with("GEAR"):
			col = RED
		col.a = clampf(5.0 - age, 0.0, 1.0)
		var ew := font.get_string_size(e, HORIZONTAL_ALIGNMENT_LEFT, -1, 30).x
		draw_string(font, Vector2((vs.x - ew) / 2.0, 120.0), e, HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col)


func _dev_text(v, hi: String, lo: String, tol: float) -> String:
	var f := float(v)
	if absf(f) < tol:
		return "ON"
	return hi if f > 0.0 else lo
