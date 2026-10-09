extends CanvasLayer
## Map screen (M): a shaded relief chart of the map (data/maps/<map>/map.jpg, tools/build_map_image.py) with the
## airfields, your own position and track, other jets, a latitude / longitude grid and your own markers.
## The flight carries on underneath (it is a chart on your knee, not a pause).
## Mouse: wheel zooms about the cursor, left drag pans, left click drops a marker, right click on a marker removes it.

const T = preload("res://scripts/ui/ui_theme.gd")
const R_EARTH := 6371008.8
const TRAIL_EVERY := 2.0               # s between track points
const TRAIL_MAX := 1800
const MIN_SCALE := 40.0                # m per pixel, zoomed in (the chart has a pixel every 256 m)
const MAX_SCALE := 2000.0
const PANEL_W := 360.0
const MARKER_COL := Color("ffd84a")
const FIELD_COL := Color("1d2a3a")
const OTHER_COL := Color("4fc3ff")
## Named places that are not airfields: [name, lat, lon, kind] (kind: peak, lake, region)
const PLACES := [
	["K2  8611", 35.8825, 76.5133, "peak"], ["NANGA PARBAT  8126", 35.2375, 74.5892, "peak"],
	["NUN  7135", 33.9806, 76.0186, "peak"], ["RAKAPOSHI  7788", 36.1425, 74.4894, "peak"],
	["Wular Lake", 34.36, 74.60, "lake"], ["Dal Lake", 34.11, 74.87, "lake"], ["Pangong Tso", 33.72, 78.75, "lake"],
	["Tso Moriri", 32.90, 78.31, "lake"], ["Mangla Lake", 33.21, 73.67, "lake"],
	["KASHMIR VALLEY", 34.5, 75.2, "region"], ["LADAKH", 34.0, 77.4, "region"], ["BALTISTAN", 35.05, 76.25, "region"],
	["GILGIT", 36.05, 74.0, "region"], ["AKSAI CHIN", 35.1, 79.3, "region"], ["JAMMU", 32.85, 74.6, "region"],
	["KARAKORAM", 35.85, 76.0, "region"], ["ZANSKAR", 33.45, 76.85, "region"],
]

var aircraft                           # the player's aircraft (scripts/aircraft/aircraft.gd)
var _root: Control
var _chart: Control
var _info: Label
var _cursor: Label
var _tex: Texture2D
var _ext := {}                         # map.json: x0, z0, x1, z1 (centres of the corner pixels), width, height
var _lat0 := 34.55
var _lon0 := 76.4
var _centre := Vector2.ZERO            # world x, z at the middle of the chart
var _scale := 400.0                    # metres per pixel
var _follow := true
var _drag_from = null
var _dragged := false
var _markers: Array[Vector2] = []
var _trail: Array[Vector2] = []
var _trail_t := 0.0
var _mouse := Vector2(-1, -1)


func _ready() -> void:
	layer = 15
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_chart()
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.get_theme()
	_root.visible = false
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.08, 0.09)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)
	_chart = Control.new()
	_chart.set_anchors_preset(Control.PRESET_FULL_RECT)
	_chart.offset_right = -PANEL_W            # the side panel is not over the chart: your jet is centred in what you see
	_chart.clip_contents = true
	_chart.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_chart.draw.connect(_draw_chart)
	_chart.gui_input.connect(_chart_input)
	_chart.mouse_exited.connect(func(): _mouse = Vector2(-1, -1))
	_root.add_child(_chart)
	# side panel: own data, markers, help
	var panel := T.glass(0.7)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -PANEL_W
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(panel)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 26)
	panel.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	m.add_child(col)
	col.add_child(T.label("MAP", 34, "Bold", T.ACCENT, 6))
	_info = T.label("", 20, "SemiBold", T.TEXT)
	_info.add_theme_font_override("font", T.tabular("SemiBold"))
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(_info)
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)
	row.add_child(_button("CENTRE ON ME", func():
		_follow = true))
	row.add_child(_button("CLEAR MARKS", func():
		_markers.clear()))
	var help := T.label("Wheel  zoom      Drag  pan\nClick  drop a mark      Right click  remove it\n%s  close" % _key_name(), 16, "SemiBold", T.DIM)
	col.add_child(help)
	var credits := T.label(String(_ext.get("credits", "")), 13, "SemiBold", T.DIM)
	credits.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(credits)
	_cursor = T.label("", 18, "SemiBold", T.TEXT)
	_cursor.add_theme_font_override("font", T.tabular("SemiBold"))
	_cursor.position = Vector2(24, 18)
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_cursor)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-open"):        # development: start with the map up (`--map-open=<m per px>`)
			if arg.contains("="):
				_scale = clampf(arg.get_slice("=", 1).to_float(), MIN_SCALE, MAX_SCALE)
			open.call_deferred()
		elif arg.begins_with("--map-mark="):      # development: a marker at x,z
			var xz := arg.trim_prefix("--map-mark=").split(",")
			_markers.append(Vector2(xz[0].to_float(), xz[1].to_float()))


