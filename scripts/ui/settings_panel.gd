extends Control
## Settings screen used by both the main menu and the in-game pause menu. Changes apply instantly.

signal closed

const T = preload("res://scripts/ui/ui_theme.gd")
var _tabs: TabContainer
var _refreshers: Array[Callable] = []


func _ready() -> void:
	theme = T.get_theme()
	var glass := T.glass(0.70)
	glass.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(glass)
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 44)
	m.add_theme_constant_override("margin_top", 34)
	m.add_theme_constant_override("margin_bottom", 28)
	glass.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 14)
	m.add_child(col)

	var head := HBoxContainer.new()
	head.add_child(T.label("SETTINGS", 46, "Bold", T.TEXT, 3))
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(sp)
	var note := T.label("Changes apply instantly", 18, "Medium", T.DIM)
	note.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(note)
	col.add_child(head)

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_tabs)

	var p := _page("DISPLAY")
	_choice(p, "Window mode", "display/window_mode", ["Windowed", "Borderless fullscreen", "Exclusive fullscreen"], [0, 1, 2])
	_toggle(p, "Vertical sync", "display/vsync")
	_choice(p, "Frame rate limit", "display/max_fps", ["Unlimited", "30", "60", "120", "144", "240"], [0, 30, 60, 120, 144, 240])
	_slider(p, "Render scale", "display/render_scale", 0.5, 1.0, 0.05, func(v): return "%d%%" % int(round(v * 100.0)))
	_slider(p, "Field of view", "display/fov", 55.0, 95.0, 1.0, func(v): return "%d°" % int(v))

	p = _page("GRAPHICS")
	_choice(p, "Anti-aliasing", "graphics/msaa", ["Off", "MSAA 2x", "MSAA 4x"], [0, 1, 2])
	_toggle(p, "Shadows", "graphics/shadows")
	_toggle(p, "Forests", "graphics/trees")
	_choice(p, "Draw distance", "graphics/draw_distance", ["Near", "Medium", "Far"], [0, 1, 2])

	p = _page("HUD")
	_toggle(p, "Flight data panel  (H)", "hud/telemetry")
	_toggle(p, "Key hints", "hud/key_hints")
	_toggle(p, "FPS counter", "hud/fps")
	_choice(p, "Units", "hud/unit_system", ["Aviation  (kt, ft, ft/min)", "Metric  (km/h, m, m/s)"], [1, 0])

	p = _page("CONTROLS")
	_toggle(p, "Invert pitch", "controls/invert_pitch")
	_slider(p, "Mouse look sensitivity", "controls/mouse_sensitivity", 0.3, 2.0, 0.05, func(v): return "%.2fx" % v)
	var keys_head := T.label("KEY BINDINGS", 20, "Bold", T.DIM, 3)
	keys_head.add_theme_constant_override("line_spacing", 0)
	p.add_child(_gap(10))
	p.add_child(keys_head)
	var settings_node = get_node("/root/Settings")
	for b in settings_node.BINDINGS:
		var row := HBoxContainer.new()
		var a := T.label(b[0], 21, "Medium", T.TEXT)
		a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(a)
		row.add_child(T.label(b[1], 21, "Bold", T.ACCENT, 1))
		p.add_child(row)

	p = _page("AUDIO")
	_slider(p, "Master volume", "audio/master", 0.0, 1.0, 0.05, func(v): return "%d%%" % int(round(v * 100.0)))
	p.add_child(T.label("Engine and cockpit sound arrive in a later update.", 18, "Medium", T.DIM))

	var foot := HBoxContainer.new()
	var reset := Button.new(); reset.text = "RESET DEFAULTS"
	reset.add_theme_font_size_override("font_size", 24)
	reset.pressed.connect(_on_reset)
	foot.add_child(reset)
	var sp2 := Control.new(); sp2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp2)
	var back := Button.new(); back.text = "BACK"
	back.add_theme_font_override("font", T.spaced("Bold", 3))
	back.add_theme_font_size_override("font_size", 30)
	back.pressed.connect(func(): closed.emit())
	foot.add_child(back)
	col.add_child(foot)
	back.call_deferred("grab_focus")


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("pause_menu"):
		get_viewport().set_input_as_handled()
		closed.emit()


func _gap(h: int) -> Control:
	var c := Control.new(); c.custom_minimum_size = Vector2(0, h); return c


func _page(title: String) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.name = title
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(sc)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	sc.add_child(v)
	return v


func _row(page: VBoxContainer, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 46)
	var l := T.label(title, 24, "SemiBold", T.TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(l)
	page.add_child(row)
	return row


func _choice(page: VBoxContainer, title: String, key: String, labels: Array, values: Array) -> void:
	var row := _row(page, title)
	var ob := OptionButton.new()
	ob.custom_minimum_size = Vector2(320, 0)
	ob.add_theme_font_size_override("font_size", 22)
	for i in labels.size():
		ob.add_item(labels[i], i)
	var refresh := func():
		var idx: int = values.find(Settings.get_value(key))
		ob.select(maxi(idx, 0))
	refresh.call()
	_refreshers.append(refresh)
	ob.item_selected.connect(func(i): Settings.set_value(key, values[i]))
	row.add_child(ob)


func _toggle(page: VBoxContainer, title: String, key: String) -> void:
	var row := _row(page, title)
	var cb := CheckButton.new()
	var refresh := func(): cb.set_pressed_no_signal(bool(Settings.get_value(key)))
	refresh.call()
	_refreshers.append(refresh)
	cb.toggled.connect(func(on): Settings.set_value(key, on))
	row.add_child(cb)


func _slider(page: VBoxContainer, title: String, key: String, lo: float, hi: float, step: float, fmt: Callable) -> void:
	var row := _row(page, title)
	var s := HSlider.new()
	s.min_value = lo; s.max_value = hi; s.step = step
	s.custom_minimum_size = Vector2(240, 0)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := T.label("", 22, "Bold", T.ACCENT)
	val.custom_minimum_size = Vector2(78, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var refresh := func():
		s.set_value_no_signal(float(Settings.get_value(key)))
		val.text = fmt.call(s.value)
	refresh.call()
	_refreshers.append(refresh)
	s.value_changed.connect(func(v):
		val.text = fmt.call(v)
		Settings.set_value(key, v))
	row.add_child(s)
	row.add_child(val)


func _on_reset() -> void:
	Settings.reset_defaults()
	for r in _refreshers:
		r.call()
