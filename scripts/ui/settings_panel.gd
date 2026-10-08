extends Control
## Settings screen used by both the main menu and the in-game pause menu. Changes apply instantly.

signal closed

const T = preload("res://scripts/ui/ui_theme.gd")
var _tabs: TabContainer
var _refreshers: Array[Callable] = []
var _key_buttons: Array = []       # [button, action, slot]
var _capture = null                # [button, action, slot] while waiting for a key
var _toast_layer: CanvasLayer
var _toast: PanelContainer
var _toast_text: Label
var _toast_bar: ColorRect
var _toast_tween: Tween


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
	for entry in Settings.BINDABLE:
		if entry.size() == 1:
			p.add_child(_gap(8))
			p.add_child(T.label(entry[0], 18, "Bold", T.DIM, 3))
			continue
		var row := _row(p, entry[1])
		row.custom_minimum_size.y = 42
		for slot in 2:
			row.add_child(_key_button(entry[0], slot))
	p.add_child(_gap(8))
	p.add_child(T.label("FIXED", 18, "Bold", T.DIM, 3))
	for f in Settings.FIXED_BINDINGS:
		var row := _row(p, f[0])
		row.custom_minimum_size.y = 40
		var l := T.label(f[1], 18, "Bold", T.DIM, 1)
		l.custom_minimum_size = Vector2(246, 0)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(l)
	Settings.changed.connect(func(k, _v):
		if k == "bindings":
			_refresh_keys())

	p = _page("WEATHER")
	_choice(p, "Wind", "weather/wind", ["Calm", "Light  (10 kt)", "Moderate  (20 kt)", "Strong  (30 kt)"], [0, 1, 2, 3])
	_choice(p, "Wind from", "weather/wind_from", ["North", "North-east", "East", "South-east", "South", "South-west", "West", "North-west"], [0.0, 45.0, 90.0, 135.0, 180.0, 225.0, 270.0, 315.0])
	_choice(p, "Turbulence", "weather/turbulence", ["Off", "Light", "Moderate", "Severe"], [0, 1, 2, 3])
	p.add_child(T.label("Runway 36 points north: a north wind is a headwind, east or west is a crosswind.", 18, "Medium", T.DIM))

	p = _page("AUDIO")
	var pct := func(v): return "%d%%" % int(round(v * 100.0))
	_slider(p, "Master volume", "audio/master", 0.0, 1.0, 0.05, pct)
	_slider(p, "Engines", "audio/engine", 0.0, 1.0, 0.05, pct)
	_slider(p, "Effects  (wind, gear, impacts)", "audio/effects", 0.0, 1.0, 0.05, pct)
	_slider(p, "Warnings", "audio/warnings", 0.0, 1.0, 0.05, pct)
	_slider(p, "Interface", "audio/ui", 0.0, 1.0, 0.05, pct)

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


func _input(event: InputEvent) -> void:
	if _capture == null or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	get_viewport().set_input_as_handled()
	var ek := event as InputEventKey
	var code := ek.physical_keycode if ek.physical_keycode != KEY_NONE else ek.keycode
	var cap: Array = _capture
	_capture = null
	if code == KEY_ESCAPE:
		_show_toast("Cancelled", T.DIM)
	elif code == KEY_DELETE:
		Settings.clear_key(cap[1], cap[2])
		_show_toast("Cleared  ·  %s" % Settings.action_label(cap[1]), T.DIM)
	else:
		var from := Settings.bind_key(cap[1], cap[2], code)
		_show_toast("%s  →  %s" % [Settings.key_name(code), Settings.action_label(cap[1])] + ("    ·  moved from %s" % from if from != "" else ""), T.WARN if from != "" else T.GOOD)
	_refresh_keys()


func _key_button(action: String, slot: int) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(120, 34)
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.add_theme_font_override("font", T.spaced("Bold", 1))
	b.add_theme_font_size_override("font_size", 18)
	b.add_theme_stylebox_override("normal", T.flat(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.16), [1, 1, 1, 2], [10, 2, 10, 2]))
	b.add_theme_stylebox_override("hover", T.flat(Color(1, 1, 1, 0.09), T.ACCENT, [1, 1, 1, 2], [10, 2, 10, 2]))
	b.add_theme_stylebox_override("focus", T.flat(Color(1, 1, 1, 0.09), T.ACCENT, [1, 1, 1, 2], [10, 2, 10, 2]))
	b.add_theme_stylebox_override("pressed", T.flat(Color(1.0, 0.6, 0.18, 0.2), T.ACCENT, [1, 1, 1, 2], [10, 2, 10, 2]))
	b.pressed.connect(func():
		_refresh_keys()
		_capture = [b, action, slot]
		b.text = "PRESS A KEY"
		b.add_theme_color_override("font_color", T.ACCENT)
		_show_toast("Press a key for %s    ·  Esc cancels  ·  Delete clears" % Settings.action_label(action), T.ACCENT, true))
	_key_buttons.append([b, action, slot])
	_set_key_text(b, action, slot)
	return b


