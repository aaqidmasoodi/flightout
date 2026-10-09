extends Control
## HUD symbology, drawn into the texture the combiner glass shows. Collimated: the texture is laid out in
## degrees from the aircraft's boresight (HUD_FOV across), and the combiner shader looks it up by viewing
## direction, so conformal symbols (horizon, pitch ladder, flight path marker, CCIP pipper) sit on the real
## world from any head position, exactly like a real HUD focused at infinity.
##
## One page per avionics master mode (scripts/sim/avionics.gd):
##   NAV  heading tape, pitch ladder, flight path marker, speed and altitude boxes, alpha / Mach / G, bank scale
##   BVR  decluttered: horizon line, scan zone, range scale with launch brackets, weapon status
##   WVR  close combat: large aiming circle, vertical scan line, G and alpha up front, short-range weapon
##   GND  ground attack: pitch ladder, continuously computed impact point (CCIP) with bomb fall line, AGL
## Units follow the game setting (hud/unit_system): knots and feet, or km/h and metres.

const Avionics = preload("res://scripts/sim/avionics.gd")
const UI = preload("res://scripts/ui/ui_theme.gd")
const HUD_FOV := 15.5                       # degrees covered by the texture, edge to edge
const SIZE := 1024
const PPD := SIZE / HUD_FOV                 # pixels per degree
const GREEN := Color(0.22, 1.0, 0.36)              # saturated: the combiner keeps it green, never white
const LW := 3.6                             # line width
## Usable symbology window in degrees, well inside the combiner glass (which spans about az +-7.7, el -11.5..+3.7
## from the design eye). Nothing is drawn outside it: the combiner shader also fades the texture out at these
## edges, so the symbology always keeps a clear margin from the glass frame on every side.
const WIN_AZ := 5.9
## The combiner is a tall plate (from the design eye it spans about el +3.7 down to -11.5, deepest in the middle
## of its U). The window keeps a margin inside it on every side.
const WIN_TOP := 2.9
const WIN_BOT := -10.3
## The texture is centred this many degrees below boresight so it covers the whole window (top to bottom).
const TEX_EL0 := -3.7
## Symbols not tied to the world (boxes, readouts, labels, mode and weapon text) are laid out on a design grid
## running from DES_TOP (top of the window) to DES_BOT (bottom); _dp stretches that grid over the real window,
## so the heading tape stays at the top, the readouts, bank scale and labels sit at the bottom and the speed
## and altitude boxes stay in the middle. Conformal symbols (horizon, pitch ladder, flight path marker, target
## box) use _deg and always stay on the world.
const DES_TOP := 4.6
const DES_BOT := -5.3

var ac: Node3D
var _t := 0.0
var _font: Font
var _font_b: Font


func _ready() -> void:
	size = Vector2(SIZE, SIZE)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UI.font("SemiBold")
	_font_b = UI.tabular("Bold")


func tick(delta: float) -> void:
	_t += delta
	queue_redraw()


# ------------------------------------------------------------------ helpers
## Placement for symbols not tied to the world: the design grid stretched over the window (see DES_TOP).
func _dp(az: float, el: float) -> Vector2:
	return _deg(az, WIN_TOP + (el - DES_TOP) * (WIN_TOP - WIN_BOT) / (DES_TOP - DES_BOT))


func _deg(az: float, el: float) -> Vector2:
	## degrees right / up of boresight -> texture pixels
	return Vector2(SIZE * 0.5 + az * PPD, SIZE * 0.5 - (el - TEX_EL0) * PPD)


func _text(p: Vector2, s: String, sz: int = 26, align := HORIZONTAL_ALIGNMENT_CENTER, bold := false) -> void:
	var f := _font_b if bold else _font
	var w := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var x := p.x
	if align == HORIZONTAL_ALIGNMENT_CENTER:
		x -= w * 0.5
	elif align == HORIZONTAL_ALIGNMENT_RIGHT:
		x -= w
	draw_string(f, Vector2(x, p.y + sz * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, GREEN)


func _box(c: Vector2, w: float, h: float) -> void:
	draw_rect(Rect2(c - Vector2(w, h) * 0.5, Vector2(w, h)), GREEN, false, LW)


func _attitude() -> Array:
	var b: Basis = ac.fm.rot
	var fwd := -b.z
	var pitch := rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0)))
	var bank := rad_to_deg(atan2(-b.x.y, b.y.y))
	return [pitch, bank]


