extends CanvasLayer
## Map screen (M): a shaded relief chart of the map (data/maps/<map>/map.jpg, tools/build_map_image.py) with the
## airfields, your own position and track, other jets, a latitude / longitude grid and your own markers. Kashmir
## (data/maps/<map>/region.json, tools/build_region.py) has a red border; the chart fades out softly at its edges
## (shaders/map_chart.gdshader).
## The flight carries on underneath (it is a chart on your knee, not a pause).
## Mouse: wheel zooms about the cursor, left drag pans, left click drops a marker; right drag measures (bearing,
## distance and time from one point to another, as the F10 ruler in DCS: start or end it on a jet, an airfield or a
## marker and it holds on to it, following a jet as it flies); right click removes a marker, or the ruler.

const T = preload("res://scripts/ui/ui_theme.gd")
const R_EARTH := 6371008.8
const TRAIL_EVERY := 2.0               # s between track points
const TRAIL_MAX := 1800
const MIN_SCALE := 40.0                # m per pixel, zoomed in (the chart has a pixel every 256 m)
const MAX_SCALE := 2000.0
const PANEL_W := 380.0
const CHART_PAD := 0.35               # the chart's soft surround on each side, as a share of its size
const SNAP_PX := 18.0                  # a point this close to a jet, an airfield or a marker takes it
const RULER_COL := Color("f4f6f8")
const BORDER_COL := Color(0.92, 0.27, 0.24, 0.85)
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
var _chart: Control                    # takes the mouse; draws nothing itself
var _relief: Control                   # the chart picture (with the region shader)
var _ink: Control                      # everything drawn over it
var _own_lbl: Label
var _near_lbl: Label
var _ruler_box: Control
var _ruler_lbl: Label
var _marks_box: Control
var _marks_lbl: Label
var _cursor: Label
var _cursor_box: Control
var _tex: Texture2D
var _region := PackedVector2Array()    # the playable region's outline (map x, z)
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
var _ruler := {}                       # {"a": anchor, "b": anchor} (anchors: _snap)
var _rpress = null                     # right button: where it went down (screen), and the anchor there
var _rpress_anchor := {}
var _rdrag := false


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
	_chart.gui_input.connect(_chart_input)
	_chart.mouse_exited.connect(func(): _mouse = Vector2(-1, -1))
	_root.add_child(_chart)
	_relief = Control.new()
	_relief.set_anchors_preset(Control.PRESET_FULL_RECT)
	_relief.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_relief.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://shaders/map_chart.gdshader")
	mat.set_shader_parameter("bg", bg.color)
	if _tex:
		# a small, soft copy of the chart for its faded surround
		var img := _tex.get_image()
		if img:
			if img.is_compressed():
				img.decompress()
			img.clear_mipmaps()
			img.resize(maxi(img.get_width() / 16, 8), maxi(img.get_height() / 16, 8), Image.INTERPOLATE_LANCZOS)
			mat.set_shader_parameter("soft_tex", ImageTexture.create_from_image(img))
	_relief.material = mat
	_relief.draw.connect(_draw_relief)
	_chart.add_child(_relief)
	_ink = Control.new()
	_ink.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ink.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ink.draw.connect(_draw_chart)
	_chart.add_child(_ink)
	# side panel: own data, nearest field, the ruler, markers, controls
	var panel := T.glass(0.78)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -PANEL_W
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(panel)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 30)
	m.add_theme_constant_override("margin_right", 30)
	m.add_theme_constant_override("margin_top", 30)
	m.add_theme_constant_override("margin_bottom", 28)
	panel.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	m.add_child(col)
	var title := HBoxContainer.new()
	title.add_theme_constant_override("separation", 14)
	title.add_child(T.label("MAP", 34, "Bold", T.ACCENT, 6))
	var region := T.label(String(_ext.get("region_name", "KASHMIR")), 15, "Bold", T.DIM, 4)
	region.size_flags_vertical = Control.SIZE_SHRINK_END
	title.add_child(region)
	col.add_child(title)
	col.add_child(_gap(10))
	_own_lbl = _section(col, "OWN SHIP")
	_near_lbl = _section(col, "NEAREST AIRFIELD")
	_ruler_lbl = _section(col, "RULER")
	_ruler_box = _ruler_lbl.get_parent()
	_marks_lbl = _section(col, "MARKS")
	_marks_box = _marks_lbl.get_parent()
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	col.add_child(row)
	row.add_child(_button("CENTRE ON ME", func():
		_follow = true))
	row.add_child(_button("CLEAR ALL", func():
		_markers.clear()
		_ruler = {}))
	col.add_child(_gap(10))
	var keys := GridContainer.new()
	keys.columns = 2
	keys.add_theme_constant_override("h_separation", 16)
	keys.add_theme_constant_override("v_separation", 3)
	for kv in [["Wheel", "zoom"], ["Left drag", "pan"], ["Left click", "drop a mark"],
			["Right drag", "bearing and distance"], ["Right click", "remove a mark or the ruler"], [_key_name(), "close"]]:
		keys.add_child(T.label(kv[0], 15, "Bold", T.TEXT))
		keys.add_child(T.label(kv[1], 15, "SemiBold", T.DIM))
	col.add_child(keys)
	col.add_child(_gap(8))
	var credits := T.label(String(_ext.get("credits", "")) + "\nBorders: Natural Earth", 12, "SemiBold", Color(T.DIM, 0.7))
	credits.autowrap_mode = TextServer.AUTOWRAP_WORD
	col.add_child(credits)
	# the cursor's position, top left of the chart
	_cursor_box = PanelContainer.new()
	_cursor_box.add_theme_stylebox_override("panel", T.flat(Color(0.03, 0.035, 0.045, 0.72), Color(1, 1, 1, 0.07), [1, 1, 1, 1], [14, 8, 14, 8]))
	_cursor_box.position = Vector2(20, 18)
	_cursor_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_box.visible = false
	_root.add_child(_cursor_box)
	_cursor = T.label("", 17, "SemiBold", T.TEXT)
	_cursor.add_theme_font_override("font", T.tabular("SemiBold"))
	_cursor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cursor_box.add_child(_cursor)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map-open"):        # development: start with the map up (`--map-open=<m per px>`)
			if arg.contains("="):
				_scale = clampf(arg.get_slice("=", 1).to_float(), MIN_SCALE, MAX_SCALE)
			open.call_deferred()
		elif arg.begins_with("--map-mark="):      # development: a marker at x,z
			var xz := arg.trim_prefix("--map-mark=").split(",")
			_markers.append(Vector2(xz[0].to_float(), xz[1].to_float()))
		elif arg.begins_with("--map-ruler="):     # development: a ruler from your jet to x,z
			var xz := arg.trim_prefix("--map-ruler=").split(",")
			_ruler = {"a": {"kind": "me", "name": "YOU", "pos": Vector2.ZERO},
				"b": {"kind": "pos", "name": "", "pos": Vector2(xz[0].to_float(), xz[1].to_float())}}


