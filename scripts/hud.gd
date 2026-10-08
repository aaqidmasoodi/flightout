extends CanvasLayer
## Flight HUD: frosted flight-data panel, system chips, status pill, optional key hints and FPS.
## The flight path marker and approach guidance live in hud_overlay.gd (cockpit view only).

const T = preload("res://scripts/ui/ui_theme.gd")

var aircraft: Node3D
var _root: Control
var _panel: Control
var _vals := {}
var _units := {}
var _chips := {}
var _thr_bar: ProgressBar
var _thr_txt: Label
var _status: Label
var _status_box: PanelContainer
var _hints: Control
var _fps: Label


func _ready() -> void:
	layer = 5
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = T.get_theme()
	add_child(_root)
	var overlay: Control = preload("res://scripts/hud_overlay.gd").new()
	overlay.aircraft = aircraft
	overlay.theme = T.get_theme()
	_root.add_child(overlay)
	_build_panel()
	_build_status()
	_build_hints()
	_fps = T.label("", 18, "Bold", T.DIM, 2)
	_fps.anchor_left = 1.0; _fps.anchor_right = 1.0
	_fps.offset_left = -160; _fps.offset_right = -24; _fps.offset_top = 18
	_fps.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_fps)
	Settings.changed.connect(_on_setting)
	_apply_settings()


func _on_setting(_k: String, _v) -> void:
	_apply_settings()


func _apply_settings() -> void:
	_panel.visible = bool(Settings.get_value("hud/telemetry"))
	_hints.visible = bool(Settings.get_value("hud/key_hints"))
	_fps.visible = bool(Settings.get_value("hud/fps"))


func _build_panel() -> void:
	_panel = T.glass(0.5)
	_panel.position = Vector2(22, 22)
	_panel.custom_minimum_size = Vector2(360, 0)
	_root.add_child(_panel)
	var m := MarginContainer.new()
	for s in ["left", "right"]:
		m.add_theme_constant_override("margin_" + s, 18)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 14)
	_panel.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	m.add_child(col)
	var head := HBoxContainer.new()
	head.add_child(T.label("FLIGHT DATA", 15, "Bold", T.ACCENT, 4))
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_vals["view"] = T.label("", 15, "Bold", T.DIM, 3)
	head.add_child(_vals["view"])
	col.add_child(head)
	var big := HBoxContainer.new()
	big.add_theme_constant_override("separation", 26)
	big.add_child(_readout("spd", "SPEED", 44))
	big.add_child(_readout("alt", "ALTITUDE", 44))
	col.add_child(big)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 22)
	grid.add_theme_constant_override("v_separation", 2)
	for k in [["mach", "MACH"], ["vs", "V/S"], ["agl", "RADAR ALT"], ["g", "G"], ["aoa", "AOA"], ["thrust", "THRUST"]]:
		grid.add_child(_readout(k[0], k[1], 24))
	col.add_child(grid)
	var thr := HBoxContainer.new()
	thr.add_theme_constant_override("separation", 10)
	thr.add_child(T.label("THR", 15, "Bold", T.DIM, 3))
	_thr_bar = ProgressBar.new()
	_thr_bar.show_percentage = false
	_thr_bar.custom_minimum_size = Vector2(0, 6)
	_thr_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thr_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thr.add_child(_thr_bar)
	_thr_txt = T.label("", 18, "Bold", T.TEXT)
	_thr_txt.custom_minimum_size = Vector2(64, 0)
	_thr_txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	thr.add_child(_thr_txt)
	col.add_child(thr)
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	for k in ["GEAR", "FLAPS", "A/BRK", "BRAKE", "A/THR", "LIGHTS", "RADAR"]:
		var c := T.label(k, 15, "Bold", T.DIM, 2)
		c.add_theme_stylebox_override("normal", T.flat(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.12), [1, 1, 1, 1], [8, 1, 8, 1]))
		chips.add_child(c)
		_chips[k] = c
	col.add_child(chips)


func _readout(key: String, title: String, size: int) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -6)
	v.add_child(T.label(title, 14, "Bold", T.DIM, 3))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 5)
	var val := T.label("0", size, "Bold", T.TEXT)
	row.add_child(val)
	var unit := T.label("", int(size * 0.42), "Bold", T.DIM, 1)
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(unit)
	v.add_child(row)
	_vals[key] = val
	_units[key] = unit
	return v


func _build_status() -> void:
	_status_box = PanelContainer.new()
	_status_box.anchor_left = 0.5; _status_box.anchor_right = 0.5
	_status_box.offset_left = -110; _status_box.offset_right = 110; _status_box.offset_top = 22
	_root.add_child(_status_box)
	_status = T.label("", 20, "Bold", T.TEXT, 4)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_box.add_child(_status)