## velocity vector in degrees off boresight (azimuth right, elevation up)
func _fpm() -> Vector2:
	var v: Vector3 = ac.velocity
	if v.length() < 15.0:
		return Vector2.ZERO
	var l: Vector3 = ac.fm.rot.inverse() * v
	return Vector2(rad_to_deg(atan2(l.x, -l.z)), rad_to_deg(atan2(l.y, -l.z)))


## true when the player flies in knots and feet (the same setting the flight data panel follows)
func _imperial() -> bool:
	return int(Settings.get_value("hud/unit_system")) == 1


func _alt_m() -> float:
	# same reference as the flight data panel (scripts/hud.gd), so the two always agree
	return ac.global_position.y - 2.0


# ------------------------------------------------------------------ draw
func _draw() -> void:
	if ac == null or ac.fm == null:
		return
	var mode: int = int(ac.master_mode) if "master_mode" in ac else 0
	match mode:
		Avionics.Mode.BVR:
			_page_bvr()
		Avionics.Mode.WVR:
			_page_wvr()
		Avionics.Mode.GND:
			_page_gnd()
		_:
			_page_nav()
	_autopilot()
	_target()
	_warnings()


func _common_boxes(show_radalt := true) -> void:
	# speed box (km/h IAS), left; altitude box (m, thousands split), right; radar altitude above it
	var imp := _imperial()
	var ias := int(ac.ias * (1.94384 if imp else 3.6))
	var sp := _dp(-4.7, 0.6)
	_box(sp, 112, 50)
	_text(sp, str(ias), 36, HORIZONTAL_ALIGNMENT_CENTER, true)
	var alt := maxi(0, int(_alt_m() * (3.28084 if imp else 1.0)))
	var ap := _dp(4.5, 0.6)
	_box(ap, 132, 50)
	_text(ap + Vector2(-38, 0), str(alt / 1000), 36, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(ap + Vector2(16, 0), "%03d" % (alt % 1000), 30)
	if show_radalt:
		var agl: float = ac.altitude_agl
		if agl < 1500.0:
			_text(ap + Vector2(0, -50), str(int(maxf(agl, 0.0) * (3.28084 if imp else 1.0))), 30)
			_text(ap + Vector2(78, -50), "R", 30, HORIZONTAL_ALIGNMENT_LEFT, true)


func _heading_tape(el: float) -> void:
	var hdg: float = ac.heading_deg
	var c := _deg(0.0, el)
	var scale := 0.36 * PPD           # pixels per degree of heading
	var span := 11.0
	var h0 := floorf((hdg - span) / 5.0) * 5.0
	var h := h0
	while h <= hdg + span:
		var x := c.x + (h - hdg) * scale
		var major := int(fposmod(h, 10.0)) == 0
		draw_line(Vector2(x, c.y + 14), Vector2(x, c.y + (2 if major else 8)), GREEN, LW)
		if major:
			_text(Vector2(x, c.y - 18), "%03d" % int(fposmod(h, 360.0)), 28)
		h += 5.0
	# caret under the tape
	draw_polyline(PackedVector2Array([c + Vector2(-10, 34), c + Vector2(0, 22), c + Vector2(10, 34)]), GREEN, LW)
	draw_line(c + Vector2(0, 22), c + Vector2(0, 40), GREEN, LW)


func _pitch_ladder(step := 5.0, max_lines := 12) -> void:
	var at: Array = _attitude()
	var pitch: float = at[0]
	var bank: float = at[1]
	var c := _deg(0.0, 0.0)
	draw_set_transform(c, deg_to_rad(-bank), Vector2.ONE)
	var p0 := floorf((pitch - 12.0) / step) * step
	var p := p0
	while p <= pitch + 12.0:
		var y := -(p - pitch) * PPD
		if p == 0.0:
			# horizon: long line with a gap
			draw_line(Vector2(-4.6 * PPD, y), Vector2(-1.2 * PPD, y), GREEN, LW)
			draw_line(Vector2(1.2 * PPD, y), Vector2(4.6 * PPD, y), GREEN, LW)
		else:
			var w := 2.2 * PPD
			var gap := 0.9 * PPD
			var tick := 10.0 if p > 0 else -10.0
			if p > 0:
				draw_line(Vector2(-w, y), Vector2(-gap, y), GREEN, LW)
				draw_line(Vector2(gap, y), Vector2(w, y), GREEN, LW)
			else:
				# below the horizon: dashed
				for k in 3:
					var a := -w + k * (w - gap) / 3.0
					draw_line(Vector2(a, y), Vector2(a + (w - gap) / 5.0, y), GREEN, LW)
					draw_line(Vector2(-a - (w - gap) / 5.0, y), Vector2(-a, y), GREEN, LW)
			draw_line(Vector2(-gap, y), Vector2(-gap, y + tick), GREEN, LW)
			draw_line(Vector2(gap, y), Vector2(gap, y + tick), GREEN, LW)
			var lbl := str(int(absf(p)))
			_text(Vector2(-w - 30, y), lbl, 28)
			_text(Vector2(w + 30, y), lbl, 28)
		p += step
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _fpm_symbol() -> Vector2:
	var f := _fpm()
	var p := _deg(clampf(f.x, -WIN_AZ + 0.6, WIN_AZ - 0.6), clampf(f.y, WIN_BOT + 0.6, WIN_TOP - 0.6))
	draw_arc(p, 11, 0, TAU, 24, GREEN, LW)
	draw_line(p + Vector2(11, 0), p + Vector2(32, 0), GREEN, LW)
	draw_line(p - Vector2(11, 0), p - Vector2(32, 0), GREEN, LW)
	draw_line(p - Vector2(0, 11), p - Vector2(0, 22), GREEN, LW)
	return p


func _bank_scale() -> void:
	var bank: float = _attitude()[1]
	var c := _deg(0.0, WIN_BOT + 5.3)          # arc and pointer along the bottom of the glass
	var r := 4.2 * PPD
	for a: int in [-45, -30, -20, -10, 0, 10, 20, 30, 45]:
		var ang := deg_to_rad(90.0 + a)
		var d := Vector2(cos(ang), sin(ang))
		var big := a % 30 == 0
		draw_line(c + d * r, c + d * (r + (26 if big else 16)), GREEN, LW)
	var ang := deg_to_rad(90.0 - clampf(bank, -60.0, 60.0))
	var d := Vector2(cos(ang), sin(ang))
	var tip := c + d * (r - 4)
	var side := Vector2(-d.y, d.x)
	draw_colored_polygon(PackedVector2Array([tip, tip - d * 22 + side * 10, tip - d * 22 - side * 10]), GREEN)


func _readouts(x_deg: float, top_el: float) -> void:
	var p := _dp(x_deg, top_el)
	_text(p, "α", 30, HORIZONTAL_ALIGNMENT_LEFT)
	_text(p + Vector2(120, 0), "%.1f" % ac.aoa_deg, 30, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(p + Vector2(0, 36), "M", 30, HORIZONTAL_ALIGNMENT_LEFT)
	_text(p + Vector2(120, 36), "%.2f" % ac.mach, 30, HORIZONTAL_ALIGNMENT_RIGHT)
	_text(p + Vector2(0, 72), "G", 30, HORIZONTAL_ALIGNMENT_LEFT)
	_text(p + Vector2(120, 72), "%.1f" % ac.g_load, 30, HORIZONTAL_ALIGNMENT_RIGHT)


func _mode_label(s: String) -> void:
	_text(_dp(4.6, -4.8), s, 28, HORIZONTAL_ALIGNMENT_CENTER, true)


# ------------------------------------------------------------------ pages
func _page_nav() -> void:
	_heading_tape(WIN_TOP - 0.75)
	_pitch_ladder(5.0)
	_fpm_symbol()
	_common_boxes()
	_readouts(-WIN_AZ, -2.4)
	_bank_scale()
	if ac.gear_down:
		_text(_dp(-4.6, -4.8), "GEAR", 28, HORIZONTAL_ALIGNMENT_CENTER, true)
	_mode_label("NAV")


func _page_bvr() -> void:
	_heading_tape(WIN_TOP - 0.75)
	# horizon only, short, so the target area stays clear
	var at: Array = _attitude()
	var c := _deg(0.0, 0.0)
	draw_set_transform(c, deg_to_rad(-float(at[1])), Vector2.ONE)
	var y := float(at[0]) * PPD
	draw_line(Vector2(-3.4 * PPD, y), Vector2(-1.5 * PPD, y), GREEN, LW)
	draw_line(Vector2(1.5 * PPD, y), Vector2(3.4 * PPD, y), GREEN, LW)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# boresight cross and the radar scan zone
	draw_line(c + Vector2(-14, 0), c + Vector2(14, 0), GREEN, LW)
	draw_line(c + Vector2(0, -14), c + Vector2(0, 14), GREEN, LW)
	var zone := Rect2(_dp(-3.2, 2.2), Vector2(6.4, 4.4) * PPD)
	for k in 16:
		var t0 := k / 16.0
		var t1 := t0 + 0.5 / 16.0
		draw_line(zone.position + Vector2(zone.size.x * t0, 0), zone.position + Vector2(zone.size.x * t1, 0), GREEN, LW)
		draw_line(zone.position + Vector2(zone.size.x * t0, zone.size.y), zone.position + Vector2(zone.size.x * t1, zone.size.y), GREEN, LW)
	# range scale on the right: 0..100 km, launch brackets (Rmax / Rmin placeholders until the radar exists)
	var top := _dp(5.0, -1.2); var bot := _dp(5.0, -4.0)
	draw_line(top, bot, GREEN, LW)
	for k in 6:
		var yy := lerpf(bot.y, top.y, k / 5.0)
		draw_line(Vector2(top.x, yy), Vector2(top.x - 14, yy), GREEN, LW)
	_text(top + Vector2(-10, -26), "100", 26, HORIZONTAL_ALIGNMENT_RIGHT)
	var rmax := lerpf(bot.y, top.y, 0.62); var rmin := lerpf(bot.y, top.y, 0.12)
	draw_line(Vector2(top.x + 4, rmax), Vector2(top.x + 24, rmax), GREEN, LW)
	draw_line(Vector2(top.x + 4, rmin), Vector2(top.x + 24, rmin), GREEN, LW)
	_common_boxes(false)
	_text(_dp(-4.4, -4.2), "R-27R  4", 28, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(_dp(-4.4, -4.85), "SCAN", 26)
	_mode_label("BVR")


func _page_wvr() -> void:
	var c := _deg(0.0, 0.0)
	# big aiming circle (missile seeker field) and the vertical scan line above it
	draw_arc(c, 2.7 * PPD, 0, TAU, 72, GREEN, LW)
	for k in 12:
		var a := TAU * k / 12.0
		var d := Vector2(cos(a), sin(a))
		draw_line(c + d * 2.7 * PPD, c + d * (2.7 * PPD - 14), GREEN, LW)
	draw_circle(c, 4, GREEN)
	for k in 7:
		var yy := c.y - 2.9 * PPD - k * 0.24 * PPD
		draw_line(Vector2(c.x, yy), Vector2(c.x, yy - 0.13 * PPD), GREEN, LW)
	_fpm_symbol()
	_common_boxes(false)
	# G and alpha big on the left, they matter most in a turning fight
	var p := _dp(-WIN_AZ, -2.2)
	_text(p, "G %.1f" % ac.g_load, 34, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(p + Vector2(0, 42), "α %.0f" % ac.aoa_deg, 30, HORIZONTAL_ALIGNMENT_LEFT, true)
	_text(_dp(-4.4, -4.8), "R-73  2", 28, HORIZONTAL_ALIGNMENT_CENTER, true)
	_mode_label("WVR")


func _page_gnd() -> void:
	_heading_tape(WIN_TOP - 0.75)
	_pitch_ladder(5.0)
	var fp := _fpm_symbol()
	# CCIP: where a released bomb would hit the ground (vacuum ballistics), drawn with its fall line
	var pos: Vector3 = ac.global_position
	var v: Vector3 = ac.velocity
	var g := 9.81
	var ground: float = WorldData.ground_height(pos.x, pos.z)
	var h := pos.y - ground
	var t := 0.0
	if h > 1.0:
		# solve h + v.y t - g t^2 / 2 = 0 for the positive root
		t = (v.y + sqrt(maxf(v.y * v.y + 2.0 * g * h, 0.0))) / g
	var impact := pos + Vector3(v.x * t, -h, v.z * t)
	var l: Vector3 = ac.fm.rot.inverse() * (impact - pos)
	if l.z < -1.0:
		var az := rad_to_deg(atan2(l.x, -l.z)); var el := rad_to_deg(atan2(l.y, -l.z))
		var pip := _deg(clampf(az, -WIN_AZ + 0.5, WIN_AZ - 0.5), clampf(el, WIN_BOT + 0.5, WIN_TOP - 0.5))
		draw_line(fp, pip, GREEN, LW)
		draw_arc(pip, 16, 0, TAU, 28, GREEN, LW)
		draw_circle(pip, 3.5, GREEN)
		if absf(az) > WIN_AZ - 0.5 or el < WIN_BOT + 0.5 or el > WIN_TOP - 0.5:
			_text(pip + Vector2(0, -30), "OFF", 22)
	_common_boxes(true)
	_text(_dp(4.5, -1.6), "AGL %d" % int(maxf(h, 0.0) * (3.28084 if _imperial() else 1.0)), 24, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(_dp(-4.4, -4.8), "FAB-250", 28, HORIZONTAL_ALIGNMENT_CENTER, true)
	_mode_label("GND")


## Autopilot: engaged modes and targets top left, target markers on the heading tape and by the boxes,
## and a flashing AP OFF for a few seconds after it disconnects.
func _autopilot() -> void:
	var ap = ac.get("autopilot")
	if ap == null:
		return
	var imp := _imperial()
	var p := _dp(-WIN_AZ, 2.1)
	if ap.engaged:
		_text(p, "AP  LEVEL" if ap.level else "AP", 28, HORIZONTAL_ALIGNMENT_LEFT, true)
		if not ap.level:
			var lines := PackedStringArray()
			lines.append("HDG %03d" % (int(round(ap.hdg_tgt)) % 360))
			if ap.vert == "VS":
				lines.append("VS %+d" % int(round(ap.vs_tgt * (196.85 if imp else 1.0))))
			lines.append("ALT %d" % int(round((ap.alt_tgt - 2.0) * (3.28084 if imp else 1.0))))
			_text(p + Vector2(0, 34), "  ".join(lines), 26, HORIZONTAL_ALIGNMENT_LEFT)
			# heading bug on the tape, clamped to its ends
			if Avionics.Mode.WVR != (int(ac.master_mode) if "master_mode" in ac else 0):
				var c := _deg(0.0, WIN_TOP - 0.75)
				var d := wrapf(float(ap.hdg_tgt) - float(ac.heading_deg), -180.0, 180.0)
				var x := c.x + clampf(d, -11.0, 11.0) * 0.36 * PPD
				draw_polyline(PackedVector2Array([Vector2(x - 9, c.y + 30), Vector2(x - 9, c.y + 20), Vector2(x, c.y + 14), Vector2(x + 9, c.y + 20), Vector2(x + 9, c.y + 30)]), GREEN, LW * 0.8)
	elif ap.status != "" and Time.get_ticks_msec() / 1000.0 - float(ap.status_time) < 3.0:
		if fmod(_t, 0.5) < 0.32:
			_text(p, "AP OFF", 28, HORIZONTAL_ALIGNMENT_LEFT, true)
	# auto-throttle target under the speed box
	if ac.autothrottle:
		var sp := _dp(-4.7, 0.6)
		_text(sp + Vector2(0, 48), "A %d" % int(round(ac.at_target * (1.94384 if imp else 3.6))), 24)


## Radar lock: a target designator box over the locked aircraft (clamped to the window edge with an arrow when
## it is outside), its range and closure underneath.
func _target() -> void:
	var sn = ac.get("sensors")
	if sn == null:
		return
	var lt: Dictionary = sn.locked()
	if lt.is_empty() or not is_instance_valid(lt.node):
		return
	var r: Array = sn.relative(lt.node.global_position)
	var az: float = r[1]
	var el: float = r[2]
	var inside := absf(az) <= WIN_AZ - 0.4 and el <= WIN_TOP - 0.4 and el >= WIN_BOT + 0.4
	var p := _deg(clampf(az, -WIN_AZ + 0.4, WIN_AZ - 0.4), clampf(el, WIN_BOT + 0.4, WIN_TOP - 0.4))
	var sz := 0.55 * PPD
	draw_rect(Rect2(p - Vector2(sz, sz) * 0.5, Vector2(sz, sz)), GREEN, false, LW)
	if not inside:
		# off the HUD: a line from the boresight toward it
		var c := _deg(0.0, 0.0)
		var d := (Vector2(az, -el)).normalized()
		draw_line(c + d * 0.8 * PPD, c + d * 2.2 * PPD, GREEN, LW)
	var imp := _imperial()
	var rng: float = float(r[0]) / (1852.0 if imp else 1000.0)
	var closure: float = -((lt.vel as Vector3) - ac.velocity).dot((lt.node.global_position - ac.global_position).normalized())
	_text(_dp(4.5, -2.6), "R %.1f" % rng, 26, HORIZONTAL_ALIGNMENT_CENTER, true)
	_text(_dp(4.5, -3.2), "VC %d" % int(round(closure * (1.94384 if imp else 3.6))), 24)


func _warnings() -> void:
	var list: Array = Avionics.active(ac)
	if list.is_empty():
		return
	var w: int = list[0]
	var info: Array = Avionics.INFO[w]
	if int(info[2]) != 0:
		return
	if fmod(_t, 0.6) < 0.38:
		var c := _dp(0.0, -2.6)
		_text(c, String(info[0]), 40, HORIZONTAL_ALIGNMENT_CENTER, true)