func _exit_tree() -> void:
	Game.map_open = false


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", T.spaced("Bold", 2))
	b.add_theme_font_size_override("font_size", 15)
	b.custom_minimum_size = Vector2(0, 40)
	b.clip_text = true
	b.add_theme_stylebox_override("normal", T.flat(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.16), [1, 1, 1, 1]))
	b.add_theme_stylebox_override("hover", T.flat(Color(1, 1, 1, 0.1), T.ACCENT, [1, 1, 1, 1]))
	b.add_theme_stylebox_override("pressed", T.flat(Color(T.ACCENT, 0.2), T.ACCENT, [1, 1, 1, 1]))
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


func _gap(h: float) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


## A titled block in the side panel; returns its text label (the block hides itself while that is empty).
func _section(col: VBoxContainer, title: String) -> Label:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(T.label(title, 13, "Bold", T.DIM, 3))
	var l := T.label("", 18, "SemiBold", T.TEXT)
	l.add_theme_font_override("font", T.tabular("SemiBold"))
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(l)
	box.add_child(_gap(10))
	col.add_child(box)
	return l


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
	var r = JSON.parse_string(FileAccess.get_file_as_string(dir + "/region.json")) if FileAccess.file_exists(dir + "/region.json") else null
	if typeof(r) == TYPE_DICTIONARY:
		for q in r.get("outline", []):
			_region.append(Vector2(float(q[0]), float(q[1])))


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
	_update_cursor()
	_relief.queue_redraw()
	_ink.queue_redraw()


