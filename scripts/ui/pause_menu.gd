extends CanvasLayer
## In-flight menu (Esc). Offline it freezes the simulation behind blurred glass. Online the world cannot pause:
## the jet keeps flying with hands off the stick while the menu is open.

const T = preload("res://scripts/ui/ui_theme.gd")
const SettingsPanel = preload("res://scripts/ui/settings_panel.gd")

var _root: Control
var _buttons: VBoxContainer
var _sub: Control
var _prev_mouse := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.get_theme()
	_root.visible = false
	add_child(_root)
	var shade := T.glass(0.35, false)
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(shade)
	var panel := T.glass(0.55)
	panel.anchor_bottom = 1.0
	panel.offset_right = 520.0
	_root.add_child(panel)
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 56)
	m.add_theme_constant_override("margin_right", 40)
	m.add_theme_constant_override("margin_top", 60)
	m.add_theme_constant_override("margin_bottom", 44)
	panel.add_child(m)
	var col := VBoxContainer.new()
	m.add_child(col)
	col.add_child(T.logo(0.75))
	col.add_child(T.label("ONLINE  ·  " + Game.client.server_name.to_upper() if Game.online else "PAUSED", 22, "Bold", T.ACCENT, 6))
	var sp := Control.new(); sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp)
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 4)
	col.add_child(_buttons)
	_button("RESUME", resume)
	_button("SETTINGS", _open_settings)
	if Game.online:
		_button("RESPAWN IN SHELTER", func(): _aircraft_call("reset"))
		_button("LEAVE SERVER", func(): Game.goto_menu())
	else:
		_button("RESTART AT RUNWAY", func(): _aircraft_call("reset"))
		_button("PRACTICE APPROACH", func(): _aircraft_call("practice_approach"))
		_button("MAIN MENU", func(): Game.goto_menu())
	_button("QUIT TO DESKTOP", func(): Game.quit())
	var sp2 := Control.new(); sp2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(sp2)
	col.add_child(T.label("ESC  to resume", 18, "Bold", Color(1, 1, 1, 0.4), 3))


func _button(text: String, cb: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", T.spaced("Bold", 3))
	b.add_theme_font_size_override("font_size", 36)
	b.custom_minimum_size = Vector2(0, 60)
	b.pressed.connect(cb)
	b.mouse_entered.connect(func(): b.grab_focus())
	_buttons.add_child(b)


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("pause_menu"):
		return
	get_viewport().set_input_as_handled()
	if _sub:
		_close_settings()
	elif _root.visible:
		resume()
	else:
		open()


func open() -> void:
	_prev_mouse = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if Game.online:
		_set_blocked(true)
	else:
		get_tree().paused = true
	_root.visible = true
	_root.modulate.a = 0.0
	create_tween().tween_property(_root, "modulate:a", 1.0, 0.18)
	(_buttons.get_child(0) as Button).grab_focus()


func resume() -> void:
	_close_settings()
	_root.visible = false
	get_tree().paused = false
	_set_blocked(false)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _set_blocked(on: bool) -> void:
	var ac := get_tree().get_first_node_in_group("player_aircraft")
	if ac:
		ac.input_blocked = on


func _aircraft_call(method: String) -> void:
	var ac := get_tree().get_first_node_in_group("player_aircraft")
	resume()
	if ac:
		ac.call(method)


func _open_settings() -> void:
	_close_settings()
	var p := SettingsPanel.new()
	p.anchor_right = 1.0; p.anchor_bottom = 1.0
	p.offset_left = 560.0; p.offset_right = -60.0; p.offset_top = 60.0; p.offset_bottom = -60.0
	_root.add_child(p)
	p.closed.connect(_close_settings)
	_sub = p
	for b in _buttons.get_children():
		(b as Button).focus_mode = Control.FOCUS_NONE


func _close_settings() -> void:
	if _sub:
		_sub.queue_free()
		_sub = null
		for b in _buttons.get_children():
			(b as Button).focus_mode = Control.FOCUS_ALL
		if _root.visible:
			(_buttons.get_child(1) as Button).grab_focus()