func _exit_tree() -> void:
	Game.map_open = false


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", T.spaced("Bold", 2))
	b.add_theme_font_size_override("font_size", 18)
	b.custom_minimum_size = Vector2(0, 40)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _key_name() -> String:
	var evs := InputMap.action_get_events("toggle_map") if InputMap.has_action("toggle_map") else []
	for e in evs:
		if e is InputEventKey:
			return OS.get_keycode_string((e as InputEventKey).physical_keycode if (e as InputEventKey).keycode == 0 else (e as InputEventKey).keycode)
	return "M"


func _load_chart() -> void:
	var dir: String = WorldData.map_dir
	if dir == "":
		return
	var j = JSON.parse_string(FileAccess.get_file_as_string(dir + "/map.json")) if FileAccess.file_exists(dir + "/map.json") else null
	if typeof(j) != TYPE_DICTIONARY:
		return
	_ext = j
	var proj = j.get("projection")
	if typeof(proj) == TYPE_DICTIONARY:
		_lat0 = float(proj.lat0)
		_lon0 = float(proj.lon0)
	if ResourceLoader.exists(dir + "/map.jpg"):
		_tex = load(dir + "/map.jpg")


# ---------------- open / close ----------------
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map") and not (event is InputEventKey and (event as InputEventKey).echo):
		get_viewport().set_input_as_handled()
		if _root.visible:
			close()
		elif not get_tree().paused:
			open()
	elif _root.visible and event.is_action_pressed("pause_menu"):
		get_viewport().set_input_as_handled()
		close()


func open() -> void:
	_root.visible = true
	Game.map_open = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_follow = true
	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.12)


func close() -> void:
	_root.visible = false
	Game.map_open = false


func is_open() -> bool:
	return _root.visible


# ---------------- per frame ----------------
func _process(delta: float) -> void:
	var me := _own()
	if me != Vector2.INF and not get_tree().paused:
		_trail_t -= delta
		if _trail_t <= 0.0:
			_trail_t = TRAIL_EVERY
			if _trail.is_empty() or _trail[-1].distance_to(me) > 150.0:
				_trail.append(me)
				if _trail.size() > TRAIL_MAX:
					_trail.remove_at(0)
	if not _root.visible:
		return
	if _follow and me != Vector2.INF:
		_centre = me
	_update_info(me)
	_chart.queue_redraw()


func _own() -> Vector2:
	if aircraft == null or not is_instance_valid(aircraft):
		return Vector2.INF
	var w := WorldData.to_world(aircraft.global_position)
	return Vector2(w.x, w.z)


func _own_dir() -> Vector2:
	var f: Vector3 = -aircraft.global_transform.basis.z
	var d := Vector2(f.x, f.z)
	return d.normalized() if d.length() > 1e-4 else Vector2(0, -1)


func _update_info(me: Vector2) -> void:
	if me == Vector2.INF:
		_info.text = ""
		return
	var ll := latlon(me)
	var w := WorldData.to_world(aircraft.global_position)
	var lines := PackedStringArray()
	lines.append("%s   %s" % [_fmt_lat(ll.x), _fmt_lon(ll.y)])
	lines.append("HDG %03d°    ALT %d ft" % [int(round(fposmod(aircraft.heading_deg, 360.0))) % 360, int(w.y * 3.28084)])
	var near := _nearest_field(me)
	if not near.is_empty():
		lines.append("%s  %s\n    %03d°  %.1f km" % [near.field.id, near.field.name, _bearing(me, near.pos), near.d / 1000.0])
	for i in _markers.size():
		lines.append("MARK %d   %03d°  %.1f km" % [i + 1, _bearing(me, _markers[i]), me.distance_to(_markers[i]) / 1000.0])
	_info.text = "\n".join(lines)


func _nearest_field(p: Vector2) -> Dictionary:
	var best := {}
	var bd := INF
	for a in WorldData.airfields:
		var q := Vector2(float(a.x), float(a.z))
		var d := p.distance_to(q)
		if d < bd:
			bd = d
			best = {"field": a, "pos": q, "d": d}
	return best