func _texel() -> float:
	if _ext.is_empty():
		return 256.0
	return (float(_ext.x1) - float(_ext.x0)) / (float(_ext.width) - 1.0)


func _own() -> Vector2:
	if aircraft == null or not is_instance_valid(aircraft):
		return Vector2.INF
	var w := WorldData.to_world(aircraft.global_position)
	return Vector2(w.x, w.z)


func _own_dir() -> Vector2:
	return _dir_of(aircraft)


func _dir_of(n: Node3D) -> Vector2:
	var f: Vector3 = -n.global_transform.basis.z
	var d := Vector2(f.x, f.z)
	return d.normalized() if d.length() > 1e-4 else Vector2(0, -1)


func _others() -> Array:
	var out := []
	for n in get_tree().get_nodes_in_group("remote_aircraft") + get_tree().get_nodes_in_group("ai_aircraft"):
		if n != aircraft and n is Node3D and (n as Node3D).is_inside_tree():
			out.append(n)
	return out


func _jet_name(n: Node) -> String:
	var cs = n.get("callsign")
	return String(cs) if cs != null and String(cs) != "" else "Jet"


func _update_info(me: Vector2) -> void:
	if me == Vector2.INF:
		_own_lbl.text = ""
		_near_lbl.text = ""
	else:
		var ll := latlon(me)
		var w := WorldData.to_world(aircraft.global_position)
		_own_lbl.text = "%s   %s\nHDG %03d°   %d ft   %d kt" % [_fmt_lat(ll.x), _fmt_lon(ll.y),
			int(round(fposmod(aircraft.heading_deg, 360.0))) % 360, int(w.y * 3.28084), int(aircraft.ground_speed * 1.94384)]
		var near := _nearest_field(me)
		_near_lbl.text = "" if near.is_empty() else "%s  %s\n%03d°   %s" % [near.field.id, near.field.name,
			_bearing(me, near.pos), _dist_text(near.d)]
	_near_lbl.get_parent().visible = _near_lbl.text != ""
	# the ruler
	var rl := ""
	if not _ruler.is_empty():
		var a := _anchor_pos(_ruler.a)
		var b := _anchor_pos(_ruler.b)
		var d := a.distance_to(b)
		var brg := _bearing(a, b)
		rl = "%s  to  %s\n%03d°   %s\nback  %03d°" % [_anchor_name(_ruler.a, "A"), _anchor_name(_ruler.b, "B"), brg,
			_dist_text(d), (brg + 180) % 360]
		var spd := _anchor_speed(_ruler.a)
		if spd > 25.0:
			rl += "   %s at %d kt" % [_time_text(d / spd), int(spd * 1.94384)]
	_ruler_lbl.text = rl
	_ruler_box.visible = rl != ""
	# markers
	var ml := PackedStringArray()
	for i in _markers.size():
		if me != Vector2.INF:
			ml.append("%d   %03d°   %s" % [i + 1, _bearing(me, _markers[i]), _dist_text(me.distance_to(_markers[i]))])
		else:
			ml.append(str(i + 1))
	_marks_lbl.text = "\n".join(ml)
	_marks_box.visible = not ml.is_empty()


func _dist_text(m: float) -> String:
	return "%.1f km   %.1f nm" % [m / 1000.0, m / 1852.0] if m < 100000.0 else "%d km   %d nm" % [int(m / 1000.0), int(m / 1852.0)]


func _time_text(s: float) -> String:
	var t := int(round(s))
	return "%d:%02d:%02d" % [t / 3600, (t / 60) % 60, t % 60] if t >= 3600 else "%d:%02d" % [t / 60, t % 60]


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


