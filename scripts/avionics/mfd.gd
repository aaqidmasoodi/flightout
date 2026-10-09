extends Control
## One multifunction display: the picture on its screen and what its bezel buttons (OSBs) do.
## The screen is a SubViewport texture on SCR_MFD_<id> (blender/build_cockpit.py mfd()). The button layout matches
## the builder: round buttons down both sides (L0.. / R0.. from the top), rectangular keys along the top and bottom
## (T0.. / B0.. from the left). Every labelled button does something; a button's label sits on the screen edge
## next to it, and a boxed label marks the page or option that is selected.
##
## Pages:
##   RDR  radar B-scope: azimuth across, range up. Radar contacts are filled triangles, datalink (AWACS) contacts
##        open triangles, the lock a box. Click a contact on the screen to lock it.
##   SA   situation map, heading up: own jet, range rings, every track with altitude and heading vector,
##        the home airfield, the autopilot heading
##   SYS  engines, fuel, hydraulics, gear and controls
##   WPN  stores on each pylon, the selected weapon
##   EW   threat warning picture and countermeasures

const UI = preload("res://scripts/ui/ui_theme.gd")
const GRN := Color(0.32, 1.0, 0.42)
const GRN_DIM := Color(0.14, 0.42, 0.18)
const WHITE := Color(0.9, 0.95, 0.92)
const RED := Color(1.0, 0.28, 0.22)
const YEL := Color(1.0, 0.85, 0.25)
const CYAN := Color(0.35, 0.85, 1.0)
const HOME := Vector3.ZERO

var ac: Node3D
var id := "L"                   # "L", "C" or "R"
var w_m := 0.2                  # screen size in metres (from the builder)
var h_m := 0.15
var cols := 6                   # round buttons per side
var rows := 5                   # keys along the top and bottom
var page := "RDR"
var pages: Array = ["RDR", "SA", "SYS", "WPN", "EW"]
var sa_north_up := false
var wpn_sel := 0
var cmds_auto := true
var _t := 0.0
var _font: Font
var _bold: Font
var _flash := {}                # slot -> seconds left of the press highlight


func setup(p_id: String, p_w: float, p_h: float, p_cols: int, p_rows: int, start_page: String, page_list: Array) -> void:
	id = p_id
	w_m = p_w
	h_m = p_h
	cols = p_cols
	rows = p_rows
	page = start_page
	pages = page_list


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = UI.tabular("SemiBold")
	_bold = UI.tabular("Bold")


func tick(delta: float) -> void:
	_t += delta
	for k in _flash.keys():
		_flash[k] = float(_flash[k]) - delta
		if _flash[k] <= 0.0:
			_flash.erase(k)
	queue_redraw()


# ------------------------------------------------------------------ layout helpers
func _imp() -> bool:
	return int(Settings.get_value("hud/unit_system")) == 1


## Screen pixel of a button's label anchor. slot: "L0".."R5" (side, from the top), "T0".."B4" (from the left).
func _slot_px(slot: String) -> Vector2:
	var side := slot[0]
	var i := slot.substr(1).to_int()
	if side == "L" or side == "R":
		var y_m := h_m * 0.5 - 0.012 - (h_m - 0.024) * i / float(cols - 1)
		return Vector2(14.0 if side == "L" else size.x - 14.0, (h_m * 0.5 - y_m) / h_m * size.y)
	var x_m := -w_m * 0.5 + 0.02 + (w_m - 0.04) * i / float(maxi(rows - 1, 1))
	return Vector2((x_m + w_m * 0.5) / w_m * size.x, 22.0 if side == "T" else size.y - 22.0)


