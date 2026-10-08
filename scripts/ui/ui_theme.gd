extends RefCounted
## FlightOut UI theme: dark frosted glass, afterburner-orange accent, Rajdhani type.

const ACCENT := Color("ff9a2e")
const TEXT := Color("eef1f4")
const DIM := Color("8f98a1")
const FAINT := Color(1, 1, 1, 0.08)
const GOOD := Color("57e389")
const WARN := Color("ffb347")
const BAD := Color("ff5a4f")
const BLUR_SHADER := preload("res://shaders/ui_blur.gdshader")
const EMBLEM := "res://assets/ui/flightout_emblem.svg"
const YEMBERA := "res://assets/ui/yembera_mark.svg"

static var _theme: Theme
static var _fonts := {}


static func font(weight: String = "SemiBold") -> Font:
	if not _fonts.has(weight):
		_fonts[weight] = load("res://assets/fonts/Rajdhani-%s.ttf" % weight)
	return _fonts[weight]


static func spaced(weight: String, spacing: int) -> Font:
	var fv := FontVariation.new()
	fv.base_font = font(weight)
	fv.spacing_glyph = spacing
	return fv


## Same font with tabular figures: every digit has the same width, so changing numbers never shift layout.
static func tabular(weight: String = "Bold") -> Font:
	var key := "tab_" + weight
	if not _fonts.has(key):
		var fv := FontVariation.new()
		fv.base_font = font(weight)
		var ts := TextServerManager.get_primary_interface()
		fv.opentype_features = {ts.name_to_tag("tnum"): 1}
		_fonts[key] = fv
	return _fonts[key]


static func label(text: String, size: int, weight: String = "SemiBold", color: Color = TEXT, spacing: int = 0) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", spaced(weight, spacing) if spacing != 0 else font(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func flat(bg: Color, border: Color = Color(0, 0, 0, 0), widths: Array = [0, 0, 0, 0], margins: Array = [0, 0, 0, 0]) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.border_width_left = widths[0]
	s.border_width_top = widths[1]
	s.border_width_right = widths[2]
	s.border_width_bottom = widths[3]
	s.content_margin_left = margins[0]
	s.content_margin_top = margins[1]
	s.content_margin_right = margins[2]
	s.content_margin_bottom = margins[3]
	return s