# ---------------- the ruler: points it can hold on to ----------------
## What is at this screen point: your jet, another jet, a marker, an airfield, or just the place.
func _snap(s: Vector2) -> Dictionary:
	var me := _own()
	if me != Vector2.INF and _to_screen(me).distance_to(s) < SNAP_PX:
		return {"kind": "me", "name": "YOU", "pos": me}
	for n in _others():
		var w := WorldData.to_world((n as Node3D).global_position)
		if _to_screen(Vector2(w.x, w.z)).distance_to(s) < SNAP_PX:
			return {"kind": "jet", "node": n, "name": _jet_name(n), "pos": Vector2(w.x, w.z)}
	for i in _markers.size():
		if _to_screen(_markers[i]).distance_to(s) < SNAP_PX:
			return {"kind": "mark", "name": "MARK %d" % (i + 1), "pos": _markers[i]}
	for a in WorldData.airfields:
		var q := Vector2(float(a.x), float(a.z))
		if _to_screen(q).distance_to(s) < SNAP_PX:
			return {"kind": "field", "name": String(a.id), "pos": q}
	return {"kind": "pos", "name": "", "pos": _to_map(s)}


func _anchor_pos(a: Dictionary) -> Vector2:
	match String(a.kind):
		"me":
			var me := _own()
			if me != Vector2.INF:
				a.pos = me
		"jet":
			if is_instance_valid(a.get("node")) and (a.node as Node3D).is_inside_tree():
				var w := WorldData.to_world((a.node as Node3D).global_position)
				a.pos = Vector2(w.x, w.z)
	return a.pos


func _anchor_name(a: Dictionary, fallback: String) -> String:
	return String(a.name) if String(a.name) != "" else fallback


## Ground speed (m/s) of a jet the ruler starts from: how long it takes it to get there
func _anchor_speed(a: Dictionary) -> float:
	match String(a.kind):
		"me":
			return aircraft.ground_speed if aircraft != null and is_instance_valid(aircraft) else 0.0
		"jet":
			if is_instance_valid(a.get("node")):
				var v = a.node.get("ground_speed")
				return float(v) if v != null else 0.0
	return 0.0


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
		if _rpress != null:
			if mm.position.distance_to(_rpress) > 6.0:
				_rdrag = true
			if _rdrag:
				_ruler = {"a": _rpress_anchor, "b": _snap(mm.position)}
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
				_rpress = mb.position
				_rpress_anchor = _snap(mb.position)
				_rdrag = false
			elif _rpress != null:
				if _rdrag:
					_ruler = {"a": _rpress_anchor, "b": _snap(mb.position)}
				else:
					# a click: on a marker, removes it; anywhere else, removes the ruler
					var hit := false
					for i in range(_markers.size() - 1, -1, -1):
						if _to_screen(_markers[i]).distance_to(mb.position) < 14.0:
							_markers.remove_at(i)
							hit = true
							break
					if not hit:
						_ruler = {}
				_rpress = null
				_rdrag = false


func _update_cursor() -> void:
	if _mouse.x < 0.0:
		_cursor_box.visible = false
		return
	var p := _to_map(_mouse)
	var ll := latlon(p)
	var h := WorldData.terrain_height(p.x, p.y)
	var t := "%s   %s     %d ft" % [_fmt_lat(ll.x), _fmt_lon(ll.y), int(h * 3.28084)]
	var me := _own()
	if me != Vector2.INF:
		t += "     from you  %03d°   %s" % [_bearing(me, p), _dist_text(me.distance_to(p))]
	_cursor.text = t
	_cursor_box.visible = true
	_cursor_box.reset_size()


# ---------------- drawing ----------------
func _draw_relief() -> void:
	if _tex and not _ext.is_empty():
		var s := _texel()
		var a := _to_screen(Vector2(float(_ext.x0) - s * 0.5, float(_ext.z0) - s * 0.5))
		var b := _to_screen(Vector2(float(_ext.x1) + s * 0.5, float(_ext.z1) + s * 0.5))
		# drawn larger than the chart: beyond its edge the shader fades it out softly (shaders/map_chart.gdshader)
		var sz := b - a
		var pad := CHART_PAD
		(_relief.material as ShaderMaterial).set_shader_parameter("pad", pad)
		(_relief.material as ShaderMaterial).set_shader_parameter("aspect", sz.y / maxf(sz.x, 1.0))
		_relief.draw_texture_rect(_tex, Rect2(a - sz * pad, sz * (1.0 + 2.0 * pad)), false)


