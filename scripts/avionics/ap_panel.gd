extends Control
## Autopilot mode control panel face, drawn into the texture on the panel under the HUD (blender/build_cockpit.py
## ap_panel() builds the hardware: display bezels, knobs and raised button caps carrying their part of this
## texture). Layout constants are in panel metres (x to the pilot's right, y up, origin at the centre) and must
## match the builder. hit() turns a point on the panel into the control under it, for clicks and hover.
##
## One column per value, like a real mode control panel:
##   SPD   HDG   ALT   V/S      legend
##   [ green ACTIVE display ]   what the autopilot is flying now (dashes while it is off)
##   [ amber SELECTED display]  what you set with the knob or by clicking it and typing; the jet ignores it ...
##          ( knob )
##        [ ENTER ]             ... until you press ENTER: the selected value goes up to the active display
## On the right: AP (engage / disengage; engaging holds the speed, heading and altitude you are flying) and LVL
## (level flight). An ENTER button blinks while its selected value differs from the active one.

const UI = preload("res://scripts/ui/ui_theme.gd")
const W := 0.19
const H := 0.07
const WIN_X := [-0.075, -0.035, 0.005, 0.045]
const ACT_Y := 0.0205
const SEL_Y := 0.0055
const WIN_W := 0.034
const WIN_H := 0.012
const KNOB_Y := -0.0115
const KNOB_R := 0.005
const COLS := ["SPD", "HDG", "ALT", "VS"]
## id -> [x, y, w, h] (metres), same as AP_BTNS in the builder
const BTNS := {"SPD": [-0.075, -0.0265, 0.03, 0.009], "HDG": [-0.035, -0.0265, 0.03, 0.009],
	"ALT": [0.005, -0.0265, 0.03, 0.009], "VS": [0.045, -0.0265, 0.03, 0.009],
	"AP": [0.0775, 0.0125, 0.024, 0.026], "LVL": [0.0775, -0.0205, 0.024, 0.017]}
const TEX := Vector2i(1024, 377)

const PAINT := Color(0.115, 0.12, 0.125)
const LEGEND := Color(0.84, 0.84, 0.8)
const AMBER := Color(1.0, 0.62, 0.12)
const AMBER_DIM := Color(0.5, 0.3, 0.06)
const GREEN := Color(0.3, 1.0, 0.4)
const GREEN_DIM := Color(0.08, 0.28, 0.1)

var ac: Node3D
var hover := {}                 # the control under the mouse, from hit()
var edit_id := ""               # selected display being typed into ("SPD", "HDG", "ALT", "VS"), "" when none
var edit_text := ""
var _t := 0.0
var _font: Font
var _digits: Font


func _ready() -> void:
	size = Vector2(TEX)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UI.font("SemiBold")
	_digits = UI.tabular("Bold")


func tick(delta: float) -> void:
	_t += delta
	queue_redraw()


## Panel metres -> texture pixels.
static func px(x: float, y: float) -> Vector2:
	return Vector2((x + W * 0.5) / W * TEX.x, (H * 0.5 - y) / H * TEX.y)


static func rect_m(cx: float, cy: float, w: float, h: float) -> Rect2:
	var a := px(cx - w * 0.5, cy + h * 0.5)
	var b := px(cx + w * 0.5, cy - h * 0.5)
	return Rect2(a, b - a)


## The control at a point on the panel (metres): {kind: "win"|"knob"|"btn", id, side: -1|1 (knobs: which half)}.
## "win" is the amber selected display (click it to type a value).
static func hit(u: float, v: float) -> Dictionary:
	for i in 4:
		var x: float = WIN_X[i]
		if absf(u - x) <= WIN_W * 0.5 + 0.0015 and absf(v - SEL_Y) <= WIN_H * 0.5 + 0.0015:
			return {"kind": "win", "id": COLS[i], "side": 0}
		if Vector2(u - x, v - KNOB_Y).length() <= KNOB_R * 1.7:
			return {"kind": "knob", "id": COLS[i], "side": 1 if u >= x else -1}
	for id in BTNS:
		var b: Array = BTNS[id]
		if absf(u - float(b[0])) <= float(b[2]) * 0.5 + 0.0015 and absf(v - float(b[1])) <= float(b[3]) * 0.5 + 0.0015:
			return {"kind": "btn", "id": id, "side": 0}
	return {}