func _text(p: Vector2, s: String, sz: int, col: Color, align := 0, bold := false) -> float:
	## align: 0 centre, -1 left, 1 right. Returns the text width.
	var f := _bold if bold else _font
	var wdt := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var x := p.x - wdt * 0.5
	if align < 0:
		x = p.x
	elif align > 0:
		x = p.x - wdt
	draw_string(f, Vector2(x, p.y + sz * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)
	return wdt


func _label(slot: String, s: String, boxed := false, col := GRN) -> void:
	var p := _slot_px(slot)
	var side := slot[0]
	var align := -1 if side == "L" else (1 if side == "R" else 0)
	var sz := 24
	var wdt := _text(p, s, sz, col, align, true)
	var x0 := p.x if align < 0 else (p.x - wdt if align > 0 else p.x - wdt * 0.5)
	var r := Rect2(x0 - 6, p.y - sz * 0.62, wdt + 12, sz * 1.24)
	if boxed:
		draw_rect(r, col, false, 2.0)
	if _flash.has(slot):
		draw_rect(r, Color(col, 0.35))


## Area left for the page picture, inside the button labels.
func _body() -> Rect2:
	return Rect2(Vector2(70, 52), size - Vector2(140, 104))


func _tri(c: Vector2, s: float, filled: bool, col: Color, rot := 0.0) -> void:
	var pts := PackedVector2Array()
	for k in 3:
		var a := rot - PI * 0.5 + TAU * k / 3.0
		pts.append(c + Vector2(cos(a), sin(a)) * s)
	if filled:
		draw_colored_polygon(pts, col)
	pts.append(pts[0])
	draw_polyline(pts, col, 2.0)


func _iff_col(t: Dictionary) -> Color:
	match String(t.iff):
		"friendly": return CYAN
		"unknown": return YEL
	return RED


func _alt_text(y: float) -> String:
	## thousands of feet, or hundreds of metres
	var alt := y - 2.0
	return str(int(round(alt * 3.28084 / 1000.0))) if _imp() else str(int(round(alt / 100.0)))


# ------------------------------------------------------------------ buttons
## A bezel button pressed (from the cockpit). Returns true if it did something.
func press(slot: String) -> bool:
	_flash[slot] = 0.18
	var s = ac.get("sensors")
	# bottom row: page select
	if slot[0] == "B":
		var i := slot.substr(1).to_int()
		if i < pages.size():
			page = pages[i]
			return true
		return false
	match page:
		"RDR":
			if s == null:
				return false
			match slot:
				"T0": s.mode = "TWS" if s.mode == "RWS" else "RWS"
				"T1": s.az_i = (s.az_i + 1) % s.AZ_LIMITS.size()
				"T2": s.bars_i = (s.bars_i + 1) % s.BAR_COUNTS.size()
				"T3": ac.press_switch("toggle_radar")
				"T4": s.unlock()
				"R0": s.range_step(1)
				"R1": s.range_step(-1)
				"L0": s.lock(0)
				_: return false
			return true
		"SA":
			if s == null:
				return false
			match slot:
				"T0": sa_north_up = not sa_north_up
				"T1": s.datalink_on = not s.datalink_on
				"R0": s.range_step(1)
				"R1": s.range_step(-1)
				_: return false
			return true
		"WPN":
			var st = _stores()
			if st == null or st.stations.is_empty():
				return false
			match slot:
				"L0": wpn_sel = posmod(wpn_sel - 1, st.stations.size())
				"L1": wpn_sel = posmod(wpn_sel + 1, st.stations.size())
				"L2": return st.cycle(int(st.stations[wpn_sel].id), bool(ac.get("on_ground")) or bool(ac.get("wow")))
				_: return false
			return true
		"EW":
			match slot:
				"T0": cmds_auto = not cmds_auto
				_: return false
			return true
	return false


## A click on the screen itself at a texture pixel (radar page: lock the contact under it).
func click(px: Vector2) -> bool:
	if page != "RDR":
		return false
	var s = ac.get("sensors")
	if s == null:
		return false
	var best := 40.0
	var hit := 0
	for k in s.tracks:
		var t: Dictionary = s.tracks[k]
		if not s.is_radar(t):
			continue
		var p = _bscope_px(t, s)
		if p == null:
			continue
		var d := (p as Vector2).distance_to(px)
		if d < best:
			best = d
			hit = k
	if hit != 0:
		if s.lock_id == hit:
			s.unlock()
		else:
			s.lock(hit)
		return true
	return false


# ------------------------------------------------------------------ draw
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.0, 0.012, 0.006))
	if ac == null or ac.get("fm") == null:
		return
	match page:
		"RDR": _page_radar()
		"SA": _page_sa()
		"SYS": _page_sys()
		"WPN": _page_wpn()
		"EW": _page_ew()
	for i in pages.size():
		_label("B%d" % i, pages[i], pages[i] == page)