## True bearing from a to b, degrees (map x east, z south; grid north is true north at the map centre, close
## enough everywhere on this map for a chart).
func _bearing(a: Vector2, b: Vector2) -> int:
	var d := b - a
	return int(round(fposmod(rad_to_deg(atan2(d.x, -d.y)), 360.0))) % 360


# ---------------- projection ----------------
func latlon(p: Vector2) -> Vector2:
	var x := p.x
	var y := -p.y
	var rho := sqrt(x * x + y * y)
	var phi0 := deg_to_rad(_lat0)
	if rho < 1e-6:
		return Vector2(_lat0, _lon0)
	var c := rho / R_EARTH
	var lat := asin(cos(c) * sin(phi0) + y * sin(c) * cos(phi0) / rho)
	var lon := deg_to_rad(_lon0) + atan2(x * sin(c), rho * cos(phi0) * cos(c) - y * sin(phi0) * sin(c))
	return Vector2(rad_to_deg(lat), rad_to_deg(lon))


func project(lat: float, lon: float) -> Vector2:
	var p := deg_to_rad(lat)
	var l := deg_to_rad(lon)
	var p0 := deg_to_rad(_lat0)
	var l0 := deg_to_rad(_lon0)
	var c := acos(clampf(sin(p0) * sin(p) + cos(p0) * cos(p) * cos(l - l0), -1.0, 1.0))
	var k := c / sin(c) if c > 1e-12 else 1.0
	var x := R_EARTH * k * cos(p) * sin(l - l0)
	var y := R_EARTH * k * (cos(p0) * sin(p) - sin(p0) * cos(p) * cos(l - l0))
	return Vector2(x, -y)


func _fmt_lat(v: float) -> String:
	return "%s %02d°%02d'" % ["N" if v >= 0 else "S", int(absf(v)), int(fposmod(absf(v) * 60.0, 60.0))]


func _fmt_lon(v: float) -> String:
	return "%s %03d°%02d'" % ["E" if v >= 0 else "W", int(absf(v)), int(fposmod(absf(v) * 60.0, 60.0))]


# ---------------- chart <-> screen ----------------
func _to_screen(p: Vector2) -> Vector2:
	return _chart.size * 0.5 + (p - _centre) / _scale


func _to_map(s: Vector2) -> Vector2:
	return _centre + (s - _chart.size * 0.5) * _scale


func _chart_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse = mm.position
		if _drag_from != null:
			if mm.position.distance_to(_drag_from) > 4.0:
				_dragged = true
			if _dragged:
				_centre -= mm.relative * _scale
				_follow = false
		_update_cursor()
		_chart.accept_event()
		return
	var mb := event as InputEventMouseButton
	if mb == null:
		return
	_chart.accept_event()
	match mb.button_index:
		MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN:
			if not mb.pressed:
				return
			var at := _to_map(mb.position)
			var f := 0.8 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.25
			_scale = clampf(_scale * f, MIN_SCALE, MAX_SCALE)
			if not _follow:
				_centre = at - (mb.position - _chart.size * 0.5) * _scale     # keep the point under the cursor
		MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_drag_from = mb.position
				_dragged = false
			else:
				if not _dragged and _drag_from != null and _markers.size() < 9:
					_markers.append(_to_map(mb.position))
				_drag_from = null
		MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				for i in range(_markers.size() - 1, -1, -1):
					if _to_screen(_markers[i]).distance_to(mb.position) < 14.0:
						_markers.remove_at(i)
						break
	_update_cursor()


func _update_cursor() -> void:
	if _mouse.x < 0.0:
		_cursor.text = ""
		return
	var p := _to_map(_mouse)
	var ll := latlon(p)
	var h := WorldData.terrain_height(p.x, p.y)
	var t := "%s   %s     %d ft" % [_fmt_lat(ll.x), _fmt_lon(ll.y), int(h * 3.28084)]
	var me := _own()
	if me != Vector2.INF:
		t += "     from you %03d°  %.1f km" % [_bearing(me, p), me.distance_to(p) / 1000.0]
	_cursor.text = t


