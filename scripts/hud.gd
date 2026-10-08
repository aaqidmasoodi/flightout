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
var _chip_state := {}
var _thr_bar: ProgressBar
var _thr_txt: Label
var _status: Label
var _status_box: PanelContainer
var _hints: Control
var _hint_grid: GridContainer
var _fps: Label
var _net: Label


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
	_net = T.label("", 15, "Bold", T.DIM, 1)
	_net.anchor_left = 1.0; _net.anchor_right = 1.0
	_net.offset_left = -700; _net.offset_right = -24; _net.offset_top = 44
	_net.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_root.add_child(_net)
	Settings.changed.connect(_on_setting)
	_apply_settings()


func _on_setting(k: String, _v) -> void:
	if k == "bindings":
		_refresh_keys()
	_apply_settings()


func _apply_settings() -> void:
	_panel.visible = bool(Settings.get_value("hud/telemetry"))
	_hints.visible = bool(Settings.get_value("hud/key_hints"))
	_fps.visible = bool(Settings.get_value("hud/fps"))
	_net.visible = bool(Settings.get_value("hud/net_stats"))


func _build_panel() -> void:
	_panel = T.glass(0.5)
	_panel.position = Vector2(22, 22)
	_root.add_child(_panel)
	var m := MarginContainer.new()
	for s in ["left", "right"]:
		m.add_theme_constant_override("margin_" + s, 18)
	m.add_theme_constant_override("margin_top", 12)
	m.add_theme_constant_override("margin_bottom", 14)
	_panel.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.custom_minimum_size = Vector2(PANEL_W, 0)
	m.add_child(col)
	var head := HBoxContainer.new()
	head.add_child(T.label("FLIGHT DATA", 15, "Bold", T.ACCENT, 4))
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	_vals["view"] = T.label("", 15, "Bold", T.DIM, 3)
	_vals["view"].horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_vals["view"].custom_minimum_size = Vector2(150, 0)
	head.add_child(_vals["view"])
	col.add_child(head)
	var big := HBoxContainer.new()
	big.add_theme_constant_override("separation", 18)
	big.add_child(_readout("spd", "IAS", 44, 4, 4))
	big.add_child(_readout("alt", "ALTITUDE", 44, 5, 2))
	col.add_child(big)
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 16)
	grid.add_theme_constant_override("v_separation", 2)
	for k in [["tas", "TAS", 4, 4], ["gs", "GROUND SPD", 4, 4], ["mach", "MACH", 4, 0],
			["vs", "V/S", 6, 6], ["agl", "RADAR ALT", 5, 2], ["hdg", "HEADING", 3, 1],
			["g", "G", 4, 0], ["aoa", "AOA", 5, 3], ["thrust", "THRUST", 3, 2],
			["fuel", "FUEL", 5, 2], ["rpm", "RPM", 3, 1], ["wind", "WIND", 6, 2]]:
		grid.add_child(_readout(k[0], k[1], 24, k[2], k[3]))
	col.add_child(grid)
	var thr := HBoxContainer.new()
	thr.add_theme_constant_override("separation", 10)
	var tl := T.label("THR", 15, "Bold", T.DIM, 3)
	tl.custom_minimum_size = Vector2(40, 0)
	thr.add_child(tl)
	_thr_bar = ProgressBar.new()
	_thr_bar.show_percentage = false
	_thr_bar.custom_minimum_size = Vector2(0, 6)
	_thr_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_thr_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	thr.add_child(_thr_bar)
	_thr_txt = T.label("", 18, "Bold", T.TEXT)
	_thr_txt.add_theme_font_override("font", T.tabular("Bold"))
	_thr_txt.custom_minimum_size = Vector2(58, 0)
	_thr_txt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	thr.add_child(_thr_txt)
	col.add_child(thr)
	var chips := GridContainer.new()
	chips.columns = 3
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	for k in CHIP_ACTIONS:
		chips.add_child(_chip_node(k[0], Settings.key_label(k[1])))
	col.add_child(chips)


const PANEL_W := 392.0
const CHIP_ACTIONS := [["GEAR", "toggle_gear"], ["FLAPS", "toggle_flaps"], ["A/BRK", "toggle_airbrake"], ["BRAKE", "wheel_brake"],
	["A/THR", "toggle_autothrottle"], ["LIGHTS", "toggle_lights"], ["RADAR", "toggle_radar"], ["CANOPY", "toggle_canopy"],
	["VIEW", "toggle_view"], ["NO LIMIT", "toggle_limiter"]]
const HINT_ACTIONS := [[["pitch_down", "pitch_up"], "Pitch"], [["roll_left", "roll_right"], "Roll"], [["yaw_left", "yaw_right"], "Yaw"],
	[["throttle_up", "throttle_down"], "Throttle"], [["toggle_gear"], "Gear"], [["toggle_flaps"], "Flaps"], [["toggle_airbrake"], "Airbrake"],
	[["wheel_brake"], "Brakes"], [["toggle_view"], "View"], [["practice_approach"], "Approach"], [["toggle_hud"], "Flight data"]]


## A readout with fixed-width slots: value (right-aligned, tabular digits) and unit.
## `chars` and `unit_chars` reserve room for the widest value, so updates never move anything.
func _readout(key: String, title: String, size: int, chars: int, unit_chars: int) -> Control:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", -6)
	v.add_child(T.label(title, 14, "Bold", T.DIM, 3))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var val := T.label("0", size, "Bold", T.TEXT)
	val.add_theme_font_override("font", T.tabular("Bold"))
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.custom_minimum_size = Vector2(ceilf(chars * size * 0.53), 0)
	val.clip_text = true
	row.add_child(val)
	var usize := int(size * 0.42)
	var unit := T.label("", usize, "Bold", T.DIM, 1)
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	unit.custom_minimum_size = Vector2(ceilf(unit_chars * usize * 0.72), 0)
	row.add_child(unit)
	v.add_child(row)
	_vals[key] = val
	_units[key] = unit
	return v


