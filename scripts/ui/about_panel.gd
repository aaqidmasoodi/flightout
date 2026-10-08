extends Control
## About screen.

signal closed
const T = preload("res://scripts/ui/ui_theme.gd")


func _ready() -> void:
	theme = T.get_theme()
	var glass := T.glass(0.70)
	glass.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(glass)
	var m := MarginContainer.new()
	for side in ["left", "right"]:
		m.add_theme_constant_override("margin_" + side, 48)
	m.add_theme_constant_override("margin_top", 40)
	m.add_theme_constant_override("margin_bottom", 30)
	glass.add_child(m)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	m.add_child(col)
	col.add_child(T.logo(0.8))
	col.add_child(T.label("Yembera FlightOut  ·  version %s" % Game.VERSION, 22, "Medium", T.DIM))
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.fit_content = true
	body.scroll_active = false
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_font_override("normal_font", T.font("Medium"))
	body.add_theme_font_override("bold_font", T.font("Bold"))
	body.add_theme_font_size_override("normal_font_size", 23)
	body.add_theme_font_size_override("bold_font_size", 23)
	body.add_theme_color_override("default_color", T.TEXT)
	body.text = "[b]FlightOut[/b] is a combat flight game with a physics-based flight model: real lift, drag and thrust, a fly-by-wire Su-27 with working gear, flaps and lights, and a 41 km island to fly over.\n\nToday it is a single-player sandbox. It is being built as the foundation for team-based multiplayer air combat.\n\n[color=#8f98a1]Developed by[/color] [b]Yembera[/b]\n[color=#8f98a1]Technology from Kashmir, built for the world  ·  yembera.com[/color]\n\n[color=#8f98a1]Engine: Godot 4.7  ·  Typeface: Rajdhani (Indian Type Foundry, SIL Open Font License)[/color]\n[color=#8f98a1]© 2026 Yembera. All rights reserved.[/color]"
	col.add_child(body)
	var foot := HBoxContainer.new()
	var ym := T.svg(T.YEMBERA, 34)
	ym.modulate = T.DIM
	foot.add_child(ym)
	var sp := Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(sp)
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