# ---- radar B-scope
func _bscope_px(t: Dictionary, s) -> Variant:
	var b := _body()
	var r: Array = s.relative(t.pos)
	var lim: float = s.GIMBAL
	if r[0] > s.range_m() or absf(r[1]) > lim:
		return null
	return Vector2(b.position.x + (r[1] / lim * 0.5 + 0.5) * b.size.x, b.end.y - r[0] / s.range_m() * b.size.y)


func _page_radar() -> void:
	var s = ac.get("sensors")
	if s == null:
		return
	var b := _body()
	var on: bool = s.radar_on()
	_label("T0", s.mode, false)
	_label("T1", "AZ %d" % int(s.az_limit()))
	_label("T2", "%dB" % s.bars())
	_label("T3", "PWR " + ("ON" if on else "OFF"), on)
	if s.lock_id != 0:
		_label("T4", "UNLK")
	_label("R0", "RNG ▲")
	_label("R1", "RNG ▼")
	_label("L0", "LOCK")
	# frame: range quarters and azimuth lines every 30 degrees
	draw_rect(b, GRN_DIM, false, 2.0)
	for k in range(1, 4):
		var y := b.end.y - b.size.y * k / 4.0
		draw_dashed_line(Vector2(b.position.x, y), Vector2(b.end.x, y), GRN_DIM, 1.5, 8.0)
	for a in [-30.0, 0.0, 30.0]:
		var x: float = b.position.x + (a / 60.0 * 0.5 + 0.5) * b.size.x
		draw_dashed_line(Vector2(x, b.position.y), Vector2(x, b.end.y), GRN_DIM, 1.5, 8.0)
	_text(Vector2(b.end.x - 8, b.end.y - 16), "RNG " + s.range_label(), 22, GRN, 1)
	if not on:
		_text(b.get_center(), "RADAR OFF", 34, GRN, 0, true)
		_text(b.get_center() + Vector2(0, 40), "PWR to transmit", 20, GRN_DIM)
	else:
		# scan limits and the sweeping antenna
		var lim: float = s.az_limit()
		for sx in [-1.0, 1.0]:
			var x: float = b.position.x + (sx * lim / 60.0 * 0.5 + 0.5) * b.size.x
			draw_line(Vector2(x, b.end.y), Vector2(x, b.end.y - 18), GRN, 2.0)
		var sx_px: float = b.position.x + (s.sweep / 60.0 * 0.5 + 0.5) * b.size.x
		draw_line(Vector2(sx_px, b.end.y + 4), Vector2(sx_px, b.end.y + 16), GRN, 3.0)
	# own heading and altitude
	_text(Vector2(b.position.x + 6, b.end.y - 14), "%03d" % (int(round(float(ac.heading_deg))) % 360), 20, GRN, -1)
	# tracks
	var unit := "NM" if _imp() else "KM"
	for k in s.tracks:
		var t: Dictionary = s.tracks[k]
		var radar: bool = s.is_radar(t)
		if not radar and not s.is_dl(t):
			continue
		var p = _bscope_px(t, s)
		if p == null:
			continue
		var col := _iff_col(t)
		# heading vector in TWS: the target's course relative to ours
		if s.mode == "TWS" and radar:
			var v: Vector3 = t.vel
			if v.length() > 20.0:
				var lv: Vector3 = ac.fm.rot.orthonormalized().inverse() * v
				var dir := Vector2(lv.x, lv.z).normalized()
				draw_line(p, p + dir * 26.0, col, 2.0)
		_tri(p, 11.0, radar, col)
		_text(p + Vector2(16, -2), _alt_text(t.pos.y), 18, col, -1)
		if k == s.lock_id:
			draw_rect(Rect2(p - Vector2(17, 17), Vector2(34, 34)), WHITE, false, 2.5)
	# locked target data
	var lt: Dictionary = s.locked()
	if not lt.is_empty():
		var r: Array = s.relative(lt.node.global_position)
		var closure: float = -(lt.vel - ac.velocity).dot((lt.node.global_position - ac.global_position).normalized())
		var rng: float = r[0] / (1852.0 if _imp() else 1000.0)
		_text(Vector2(b.position.x + 6, b.position.y + 18), "STT", 22, WHITE, -1, true)
		_text(Vector2(b.position.x + 6, b.position.y + 44), "R %.1f %s" % [rng, unit], 20, WHITE, -1)
		_text(Vector2(b.position.x + 6, b.position.y + 68), "VC %d" % int(round(closure * (1.94384 if _imp() else 3.6))), 20, WHITE, -1)
		_text(Vector2(b.position.x + 6, b.position.y + 92), "ALT %s" % _alt_text(lt.node.global_position.y), 20, WHITE, -1)