func _draw_chart() -> void:
	var c := _ink
	var font := T.font("Bold")
	_draw_graticule(font)
	_draw_region()
	_draw_places(font)
	# own track
	var me := _own()
	if _trail.size() > 1:
		var pts := PackedVector2Array()
		for p in _trail:
			pts.append(_to_screen(p))
		if me != Vector2.INF:
			pts.append(_to_screen(me))
		c.draw_polyline(pts, Color(1, 0.6, 0.18, 0.75), 2.0, true)
	_draw_fields(font)
	_draw_others(font)
	# markers, and the line from you to each
	for i in _markers.size():
		var q := _to_screen(_markers[i])
		if me != Vector2.INF:
			c.draw_dashed_line(_to_screen(me), q, Color(MARKER_COL, 0.55), 1.5, 8.0)
		var d := PackedVector2Array([q + Vector2(0, -10), q + Vector2(10, 0), q + Vector2(0, 10), q + Vector2(-10, 0)])
		c.draw_colored_polygon(d, Color(0, 0, 0, 0.55))
		d.append(d[0])
		c.draw_polyline(d, MARKER_COL, 2.5, true)
		_text(font, q + Vector2(13, 6), str(i + 1), 20, MARKER_COL, Color(0, 0, 0, 0.8))
	if me != Vector2.INF:
		_draw_jet(_to_screen(me), _own_dir(), T.ACCENT, 1.25)
	_draw_ruler(font)
	_draw_hover(font)
	_draw_scale(font)


## The playable region's border: a thin red line with a soft dark edge outside it
func _draw_region() -> void:
	if _region.size() < 3:
		return
	var pts := PackedVector2Array()
	for q in _region:
		pts.append(_to_screen(q))
	_ink.draw_polyline(pts, Color(0.35, 0.02, 0.02, 0.35), 6.0, true)
	_ink.draw_polyline(pts, BORDER_COL, 2.0, true)