static func _dot_texture(size: int, col: Color) -> ImageTexture:
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size, size) / 2.0
	for x in size:
		for y in size:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			img.set_pixel(x, y, Color(col.r, col.g, col.b, clampf(size / 2.0 - d, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


static func get_theme() -> Theme:
	if _theme:
		return _theme
	var t := Theme.new()
	t.default_font = font("SemiBold")
	t.default_font_size = 22
	# buttons: text only, accent bar on hover/focus
	var bn := flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), [4, 0, 0, 0], [22, 6, 22, 6])
	var bh := flat(Color(1, 1, 1, 0.06), ACCENT, [4, 0, 0, 0], [30, 6, 22, 6])
	var bp := flat(Color(1.0, 0.6, 0.18, 0.16), ACCENT, [4, 0, 0, 0], [30, 6, 22, 6])
	t.set_stylebox("normal", "Button", bn)
	t.set_stylebox("hover", "Button", bh)
	t.set_stylebox("focus", "Button", bh)
	t.set_stylebox("pressed", "Button", bp)
	t.set_stylebox("hover_pressed", "Button", bp)
	t.set_stylebox("disabled", "Button", bn)
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", ACCENT)
	t.set_color("font_focus_color", "Button", ACCENT)
	t.set_color("font_pressed_color", "Button", ACCENT)
	t.set_color("font_hover_pressed_color", "Button", ACCENT)
	t.set_color("font_disabled_color", "Button", DIM)
	t.set_color("font_color", "Label", TEXT)
	# option buttons and their popups
	var on := flat(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.18), [0, 0, 0, 2], [14, 6, 14, 6])
	var oh := flat(Color(1, 1, 1, 0.09), ACCENT, [0, 0, 0, 2], [14, 6, 14, 6])
	for st in ["normal", "disabled"]:
		t.set_stylebox(st, "OptionButton", on)
	for st in ["hover", "focus", "pressed", "hover_pressed"]:
		t.set_stylebox(st, "OptionButton", oh)
	t.set_color("font_color", "OptionButton", TEXT)
	t.set_color("font_hover_color", "OptionButton", ACCENT)
	t.set_color("font_focus_color", "OptionButton", ACCENT)
	t.set_color("font_pressed_color", "OptionButton", ACCENT)
	t.set_stylebox("panel", "PopupMenu", flat(Color(0.06, 0.07, 0.08, 0.97), Color(1, 1, 1, 0.12), [1, 1, 1, 1], [6, 6, 6, 6]))
	t.set_stylebox("hover", "PopupMenu", flat(Color(1.0, 0.6, 0.18, 0.18)))
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", ACCENT)
	t.set_font_size("font_size", "PopupMenu", 22)
	# check buttons
	t.set_color("font_color", "CheckButton", TEXT)
	t.set_color("font_hover_color", "CheckButton", ACCENT)
	t.set_color("font_focus_color", "CheckButton", ACCENT)
	t.set_color("font_pressed_color", "CheckButton", TEXT)
	t.set_stylebox("focus", "CheckButton", StyleBoxEmpty.new())
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		t.set_stylebox(st, "CheckButton", StyleBoxEmpty.new())
	# sliders
	var track := flat(Color(1, 1, 1, 0.14), Color(0, 0, 0, 0), [0, 0, 0, 0], [0, 3, 0, 3])
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", flat(ACCENT, Color(0, 0, 0, 0), [0, 0, 0, 0], [0, 3, 0, 3]))
	t.set_stylebox("grabber_area_highlight", "HSlider", flat(ACCENT, Color(0, 0, 0, 0), [0, 0, 0, 0], [0, 3, 0, 3]))
	var dot := _dot_texture(18, TEXT)
	t.set_icon("grabber", "HSlider", dot)
	t.set_icon("grabber_highlight", "HSlider", _dot_texture(18, ACCENT))
	# tabs
	t.set_stylebox("tab_selected", "TabContainer", flat(Color(1, 1, 1, 0.04), ACCENT, [0, 0, 0, 3], [20, 8, 20, 8]))
	t.set_stylebox("tab_unselected", "TabContainer", flat(Color(0, 0, 0, 0), Color(0, 0, 0, 0), [0, 0, 0, 3], [20, 8, 20, 8]))
	t.set_stylebox("tab_hovered", "TabContainer", flat(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.25), [0, 0, 0, 3], [20, 8, 20, 8]))
	t.set_stylebox("tab_focus", "TabContainer", StyleBoxEmpty.new())
	t.set_stylebox("panel", "TabContainer", flat(Color(0, 0, 0, 0), FAINT, [0, 1, 0, 0], [0, 16, 0, 0]))
	t.set_stylebox("tabbar_background", "TabContainer", StyleBoxEmpty.new())
	t.set_color("font_selected_color", "TabContainer", ACCENT)
	t.set_color("font_unselected_color", "TabContainer", DIM)
	t.set_color("font_hovered_color", "TabContainer", TEXT)
	t.set_font("font", "TabContainer", spaced("Bold", 2))
	t.set_font_size("font_size", "TabContainer", 22)
	# progress bars
	t.set_stylebox("background", "ProgressBar", flat(Color(1, 1, 1, 0.08)))
	t.set_stylebox("fill", "ProgressBar", flat(ACCENT))
	t.set_color("font_color", "ProgressBar", Color(0, 0, 0, 0))
	# scroll bars: thin
	t.set_stylebox("scroll", "VScrollBar", flat(Color(1, 1, 1, 0.04), Color(0, 0, 0, 0), [0, 0, 0, 0], [3, 0, 3, 0]))
	t.set_stylebox("grabber", "VScrollBar", flat(Color(1, 1, 1, 0.2), Color(0, 0, 0, 0), [0, 0, 0, 0], [3, 0, 3, 0]))
	t.set_stylebox("grabber_highlight", "VScrollBar", flat(ACCENT, Color(0, 0, 0, 0), [0, 0, 0, 0], [3, 0, 3, 0]))
	_theme = t
	return t


## Frosted-glass container: add your content as a child after calling this.
static func glass(tint_alpha: float = 0.62, outline: bool = true) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var bg := ColorRect.new()
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = BLUR_SHADER
	m.set_shader_parameter("tint", Color(0.03, 0.035, 0.045, tint_alpha))
	bg.material = m
	p.add_child(bg)
	if outline:
		var edge := Panel.new()
		edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		edge.add_theme_stylebox_override("panel", flat(Color(0, 0, 0, 0), Color(1, 1, 1, 0.07), [1, 1, 1, 1]))
		p.add_child(edge)
	return p


static func svg(path: String, px: int) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load(path)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(px, px)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr


## FlightOut lockup: small "YEMBERA" over the emblem + wordmark.
static func logo(scale: float = 1.0) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", int(-4 * scale))
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", int(8 * scale))
	var ym := svg(YEMBERA, int(16 * scale))
	ym.modulate = DIM
	top.add_child(ym)
	top.add_child(label("YEMBERA", int(16 * scale), "Bold", DIM, int(6 * scale)))
	v.add_child(top)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", int(10 * scale))
	row.add_child(svg(EMBLEM, int(86 * scale)))
	var word := HBoxContainer.new()
	word.add_theme_constant_override("separation", 0)
	word.add_child(label("FLIGHT", int(68 * scale), "Bold", TEXT, int(3 * scale)))
	word.add_child(label("OUT", int(68 * scale), "Bold", ACCENT, int(3 * scale)))
	row.add_child(word)
	v.add_child(row)
	return v