# ---- situation map
func _page_sa() -> void:
	var s = ac.get("sensors")
	var b := _body()
	if s != null:
		_label("T0", "N UP" if sa_north_up else "HDG UP")
		_label("T1", "DL", s.datalink_on)
		_label("R0", "RNG ▲")
		_label("R1", "RNG ▼")
	var c := Vector2(b.get_center().x, b.position.y + b.size.y * 0.66)
	var rr := b.size.y * 0.62           # pixels for the full range
	var rng: float = s.range_m() if s else 40000.0
	var hdg: float = ac.heading_deg
	var rot := 0.0 if sa_north_up else -deg_to_rad(hdg)
	# range rings and compass ticks
	draw_arc(c, rr, 0, TAU, 96, GRN_DIM, 1.5)
	draw_arc(c, rr * 0.5, 0, TAU, 64, GRN_DIM, 1.0)
	for k in 36:
		var a := deg_to_rad(k * 10.0) + rot
		var d := Vector2(sin(a), -cos(a))
		draw_line(c + d * rr, c + d * (rr - (14.0 if k % 3 == 0 else 7.0)), GRN, 1.5)
		if k % 9 == 0:
			_text(c + d * (rr + 16.0), ["N", "E", "S", "W"][k / 9], 20, GRN)
	if s:
		_text(Vector2(b.end.x - 8, b.end.y - 16), "RNG " + s.range_label(), 22, GRN, 1)
	# world (x east, z south) -> map pixels
	var to_px := func(world: Vector3) -> Vector2:
		var rel := world - ac.global_position
		var v := Vector2(rel.x, rel.z) / rng * rr
		return c + v.rotated(rot)
	# home airfield
	var hp: Vector2 = to_px.call(HOME)
	if b.has_point(hp):
		draw_rect(Rect2(hp - Vector2(8, 8), Vector2(16, 16)), WHITE, false, 2.0)
		draw_line(hp - Vector2(0, 12), hp + Vector2(0, 12), WHITE, 2.0)
	# autopilot heading
	var ap = ac.get("autopilot")
	if ap and ap.engaged:
		var a := deg_to_rad(float(ap.hdg_tgt)) + rot
		draw_dashed_line(c, c + Vector2(sin(a), -cos(a)) * rr, CYAN, 1.5, 10.0)
	# tracks
	if s:
		for k in s.tracks:
			var t: Dictionary = s.tracks[k]
			var radar: bool = s.is_radar(t)
			if not radar and not s.is_dl(t):
				continue
			var p: Vector2 = to_px.call(t.pos)
			if not b.has_point(p):
				continue
			var col := _iff_col(t)
			var v: Vector3 = t.vel
			var trot := 0.0
			if v.length() > 20.0:
				trot = atan2(v.x, -v.z) + rot
				draw_line(p, p + Vector2(sin(trot), -cos(trot)) * 28.0, col, 2.0)
			if t.iff == "friendly":
				draw_arc(p, 9.0, 0, TAU, 20, col, 2.0)
			else:
				_tri(p, 11.0, radar, col, trot)
			_text(p + Vector2(15, 12), _alt_text(t.pos.y), 18, col, -1)
			if k == s.lock_id:
				draw_rect(Rect2(p - Vector2(17, 17), Vector2(34, 34)), WHITE, false, 2.5)
	# own jet
	var own_rot := 0.0 if not sa_north_up else deg_to_rad(hdg)
	var pts := PackedVector2Array([Vector2(0, -16), Vector2(10, 10), Vector2(0, 5), Vector2(-10, 10), Vector2(0, -16)])
	for i in pts.size():
		pts[i] = c + pts[i].rotated(own_rot)
	draw_polyline(pts, WHITE, 2.5)
	_text(Vector2(b.position.x + 6, b.position.y + 16), "%03d" % (int(round(hdg)) % 360), 22, GRN, -1)