## System chip: name plus its hotkey in a small key cap, e.g. GEAR [G].
func _chip_node(title: String, key: String) -> Control:
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(122, 30)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	box.add_child(row)
	var n := T.label(title, 15, "Bold", T.DIM, 2)
	n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	n.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(n)
	# key cap: small white rounded box, bold black letter (same in every chip state for clear contrast)
	var cap := T.label(key, 12, "Bold", Color(0.03, 0.03, 0.04), 0)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cap.custom_minimum_size = Vector2(16, 16)
	var cs := StyleBoxFlat.new()
	cs.bg_color = Color(0.96, 0.97, 0.98)
	cs.set_corner_radius_all(3)
	cs.content_margin_left = 4; cs.content_margin_right = 4
	cs.content_margin_top = -1; cs.content_margin_bottom = -1
	cap.add_theme_stylebox_override("normal", cs)
	row.add_child(cap)
	_chips[title] = [box, n, cap]
	_style_chip(title, false, T.ACCENT)
	return box


func _style_chip(k: String, on: bool, col: Color) -> void:
	var c: Array = _chips[k]
	(c[0] as PanelContainer).add_theme_stylebox_override("panel", T.flat(col if on else Color(1, 1, 1, 0.05), col if on else Color(1, 1, 1, 0.12), [1, 1, 1, 1], [8, 2, 6, 2]))
	(c[1] as Label).add_theme_color_override("font_color", Color(0.04, 0.04, 0.05) if on else T.DIM)
	(c[2] as Label).modulate = Color(1, 1, 1, 1.0 if on else 0.82)


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
	_hint_grid = GridContainer.new()
	_hint_grid.columns = 4
	_hint_grid.add_theme_constant_override("h_separation", 14)
	_hint_grid.add_theme_constant_override("v_separation", 0)
	m.add_child(_hint_grid)
	_fill_hints()


func _fill_hints() -> void:
	for c in _hint_grid.get_children():
		c.queue_free()
	for b in HINT_ACTIONS:
		var keys := []
		for act in b[0]:
			keys.append(Settings.key_label(act))
		_hint_grid.add_child(T.label("/".join(keys), 17, "Bold", T.ACCENT, 1))
		_hint_grid.add_child(T.label(b[1], 17, "Medium", T.TEXT))
	_hint_grid.add_child(T.label("ESC", 17, "Bold", T.ACCENT, 1))
	_hint_grid.add_child(T.label("Menu", 17, "Medium", T.TEXT))


func _refresh_keys() -> void:
	for k in CHIP_ACTIONS:
		(_chips[k[0]][2] as Label).text = Settings.key_label(k[1])
	_fill_hints()


func _show(key: String, pair: Array) -> void:
	_vals[key].text = pair[0]
	_units[key].text = pair[1]


func _chip(k: String, on: bool, col: Color = T.ACCENT) -> void:
	if _chip_state.get(k) == on:
		return
	_chip_state[k] = on
	_style_chip(k, on, col)


func _process(_delta: float) -> void:
	if aircraft == null:
		return
	var a = aircraft
	if _fps.visible:
		_fps.text = "%d FPS" % Engine.get_frames_per_second()
	if _net.visible:
		_net.text = Game.client.stats_text() if Game.online else ""
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
	_show("spd", Settings.speed_text(a.ias))
	_show("tas", Settings.speed_text(a.speed))
	_show("gs", Settings.speed_text(a.ground_speed))
	var aviation := int(Settings.get_value("hud/unit_system")) == 1
	_show("fuel", ["%d" % int(a.fuel_kg * (2.20462 if aviation else 1.0)), "LB" if aviation else "KG"])
	_show("rpm", ["%d" % int(a.rpm), "%"])
	var w: Vector3 = a.wind
	var wspd := Vector2(w.x, w.z).length()
	if wspd < 0.5:
		_show("wind", ["CALM", ""])
	else:
		var from := fposmod(rad_to_deg(atan2(-w.x, w.z)), 360.0)
		_show("wind", ["%03d/%d" % [int(round(from / 10.0)) * 10 % 360, int(wspd * (1.94384 if aviation else 3.6))], "KT" if aviation else "KMH"])
	_vals["fuel"].add_theme_color_override("font_color", T.BAD if a.fuel_kg < 800.0 else T.TEXT)
	_show("hdg", ["%03d" % (int(round(a.heading_deg)) % 360), "°"])
	_show("alt", Settings.alt_text(a.global_position.y - 2.0))
	_show("mach", ["%.2f" % a.mach, ""])
	_show("vs", Settings.vs_text(a.vertical_speed))
	_show("agl", Settings.alt_text(a.altitude_agl))
	_show("g", ["%.1f" % a.g_load, ""])
	_show("aoa", ["%.1f" % a.aoa_deg, "DEG"])
	_show("thrust", ["%d" % int(a.thrust_now / 1000.0), "KN"])
	_vals["aoa"].add_theme_color_override("font_color", T.BAD if a.stall_frac > 0.5 else (T.WARN if a.stall_frac > 0.0 else T.TEXT))
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
	_chip("CANOPY", a.canopy_open, T.WARN)
	_chip("NO LIMIT", not a.aoa_limiter, T.BAD)
	_chip("VIEW", cam != null and "view_name" in cam and String(cam.view_name) != "CLOSE", Color(0.4, 0.7, 1.0))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_hud"):
		Settings.set_value("hud/telemetry", not bool(Settings.get_value("hud/telemetry")))
