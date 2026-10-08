extends Node
## Main menu. Starts fast: only the jet backdrop and UI load here. Play streams the world in on a loading screen.

const T = preload("res://scripts/ui/ui_theme.gd")
const Backdrop = preload("res://scripts/ui/menu_backdrop.gd")
const SettingsPanel = preload("res://scripts/ui/settings_panel.gd")
const AboutPanel = preload("res://scripts/ui/about_panel.gd")
const PRELOAD := ["res://assets/su27.glb", "res://assets/world/world.glb", "res://scenes/main.tscn"]

var _ui: Control
var _left: Control
var _buttons: VBoxContainer
var _sub: Control
var _loading: Control
var _bar: ProgressBar
var _status: Label
var _loading_active := false
var _switching := false


func _ready() -> void:
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	add_child(Backdrop.new())
	var layer := CanvasLayer.new()
	add_child(layer)
	_ui = Control.new()
	_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.theme = T.get_theme()
	layer.add_child(_ui)
	_build_left_panel()
	_build_corner_info()
	_ui.modulate.a = 0.0
	create_tween().tween_property(_ui, "modulate:a", 1.0, 1.0).set_trans(Tween.TRANS_SINE)


func _build_left_panel() -> void:
	var panel := T.glass(0.55)
	panel.anchor_left = 0.0; panel.anchor_right = 0.0; panel.anchor_top = 0.0; panel.anchor_bottom = 1.0
	panel.offset_right = 580.0
	_ui.add_child(panel)
	_left = panel
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 60)
	m.add_theme_constant_override("margin_right", 44)
	m.add_theme_constant_override("margin_top", 64)
	m.add_theme_constant_override("margin_bottom", 44)
	panel.add_child(m)
	var col := VBoxContainer.new()
	m.add_child(col)
	col.add_child(T.logo(1.0))
	var tag := T.label("COMBAT FLIGHT  ·  SU-27S FLANKER", 18, "Bold", T.DIM, 4)
	col.add_child(tag)
	col.add_child(_spacer())
	_buttons = VBoxContainer.new()
	_buttons.add_theme_constant_override("separation", 6)
	col.add_child(_buttons)
	_menu_button("PLAY", _on_play)
	_menu_button("SETTINGS", _on_settings)
	_menu_button("ABOUT", _on_about)
	_menu_button("QUIT", func(): Game.quit())
	col.add_child(_spacer())
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 12)
	var ym := T.svg(T.YEMBERA, 30)
	ym.modulate = Color(1, 1, 1, 0.55)
	foot.add_child(ym)
	var fv := VBoxContainer.new()
	fv.add_theme_constant_override("separation", -4)
	fv.add_child(T.label("A YEMBERA GAME", 16, "Bold", Color(1, 1, 1, 0.55), 4))
	fv.add_child(T.label("Technology from Kashmir, built for the world", 15, "Medium", Color(1, 1, 1, 0.38)))
	foot.add_child(fv)
	col.add_child(foot)
	(_buttons.get_child(0) as Button).call_deferred("grab_focus")


func _build_corner_info() -> void:
	var v := T.label("v%s" % Game.VERSION, 16, "Bold", Color(1, 1, 1, 0.45), 2)
	v.anchor_left = 1.0; v.anchor_right = 1.0; v.anchor_top = 1.0; v.anchor_bottom = 1.0
	v.offset_left = -220; v.offset_right = -28; v.offset_top = -44; v.offset_bottom = -18
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_ui.add_child(v)


func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


func _menu_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_font_override("font", T.spaced("Bold", 4))
	b.add_theme_font_size_override("font_size", 46)
	b.custom_minimum_size = Vector2(0, 72)
	b.pressed.connect(cb)
	b.mouse_entered.connect(func(): b.grab_focus())
	_buttons.add_child(b)
	return b


# ---------------- sub screens ----------------
func _open_sub(panel: Control) -> void:
	_close_sub()
	_sub = panel
	panel.anchor_left = 0.0; panel.anchor_right = 1.0; panel.anchor_top = 0.0; panel.anchor_bottom = 1.0
	panel.offset_left = 620.0; panel.offset_right = -60.0; panel.offset_top = 60.0; panel.offset_bottom = -60.0
	_ui.add_child(panel)
	panel.closed.connect(_close_sub)
	panel.modulate.a = 0.0
	create_tween().tween_property(panel, "modulate:a", 1.0, 0.25)
	for b in _buttons.get_children():
		(b as Button).focus_mode = Control.FOCUS_NONE


func _close_sub() -> void:
	if _sub:
		_sub.queue_free()
		_sub = null
		for b in _buttons.get_children():
			(b as Button).focus_mode = Control.FOCUS_ALL
		(_buttons.get_child(0) as Button).grab_focus()


func _on_settings() -> void:
	_open_sub(SettingsPanel.new())


func _on_about() -> void:
	_open_sub(AboutPanel.new())


# ---------------- loading ----------------
func _on_play() -> void:
	if _loading_active:
		return
	_loading_active = true
	_close_sub()
	for p in PRELOAD:
		ResourceLoader.load_threaded_request(p, "", true)
	_loading = T.glass(0.80, false)
	_loading.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui.add_child(_loading)
	var center := CenterContainer.new()
	_loading.add_child(center)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 22)
	col.custom_minimum_size = Vector2(620, 0)
	center.add_child(col)
	col.add_child(T.logo(1.0))
	_status = T.label("LOADING THE ISLAND", 22, "Bold", T.DIM, 4)
	col.add_child(_status)
	_bar = ProgressBar.new()
	_bar.custom_minimum_size = Vector2(0, 6)
	_bar.show_percentage = false
	col.add_child(_bar)
	col.add_child(T.label("Tip: press P in flight for a practice approach, and Esc for this menu.", 19, "Medium", Color(1, 1, 1, 0.4)))
	_loading.modulate.a = 0.0
	create_tween().tween_property(_loading, "modulate:a", 1.0, 0.35)


func _process(_delta: float) -> void:
	if not _loading_active or _switching:
		return
	var total := 0.0
	var done := true
	for p in PRELOAD:
		var prog := []
		var st := ResourceLoader.load_threaded_get_status(p, prog)
		if st == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			done = false
			total += float(prog[0]) if prog.size() > 0 else 0.0
		else:
			total += 1.0
	_bar.value = lerpf(_bar.value, total / PRELOAD.size() * 100.0, 0.25)
	if done:
		_switching = true
		_status.text = "PREPARING FOR TAKEOFF"
		_bar.value = 100.0
		for p in PRELOAD:
			var r := ResourceLoader.load_threaded_get(p)
			if r:
				Game.keep(p, r)
		await get_tree().process_frame
		await get_tree().process_frame
		get_tree().change_scene_to_packed(Game._cache["res://scenes/main.tscn"])