# ---- systems
func _bar(r: Rect2, frac: float, col: Color, label: String, value: String) -> void:
	draw_rect(r, GRN_DIM, false, 2.0)
	var f := clampf(frac, 0.0, 1.0)
	draw_rect(Rect2(Vector2(r.position.x + 3, r.end.y - 3 - (r.size.y - 6) * f), Vector2(r.size.x - 6, (r.size.y - 6) * f)), col)
	_text(Vector2(r.get_center().x, r.position.y - 16), label, 18, GRN)
	_text(Vector2(r.get_center().x, r.end.y + 16), value, 20, WHITE)


func _page_sys() -> void:
	var b := _body()
	var narrow := size.x < 700.0
	var rpm: float = ac.rpm
	var eng: float = ac.engine
	var ab := eng > 0.85
	var bw := 34.0 if narrow else 44.0
	var x0 := b.position.x + 10.0
	var top := b.position.y + 56.0
	var hgt := b.size.y * (0.4 if narrow else 0.5)
	# engines: RPM and EGT, left and right
	_text(Vector2(x0 + bw * 2.0 + 12, top - 30), "ENG", 22, WHITE, 0, true)
	for k in 2:
		_bar(Rect2(Vector2(x0 + k * (bw + 10), top), Vector2(bw, hgt)), rpm / 110.0, RED if ab else GRN, "N" + ["L", "R"][k], str(int(round(rpm))))
	var egt := 350.0 + eng * 520.0 + (180.0 if ab else 0.0)
	for k in 2:
		_bar(Rect2(Vector2(x0 + (k + 2) * (bw + 10) + 14, top), Vector2(bw, hgt)), egt / 1100.0, YEL if egt > 900.0 else GRN, "T" + ["L", "R"][k], str(int(round(egt))))
	# fuel
	var fuel: float = ac.fuel_kg
	var cap: float = ac.spec.fuel_capacity if ac.get("spec") else 9400.0
	var fx := x0 + 4 * (bw + 10) + 40.0
	if narrow:
		fx = x0
		top = b.position.y + hgt + 110.0
	_bar(Rect2(Vector2(fx, top), Vector2(bw, hgt)), fuel / cap, RED if fuel < 1200.0 else GRN, "FUEL", "%d" % int(round(fuel * (2.20462 if _imp() else 1.0))))
	var ff: float = ac.fuel_flow
	var endur := fuel / maxf(ff, 0.01) / 60.0
	var tx := fx + bw + 24.0
	_text(Vector2(tx, top + 10), "LB" if _imp() else "KG", 18, GRN_DIM, -1)
	_text(Vector2(tx, top + 40), "FF %d" % int(round(ff * 3600.0 * (2.20462 if _imp() else 1.0))), 20, GRN, -1)
	_text(Vector2(tx, top + 68), "END %d MIN" % int(clampf(endur, 0.0, 999.0)), 20, GRN, -1)
	_text(Vector2(tx, top + 96), "THR %d%%" % int(round(float(ac.throttle) * 100.0)), 20, GRN, -1)
	# systems: hydraulics, gear, flaps, airbrake, canopy
	var sy := b.end.y - (150.0 if narrow else 120.0)
	var sx := b.position.x + 10.0
	var items := [["HYD1", true, "280"], ["HYD2", true, "280"], ["GEAR", ac.gear_down, "DN" if ac.gear_down else "UP"],
		["FLAP", ac.flaps, "DN" if ac.flaps else "UP"], ["A/BRK", ac.airbrake, "OUT" if ac.airbrake else "IN"],
		["CNPY", ac.canopy_open, "OPEN" if ac.canopy_open else "SHUT"]]
	var per_row := 3 if narrow else 6
	var cw := (b.size.x - 20.0) / per_row
	for i in items.size():
		var it: Array = items[i]
		var p := Vector2(sx + (i % per_row) * cw, sy + (i / per_row) * 62.0)
		var warn: bool = it[0] == "CNPY" and it[1]
		var col := YEL if warn else (GRN if it[1] else GRN_DIM)
		draw_rect(Rect2(p, Vector2(cw - 10, 50)), col, false, 2.0)
		_text(p + Vector2((cw - 10) * 0.5, 15), it[0], 17, GRN)
		_text(p + Vector2((cw - 10) * 0.5, 36), it[2], 19, WHITE if not warn else YEL, 0, true)
	_text(Vector2(b.end.x - 6, b.position.y + 12), "G %.1f" % float(ac.g_load), 22, WHITE, 1, true)