# ---------------- drawing ----------------
func _draw_chart() -> void:
	var c := _chart
	var font := T.font("Bold")
	if _tex and not _ext.is_empty():
		var s := (float(_ext.x1) - float(_ext.x0)) / (float(_ext.width) - 1.0)
		var a := _to_screen(Vector2(float(_ext.x0) - s * 0.5, float(_ext.z0) - s * 0.5))
		var b := _to_screen(Vector2(float(_ext.x1) + s * 0.5, float(_ext.z1) + s * 0.5))
		c.draw_texture_rect(_tex, Rect2(a, b - a), false)
	_draw_graticule(font)
	_draw_places(font)
	# own track
	if _trail.size() > 1:
		var pts := PackedVector2Array()
		for p in _trail:
			pts.append(_to_screen(p))
		var me := _own()
		if me != Vector2.INF:
			pts.append(_to_screen(me))
		c.draw_polyline(pts, Color(1, 0.6, 0.18, 0.75), 2.0, true)
	_draw_fields(font)
	_draw_others()
	# markers, and the line from you to each
	var me := _own()
	for i in _markers.size():
		var q := _to_screen(_markers[i])
		if me != Vector2.INF:
			c.draw_dashed_line(_to_screen(me), q, Color(MARKER_COL, 0.55), 1.5, 8.0)
		var d := PackedVector2Array([q + Vector2(0, -10), q + Vector2(10, 0), q + Vector2(0, 10), q + Vector2(-10, 0)])
		c.draw_colored_polygon(d, Color(0, 0, 0, 0.55))
		d.append(d[0])
		c.draw_polyline(d, MARKER_COL, 2.5, true)
		c.draw_string_outline(font, q + Vector2(13, 6), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, 5, Color(0, 0, 0, 0.8))
		c.draw_string(font, q + Vector2(13, 6), str(i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, MARKER_COL)
	if me != Vector2.INF:
		_draw_jet(_to_screen(me), _own_dir(), T.ACCENT, 1.25)
	_draw_scale(font)


func _draw_graticule(font: Font) -> void:
	var c := _chart
	var col := Color(1, 1, 1, 0.22)
	var lat_a := 30.0
	var lat_b := 39.0
	var lon_a := 70.0
	var lon_b := 82.0
	var step := 1.0 if _scale < 900.0 else 2.0
	var lat := lat_a
	while lat <= lat_b:
		var pts := PackedVector2Array()
		var lon := lon_a
		while lon <= lon_b + 0.01:
			pts.append(_to_screen(project(lat, lon)))
			lon += 0.25
		c.draw_polyline(pts, col, 1.0, true)
		var lp := _to_screen(project(lat, _lon_at_left(lat)))
		c.draw_string(font, Vector2(6, lp.y - 4), "%d°N" % int(lat), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.6))
		lat += step
	var lo := lon_a
	while lo <= lon_b:
		var pts := PackedVector2Array()
		var la := lat_a
		while la <= lat_b + 0.01:
			pts.append(_to_screen(project(la, lo)))
			la += 0.25
		c.draw_polyline(pts, col, 1.0, true)
		var bp := _to_screen(project(_lat_at_bottom(lo), lo))
		c.draw_string(font, Vector2(bp.x + 4, c.size.y - 8), "%d°E" % int(lo), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(1, 1, 1, 0.6))
		lo += step


func _lon_at_left(_lat: float) -> float:
	return latlon(_to_map(Vector2(0, _chart.size.y * 0.5))).y


func _lat_at_bottom(_lon: float) -> float:
	return latlon(_to_map(Vector2(_chart.size.x * 0.5, _chart.size.y))).x