func _draw_ruler(font: Font) -> void:
	if _ruler.is_empty():
		return
	var c := _ink
	var a := _to_screen(_anchor_pos(_ruler.a))
	var b := _to_screen(_anchor_pos(_ruler.b))
	var v := b - a
	if v.length() < 2.0:
		return
	var u := v.normalized()
	var n := Vector2(-u.y, u.x)
	c.draw_line(a, b, Color(0, 0, 0, 0.7), 5.0, true)
	c.draw_line(a, b, RULER_COL, 2.0, true)
	# arrowhead at the far end, rings at both
	var tip := b - u * 9.0
	c.draw_colored_polygon(PackedVector2Array([tip + u * 2.0, tip - u * 12.0 + n * 6.0, tip - u * 12.0 - n * 6.0]), RULER_COL)
	for q in [a, b]:
		c.draw_arc(q, 9.0, 0.0, TAU, 24, Color(0, 0, 0, 0.7), 4.0, true)
		c.draw_arc(q, 9.0, 0.0, TAU, 24, RULER_COL, 2.0, true)
	# the reading, beside the middle of the line
	var A := _anchor_pos(_ruler.a)
	var B := _anchor_pos(_ruler.b)
	var d := A.distance_to(B)
	var l1 := "%03d°   %s" % [_bearing(A, B), _dist_text(d)]
	var spd := _anchor_speed(_ruler.a)
	var l2 := "%s  to  %s" % [_anchor_name(_ruler.a, "A"), _anchor_name(_ruler.b, "B")]
	if spd > 25.0:
		l2 += "   %s" % _time_text(d / spd)
	var w := maxf(font.get_string_size(l1, HORIZONTAL_ALIGNMENT_LEFT, -1, 19).x, font.get_string_size(l2, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x)
	var side := n if n.y <= 0.0 else -n          # above the line
	var mid := (a + b) * 0.5 + side * 30.0
	var box := Rect2(mid - Vector2(w * 0.5 + 12, 24), Vector2(w + 24, 48))
	c.draw_rect(box, Color(0.03, 0.035, 0.045, 0.82))
	c.draw_rect(box, Color(1, 1, 1, 0.14), false, 1.0)
	c.draw_string(font, box.position + Vector2(12, 22), l1, HORIZONTAL_ALIGNMENT_LEFT, -1, 19, RULER_COL)
	c.draw_string(font, box.position + Vector2(12, 40), l2, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, T.DIM)


## Under the cursor: an airfield's or a jet's details
func _draw_hover(font: Font) -> void:
	if _mouse.x < 0.0 or _dragged or _rdrag:
		return
	var me := _own()
	var lines := PackedStringArray()
	var snap := _snap(_mouse)
	match String(snap.kind):
		"field":
			for a in WorldData.airfields:
				if String(a.id) != String(snap.name):
					continue
				lines.append("%s   %s" % [a.id, a.name])
				for r in a.runways:
					var A := Vector3(r.a[0], r.a[1], r.a[2])
					var B := Vector3(r.b[0], r.b[1], r.b[2])
					lines.append("RWY %s/%s   %d m   %d ft" % [r.ids[0], r.ids[1], int(Vector2(A.x, A.z).distance_to(Vector2(B.x, B.z))), int(A.y * 3.28084)])
				break
		"jet":
			var n: Node3D = snap.node
			var w := WorldData.to_world(n.global_position)
			var spd = n.get("ground_speed")
			var hd := _dir_of(n)
			lines.append(String(snap.name))
			lines.append("%d ft   %03d°   %d kt" % [int(w.y * 3.28084), int(round(fposmod(rad_to_deg(atan2(hd.x, -hd.y)), 360.0))) % 360,
				int(float(spd if spd != null else 0.0) * 1.94384)])
		_:
			return
	if me != Vector2.INF and String(snap.kind) != "me":
		lines.append("from you  %03d°   %s" % [_bearing(me, snap.pos), _dist_text(me.distance_to(snap.pos))])
	var w := 0.0
	for l in lines:
		w = maxf(w, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x)
	var at := _mouse + Vector2(22, 18)
	var box := Rect2(at, Vector2(w + 24, lines.size() * 21 + 14))
	if box.end.x > _ink.size.x - 10:
		box.position.x = _mouse.x - 22 - box.size.x
	if box.end.y > _ink.size.y - 10:
		box.position.y = _mouse.y - 18 - box.size.y
	_ink.draw_rect(box, Color(0.03, 0.035, 0.045, 0.85))
	_ink.draw_rect(box, Color(1, 1, 1, 0.14), false, 1.0)
	for i in lines.size():
		_ink.draw_string(font, box.position + Vector2(12, 24 + i * 21), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
			T.TEXT if i == 0 else T.DIM)
func _draw_graticule(font: Font) -> void:
	var c := _ink
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
	var c := _ink
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
	_ink.draw_string_outline(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 4, outline)
	_ink.draw_string(font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_fields(font: Font) -> void:
	var c := _ink
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


func _draw_others(font: Font) -> void:
	for n in _others():
		var w := WorldData.to_world((n as Node3D).global_position)
		var q := _to_screen(Vector2(w.x, w.z))
		_draw_jet(q, _dir_of(n), OTHER_COL, 0.9)
		if _scale < 1200.0:
			_text(font, q + Vector2(14, 22), "%s  %d" % [_jet_name(n), int(round(w.y * 3.28084 / 100.0)) * 100], 14, OTHER_COL, Color(0, 0, 0, 0.75))


func _draw_jet(q: Vector2, dir: Vector2, col: Color, k: float) -> void:
	var side := Vector2(-dir.y, dir.x)
	var pts := PackedVector2Array([q + dir * 16.0 * k, q - dir * 10.0 * k + side * 9.0 * k, q - dir * 5.0 * k, q - dir * 10.0 * k - side * 9.0 * k])
	_ink.draw_colored_polygon(pts, col)
	pts.append(pts[0])
	_ink.draw_polyline(pts, Color(0, 0, 0, 0.85), 2.0, true)
	_ink.draw_line(q + dir * 16.0 * k, q + dir * 60.0 * k, Color(col, 0.7), 2.0, true)


func _draw_scale(font: Font) -> void:
	var c := _ink
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