func _build_hints() -> void:
	_hints = T.glass(0.45)
	_hints.anchor_top = 1.0; _hints.anchor_bottom = 1.0
	_hints.offset_left = 22; _hints.offset_top = -170; _hints.offset_bottom = -22
	_root.add_child(_hints)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 14)
	_hints.add_child(m)
	var g := GridContainer.new()
	g.columns = 4
	g.add_theme_constant_override("h_separation", 14)
	g.add_theme_constant_override("v_separation", 0)
	m.add_child(g)
	for b in [["W/S", "Pitch"], ["A/D", "Roll"], ["Q/E", "Yaw"], ["SHIFT/CTRL", "Throttle"], ["G", "Gear"], ["F", "Flaps"],
			["B", "Airbrake"], ["SPACE", "Brakes"], ["V", "View"], ["P", "Approach"], ["H", "Flight data"], ["ESC", "Menu"]]:
		g.add_child(T.label(b[0], 17, "Bold", T.ACCENT, 1))
		g.add_child(T.label(b[1], 17, "Medium", T.TEXT))


func _show(key: String, pair: Array) -> void:
	_vals[key].text = pair[0]
	_units[key].text = pair[1]


func _chip(k: String, on: bool, col: Color = T.ACCENT) -> void:
	var c: Label = _chips[k]
	c.add_theme_color_override("font_color", Color.BLACK if on else T.DIM)
	c.add_theme_stylebox_override("normal", T.flat(col if on else Color(1, 1, 1, 0.05), col if on else Color(1, 1, 1, 0.12), [1, 1, 1, 1], [8, 1, 8, 1]))


func _process(_delta: float) -> void:
	if aircraft == null:
		return
	var a = aircraft
	if _fps.visible:
		_fps.text = "%d FPS" % Engine.get_frames_per_second()
	# status pill
	var box := StyleBoxFlat.new()
	box.content_margin_top = 4; box.content_margin_bottom = 4
	box.border_width_bottom = 3
	if a.crashed:
		_status.text = "CRASHED"; box.bg_color = Color(0.45, 0.06, 0.05, 0.75); box.border_color = T.BAD
	elif a.wow:
		_status.text = "ON GROUND" if absf(a.nose_steer_deg) < 1.0 else "ON GROUND  %+.0f°" % a.nose_steer_deg
		box.bg_color = Color(0.04, 0.05, 0.06, 0.6); box.border_color = T.GOOD
	else:
		_status.text = "AIRBORNE"; box.bg_color = Color(0.04, 0.05, 0.06, 0.6); box.border_color = Color(0.4, 0.7, 1.0)
	_status_box.add_theme_stylebox_override("panel", box)
	if not _panel.visible:
		return
	var cam := get_viewport().get_camera_3d()
	_vals["view"].text = ("VIEW  " + String(cam.view_name)) if cam and "view_name" in cam else ""
	_show("spd", Settings.speed_text(a.speed))
	_show("alt", Settings.alt_text(a.global_position.y - 2.0))
	_show("mach", ["%.2f" % a.mach, ""])
	_show("vs", Settings.vs_text(a.vertical_speed))
	_show("agl", Settings.alt_text(a.altitude_agl))
	_show("g", ["%.1f" % a.g_load, ""])
	_show("aoa", ["%.1f" % a.aoa_deg, "°"])
	_show("thrust", ["%d" % int(a.thrust_now / 1000.0), "KN"])
	_vals["aoa"].add_theme_color_override("font_color", T.BAD if a.aoa_deg > 21.0 else T.TEXT)
	_vals["g"].add_theme_color_override("font_color", T.WARN if a.g_load > 7.0 else T.TEXT)
	_thr_bar.value = a.throttle * 100.0
	var ab: bool = a.engine > 0.85
	_thr_bar.add_theme_stylebox_override("fill", T.flat(Color(1.0, 0.35, 0.1) if ab else T.ACCENT))
	_thr_txt.text = "AB" if ab else "%d%%" % int(a.throttle * 100.0)
	_thr_txt.add_theme_color_override("font_color", Color(1.0, 0.45, 0.15) if ab else T.TEXT)
	_chip("GEAR", a.gear_down, T.GOOD)
	_chip("FLAPS", a.flaps)
	_chip("A/BRK", a.airbrake)
	_chip("BRAKE", a.wheel_brakes, T.WARN)
	_chip("A/THR", a.autothrottle)
	_chip("LIGHTS", a.fx != null and a.fx.lights_on)
	_chip("RADAR", a.radar_on)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_hud"):
		Settings.set_value("hud/telemetry", not bool(Settings.get_value("hud/telemetry")))