func _set_key_text(b: Button, action: String, slot: int) -> void:
	var arr: Array = Settings.bindings.get(action, [])
	var code: int = int(arr[slot]) if slot < arr.size() else 0
	b.text = Settings.key_name(code) if code != 0 else "--"
	b.add_theme_color_override("font_color", T.TEXT if code != 0 else T.DIM)


func _refresh_keys() -> void:
	for e in _key_buttons:
		if is_instance_valid(e[0]):
			_set_key_text(e[0], e[1], e[2])


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
	var gutter := MarginContainer.new()
	gutter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gutter.add_theme_constant_override("margin_right", 34)
	gutter.add_theme_constant_override("margin_bottom", 8)
	sc.add_child(gutter)
	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.add_theme_constant_override("separation", 12)
	gutter.add_child(v)
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
	_refresh_keys()


# ---------------- toast: status messages at the bottom-right of the screen ----------------
const TOAST_IN := -60.0       # resting offset from the right edge (lines up with the settings panel)
const TOAST_OUT := 60.0       # off-screen to the right
var _toast_visible := false


func _ensure_toast() -> void:
	if _toast:
		return
	_toast_layer = CanvasLayer.new()
	_toast_layer.layer = 40
	add_child(_toast_layer)
	_toast = T.glass(0.78)
	_toast.theme = T.get_theme()
	_toast.anchor_left = 1.0
	_toast.anchor_right = 1.0
	_toast.anchor_top = 1.0
	_toast.anchor_bottom = 1.0
	_toast.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_toast.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_toast.offset_right = TOAST_OUT
	_toast.offset_left = TOAST_OUT
	_toast.offset_bottom = -9.0      # in the gap below the settings panel (which ends 60 px above the edge)
	_toast.offset_top = -9.0
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_layer.add_child(_toast)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.add_child(row)
	_toast_bar = ColorRect.new()
	_toast_bar.custom_minimum_size = Vector2(4, 0)
	row.add_child(_toast_bar)
	_toast_text = T.label("", 18, "SemiBold", T.TEXT)
	_toast_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_right", 20)
	m.add_theme_constant_override("margin_top", 7)
	m.add_theme_constant_override("margin_bottom", 7)
	m.add_child(_toast_text)
	row.add_child(m)
	_toast.modulate.a = 0.0


func _show_toast(text: String, col: Color, persistent: bool = false) -> void:
	_ensure_toast()
	_toast_text.text = text
	_toast.offset_left = _toast.offset_right    # let the minimum size decide the width (grows to the left)
	_toast.offset_top = _toast.offset_bottom
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	if _toast_visible:
		# already on screen: update in place, with a quick pulse of the colour bar
		_toast_bar.color = Color(1, 1, 1)
		_toast_tween.tween_property(_toast_bar, "color", col, 0.25)
		_toast_tween.parallel().tween_property(_toast, "modulate:a", 1.0, 0.1)
		_toast_tween.parallel().tween_property(_toast, "offset_right", TOAST_IN, 0.2)
	else:
		# entry: slide in from the right with a slight overshoot, fading in
		_toast_bar.color = col
		_toast.offset_right = TOAST_OUT
		_toast_tween.tween_property(_toast, "offset_right", TOAST_IN, 0.42).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		_toast_tween.parallel().tween_property(_toast, "modulate:a", 1.0, 0.25)
	_toast_visible = true
	_yield_corner(true)
	if not persistent:
		_toast_tween.tween_interval(2.6)
		_toast_tween.tween_callback(func():
			_toast_visible = false
			_yield_corner(false))
		# exit: slide back out to the right, fading away
		_toast_tween.tween_property(_toast, "offset_right", TOAST_OUT, 0.32).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_toast_tween.parallel().tween_property(_toast, "modulate:a", 0.0, 0.28)


## Other corner elements (the version label) step aside while a toast is showing.
func _yield_corner(hide: bool) -> void:
	for n in get_tree().get_nodes_in_group("toast_yield"):
		create_tween().tween_property(n, "modulate:a", 0.0 if hide else 1.0, 0.25)


func _exit_tree() -> void:
	if is_inside_tree():
		_yield_corner(false)