# ---- weapons
## Top view of the Su-27 in metres (x right, y aft), right half: mirrored for the left.
const PLANFORM := [Vector2(0, -11.9), Vector2(0.7, -9.0), Vector2(1.0, -6.0), Vector2(1.8, -4.0), Vector2(2.2, -0.6),
	Vector2(7.4, 3.0), Vector2(7.4, 4.9), Vector2(2.2, 5.7), Vector2(2.3, 7.4), Vector2(4.95, 10.0), Vector2(4.95, 10.95),
	Vector2(1.9, 10.6), Vector2(1.0, 10.9), Vector2(0, 10.5)]


func _stores():
	return ac.get("stores")


func _page_wpn() -> void:
	var b := _body()
	var st = _stores()
	if st == null or st.stations.is_empty():
		_text(b.get_center(), "NO STORES", 30, GRN, 0, true)
		return
	_label("L0", "SEL ▲")
	_label("L1", "SEL ▼")
	var on_ground: bool = bool(ac.get("on_ground")) or bool(ac.get("wow"))
	_label("L2", "LOAD", false, GRN if on_ground else GRN_DIM)
	var narrow := size.x < 700.0
	var area := Rect2(b.position + Vector2(0, 6), Vector2(b.size.x, b.size.y * (0.62 if narrow else 0.7)))
	var sc := minf(area.size.x / 17.0, area.size.y / 24.5)
	var c := area.get_center() + Vector2(0, -0.6 * sc)
	var pts := PackedVector2Array()
	for p in PLANFORM:
		pts.append(c + p * sc)
	for i in range(PLANFORM.size() - 1, -1, -1):
		pts.append(c + Vector2(-PLANFORM[i].x, PLANFORM[i].y) * sc)
	draw_polyline(pts, GRN_DIM, 2.0)
	wpn_sel = clampi(wpn_sel, 0, st.stations.size() - 1)
	for i in st.stations.size():
		var sd: Dictionary = st.stations[i]
		var ax: Array = sd.axis
		var p := c + Vector2(-float(ax[0]), float(ax[1])) * sc     # model +x is the jet's left
		var store: String = st.loadout.get(int(sd.id), "")
		var sel: bool = i == wpn_sel
		var col := WHITE if sel else (GRN if store != "" else GRN_DIM)
		if store != "":
			var info: Dictionary = st.info(store)
			var fox := int(info.get("fox", 0))
			# a little missile: long for the R-27 family, short for R-73 / R-77, coloured by Fox number
			var ln := (4.2 if store.begins_with("R-27") else 3.0) * sc * 0.5
			var mc: Color = col if sel else [GRN, YEL, CYAN, WHITE][clampi(fox, 0, 3)]
			draw_line(p - Vector2(0, ln), p + Vector2(0, ln), mc, 5.0)
			draw_line(p + Vector2(-5, ln - 4), p + Vector2(5, ln - 4), mc, 2.0)
		else:
			draw_rect(Rect2(p - Vector2(5, 5), Vector2(10, 10)), col, false, 2.0)
		if sel:
			draw_rect(Rect2(p - Vector2(12, 3.0 * sc), Vector2(24, 6.0 * sc)), WHITE, false, 2.0)
		_text(p + Vector2(0, -2.6 * sc), str(int(sd.id)), 15, col)
	# selected station and the inventory
	var cur: Dictionary = st.stations[wpn_sel]
	var cs: String = st.loadout.get(int(cur.id), "")
	var y := area.end.y + 22.0
	_text(Vector2(b.position.x + 6, y), "STA %d  %s" % [int(cur.id), String(cur.name)], 20, WHITE, -1, true)
	_text(Vector2(b.position.x + 6, y + 26), (cs + "  " + st.describe(cs)) if cs != "" else "EMPTY", 20, GRN if cs != "" else GRN_DIM, -1)
	if not on_ground:
		_text(Vector2(b.end.x - 6, y), "LOAD ON GROUND", 15, GRN_DIM, 1)
	var inv := {}
	for sid in st.loadout:
		var k: String = st.loadout[sid]
		if k != "":
			inv[k] = int(inv.get(k, 0)) + 1
	var line := PackedStringArray()
	for k in inv:
		line.append("%s x%d" % [k, inv[k]])
	_text(Vector2(b.position.x + 6, b.end.y - 34), "  ".join(line), 15 if narrow else 18, GRN, -1)
	_text(Vector2(b.position.x + 6, b.end.y - 10), "GUN 150", 18, GRN, -1)