func _text(p: Vector2, s: String, sz: int, col: Color, f: Font = null) -> void:
	var font := f if f else _font
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	draw_string(font, Vector2(p.x - w * 0.5, p.y + sz * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)


## A value as the displays show it, in the pilot's units.
static func shown(id: String, v: float, imp: bool) -> String:
	match id:
		"SPD": return "%d" % int(round(v * (1.94384 if imp else 3.6)))
		"HDG": return "%03d" % (int(round(v)) % 360)
		"ALT": return "%d" % int(round((v - 2.0) * (3.28084 if imp else 1.0)))
		"VS": return "%+d" % int(round(v * (196.85 if imp else 1.0)))
	return ""


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, Vector2(TEX)), PAINT)
	if ac == null or ac.get("autopilot") == null:
		return
	var ap = ac.autopilot
	var imp := int(Settings.get_value("hud/unit_system")) == 1
	draw_rect(Rect2(Vector2(8, 8), Vector2(TEX) - Vector2(16, 16)), Color(0.2, 0.205, 0.21), false, 2.0)
	var legends := ["SPD " + ("KT" if imp else "KM/H"), "HDG", "ALT " + ("FT" if imp else "M"), "V/S " + ("FPM" if imp else "M/S")]
	var sel := [ap.spd_sel, ap.hdg_sel, ap.alt_sel, ap.vs_sel]
	var tgt := [ap.spd_tgt, ap.hdg_tgt, ap.alt_tgt, ap.vs_tgt]
	for i in 4:
		var x: float = WIN_X[i]
		var id: String = COLS[i]
		_text(px(x, ACT_Y + WIN_H * 0.5 + 0.0042), legends[i], 24, LEGEND)
		# green active display: what the autopilot is flying
		var ra := rect_m(x, ACT_Y, WIN_W, WIN_H)
		draw_rect(ra, Color(0.005, 0.012, 0.006))
		if ap.active(id):
			_text(ra.get_center(), shown(id, tgt[i], imp), 46, GREEN, _digits)
		else:
			_text(ra.get_center(), "- - -", 40, GREEN_DIM, _digits)
		# amber selected display: what the knob sets (or what is being typed)
		var rs := rect_m(x, SEL_Y, WIN_W, WIN_H)
		draw_rect(rs, Color(0.012, 0.008, 0.004))
		if edit_id == id:
			draw_rect(rs, Color(0.1, 0.065, 0.01))
			_text(rs.get_center(), edit_text + ("_" if fmod(_t, 0.8) < 0.5 else " "), 46, AMBER, _digits)
		else:
			_text(rs.get_center(), shown(id, sel[i], imp), 46, AMBER if ap._pre.get(id, false) or ap.engaged else AMBER_DIM, _digits)
		# knob scale
		var c := px(x, KNOB_Y)
		var rr := KNOB_R * 1.45 / W * TEX.x
		for k in 12:
			var a := TAU * k / 12.0
			var d := Vector2(cos(a), sin(a))
			draw_line(c + d * rr, c + d * (rr + 8.0), Color(0.55, 0.55, 0.52), 2.0)
		if hover.get("id", "") == id and hover.get("kind", "") in ["knob", "win"]:
			var hr: Rect2 = rs if hover.kind == "win" else Rect2(c - Vector2(rr + 12.0, rr + 12.0), Vector2(rr + 12.0, rr + 12.0) * 2.0)
			draw_rect(hr.grow(4.0), Color(0.9, 0.9, 0.88), false, 3.0)

	# buttons: ENTER under each column, AP and LVL on the right
	for id in BTNS:
		var b: Array = BTNS[id]
		var r := rect_m(float(b[0]), float(b[1]), float(b[2]), float(b[3]))
		draw_rect(r, Color(0.2, 0.205, 0.21))
		draw_rect(r, Color(0.07, 0.07, 0.075), false, 3.0)
		var lit := false
		var col := GREEN
		var label := "ENTER"
		if id == "AP":
			label = "AP"
			lit = ap.engaged
			if not ap.engaged and ap.status != "" and Time.get_ticks_msec() / 1000.0 - float(ap.status_time) < 3.0:
				lit = fmod(_t, 0.5) < 0.3
				col = AMBER
		elif id == "LVL":
			label = "LVL"
			lit = ap.engaged and ap.level
		elif ap.pending(id) or (not ap.engaged and ap._pre.get(id, false)):
			# a selected value waiting to be entered
			lit = fmod(_t, 0.8) < 0.45
			col = AMBER
		var bar_h: float = minf(r.size.y * 0.24, 16.0)
		var bar := Rect2(r.position + Vector2(10, 6), Vector2(r.size.x - 20, bar_h))
		draw_rect(bar, col if lit else Color(0.05, 0.07, 0.05))
		var sz := 30 if id == "AP" else 22
		_text(Vector2(r.position.x + r.size.x * 0.5, r.position.y + 6 + bar_h + (r.size.y - 6 - bar_h) * 0.5), label, sz, LEGEND)
		if hover.get("kind", "") == "btn" and hover.get("id", "") == id:
			draw_rect(r.grow(5.0), Color(0.9, 0.9, 0.88), false, 3.0)