func _draw_places(font: Font) -> void:
	var c := _chart
	for pl in PLACES:
		var q := _to_screen(project(pl[1], pl[2]))
		if not Rect2(Vector2(-200, -50), c.size + Vector2(400, 100)).has_point(q):
			continue
		match String(pl[3]):
			"peak":
				if _scale > 900.0:
					continue
				c.draw_colored_polygon(PackedVector2Array([q + Vector2(0, -7), q + Vector2(6, 4), q + Vector2(-6, 4)]), Color(0.25, 0.12, 0.08))
				_text(font, q + Vector2(9, 5), pl[0], 15, Color(0.2, 0.1, 0.06), Color(1, 1, 1, 0.55))
			"lake":
				if _scale > 500.0:
					continue
				_text(font, q + Vector2(-30, 0), pl[0], 15, Color(0.1, 0.25, 0.45), Color(1, 1, 1, 0.5), true)
			"region":
				var sz := int(clampf(9000.0 / _scale, 16.0, 30.0))
				var w := font.get_string_size(pl[0], HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
				_text(font, q - Vector2(w * 0.5, 0), pl[0], sz, Color(0.18, 0.14, 0.1, 0.75), Color(1, 1, 1, 0.3))


func _text(font: Font, at: Vector2, s: String, size: int, col: Color, outline: Color, _italic: bool = false) -> void:
	_chart.draw_string_outline(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, outline)
	_chart.draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_fields(font: Font) -> void:
	var c := _chart
	for a in WorldData.airfields:
		var q := _to_screen(Vector2(float(a.x), float(a.z)))
		if not Rect2(Vector2(-100, -100), c.size + Vector2(200, 200)).has_point(q):
			continue
		# runways at their true length and heading, but never shorter than a readable symbol
		for r in a.runways:
			var A := Vector2(r.a[0], r.a[2])
			var B := Vector2(r.b[0], r.b[2])
			var mid := _to_screen((A + B) * 0.5)
			var half := (B - A) * 0.5 / _scale
			if half.length() < 9.0:
				half = half.normalized() * 9.0
			c.draw_line(mid - half, mid + half, Color(1, 1, 1, 0.9), 6.0, true)
			c.draw_line(mid - half, mid + half, FIELD_COL, 3.0, true)
		c.draw_arc(q, 13.0, 0.0, TAU, 32, Color(1, 1, 1, 0.9), 4.0, true)
		c.draw_arc(q, 13.0, 0.0, TAU, 32, FIELD_COL, 2.0, true)
		var label := String(a.id)
		if _scale < 250.0:
			label += "  " + String(a.name)
		_text(font, q + Vector2(17, -8), label, 17, FIELD_COL, Color(1, 1, 1, 0.75))
		if _scale < 250.0 and not a.runways.is_empty():
			var r0: Dictionary = a.runways[0]
			var elev := int(float(r0.a[1]) * 3.28084)
			_text(font, q + Vector2(17, 10), "%s/%s   %d ft" % [r0.ids[0], r0.ids[1], elev], 14, FIELD_COL, Color(1, 1, 1, 0.6))


func _draw_others() -> void:
	var me = aircraft
	for n in get_tree().get_nodes_in_group("remote_aircraft") + get_tree().get_nodes_in_group("ai_aircraft"):
		if n == me or not (n is Node3D) or not (n as Node3D).is_inside_tree():
			continue
		var w := WorldData.to_world((n as Node3D).global_position)
		var f := -(n as Node3D).global_transform.basis.z
		var d := Vector2(f.x, f.z)
		_draw_jet(_to_screen(Vector2(w.x, w.z)), d.normalized() if d.length() > 1e-4 else Vector2(0, -1), OTHER_COL, 0.9)


func _draw_jet(q: Vector2, dir: Vector2, col: Color, k: float) -> void:
	var side := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([q + dir * 16.0 * k, q - dir * 10.0 * k + side * 9.0 * k, q - dir * 5.0 * k, q - dir * 10.0 * k - side * 9.0 * k])
	_chart.draw_colored_polygon(pts, col)
	pts.append(pts[0])
	_chart.draw_polyline(pts, Color(0, 0, 0, 0.85), 2.0, true)
	_chart.draw_line(q + dir * 16.0 * k, q + dir * 60.0 * k, Color(col, 0.7), 2.0, true)


func _draw_scale(font: Font) -> void:
	var c := _chart
	# a round distance about 160 px long
	var want := _scale * 160.0
	var nice := [1000.0, 2000.0, 5000.0, 10000.0, 20000.0, 50000.0, 100000.0, 200000.0, 500000.0]
	var d: float = nice[0]
	for v in nice:
		if v <= want:
			d = v
	var px := d / _scale
	var o := Vector2(26, c.size.y - 40)
	c.draw_rect(Rect2(o - Vector2(8, 26), Vector2(px + 70, 40)), Color(0, 0, 0, 0.45))
	c.draw_line(o, o + Vector2(px, 0), Color.WHITE, 3.0)
	c.draw_line(o + Vector2(0, -7), o + Vector2(0, 3), Color.WHITE, 2.0)
	c.draw_line(o + Vector2(px, -7), o + Vector2(px, 3), Color.WHITE, 2.0)
	c.draw_string(font, o + Vector2(px + 8, 6), "%d km" % int(d / 1000.0), HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color.WHITE)
	# north arrow (grid north)
	var n := Vector2(c.size.x - 44.0, 54.0)
	c.draw_colored_polygon(PackedVector2Array([n + Vector2(0, -22), n + Vector2(9, 8), n + Vector2(0, 2), n + Vector2(-9, 8)]), Color.WHITE)
	c.draw_string(font, n + Vector2(-6, 30), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color.WHITE)