# ---- electronic warfare
func _page_ew() -> void:
	var b := _body()
	_label("T0", "AUTO" if cmds_auto else "MAN", cmds_auto)
	var c := b.get_center() + Vector2(0, -10)
	var rr := minf(b.size.x, b.size.y) * 0.42
	draw_arc(c, rr, 0, TAU, 72, GRN_DIM, 2.0)
	draw_arc(c, rr * 0.5, 0, TAU, 48, GRN_DIM, 1.5)
	for k in 12:
		var a := TAU * k / 12.0
		draw_line(c + Vector2(sin(a), -cos(a)) * rr, c + Vector2(sin(a), -cos(a)) * (rr - 10.0), GRN, 2.0)
	draw_line(c - Vector2(8, 0), c + Vector2(8, 0), GRN, 2.0)
	draw_line(c - Vector2(0, 8), c + Vector2(0, 8), GRN, 2.0)
	# threats: hostile fighters within 80 km whose nose points at us (their radar is the threat)
	var s = ac.get("sensors")
	var n := 0
	if s:
		for k in s.tracks:
			var t: Dictionary = s.tracks[k]
			if t.iff == "friendly" or not is_instance_valid(t.node):
				continue
			var tn: Node3D = t.node
			var to_me: Vector3 = ac.global_position - tn.global_position
			if to_me.length() > 80000.0:
				continue
			var fwd: Vector3 = -tn.global_basis.z
			if t.vel.length() > 20.0:
				fwd = (t.vel as Vector3).normalized()
			if fwd.dot(to_me.normalized()) < cos(deg_to_rad(60.0)):
				continue
			var r: Array = s.relative(tn.global_position)
			var a := deg_to_rad(r[1])
			var dist := clampf(1.0 - r[0] / 80000.0, 0.15, 1.0)
			var p := c + Vector2(sin(a), -cos(a)) * rr * (1.05 - dist * 0.85)
			var flash := fmod(_t, 0.6) < 0.4
			_text(p, "29", 26, RED if flash else Color(RED, 0.4), 0, true)
			n += 1
	_text(Vector2(b.position.x + 6, b.position.y + 16), "THREATS %d" % n, 20, RED if n > 0 else GRN, -1)
	_text(Vector2(b.position.x + 6, b.end.y - 44), "CHAFF 32", 20, GRN, -1)
	_text(Vector2(b.position.x + 6, b.end.y - 18), "FLARE 32", 20, GRN, -1)
