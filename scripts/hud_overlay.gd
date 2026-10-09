extends Control
## Graphical HUD layer: flight path marker, ILS-style approach guidance, warnings and landing grades.

const UI = preload("res://scripts/ui/ui_theme.gd")

var aircraft: Node3D
var _t := 0.0
const GREEN := Color("57e389")
const AMBER := Color("ffb347")
const RED := Color("ff5a4f")


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

	var cockpit: bool = cam != null and "view_name" in cam and String(cam.view_name) == "COCKPIT"

	# --- flight path marker: where the jet is actually going (cockpit view only) ---
	var vel: Vector3 = a.velocity
	if cockpit and vel.length() > 15.0 and a.get("cockpit") == null:   # jets with a real HUD draw it on the combiner
		var p3: Vector3 = a.global_position + vel.normalized() * 600.0
		if not cam.is_position_behind(p3):
			var c := cam.unproject_position(p3)
			draw_arc(c, 10.0, 0.0, TAU, 24, GREEN, 2.0)
			draw_line(c + Vector2(10, 0), c + Vector2(26, 0), GREEN, 2.0)
			draw_line(c - Vector2(10, 0), c - Vector2(26, 0), GREEN, 2.0)
			draw_line(c - Vector2(0, 10), c - Vector2(0, 20), GREEN, 2.0)

	# --- approach guidance (ILS style) ---
	var g: Dictionary = WorldData.approach_guidance(a.global_position, -a.global_transform.basis.z)
	if cockpit and not g.is_empty() and not a.wow:
		var box := Rect2(Vector2(vs.x - 300.0, vs.y - 300.0), Vector2(250.0, 250.0))
		var frame := Rect2(box.position - Vector2(14, 92), box.size + Vector2(28, 106))
		draw_rect(frame, Color(0.03, 0.035, 0.045, 0.55), true)
		draw_rect(frame, Color(1, 1, 1, 0.08), false, 1.0)
		draw_rect(box, Color(1, 1, 1, 0.12), false, 1.0)
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
		var kmh := int(a.ias * 3.6)
		var spd_col := GREEN if (kmh >= 260 and kmh <= 310) else AMBER
		var spd: Array = Settings.speed_text(a.ias)
		var dist: Array = Settings.dist_text(float(g.dist))
		var aviation := int(Settings.get_value("hud/unit_system")) == 1
		draw_string(font, box.position + Vector2(0, -64), "ILS  RWY %s" % g.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, AMBER)
		draw_string(font, box.position + Vector2(box.size.x, -64), "%s %s" % [dist[0], dist[1]], HORIZONTAL_ALIGNMENT_RIGHT, -1, 18, Color.WHITE)
		draw_string(font, box.position + Vector2(0, -38), "GLIDE %s    CENTRE %s" % [_dev_text(g.gs_dev, "HIGH", "LOW", 0.2), _dev_text(g.loc_dev, "RIGHT", "LEFT", 0.5)], HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color.WHITE)
		draw_string(font, box.position + Vector2(0, -12), "IAS %s  ·  TARGET %s" % [spd[0], "145-160 KT" if aviation else "270-300 KM/H"], HORIZONTAL_ALIGNMENT_LEFT, -1, 18, spd_col)

	# --- warnings: themed plates, priority ordered, lower centre of the screen ---
	var warns: Array = []   # [title, subtitle, colour]
	var agl: float = a.altitude_agl
	var vsi: float = a.vertical_speed
	# what to show comes from the avionics layer, which also applies the master mode's inhibits
	var av = preload("res://scripts/sim/avionics.gd")
	for wid in av.active(a):
		var info: Array = av.INFO[wid]
		warns.append([info[0], info[1], RED if int(info[2]) == 0 else AMBER])
	if warns.size() > 3:
		warns.resize(3)
	if not warns.is_empty():
		var tf: Font = UI.spaced("Bold", 5)
		var sf: Font = UI.spaced("Bold", 3)
		var widths := []
		var total := 0.0
		for w in warns:
			var tw := maxf(tf.get_string_size(w[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 30).x, sf.get_string_size(w[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x) + 46.0
			widths.append(maxf(tw, 190.0))
			total += widths[-1]
		total += 12.0 * (warns.size() - 1)
		var x := (vs.x - total) / 2.0
		var y := vs.y * 0.84
		var pulse := 0.5 + 0.5 * sin(_t * TAU * 1.6)
		for k in warns.size():
			var w: Array = warns[k]
			var col: Color = w[2]
			var r := Rect2(x, y, widths[k], 64.0)
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.03, 0.035, 0.045, 0.74)
			sb.set_corner_radius_all(4)
			sb.border_width_left = 5
			sb.border_width_top = 1
			sb.border_width_right = 1
			sb.border_width_bottom = 1
			var edge := col
			edge.a = 0.35 + 0.65 * (pulse if col == RED else 0.6)
			sb.border_color = edge
			draw_style_box(sb, r)
			draw_string(tf, Vector2(r.position.x + 24.0, r.position.y + 34.0), w[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 30, col)
			draw_string(sf, Vector2(r.position.x + 25.0, r.position.y + 53.0), w[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.6))
			x += widths[k] + 12.0

	# --- landing grade / events: same plate style, top centre, fades out ---
	var age: float = Time.get_ticks_msec() / 1000.0 - float(a.landing_event_time)
	if age < 5.0 and a.landing_event != "":
		var e: String = a.landing_event
		var col := GREEN
		if e.begins_with("FIRM") or e.begins_with("TAIL") or e.begins_with("PRACTICE") or e.begins_with("AOA"):
			col = AMBER
		elif e.begins_with("HARD") or e.begins_with("GEAR") or e.begins_with("CRASH"):
			col = RED
		var fade := clampf(5.0 - age, 0.0, 1.0) * clampf(age * 6.0, 0.0, 1.0)
		var ef: Font = UI.spaced("Bold", 4)
		var ew := ef.get_string_size(e, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
		var er := Rect2((vs.x - ew) / 2.0 - 26.0, 84.0, ew + 52.0, 46.0)
		var eb := StyleBoxFlat.new()
		eb.bg_color = Color(0.03, 0.035, 0.045, 0.7 * fade)
		eb.set_corner_radius_all(4)
		eb.border_width_bottom = 3
		var ec := col
		ec.a = fade
		eb.border_color = ec
		draw_style_box(eb, er)
		draw_string(ef, Vector2(er.position.x + 26.0, er.position.y + 31.0), e, HORIZONTAL_ALIGNMENT_LEFT, -1, 24, Color(1, 1, 1, fade))


func _dev_text(v, hi: String, lo: String, tol: float) -> String:
	var f := float(v)
	if absf(f) < tol:
		return "ON"
	return hi if f > 0.0 else lo
